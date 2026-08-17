#!/usr/bin/env bash
#
# Build the Tenth Edition SOURCE DISK.  Phase B3.0.
#
#	tools/v10-srcdisk.sh [v8-image]
#
# Produces work/v10gold/ipnx-v10-src.img: an RA81 carrying the source the
# bootstrap compiles, mounted on the V10 machine as unit 1 at /n/v10.
#
# WHY A DISK AND NOT netfs.  The V8 machine reads the whole 243 MB tree off a
# netfs share and never copies it, which is much better than this -- and it is
# not available on V10, for two independent reasons, either of which alone
# would settle it:
#
#   * seki has no netfs mount slots.  lsys/astro/seki.m configures
#     `netafs 0' and `netbfs 0' -- the network filesystem types are compiled
#     in with ZERO instances, so there is nothing to mount onto.
#   * SIMH's vax750 has no Interlan.  `show devices' lists XU (DEUNA,
#     disabled) and nothing else; libsimh/patches/pdp11_il.c models the
#     NI1010 for the 780 build.  seki's own config DOES have the card
#     (`ni1010a 0 ub 0 reg 0164000 vec 0340'), so this half is ours to fix,
#     not Bell Labs' -- but it is not fixed today.
#
# WHY ITS OWN IMAGE AND NOT THE GOLDEN'S SPARE PARTITIONS.  ra_sizes[] leaves
# partitions d and e (122 MB each) unused, so there is room.  But the golden
# takes half an hour to rebuild and this disk will be rebuilt whenever the
# source subset or a makefile changes, and coupling the two would make every
# makefile edit cost a golden.  Separate images, separate lifetimes.
#
# WHAT IS ON IT.  558 files, 4.7 MB -- what stages 1 to 3 compile, and no
# more.  The full tree is 306 MB and 22,254 non-binary files, which does not
# fit in a 122 MB partition and would take hours to copy a file at a time.
#
#	/src/cmd/{yacc,ccom,as,cpp,c2}   the compiler, from source
#	/src/cmd/{cc,ld,halt,sleep}.c    the loose ones
#	/src/libc                        stage 2
#	/ours                            our overlay (v10/src)
#	/mk                              our generated makefiles
#
# THE 120 MB CEILING APPLIES HERE TOO, and for the same reason as the golden:
# V8 is what writes this filesystem, and V8's sys/filsys.h has only the R and
# B arms of the union -- no N -- so a filesystem over MAXSMALL blocks
# (961*32 = 30752) is one V8 cannot read back.  This one is well under.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v8clone.sh"
source "$ROOT/tools/norun.sh"

# THIS SCRIPT IS THE WRITER IN THE 2026-08-17 OVERLAP, so the guard belongs
# here most of all: it ends by zeroing and rebuilding
# work/v10gold/ipnx-v10-src.img, and a stage-2 run had that file attached as
# rq1 at the time.  It boots a vax780 while stage 2 runs a vax750, so neither
# one's `pgrep' saw the other.  See tools/norun.sh.
no_other_sims || exit 1

TPORT="${TPORT:-9270}"; OPORT="${OPORT:-9271}"; MPORT="${MPORT:-9272}"
GOLD="$ROOT/work/v10gold"
NETFSD="$ROOT/netfs/.build/release/netfsd"
PIDS=()

# The filesystem goes on partition c, whose offset ra_sizes[] fixes at 30720
# sectors.  16384 blocks of 4096 is 64 MB -- four times what the source needs,
# room for the object trees later, and half of MAXSMALL.
SRC_OFFSET=30720
SRC_BLOCKS=16384
SRC_SECTORS=$(( SRC_BLOCKS * 8 ))

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    done
    true
}
trap cleanup EXIT

[[ -d "$ROOT/work/v10" ]] || { echo "v10-srcdisk: no work/v10 -- run tools/v10-import.py"; exit 1; }
pgrep -x vax780 >/dev/null && { echo "v10-srcdisk: a vax780 is already running"; exit 1; }

python3 "$ROOT/tools/v10-overlay.py" --check || { echo "regenerate the overlay first"; exit 1; }
python3 "$ROOT/v10/mk/mkdep.py"      --check || { echo "regenerate the makefiles first"; exit 1; }
python3 "$ROOT/tools/v10-where.py"   --check || { echo "regenerate where.txt first"; exit 1; }

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) >/dev/null || exit 1

mkdir -p "$GOLD"
echo "== creating the partition file ($SRC_BLOCKS blocks, $((SRC_BLOCKS*4096/1048576)) MB) =="
dd if=/dev/zero of="$ROOT/work/myv8/v10src.part" bs=512 count=$SRC_SECTORS 2>/dev/null

IMG=$(v8_clone "${1:-rp07new}" srcdisk) || exit 1

serve() { "$NETFSD" -p "$1" "$2" > "$ROOT/work/netfs-$3.log" 2>&1 & PIDS+=($!); }
serve "$TPORT" "$ROOT/work/v10"   v10stree
serve "$OPORT" "$ROOT/v10/src"    v10sours
serve "$MPORT" "$ROOT/v10/mk/gen" v10smk
sleep 1
for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || { echo "netfsd died"; tail -5 "$ROOT"/work/netfs-v10s*.log; exit 1; }
done

echo "== driving the guest =="
expect "$ROOT/tools/v10-srcdisk.exp" "$IMG" "$TPORT" "$OPORT" "$MPORT" "$SRC_BLOCKS" 2>&1 \
    | tee "$ROOT/work/v10-srcdisk.log"
rc=${PIPESTATUS[0]}

OUT="$GOLD/ipnx-v10-src.img"
echo
echo "== assembling $OUT =="
# CHECKED AGAIN, HERE, and not only at the top.  The run above takes minutes,
# and the guard that matters is the one held at the moment of the write: a
# stage-2 run started meanwhile would have this file open right now.  The
# top-of-script check cannot see the future; this one can see the present.
claim_images "$OUT" || exit 1
# Sized to the whole RA81 so SIMH's autosize picks RA81 rather than guessing
# from a short file -- the same reason the golden is full-sized.
dd if=/dev/zero of="$OUT" bs=512 count=891072 2>/dev/null
dd if="$ROOT/work/myv8/v10src.part" of="$OUT" bs=512 seek=$SRC_OFFSET conv=notrunc 2>/dev/null
printf '   src   at sector %6d  (%s)\n' $SRC_OFFSET "$(du -h "$ROOT/work/myv8/v10src.part" | cut -f1)"
printf '   image %s\n' "$(du -h "$OUT" | cut -f1)"
echo "   sha256 $(shasum -a 256 "$OUT" | cut -c1-16)"
echo "== v10-srcdisk exit $rc =="
exit "$rc"
