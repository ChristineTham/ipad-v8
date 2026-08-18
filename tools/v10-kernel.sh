#!/usr/bin/env bash
#
# K7: build a Tenth Edition kernel for the VAX-11/780, on V10.
#
#	tools/v10-kernel.sh [stage1-image] [src-image]
#
# The recipe is lsys/lib/mk.star's, and it is five commands -- mkconf, as, cc,
# cc, ld -- because the kernel is on the tape as prebuilt per-subsystem
# archives and only the generated conf.c and a vers.c stamp are compiled.  See
# docs/v10-restoration.md K6/K7.
#
# Starts from the STAGE-1 machine, so the compiler is V10's own rebuilt by V10.
# Boots a clone; the source disk is read, never written (mkconf writes beside
# its config, so the tree is copied to local disk first).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"
source "$ROOT/tools/srcid.sh"

# THE GUARD THIS HARNESS DID NOT HAVE, AND K12.2 IS WHY IT NEEDS ONE.  Until the
# overlay carried kernel sources, this script read only the tape's `lsys/' and our
# `ipnx780.m' off the source disk, and a stale disk cost nothing but a slightly
# old config.  It now compiles `v10/src/lsys/**.c' into the tape's own archives,
# so a stale disk silently links the PREVIOUS generation of a kernel patch and
# reports a clean 22/22 about it -- the exact failure mode srcid was written for,
# in the one harness that lacked it.  v10-link.sh shipped without its source line
# once and announced "the source disk is stale" about a disk four minutes old; a
# guard that cannot run must not be mistaken for one that passed.
for fn in srcid_check no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || {
        echo "v10-kernel: $fn is not defined -- a tools/*.sh source line is missing."
        exit 2
    }
done

GOLD="${1:-ipnx-v10-ra81.img.stage1}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"
LOG="$ROOT/work/v10-kernel.log"

[[ -f "$SRC" ]] || { echo "v10-kernel: no $SRC -- run tools/v10-srcdisk.sh"; exit 1; }
pgrep -f "BIN/vax750" >/dev/null && { echo "v10-kernel: a vax750 is already running"; exit 1; }
python3 "$ROOT/tools/v10-overlay.py" --check || { echo "regenerate the overlay first"; exit 1; }

srcid_check "$SRC" || {
    echo "v10-kernel: the source disk is stale -- bash tools/v10-srcdisk.sh"
    exit 1
}
no_overlap "$SRC" "$ROOT/work/v10gold/$GOLD" || exit 1

IMG=$(v10_clone "$GOLD" k7) || exit 1
echo "== K7: a 780 kernel on $(basename "$IMG") =="
expect "$ROOT/tools/v10-kernel.exp" "$IMG" "$SRC" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
# ld writes a partial a.out and THEN discovers an undefined symbol, so the file
# existing proves nothing.  A 780 kernel is hundreds of KB; anything under 100 KB
# is a failed link that happened to leave a file behind.
size=$(tr -d '\r' < "$LOG" | sed -n '/^KSIZE$/,/^KSIZEEND$/p' \
       | awk '$NF ~ /\.u$/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9][0-9][0-9]+$/) s=$i} END{print s+0}')
echo
echo "== the kernel =="
echo "   ipnx780.u is $size bytes"
if (( size > 100000 )); then
    echo "   -> plausible: a linked 780 kernel"
else
    echo "   -> NOT a kernel.  Under 100 KB means the link failed and left a file."
    rc=1
fi
echo
echo "   the kernel-build machine is $IMG"
echo "== v10-kernel exit $rc =="
exit "$rc"
