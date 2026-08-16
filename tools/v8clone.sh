# tools/v8clone.sh -- never boot the golden.  Source this; do not run it.
#
#	source "$(dirname "${BASH_SOURCE[0]}")/v8clone.sh"
#	IMG=$(v8_clone "${1:-rp07new}" selftest) || exit 1
#
# WHY THIS EXISTS.  CLAUDE.md has said since Track S:
#
#	Run every guest harness against a CLONE, never the golden.  Booting a
#	disk mounts it, and mounting rewrites the superblock -- so a clean,
#	successful, properly halted run still leaves the image with a different
#	hash than the one in git.
#
# Three harnesses defaulted to booting `rp07new' -- the golden -- directly:
# net-selftest.sh, netfs-latency.sh and boot-newdisk.sh.  net-selftest.sh's own
# header even claimed the opposite, that "a pass leaves the disk exactly as it
# found it".  It does not, and on 2026-08-16 a single net-selftest run (used to
# check an unrelated change to v8drive.exp) moved the golden from 8ccbf05614e8
# to 396f994339f8.
#
# NOTHING WAS DAMAGED and that is exactly what makes it dangerous.  The run
# halted cleanly, every assertion passed, and the exit status was 0.  The only
# thing that noticed was tools/app-check.sh, comparing the golden against the
# committed image -- which is precisely why image/ipnx-v8-rp07.img.xz is in git
# (`tools/image-pack.py unpack' put it back in eight seconds).
#
# So the rule lives here now rather than in three headers that can each be
# forgotten separately, the same way v8drive.exp holds the console rule.
#
# `cp -c' is an APFS clone: no time, no space until the copies diverge.  The
# clone is deliberately LEFT BEHIND -- if a harness found something, the disk
# it found it on should still exist to look at.

# v8_clone <source-image> [tag]  ->  prints the clone's name
#
# Both names are bare, relative to work/myv8, because that is what v8drive.exp
# expects to be handed.
v8_clone() {
    local src="$1" tag="${2:-run}" media rc
    media="$(cd "$(dirname "${BASH_SOURCE[0]}")/../work/myv8" 2>/dev/null && pwd)"
    if [[ -z "$media" ]]; then
        echo "v8_clone: no work/myv8" >&2
        return 1
    fi
    if [[ ! -f "$media/$src" ]]; then
        echo "v8_clone: no image '$src' in $media" >&2
        return 1
    fi

    local dst="${src}.${tag}"
    rm -f "$media/$dst"
    cp -c "$media/$src" "$media/$dst"
    rc=$?
    if (( rc != 0 )); then
        # Not fatal by itself -- a non-APFS volume has no clone support and
        # falls back to a real 492 MB copy -- but say so, because the run is
        # then minutes slower for a reason nothing else would explain.
        echo "v8_clone: cp -c failed ($rc); falling back to a full copy" >&2
        cp "$media/$src" "$media/$dst" || return 1
    fi
    echo "$dst"
}
