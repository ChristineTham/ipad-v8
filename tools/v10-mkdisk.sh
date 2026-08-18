#!/usr/bin/env bash
# K14: can V10 build a bootable disk of its own?
#
#	bash tools/v10-mkdisk.sh [k13-image]
#
# Rung 10's decisive experiment.  K11 proved V10 can MAKE a 111,384-block
# filesystem; this asks whether it can put a system in one and boot it.  No
# courier disk: the tape, our overlay and the generated makefiles all arrive over
# TCP, which is what K13 was for.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"

for fn in no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || {
        echo "v10-mkdisk: $fn is not defined -- a tools/*.sh source line is missing."
        exit 2
    }
done

GOLD="${1:-ipnx-v10-ra81.img.stage1.k102.k7.k13}"
BLANK="$ROOT/work/v10gold/ipnx-v10-made.img"
TPORT="${TPORT:-9290}"; OPORT="${OPORT:-9291}"; MPORT="${MPORT:-9292}"
NETFSD="$ROOT/netfs/.build/release/netfsd"
LOG="$ROOT/work/v10-mkdisk.log"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-mkdisk: no $GOLD -- bash tools/v10-netboot.sh builds it."
    exit 1
}
# NO srcid_check HERE, AND THAT IS THE POINT: this run reads no source disk at
# all.  The repository working tree IS the source, served live, so there is no
# stamp to disagree with.  The two --check calls below are what replace it.
python3 "$ROOT/tools/v10-overlay.py" --check || exit 1
python3 "$ROOT/v10/mk/mkdep.py"      --check || exit 1

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) >/dev/null || exit 1

# A FRESH ZEROED RA81 EVERY RUN.  mkbitfs does not clear data blocks, so a second
# run over the same file leaves the previous one's contents in what the new
# filesystem calls free space -- invisible to the guest, very visible to anything
# that reads the image, which is exactly what the verification below does.
echo "== creating a blank RA81 =="
rm -f "$BLANK" "$BLANK.id"
dd if=/dev/zero of="$BLANK" bs=512 count=891072 2>/dev/null

PIDS=()
serve() { "$NETFSD" -p "$1" -v "$2" > "$ROOT/work/netfs-$3.log" 2>&1 & PIDS+=($!); }
serve "$TPORT" "$ROOT/work/v10"      mktree
serve "$OPORT" "$ROOT/v10/src"       mkours
serve "$MPORT" "$ROOT/v10/mk/gen"    mkmk
sleep 1
for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || { echo "netfsd died"; tail -5 "$ROOT"/work/netfs-mk*.log; exit 1; }
done
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done' EXIT

no_overlap "$BLANK" "$ROOT/work/v10gold/$GOLD" || exit 1
IMG=$(v10_clone "$GOLD" k14) || exit 1

# THE BOOT BLOCK, HOST-SIDE AND BEFORE THE RUN, because that is how the one V10
# disk this project already boots gets one -- tools/v10-golden.sh:202:
#
#	dd if=.../lsys/boot/bb/4kb of="$OUT" bs=512 count=1 conv=notrunc
#
# Two guest-side attempts failed instead: reading `bb/4kb' off a share after
# `umount -a' gave `cp: I/O error', and `cp' to the block device left block 0 all
# zero -- 508 bytes at offset 0 is a read-modify-write of a 4096-byte buffer, which
# V10's cp may not do to a block special at all.  None of that needs answering: the
# block is 508 bytes of position-independent code at sector 0 and the host can
# place it.
#
# BEFORE the run, not after, because boot 2 -- the boot of the copy -- happens
# INSIDE the expect script, and a boot block written afterwards would be tested by
# nothing.  The risk is the opposite one: if `mkbitfs' zeroes sector 0 on its way
# past, this is lost.  That is exactly what the block-0 check below measures, so a
# wrong guess here reports itself instead of hiding.
echo "== placing the tape's own 4K boot block at sector 0 =="
dd if="$ROOT/work/v10/src/lsys/boot/bb/4kb" of="$BLANK" \
   bs=512 count=1 conv=notrunc 2>/dev/null

echo "== V10 builds a disk on $(basename "$BLANK") =="
expect "$ROOT/tools/v10-mkdisk.exp" "$IMG" "$BLANK" "$TPORT" "$OPORT" "$MPORT" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# THE HOST READS WHAT THE GUEST WROTE, because a full V10 filesystem SLEEPS rather
# than failing and no guest-side probe can see past that.
echo
echo "== what is actually on the disk V10 built =="
python3 "$ROOT/tools/v10-free.py" "$BLANK" h || rc=1
# BLOCK 0, READ FROM THE IMAGE.  The ROM jumps to offset 0xC inside it, so an
# all-zero block 0 is a HALT at PC 0000000D and nothing past it is ever read.
BB0=$(python3 -c "print(sum(1 for b in open('$BLANK','rb').read(512) if b))")
printf '   block 0: %s of 512 bytes non-zero%s\n' "$BB0" \
    "$( [[ "$BB0" == 0 ]] && echo '   <- NO BOOT BLOCK, it cannot boot' )"
[[ "$BB0" != 0 ]] || rc=1

if ! python3 "$ROOT/tools/v10-free.py" "$BLANK" h 2>/dev/null | grep -q 'flag=1'; then
    echo "== NO MEASUREMENT: no N-arm bitmap, so this is inside V8's old ceiling =="
    rc=1
fi

echo
echo "== K14: DID V10 BUILD A BOOTABLE DISK? =="
if [[ "$rc" == 0 ]]; then
    echo "   Yes.  A filesystem V10 made, filled and booted -- with its source"
    echo "   arriving over TCP and no courier disk anywhere in the run."
else
    echo "   Not yet.  The first NO names the step: the shares, mkbitfs, the"
    echo "   node, the copy, or the boot of the copy."
fi
echo "   the disk is $BLANK"
echo "   full transcript $LOG"
echo "== v10-mkdisk exit $rc =="
exit "$rc"
