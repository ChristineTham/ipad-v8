#!/usr/bin/env bash
#
# Build, sign, notarise and package the Mac app for direct download.
#
#	tools/release-mac.sh [--skip-notarise]
#
# Produces build/release/ipnx.dmg — stapled, so it opens on a Mac that has
# never heard of it and has no network to ask Apple with.
#
# WHY A SCRIPT AND NOT A CHECKLIST. Every step here has a way of appearing to
# succeed while producing something Gatekeeper will refuse, and the failure
# always lands on a stranger's Mac rather than this one:
#
#   * an unstapled artefact notarises fine and then needs the user to be
#     online at first launch;
#   * notarising the .app but shipping the .dmg leaves the CONTAINER
#     unstapled, which is the same problem one layer out;
#   * a missing --timestamp or hardened runtime is rejected by the service,
#     not by the build, so it fails minutes later and far away.
#
# The verification at the end is therefore not decoration. It asserts what a
# user's Mac will assert.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
APPNAME="ipnx"
SCHEME="ipnxMac"
PROFILE="hellotham-notary"      # xcrun notarytool store-credentials
OUT="$ROOT/build/release"
ARCHIVE="$OUT/$APPNAME.xcarchive"
APP="$OUT/$APPNAME.app"
DMG="$OUT/$APPNAME.dmg"
SKIP_NOTARISE=0
[[ "${1:-}" == "--skip-notarise" ]] && SKIP_NOTARISE=1

step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }
die()  { printf "\nrelease: %s\n" "$1" >&2; exit 1; }

# Submit and INSIST ON "Accepted".
#
# `notarytool submit --wait` exits 0 for a submission that completed, which
# includes one the service rejected — the verdict is in the output, not the
# status. Piping it through sed for tidy indentation would hide the exit code
# as well, so the output is captured and read.
notarise() {
    local what="$1" log="$OUT/notarise-$(basename "$1").log"
    xcrun notarytool submit "$what" --keychain-profile "$PROFILE" --wait > "$log" 2>&1
    sed 's/^/  /' "$log"
    if ! grep -qE '^ *status: Accepted' "$log"; then
        echo
        echo "  The submission was not accepted. Ask the service why:" >&2
        local id
        id=$(grep -m1 -E '^ *id: ' "$log" | awk '{print $2}')
        [[ -n "$id" ]] && echo "    xcrun notarytool log $id --keychain-profile $PROFILE" >&2
        die "notarisation rejected for $(basename "$what")"
    fi
}

# --- 0. preconditions -------------------------------------------------------
step "preconditions"
VERSION=$(python3 - <<'PY'
import re
s = open('v8/RELEASE').read()
g = lambda k: re.search(r'(?m)^%s=(.*)$' % k, s).group(1).strip()
maj, mnr, pat = int(g('MAJOR')), int(g('MINOR')), int(g('PATCH'))
print("%d.%d" % (maj, mnr) if pat == 0 else "%d.%d.%d" % (maj, mnr, pat))
PY
) || die "could not read v8/RELEASE"
echo "  release            $VERSION"

# The app must carry the golden that is committed, or we would ship a disk
# nobody can reproduce. app-check asserts the whole chain.
bash tools/app-check.sh --full > /tmp/app-check.$$ 2>&1 || {
    cat /tmp/app-check.$$; rm -f /tmp/app-check.$$
    die "app-check failed — the built app is not current"
}
rm -f /tmp/app-check.$$
echo "  app-check          ok"

# Same capture-then-test shape as the signature check below, and for the same
# reason: `... | grep -q` under `pipefail` can fail on SIGPIPE rather than on
# the thing it is testing. It happens to survive here because the output is
# small enough to buffer, which is not a property worth relying on.
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null)
[[ "$IDENTITIES" == *"Developer ID Application"* ]] \
    || die "no Developer ID Application identity in the keychain"
echo "  signing identity   present"

if [[ $SKIP_NOTARISE == 0 ]]; then
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
        || die "notary profile '$PROFILE' not set up. Run:
    xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id RPL5R637DS"
    echo "  notary profile     $PROFILE"
fi

rm -rf "$OUT"; mkdir -p "$OUT"

# --- 1. archive -------------------------------------------------------------
# Release configuration, so this is the optimised build with the hardened
# runtime on — not the Debug build that has been used for testing all along.
step "archiving (Release)"
xcodebuild -project app/$APPNAME.xcodeproj -scheme "$SCHEME" \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -archivePath "$ARCHIVE" archive > "$OUT/archive.log" 2>&1 \
    || { tail -30 "$OUT/archive.log"; die "archive failed (see $OUT/archive.log)"; }
echo "  $ARCHIVE"

# The archive is already signed with the Developer ID identity, because the
# target sets it explicitly rather than leaving it to an export step. So the
# app is lifted straight out; -exportArchive would re-sign it and is one more
# thing to get wrong.
cp -R "$ARCHIVE/Products/Applications/$APPNAME.app" "$APP" \
    || die "no $APPNAME.app in the archive"

# --- 2. verify the signature BEFORE spending a notarisation on it -----------
step "verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /' \
    || die "codesign --verify failed"

# Capture ONCE, then read the copy.
#
# `codesign -dv ... | grep -q` looks obvious and is a trap under `pipefail`:
# grep -q exits the moment it matches, codesign takes SIGPIPE, and the
# pipeline reports failure — so the check fails precisely when it should pass.
# It cost a build to notice, because the diagnostic said the hardened runtime
# was off while the line above it printed flags=0x10000(runtime).
DESC=$(codesign -dv --verbose=2 "$APP" 2>&1)
echo "$DESC" | grep -E "Authority|TeamIdentifier|flags" | sed 's/^/  /'
[[ "$DESC" == *"(runtime)"* ]] \
    || die "hardened runtime is NOT enabled — the notary service will reject this"

# --- 3. notarise the app ----------------------------------------------------
if [[ $SKIP_NOTARISE == 1 ]]; then
    step "skipping notarisation (--skip-notarise)"
else
    step "notarising the app"
    ZIP="$OUT/$APPNAME-notarise.zip"
    # ditto, not zip(1): only ditto preserves the bundle's symlinks and
    # extended attributes, and a mangled bundle fails notarisation for reasons
    # that have nothing to do with the signature.
    /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
    notarise "$ZIP"
    xcrun stapler staple "$APP" 2>&1 | sed 's/^/  /' || die "stapling the app failed"
    rm -f "$ZIP"
fi

# --- 4. the disk image ------------------------------------------------------
# A plain drag-to-Applications image. No background art, no custom icon
# layout: those need a mounted-and-scripted image and add failure modes for a
# window that people look at for two seconds.
step "building the disk image"
STAGE="$OUT/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APPNAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" > "$OUT/dmg.log" 2>&1 \
    || { tail -20 "$OUT/dmg.log"; die "hdiutil failed"; }
rm -rf "$STAGE"
echo "  $DMG"

# --- 5. sign, notarise and staple the CONTAINER -----------------------------
# The .dmg is what gets downloaded, so it is what has to carry the ticket.
# A stapled app inside an unstapled image still makes the first launch phone
# home, which is exactly what stapling exists to avoid.
step "signing the disk image"
codesign --sign "Developer ID Application" --timestamp "$DMG" 2>&1 | sed 's/^/  /' \
    || die "signing the dmg failed"

if [[ $SKIP_NOTARISE == 0 ]]; then
    step "notarising the disk image"
    notarise "$DMG"
    xcrun stapler staple "$DMG" 2>&1 | sed 's/^/  /' || die "stapling the dmg failed"
fi

# --- 6. assert what a stranger's Mac will assert ----------------------------
step "gatekeeper assessment"
if [[ $SKIP_NOTARISE == 0 ]]; then
    xcrun stapler validate "$DMG" 2>&1 | sed 's/^/  /' || die "the dmg is not stapled"
    spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/  /' \
        || die "spctl rejected the dmg"
else
    echo "  skipped (not notarised)"
fi

# --- 7. numbers, and put them where the website reads them ------------------
step "artefact"
SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
SIZE_MB=$(python3 -c "import os;print('%.1f MB' % (os.path.getsize('$DMG')/1e6))")
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "  file    $(basename "$DMG")"
echo "  size    $SIZE_MB"
echo "  sha256  $SHA"

SITE="$ROOT/website/src/lib/site.ts"
if [[ -f "$SITE" ]]; then
    python3 - "$SITE" "$SIZE_MB" "$SHA" <<'PY'
import re, sys
path, size, sha = sys.argv[1:4]
s = open(path).read()
s = re.sub(r"(?m)^(  size: ).*$",   r"\1'%s'," % size, s)
s = re.sub(r"(?m)^(  sha256: ).*$", r"\1'%s'," % sha, s)
open(path, 'w').write(s)
print("  website/src/lib/site.ts updated")
PY
fi

step "done"
echo "Upload with:"
echo "  gh release create v$VERSION \"$DMG\" --title \"ipnx $VERSION\" --notes-file <notes>"
