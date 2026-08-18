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

# THE LAYOUT, IN THE UNITS ra_sizes[] ACTUALLY USES, CONVERTED ONCE HERE.
#
# `ra_sizes[]' IS IN 512-BYTE SECTORS, NOT BLOCKS, and asking mkbitfs for 10,240
# *blocks* of partition `a' is asking for eight times the partition.  That is the
# V8 RP06 trap word for word -- CLAUDE.md: "RP06 partition `a' is 15,884 SECTORS,
# not blocks" -- on a different disk, and `tools/v10-free.py' had the conversion
# right in a comment the whole time.  It caught the error rather than the harness:
#
#	v10-free: s_fsize reads 0, which is not a size partition a can hold (max 1280)
#
# The numbers, therefore, and they explain the golden's own layout exactly:
#
#	part  sectors  offset   4K blocks       MB
#	a      10240        0       1280       5.0   root -- and the golden's root
#	                                             filesystem IS 1280 blocks, so
#	                                             Bell Labs sized it to the
#	                                             partition to the block
#	b      20480    10240       2560      10.0   swap, and dump shares it
#	c     249848    30720      31231     122.0   /usr -- the golden uses 30752,
#	                                             which is MAXSMALL exactly
#	h     891072        0     111384     435.1   the whole drive
#
# SO THERE ARE TWO FILESYSTEMS, WHICH IS NOT A CHOICE.  A 5 MB root cannot hold
# the 6.4 MB this run copies, and root cannot go anywhere else:
# `lsys/boot/README' requires /unix to be "in the filesystem beginning at the front
# of the boot device" and `star/uda.s' carries no partition offset, so root is the
# filesystem at sector 0 -- `a' or `h' and nothing else.  `h' overlaps swap (see
# v10-mkdisk.exp).  That leaves the layout V10 itself uses, which needs no kernel
# patch at all: root on `a', swap on `b', /usr on `c', mounted by the /etc/rc the
# golden already ships.
SECT_PER_BLK=8
RA_SECT_A=10240
ROOTPART="${ROOTPART:-a}"; USRPART="${USRPART:-c}"
ROOTBLKS="${ROOTBLKS:-$(( RA_SECT_A / SECT_PER_BLK ))}"   # 1280, the whole of `a'
USRBLKS="${USRBLKS:-30752}"                               # MAXSMALL, as the golden does
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
expect "$ROOT/tools/v10-mkdisk.exp" "$IMG" "$BLANK" "$TPORT" "$OPORT" "$MPORT" \
    "$ROOTBLKS" "$ROOTPART" "$USRBLKS" "$USRPART" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# THE HOST READS WHAT THE GUEST WROTE, because a full V10 filesystem SLEEPS rather
# than failing and no guest-side probe can see past that.
echo
echo "== what is actually on the disk V10 built =="
python3 "$ROOT/tools/v10-free.py" "$BLANK" "$ROOTPART" || rc=1
python3 "$ROOT/tools/v10-free.py" "$BLANK" "$USRPART" || rc=1
# BLOCK 0, READ FROM THE IMAGE.  The ROM jumps to offset 0xC inside it, so an
# all-zero block 0 is a HALT at PC 0000000D and nothing past it is ever read.
BB0=$(python3 -c "print(sum(1 for b in open('$BLANK','rb').read(512) if b))")
printf '   block 0: %s of 512 bytes non-zero%s\n' "$BB0" \
    "$( [[ "$BB0" == 0 ]] && echo '   <- NO BOOT BLOCK, it cannot boot' )"
[[ "$BB0" != 0 ]] || rc=1

# THE SIZE, AND THE TWO FREE READINGS AGAINST EACH OTHER.  This check used to
# assert `flag=1' -- K11's bitmap outside the superblock -- which was right for one
# whole-drive filesystem and is WRONG for a root on partition `a': 10,240 blocks is
# inside MAXSMALL (BITMAP*BITCELL = 961*32 = 30,752), so V10's own mkbitfs chooses
# smallfree() and flag reads 0, exactly as it does on the golden's own root and
# /usr.  Asserting flag=1 here would fail on a correct disk.  What IS load-bearing
# is that the filesystem is the size we asked for and that s_tfree agrees with the
# bitmap -- two readings from different places in the superblock, so a disagreement
# is real news rather than a restatement.
FREE=$(python3 "$ROOT/tools/v10-free.py" "$BLANK" "$ROOTPART" 2>/dev/null)
FS=$(printf '%s\n' "$FREE" | sed -n 's/^  filesystem size *\([0-9]*\) blocks.*/\1/p')
if [[ "$FS" != "$ROOTBLKS" ]]; then
    echo "== NO MEASUREMENT: root filesystem size reads '${FS:-nothing}', not $ROOTBLKS =="
    rc=1
fi
UFS=$(python3 "$ROOT/tools/v10-free.py" "$BLANK" "$USRPART" 2>/dev/null | \
      sed -n 's/^  filesystem size *\([0-9]*\) blocks.*/\1/p')
if [[ "$UFS" != "$USRBLKS" ]]; then
    echo "== NO MEASUREMENT: /usr filesystem size reads '${UFS:-nothing}', not $USRBLKS =="
    rc=1
fi
if printf '%s\n' "$FREE" | grep -q 'disagrees'; then
    echo "== NO MEASUREMENT: s_tfree and the bitmap disagree =="
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
