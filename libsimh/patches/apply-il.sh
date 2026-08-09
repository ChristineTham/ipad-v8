#!/bin/bash
# Add the Interlan NI1010 (IL) device to a clean open-simh checkout.
#
# The checkout under work/opensimh is cloned by libsimh/build-xcframework.sh
# and can be blown away at any time, so the device and the four integration
# edits live here in the repo and are applied on demand. Idempotent: running
# it twice is a no-op.
#
#   libsimh/patches/apply-il.sh [path-to-opensimh]
#
# Why these four places:
#   vax780_defs.h    interrupt classes -- IL needs two, and BR5 is full
#   vax780_syslist.c the device has to be in sim_devices[] to exist at all
#   pdp11_io_lib.c   autoconfigure has to put it at 0164040, where V8 looks
#   makefile         and it has to be compiled into the VAX780 target
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIMH="${1:-$ROOT/work/opensimh}"
SRC="$ROOT/libsimh/patches/pdp11_il.c"

[ -d "$SIMH/VAX" ] || { echo "apply-il: $SIMH is not an open-simh checkout" >&2; exit 1; }
[ -f "$SRC" ]      || { echo "apply-il: missing $SRC" >&2; exit 1; }

cp "$SRC" "$SIMH/PDP11/pdp11_il.c"
echo "apply-il: copied pdp11_il.c"

python3 - "$SIMH" <<'PY'
import sys, pathlib

simh = pathlib.Path(sys.argv[1])
changed = []

def edit(relpath, anchor, addition, marker):
    p = simh / relpath
    s = p.read_text()
    if marker in s:
        return False
    if anchor not in s:
        sys.exit(f"apply-il: anchor not found in {relpath}: {anchor!r}")
    p.write_text(s.replace(anchor, anchor + addition, 1))
    changed.append(relpath)
    return True

# 1. Interrupt classes. BR5 (IPL 0x15) has all 16 bits allocated, so IL's two
#    interrupts go on BR4 at bits 8 and 9. They must be consecutive: SIMH maps
#    a multi-vector DIB's ack routines to consecutive bits from IVCL's base.
#    BR4 vs BR5 costs nothing here -- V8's driver guards with spl6(), which
#    blocks both.
edit("VAX/vax780_defs.h",
     "#define INT_V_TDTX      7\n",
     "#define INT_V_ILR       8                               /* Interlan NI1010 rcv */\n"
     "#define INT_V_ILC       9                               /* Interlan NI1010 cmd */\n",
     "INT_V_ILR")

edit("VAX/vax780_defs.h",
     "#define INT_UW          (1u << INT_V_UW)\n",
     "#define INT_ILR         (1u << INT_V_ILR)\n"
     "#define INT_ILC         (1u << INT_V_ILC)\n",
     "#define INT_ILR ")

edit("VAX/vax780_defs.h",
     "#define IPL_UW          (0x15 - IPL_HMIN)\n",
     "#define IPL_ILR         (0x14 - IPL_HMIN)\n"
     "#define IPL_ILC         (0x14 - IPL_HMIN)\n",
     "#define IPL_ILR ")

# 2. Device list.
edit("VAX/vax780_syslist.c",
     "extern DEVICE xu_dev, xub_dev;\n",
     "extern DEVICE il_dev;\n",
     "extern DEVICE il_dev;")

edit("VAX/vax780_syslist.c",
     "    &xu_dev,\n",
     "    &il_dev,\n",
     "    &il_dev,")

# 3. Autoconfigure: fixed CSR 0164040 -- what V8's config declares and what
#    dev/il.c's ilstd[] records as the board's standard address. auto_tab
#    addresses are relative to the base of the I/O page, so that is written
#    04040 here (compare CH11 at 0164140, which appears as 04140); using the
#    full 0164040 puts the device outside the 8 KB page entirely. The vector
#    floats -- V8 discovers it in ilprobe via cvec. amod is 0 so adding this
#    entry cannot shift any other device's floating CSR.
edit("PDP11/pdp11_io_lib.c",
     "    { { \"XU\", \"XUB\" },   1,  1,  8, 4, \n        {014510}, {0120} },                             /* DEUNA */\n",
     "    { { \"IL\" },          1,  2,  0, 8, \n"
     "        {04040} },                                      /* Interlan NI1010 0164040 - fx CSR, flt VEC */\n",
     '{ { "IL" }')

print("apply-il: edited " + (", ".join(changed) if changed else "nothing (already applied)"))
PY

# 4. Build. Done separately because it is a substitution inside one variable's
#    value rather than an insertion after a unique anchor.
if ! grep -q 'pdp11_il.c' "$SIMH/makefile"; then
    python3 - "$SIMH" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]) / "makefile"
s = p.read_text()
# Only the VAX780 file list, identified by the VAX780_OPT line that follows it.
i = s.index("VAX780 = ")
j = s.index("VAX780_OPT", i)
block = s[i:j]
assert "pdp11_ch.c" in block, "apply-il: unexpected VAX780 file list"
s = s[:i] + block.replace("${PDP11D}/pdp11_ch.c",
                          "${PDP11D}/pdp11_ch.c ${PDP11D}/pdp11_il.c", 1) + s[j:]
p.write_text(s)
print("apply-il: added pdp11_il.c to the VAX780 build")
PY
fi

echo "apply-il: done"
