#!/usr/bin/env bash
#
# Is the app you would launch RIGHT NOW the latest, and will it start?
#
#	tools/app-check.sh [--full]
#
# WHY THIS EXISTS.  A fix can be written, built, proven and committed while the
# thing the user actually double-clicks still runs last week's system -- and
# nothing anywhere says so.  It happened: the golden was rebuilt with a new
# /etc/motd, /etc/copyright and /usr/inet/lib/services, all three landed in the
# repo, and the running app had none of them, because provision() only copied
# the image when no working disk existed.  Every test passed.  The disk was
# right.  The app was stale.
#
# So this asserts the whole chain, end to end:
#
#	repo golden  ->  app bundle  ->  what launches
#
# It is deliberately CHEAP, because a check that takes a minute is a check
# that gets skipped.  rsync -a preserves size and mtime, so a bundled image
# that matches the golden on both is the golden; --full adds the sha256 for
# when that is not enough.
#
# What it CANNOT check is left to the app itself: the working copy in
# Application Support is compared against the bundle at every launch, by
# image.id, and replaced when it differs.  That is the mechanism this script
# proves is wired up, not a thing it can test from outside.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

fail=0
note() { printf "  %-46s %s\n" "$1" "$2"; }
bad()  { printf "  %-46s %s\n" "$1" "FAIL: $2"; fail=1; }

echo "app-check"

# --- 1. nothing of ours is still running -----------------------------------
# A leftover vax780 is not untidiness: it holds a disk open, and two of them
# on one image is the filesystem-corruption hazard this project never risks.
n=$(pgrep -x vax780 2>/dev/null | wc -l | tr -d ' ')
[[ "$n" == "0" ]] && note "no stray simulators" "ok" \
                  || bad  "no stray simulators" "$n vax780 still running"
n=$(pgrep -x ipnx 2>/dev/null | wc -l | tr -d ' ')
[[ "$n" -le 1 ]] && note "at most one ipnx" "ok ($n running)" \
                 || bad  "at most one ipnx" "$n instances -- two VAXes, one disk"

# --- 2. the golden exists and is the committed one -------------------------
GOLD="$ROOT/work/myv8/rp07new"
# The disk V10 built (K14).  Not committed and not required: the build phase
# warns and carries on without it, so this check is conditional on its presence.
V10GOLD="$ROOT/work/v10gold/ipnx-v10-made.img"
if [[ ! -f "$GOLD" ]]; then
    bad "golden present" "no work/myv8/rp07new (tools/drive-stages48.sh)"
else
    note "golden present" "$(stat -f%z "$GOLD") bytes"
    SHAFILE="$ROOT/image/ipnx-v8-rp07.img.xz.sha256"
    if [[ $FULL == 1 && -f "$SHAFILE" ]]; then
        want=$(awk '{print $1}' < "$SHAFILE" | head -1)
        got=$(shasum -a 256 "$GOLD" | cut -d' ' -f1)
        [[ "$want" == "$got" ]] && note "golden matches the committed image" "${got:0:12}" \
                                || bad  "golden matches the committed image" "have ${got:0:12}, committed ${want:0:12}"
    fi
fi

# --- 3. every built bundle carries THAT golden -----------------------------
# Both targets, wherever DerivedData put them. A bundle that was never built
# is not a failure; a bundle that was built from a different image is.
found=0
while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    found=1
    rel="${app#$ROOT/}"
    # macOS keeps resources in Contents/Resources; iOS at the bundle root.
    for sub in "Contents/Resources" "."; do
        [[ -f "$app/$sub/v8.disk" ]] && res="$app/$sub" && break
    done
    if [[ ! -f "${res:-}/v8.disk" ]]; then
        bad "$rel" "no v8.disk in the bundle"; continue
    fi
    if [[ ! -f "$res/v8.disk.id" ]]; then
        bad "$rel" "no v8.disk.id -- rebuild to stamp it"; continue
    fi
    # THE HASH IS THE AUTHORITY WHEN WE HAVE IT.  size+mtime is a cheap proxy
    # for "same file", and it is only a proxy: restoring the golden from the
    # committed image (tools/image-pack.py unpack, which is the normal repair
    # after a harness has drifted it) writes byte-identical content with a NEW
    # mtime.  The proxy then disagrees with the sha256 -- and the first cut of
    # this script let the proxy `continue' before the hash was ever consulted,
    # so it reported "bundled image is not the current golden" about a bundle
    # whose contents provably were.  A check that can veto stronger evidence
    # with weaker evidence is worse than not having it.
    if [[ $FULL == 1 && -f "$GOLD" ]]; then
        want=$(shasum -a 256 "$GOLD" | cut -d' ' -f1)
        got=$(tr -d '[:space:]' < "$res/v8.disk.id")
        [[ "$want" == "$got" ]] || { bad "$rel" "v8.disk.id does not match the golden"; continue; }
    elif [[ -f "$GOLD" ]]; then
        a=$(stat -f"%z %m" "$GOLD"); b=$(stat -f"%z %m" "$res/v8.disk")
        if [[ "$a" != "$b" ]]; then
            bad "$rel" "bundled image is not the current golden (mtime/size; --full to hash)"
            continue
        fi
    fi
    note "$rel" "current (image $(cut -c1-12 < "$res/v8.disk.id"))"

    # THE TENTH EDITION'S CHAIN, ON EXACTLY THE SAME ARGUMENT.  The whole reason
    # this script exists is that "it is in the golden, it will arrive on Reset"
    # is not shipping it: the app copies its image into Application Support on
    # first launch and then uses that working copy forever, so a rebuilt golden
    # reaches the bundle and stops there.  A second machine has a second way to
    # go stale, and an unchecked one is exactly as invisible as V8's was.
    #
    # Absent V10 media is NOT a failure -- a fresh checkout has no work/, and the
    # build phase says so and carries on.  What must not pass is a bundle that
    # carries a v10.disk whose stamp disagrees with the image on disk.
    if [[ -f "$V10GOLD" ]]; then
        if [[ ! -f "$res/v10.disk" ]]; then
            bad "$rel" "V10 media exists but no v10.disk in the bundle -- rebuild"
        elif [[ ! -f "$res/v10.disk.id" ]]; then
            bad "$rel" "no v10.disk.id -- rebuild to stamp it"
        elif [[ ! -f "$res/uda" ]]; then
            bad "$rel" "no uda -- V10's boot ROM is missing from the bundle"
        elif [[ $FULL == 1 ]]; then
            w10=$(shasum -a 256 "$V10GOLD" | cut -d' ' -f1)
            g10=$(tr -d '[:space:]' < "$res/v10.disk.id")
            if [[ "$w10" == "$g10" ]]; then
                note "$rel" "V10 current (image ${g10:0:12})"
            else
                bad "$rel" "v10.disk.id does not match work/v10gold/ipnx-v10-made.img"
            fi
        else
            note "$rel" "V10 present (image $(cut -c1-12 < "$res/v10.disk.id"))"
        fi
    fi
done < <(find "$ROOT/app/build" -maxdepth 5 -name "ipnx.app" -type d 2>/dev/null)

[[ $found == 0 ]] && note "built bundles" "none yet -- nothing to be stale"

# --- 4. the bundle is newer than the sources -------------------------------
# The image can be current while the CODE is not: a Swift change that was
# never rebuilt launches the old binary against the new disk.
#
# AND THE EMULATOR CORES COUNT AS SOURCES, which this check missed until
# 2026-08-22.  It watched app/ipnx and netfs/Sources only, so a change to
# libsimh/patches/pdp11_il.c -- the NI1010 device model -- could be measured,
# committed and never reach the app: the xcframework is an intermediate, and
# nothing compared it with anything.  That is the golden-disk mistake in a
# different layer ("it is in the repo, it will arrive in the build"), and the
# fix that exposed it was worth 673x on V10's netfs, so it is exactly the kind
# of change that must not go missing.  The two hand-maintained core patch sets
# are libsimh/patches and tools/dmdbridge/patches -- libdmd has no patches
# directory of its own, its build-xcframework.sh reads the dmd diffs out of
# tools/dmdbridge.  Each xcframework is rebuilt from those and the app links
# them, so requiring the app binary to be newer than the patches covers the
# whole chain in one comparison.
while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    rel="${app#$ROOT/}"
    bin=$(find "$app" -type f -name ipnx -perm +111 2>/dev/null | head -1)
    [[ -z "$bin" ]] && continue
    newer=$(find "$ROOT/app/ipnx" "$ROOT/netfs/Sources" \
                 "$ROOT/libsimh/patches" "$ROOT/tools/dmdbridge/patches" -type f \
                 \( -name '*.swift' -o -name '*.h' -o -name '*.metal' \
                    -o -name '*.c' -o -name '*.diff' \) \
                 -newer "$bin" 2>/dev/null | head -3)
    # (the patch sets are checked against the xcframeworks as well, below --
    #  an app rebuilt over a STALE xcframework would satisfy this line alone)
    if [[ -n "$newer" ]]; then
        bad "$rel build is up to date" \
            "$(echo "$newer" | head -1 | sed "s|$ROOT/||") changed since it was built"
    else
        note "$rel build is up to date" "ok"
    fi
done < <(find "$ROOT/app/build" -maxdepth 5 -name "ipnx.app" -type d 2>/dev/null)

# --- 4b. and the xcframeworks are newer than the core patches ---------------
# THE APP-BINARY COMPARISON ALONE IS NOT ENOUGH, and the hole is exactly the
# one section 4 was extended to close, one layer down: edit
# libsimh/patches/pdp11_il.c, rebuild only the APP, and the binary is newest --
# so the check passes while the app still links an xcframework built from the
# previous device model.  The chain is patches -> xcframework -> app, and it
# needs both comparisons.  Found by proving section 4's new gate bites: the
# touch that made it fire was cleared by an app rebuild that could not
# possibly have picked the change up.
core_chain () {                 # <label> <patch-dir> <xcframework> <rebuild-cmd>
    local label=$1 pdir=$2 fw=$3 cmd=$4
    [[ -d "$pdir" ]] || return 0
    if [[ ! -d "$fw" ]]; then
        note "$label xcframework" "not built yet -- nothing to be stale"
        return 0
    fi
    # The newest file anywhere in the framework: xcodebuild -create-xcframework
    # rewrites the libraries, and comparing the directory's own mtime would
    # miss a rebuild that replaced only what is inside it.
    # CAPTURE, THEN TEST -- this file's own rule about `| grep -q' under
    # pipefail, and the first version of this line broke on the other half of
    # the same lesson: it carried a `-newermt '1970-01-01'' that BSD find
    # cannot parse ("Can't parse date/time"), so the pipeline produced nothing
    # and the check reported "empty -- cannot compare" and PASSED.  A predicate
    # added for tidiness turned a gate into a rubber stamp.
    local listing newest
    listing=$(find "$fw" -type f -print0 2>/dev/null | xargs -0 stat -f '%m %N' 2>/dev/null)
    newest=$(printf '%s\n' "$listing" | sort -rn | head -1 | cut -d' ' -f2-)
    if [[ -z "$newest" || ! -f "$newest" ]]; then
        bad "$label xcframework is built from the current patches" \
            "cannot read $fw -- refusing to report a comparison not made"
        return 0
    fi
    local newer
    newer=$(find "$pdir" -type f \( -name '*.c' -o -name '*.h' -o -name '*.diff' \) \
                 -newer "$newest" 2>/dev/null | head -1)
    if [[ -n "$newer" ]]; then
        bad "$label xcframework is built from the current patches" \
            "$(echo "$newer" | sed "s|$ROOT/||") is newer -- run $cmd"
    else
        note "$label xcframework is built from the current patches" "ok"
    fi
}
core_chain "libsimh" "$ROOT/libsimh/patches" \
           "$ROOT/libsimh/dist/SimhVAX.xcframework" "libsimh/build-xcframework.sh"
core_chain "libdmd " "$ROOT/tools/dmdbridge/patches" \
           "$ROOT/libdmd/dist/DmdCore.xcframework" "libdmd/build-xcframework.sh"

echo
if [[ $fail == 0 ]]; then
    echo "PASS - the app you would launch is the latest"
    exit 0
fi
cat <<'EOF'
FAIL - the app is NOT current. Rebuild before calling this done:

    cd app && xcodebuild -project ipnx.xcodeproj -scheme ipnxMac \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build

EOF
exit 1
