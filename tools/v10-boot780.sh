#!/usr/bin/env bash
#
# K8/K9: boot the Tenth Edition 780 kernel, on the desktop simulator or on the
# library the app ships.
#
#	bash tools/v10-boot780.sh                 # K8, desktop open-simh
#	bash tools/v10-boot780.sh app             # K9, the app's libsimh
#	bash tools/v10-boot780.sh app <image>     # ... against another image
#
# WHY THIS WRAPPER EXISTS AT ALL.  tools/v10-boot780.exp was run by hand --
# `expect tools/v10-boot780.exp <image>' -- so the clone rule was being kept by
# whoever typed it.  Every other guest harness here has a wrapper for exactly
# that reason: CLAUDE.md's golden-drift incident was a clean, successful,
# properly halted run that changed an image's hash, and the V10 images have no
# committed copy to restore from.  Booting mounts, mounting rewrites the
# superblock, and this harness also WRITES -- it rewrites /etc/motd.
#
# K9 IS THE ONE THAT MAKES V10 SHIPPABLE.  K8 proves a kernel we built boots on
# a simulator; K9 proves it boots on `libsimh', the static library both app
# targets link.  Same harness, same assertions, same machine configuration --
# only the binary differs, so a difference in the result cannot be a difference
# in the test.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v10clone.sh"
source "$ROOT/tools/norun.sh"

MODE=""
if [[ "${1:-}" == "app" ]]; then MODE="app"; shift; fi
GOLD="${1:-ipnx-v10-ra81.img.stage1.k7}"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-boot780: no $GOLD in work/v10gold --"
    echo "             run tools/v10-kernel.sh to build a 780 kernel image first."
    exit 1
}
# The tape's own boot ROM, unpatched: on a 780 its compiled-in addresses are
# already right.  Named here so a missing tree says so before a clone is made.
[[ -f "$ROOT/work/v10/src/lsys/boot/star/uda" ]] || {
    echo "v10-boot780: no work/v10/src/lsys/boot/star/uda -- run tools/v10-import.py"
    exit 1
}
if [[ "$MODE" == "app" ]]; then
    [[ -x "$ROOT/libsimh/build/macos/vax780cli" ]] || {
        echo "v10-boot780: no libsimh/build/macos/vax780cli."
        echo "             cd libsimh/build/macos && make vax780cli"
        exit 1
    }
fi

no_overlap "$ROOT/work/v10gold/$GOLD" || exit 1

TAG="b780"; [[ "$MODE" == "app" ]] && TAG="b780app"
LOG="$ROOT/work/v10-boot780${MODE:+-app}.log"
IMG=$(v10_clone "$GOLD" "$TAG") || exit 1
echo "== booting $(basename "$IMG") =="

expect "$ROOT/tools/v10-boot780.exp" "$IMG" ${MODE:+app} 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

echo
echo "   the machine is $IMG"
echo "   sha256 $(shasum -a 256 "$IMG" | cut -c1-16)"
echo "== v10-boot780${MODE:+ (app)} exit $rc =="
exit "$rc"
