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
source "$ROOT/tools/srcid.sh"

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
# sectors and whose size it fixes at 249848 -- 31,231 blocks of 4096, so the
# partition itself is the first ceiling and MAXSMALL (30,752) is barely under
# it.
#
# RAISED FROM 16384 FOR K10.  16,384 blocks is 64 MB, which held stage 1-3's
# 4.7 MB with room to spare; the world adds 14.4 MB of command sources, and
# 24,576 blocks (96 MB) keeps the same generous margin rather than discovering
# the limit in the middle of a two-hour copy.  Still under MAXSMALL, which
# still matters: V8 MOUNTS this filesystem to populate it, and V8's filsys.h
# has no N arm of the superblock union, so a filesystem over 30,752 blocks is
# one the machine writing it cannot read back.  That ceiling is K11's to
# remove, by having V10 write its own disks; it is not in K10's way.
#
# Inodes are the other limit and are fine: mkbitfs gives (size-2)/65 i-list
# blocks at 64 inodes each, so 24,576 blocks is 24,064 inodes against roughly
# 3,700 files.
SRC_OFFSET=30720
SRC_BLOCKS=24576
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

# A FAILED RUN MUST NOT LEAVE A CURRENT STAMP ON AN INCOMPLETE IMAGE, and this
# script did exactly that until 2026-08-18: it assembled and called srcid_write
# unconditionally and only then exited with the guest's status.  So a run that
# bailed -- that day, SLiRP answering `attach il nat:' with `Sockets: bind error
# 13 - Permission denied' hundreds of times, after which the guest quit at sim>
# without halting -- produced a possibly-truncated source disk carrying a stamp
# that says it holds the current v10/mk/gen and v10/src.  srcid_check would then
# PASS it, and the next stage would compile a partial tree and report failures
# that read as findings about the tape.
#
# Deleting the stamp is not the fix: a MISSING .id is deliberately only a warning
# (see tools/srcid.sh), so it would not stop anything.  Not writing the image at
# all is the fix.  The previous image and its stamp stay, and are then judged on
# their own merits -- current, and usable; or stale, and refused.
#
# This is the same argument as the assemble-time claim_images below: the value of
# a guard is what it refuses, and a guard that cannot fire is not a guard.
if [[ "$rc" != 0 ]]; then
    echo
    echo "== NOT assembling $OUT =="
    echo "   The guest run failed (exit $rc), so what it copied cannot be"
    echo "   trusted -- CLAUDE.md's rule is that a machine which did not halt"
    echo "   cleanly has a damaged disk, and this one is a build product, so"
    echo "   there is nothing to recover and nothing to lose."
    echo "   The existing source disk and its .id stamp are left untouched:"
    echo "   a later stage will use it if it is current and refuse it if not."
    echo "   Read work/v10-srcdisk.log, fix the cause, and run this again."
    echo "== v10-srcdisk exit $rc =="
    exit "$rc"
fi

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
# THE STAMP, so a later stage can tell whether this image carries the build
# description that is in the repo NOW.  See tools/srcid.sh -- the guest reads its
# makefiles and our overlay off this disk, so regenerating them in the repo is
# invisible to it and a stale disk produces a clean, wrong run.
srcid_write "$OUT"
echo "== v10-srcdisk exit $rc =="
exit "$rc"
