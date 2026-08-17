#!/usr/bin/env bash
#
# Does a V10 harness STOP BY ITSELF?  Boot, log in, halt, exit -- and time it.
#
#	tools/v10-halt-test.sh [image]
#
# WHY THIS EXISTS.  Twice now a stage run has done all of its work, halted the
# guest cleanly -- `death' and `Infinite loop, PC: 80017019' both in the log --
# and then sat at `sim>' owning a vax750 with nothing left to do, so the next
# round could not start and the only way out was killing a process by hand.
# Needing that is the bug, and the fix (bounded expects, a `close'-based reap,
# and an event-loop watchdog in v10drive.exp) is worth nothing unless it is
# demonstrated against a real simulator rather than reasoned about.
#
# So this is the smallest run that exercises the whole teardown path: it does
# no work at all, which is the point -- if it does not exit on its own, every
# longer run has the same defect and there is no reason to start one.
#
# It boots a CLONE, like every other harness here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v10clone.sh"

GOLD="${1:-ipnx-v10-ra81.img}"

pgrep -f "BIN/vax750" >/dev/null && { echo "v10-halt-test: a vax750 is already running"; exit 1; }

IMG=$(v10_clone "$GOLD" halttest) || exit 1
echo "== halt test on $(basename "$IMG") =="

# tee, NEVER `tail'.  A pipe into tail buffers the whole run until EOF, so a
# run that is killed -- or merely watched -- shows nothing at all, which is
# exactly the case this test exists to diagnose.
LOG="$ROOT/work/v10-halt-test.log"
start=$(date +%s)
expect "$ROOT/tools/v10-halt-test.exp" "$IMG" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
elapsed=$(( $(date +%s) - start ))

echo
echo "   expect exit $rc after ${elapsed}s"

# THE ASSERTION IS ABOUT THE HOST, NOT THE GUEST.  Everything above could be
# perfect and still leave a simulator attached to the image.
left=$(pgrep -f "BIN/vax750" | wc -l | tr -d ' ')
if [[ "$left" != "0" ]]; then
    echo "   FAIL: $left vax750 still running -- the harness did not let go"
    exit 1
fi
echo "   ok: no vax750 left running"
rm -f "$IMG"
exit "$rc"
