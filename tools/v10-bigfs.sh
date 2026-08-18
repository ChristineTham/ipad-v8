#!/usr/bin/env bash
# K11: make a full-capacity filesystem with V10's own tools, and check it.
#
#	bash tools/v10-bigfs.sh [stage1-image] [src-image]
#
# The ceiling being retired is V8's, not V10's -- see the header of
# tools/v10-bigfs.exp for the arithmetic.  The short form: every V10 disk so far
# was made BY V8, so it had to fit in V8's in-superblock bitmap and stopped at
# MAXSMALL = 961*32 = 30,752 blocks; V10's own mkbitfs writes the bitmap into its
# own blocks past that and does not run out until 31,457,280.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"
source "$ROOT/tools/srcid.sh"

# The functions this depends on, checked by name.  v10-link.sh shipped without
# its srcid.sh source line and then announced "the source disk is stale" about a
# disk built four minutes earlier -- a guard that cannot run must not report its
# own subject as the fault.
for fn in srcid_check no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || {
        echo "v10-bigfs: $fn is not defined -- a tools/*.sh source line is missing."
        exit 2
    }
done

GOLD="${1:-ipnx-v10-ra81.img.stage1}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"
BLANK="$ROOT/work/v10gold/ipnx-v10-big.img"
LOG="$ROOT/work/v10-bigfs.log"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-bigfs: no $GOLD in work/v10gold -- stages 1-3 build it."
    exit 1
}
python3 "$ROOT/v10/mk/mkdep.py" --check || {
    echo "v10-bigfs: the makefiles are stale -- run v10/mk/mkdep.py"
    exit 1
}
srcid_check "$SRC" || {
    echo "v10-bigfs: the source disk is stale -- bash tools/v10-srcdisk.sh"
    exit 1
}

# A FRESH, ZEROED RA81, RECREATED EVERY RUN.  `mkfs' does not clear data blocks,
# so a second run over the same file leaves the previous run's contents in what
# the new filesystem calls free space -- invisible to the guest and very visible
# to anything that reads the image, which is what this run's whole verification
# does.  891,072 sectors is the RA81's real size, and full-sizing it is also what
# makes SIMH's autosize pick RA81 rather than guessing from a short file.
echo "== creating a blank RA81 at $(basename "$BLANK") =="
rm -f "$BLANK" "$BLANK.id"
dd if=/dev/zero of="$BLANK" bs=512 count=891072 2>/dev/null
printf '   %s\n' "$(du -h "$BLANK" | cut -f1)"

no_overlap "$SRC" "$BLANK" "$ROOT/work/v10gold/$GOLD" || exit 1

IMG=$(v10_clone "$GOLD" k11) || exit 1
SRCIMG=$(v10_clone "$SRC" k11src) || exit 1
echo "== making a full-capacity filesystem on $(basename "$BLANK") =="

expect "$ROOT/tools/v10-bigfs.exp" "$IMG" "$SRCIMG" "$BLANK" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# ------------------------------------------- the host reads what the guest wrote ---
#
# THE DECISIVE CHECK IS HOST-SIDE, and it has to be.  A full V10 filesystem does
# not fail, it SLEEPS -- lsys/fs/alloc.c prints `file system full' and waits for
# space that is not coming -- so every guest-side probe blocks in the same alloc()
# as the thing it is checking.  tools/v10-free.py reads the superblock out of the
# image file, and for this run it must report the N arm: `flag=1', the bitmap in
# its own blocks, which is the whole thing K11 is about.
echo
echo "== what is actually on the disk =="
python3 "$ROOT/tools/v10-free.py" "$BLANK" h || rc=1

# The three claims, each read from the image rather than from the transcript.
if ! python3 "$ROOT/tools/v10-free.py" "$BLANK" h 2>/dev/null | grep -q 'flag=1'; then
    echo
    echo "== NO MEASUREMENT: the superblock does not carry an N-arm bitmap =="
    echo "   S_flag is 0, so mkbitfs took its smallfree() branch and the"
    echo "   filesystem is inside V8's old ceiling after all.  Either the block"
    echo "   count was under MAXSMALL (30,752) or the write did not happen."
    rc=1
fi
size=$(python3 "$ROOT/tools/v10-free.py" "$BLANK" h 2>/dev/null \
       | awk '/filesystem size/{print $3}')
if [[ -n "${size:-}" ]] && (( size <= 30752 )); then
    echo
    echo "== NO MEASUREMENT: $size blocks is not past the ceiling =="
    echo "   MAXSMALL is 30,752 blocks, so this proves nothing V8 could not do."
    rc=1
fi

echo
echo "== K11: THE CEILING WAS V8'S =="
printf "   V8's in-superblock bitmap caps a filesystem at   %6d blocks  120.1 MB\n" 30752
printf "   V10's own mkbitfs, out-of-superblock, caps at  %8d blocks  128 GB\n" 31457280
printf "   this filesystem                                  %6s blocks\n" "${size:-?}"
echo
echo "   the disk is $BLANK"
echo "   full transcript $LOG"
echo "== v10-bigfs exit $rc =="
exit "$rc"
