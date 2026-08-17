# tools/srcid.sh -- is the source disk carrying the sources we just generated?
# Source; do not run.
#
#	source "$(dirname "${BASH_SOURCE[0]}")/srcid.sh"
#	srcid_write "$OUT"                  # after building the image
#	srcid_check "$SRC" || exit 1         # before booting with it attached
#
# WHY THIS EXISTS.  The V10 source disk is a BUILD ARTEFACT: v10-srcdisk.sh
# copies `v10/mk/gen/' and `v10/src/' onto an RA81 image, and every later stage
# reads them from there as /n/v10/mk and /n/v10/ours.  So regenerating a makefile
# in the repository changes NOTHING the guest sees, and there is no symptom --
# the run boots, compiles, asserts and reports, against the previous generation
# of the build description.
#
# IT COST A RUN ON 2026-08-17.  `setupshares.o' was made a named exclusion,
# libc.ord regenerated from 261 names to 260, everything committed -- and stage 2
# still reported
#
#	all 260 members compiled                     NO
#	member list+order = tape less 1 dropped      NO
#	install                                      NO
#
# because the guest was still walking the 261-name libc.ord on the disk.  Worse,
# the host and the guest then disagreed about the member list, so the summary's
# arithmetic mixed a 260-member total with a 118-member difference count read off
# a 261-member walk and printed a byte-identical figure that was true of neither.
#
# This is the same hazard CLAUDE.md already records about the app -- "it is in
# the golden, it will arrive on Reset" is not shipping it -- and it has the same
# answer: the artefact carries a record of its ORIGIN, and whoever consumes it
# compares.  The app writes `v8.disk.id' beside the embedded image; this writes
# `<image>.id' beside the source disk.
#
# WHAT GOES INTO THE DIGEST is what the image actually carries from the repo:
# the generated makefiles and order files, and our overlay.  Not the tarball --
# tools/v10-import.py --verify already covers that, and v10/MANIFEST is the
# committed record.  Not the harnesses, which are read from the repo at run time
# and are therefore never stale.
#
# A MISSING .id IS A WARNING, NOT A FAILURE.  An image built before this check
# existed has no stamp and is not necessarily wrong, so refusing it outright
# would strand a working source disk.  A stamp that DISAGREES is a failure,
# because that is the case we can prove.

# RESOLVED ONCE, AT SOURCE TIME, and absolutely.  Every caller sources this as
# "$ROOT/tools/srcid.sh" with an absolute $ROOT, so this is unambiguous here --
# whereas resolving it inside a function is not, and the failure is silent:
# `${BASH_SOURCE[0]}' is empty in a shell without it, `dirname ""' is `.', and
# the digest then covers a directory with no v10/ in it and comes out as the
# sha256 of NOTHING.  Two images stamped with that agree perfectly, so the guard
# would pass forever while checking nothing -- found by testing this file from an
# interactive zsh, which is exactly the accident it now cannot have.
SRCID_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-${ROOT:-.}/tools/x}")/.." && pwd)"

# srcid_digest [root]
#
# sha256 over the generated build description and our overlay.  `find | sort'
# rather than `shasum -a 256 dir', because directory order is not stable across
# filesystems and a digest that changes for no reason is a guard that gets
# switched off.  Paths are included, so a RENAME counts as a change.
#
# An EMPTY digest is refused rather than returned: it is the signature of a
# mislocated root, and it is the one value that would make every comparison
# succeed.
srcid_digest() {
    local root="${1:-$SRCID_ROOT}" d
    d=$( srcid__walk "$root" )
    if [[ -z "$d" || "$d" == e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]]; then
        echo "srcid: digest over '$root' is empty -- v10/mk/gen and v10/src are" >&2
        echo "srcid: not there, so this is the wrong root.  Refusing to return a" >&2
        echo "srcid: value that would make every staleness check agree." >&2
        return 1
    fi
    printf '%s\n' "$d"
}

srcid__walk() {
    local root="${1:?}"
    ( cd "$root" && \
      find v10/mk/gen v10/src -type f -print0 2>/dev/null \
        | LC_ALL=C sort -z \
        | xargs -0 shasum -a 256 \
        | shasum -a 256 | cut -d' ' -f1 )
}

# srcid_write <image>
srcid_write() {
    local img="${1:?srcid_write needs an image}" d
    d=$(srcid_digest) || return 1
    printf '%s\n' "$d" > "$img.id" || return 1
    echo "   src id $(cut -c1-16 < "$img.id")  (v10/mk/gen + v10/src)"
}

# srcid_check <image>
srcid_check() {
    local img="${1:?srcid_check needs an image}" want have
    have=$(srcid_digest) || return 1
    if [[ ! -f "$img.id" ]]; then
        echo "srcid: $img has no .id stamp -- built before this check existed." >&2
        echo "srcid: cannot tell whether it carries the current v10/mk/gen and" >&2
        echo "srcid: v10/src.  Rebuild it with tools/v10-srcdisk.sh to be sure." >&2
        return 0
    fi
    want=$(cat "$img.id")
    if [[ "$want" != "$have" ]]; then
        echo "srcid: THE SOURCE DISK IS STALE -- refusing to measure against it." >&2
        echo "srcid:   image carries $(echo "$want" | cut -c1-16)" >&2
        echo "srcid:   repo now has  $(echo "$have" | cut -c1-16)" >&2
        echo "srcid:" >&2
        echo "srcid: v10/mk/gen or v10/src changed since this image was built, and" >&2
        echo "srcid: the guest reads its makefiles, order files and overlay FROM THE" >&2
        echo "srcid: IMAGE.  A run now would compile the previous generation and" >&2
        echo "srcid: report on it without any symptom -- that is exactly how a" >&2
        echo "srcid: libc.ord regenerated from 261 names to 260 left three" >&2
        echo "srcid: assertions failing on a build that was already correct." >&2
        echo "srcid:" >&2
        echo "srcid: Rebuild it:  bash tools/v10-srcdisk.sh" >&2
        return 1
    fi
    return 0
}
