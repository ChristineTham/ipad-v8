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
    if [[ -f "$GOLD" ]]; then
        a=$(stat -f"%z %m" "$GOLD"); b=$(stat -f"%z %m" "$res/v8.disk")
        if [[ "$a" != "$b" ]]; then
            bad "$rel" "bundled image is not the current golden"
            continue
        fi
    fi
    if [[ $FULL == 1 ]]; then
        want=$(shasum -a 256 "$GOLD" | cut -d' ' -f1)
        got=$(tr -d '[:space:]' < "$res/v8.disk.id")
        [[ "$want" == "$got" ]] || { bad "$rel" "v8.disk.id does not match the golden"; continue; }
    fi
    note "$rel" "current (image $(cut -c1-12 < "$res/v8.disk.id"))"
done < <(find "$ROOT/app/build" -maxdepth 5 -name "ipnx.app" -type d 2>/dev/null)

[[ $found == 0 ]] && note "built bundles" "none yet -- nothing to be stale"

# --- 4. the bundle is newer than the sources -------------------------------
# The image can be current while the CODE is not: a Swift change that was
# never rebuilt launches the old binary against the new disk.
while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    rel="${app#$ROOT/}"
    bin=$(find "$app" -type f -name ipnx -perm +111 2>/dev/null | head -1)
    [[ -z "$bin" ]] && continue
    newer=$(find "$ROOT/app/ipnx" "$ROOT/netfs/Sources" -type f \
                 \( -name '*.swift' -o -name '*.h' -o -name '*.metal' \) \
                 -newer "$bin" 2>/dev/null | head -3)
    if [[ -n "$newer" ]]; then
        bad "$rel build is up to date" \
            "$(echo "$newer" | head -1 | sed "s|$ROOT/||") changed since it was built"
    else
        note "$rel build is up to date" "ok"
    fi
done < <(find "$ROOT/app/build" -maxdepth 5 -name "ipnx.app" -type d 2>/dev/null)

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
