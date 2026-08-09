#!/bin/bash
# Watchdog wrapper for the N0 probe. Hard timeout, trap cleanup, and the
# -x form of pkill (a PATH-resolved `spawn vax780` has the bare name as its
# whole command line, so a -f path pattern never matches and leaves the
# simulator pinning a core).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/work/myv8"
cd "$WORK" || exit 1
export PATH="$ROOT/work/opensimh/BIN:$PATH"

LIMIT=${LIMIT:-900}
LOG=rp07probe.log

cleanup() {
    [[ -n "${EXP_PID:-}" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

command -v vax780 >/dev/null || { echo "probe: vax780 not on PATH"; exit 1; }
for f in bootV8 rp06v8.golden rp07v8.new; do
    [[ -e $f ]] || { echo "probe: missing $WORK/$f"; exit 1; }
done

: > "$LOG"
expect "$ROOT/tools/rp07probe.exp" &
EXP_PID=$!

for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$EXP_PID" 2>/dev/null || break
    sleep 1
done

if kill -0 "$EXP_PID" 2>/dev/null; then
    echo "probe: TIMEOUT after ${LIMIT}s — last log lines:"; tail -30 "$LOG"; exit 2
fi

wait "$EXP_PID"; rc=$?
echo "probe: expect exited $rc"
exit $rc
