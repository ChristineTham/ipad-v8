# tools/v10clone.sh -- never boot the V10 golden either.  Source; do not run.
#
#	source "$(dirname "${BASH_SOURCE[0]}")/v10clone.sh"
#	IMG=$(v10_clone ipnx-v10-ra81.img stage1) || exit 1
#
# The sibling of tools/v8clone.sh, and the argument is identical: booting a
# disk mounts it, mounting rewrites the superblock, and a clean, successful,
# properly halted run therefore still leaves a different image than it found.
# On V8 that cost the golden its hash once, on a run made to check something
# else entirely -- see v8clone.sh for the whole story.
#
# IT IS SHARPER HERE, because the V10 machine writes more.  V8's harnesses
# mount a share and read; the bootstrap compiles, so every stage leaves object
# directories, installed binaries and a rewritten /etc behind by design.  A
# stage-1 run is SUPPOSED to modify its disk.  What must not happen is that it
# modifies the one other runs start from.
#
# There is no committed V10 image to restore from -- image/ipnx-v8-rp07.img.xz
# has no V10 counterpart yet -- so the only recovery is a full rebuild:
# tools/v10-golden.sh, about half an hour.  That makes cloning cheaper here
# than it is on V8, not more expensive.
#
# `cp -c' is an APFS clone: no time, no space until the copies diverge.  The
# clone is deliberately LEFT BEHIND, so a run that found something leaves the
# disk it found it on.

# v10_clone <source-image> [tag]  ->  prints the clone's ABSOLUTE path
#
# Absolute, unlike v8_clone's bare name: the V10 media directory holds the
# goldens (work/v10gold) while v10drive.exp's spawn happens in work/myv8, so a
# bare name would resolve against the wrong directory.  v10_boot accepts
# either, and an absolute path cannot be wrong.
v10_clone() {
    local src="$1" tag="${2:-run}" media rc
    media="$(cd "$(dirname "${BASH_SOURCE[0]}")/../work/v10gold" 2>/dev/null && pwd)"
    if [[ -z "$media" ]]; then
        echo "v10_clone: no work/v10gold -- run tools/v10-golden.sh" >&2
        return 1
    fi
    # Accept a bare name or a path; the answer is always absolute.
    case "$src" in
        /*) : ;;
        *)  src="$media/$src" ;;
    esac
    if [[ ! -f "$src" ]]; then
        echo "v10_clone: no image '$src'" >&2
        return 1
    fi

    local dst="${src}.${tag}"
    rm -f "$dst"
    cp -c "$src" "$dst"
    rc=$?
    if (( rc != 0 )); then
        # Not fatal -- a non-APFS volume has no clone support and falls back
        # to a real 435 MB copy -- but say so, because the run is then minutes
        # slower for a reason nothing else would explain.
        echo "v10_clone: cp -c failed ($rc); falling back to a full copy" >&2
        cp "$src" "$dst" || return 1
    fi
    echo "$dst"
}
