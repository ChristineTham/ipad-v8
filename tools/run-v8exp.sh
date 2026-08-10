#!/bin/bash
# Generic watchdog runner for the V8 expect scripts in tools/.
#
#   tools/run-v8exp.sh n3-ipup [seconds]
#
# Hard timeout, trap cleanup, and pkill -x on the bare name -- a PATH-resolved
# `spawn vax780' has no path in its command line for a -f pattern to match.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?usage: run-v8exp.sh <script-basename> [limit-seconds]}"
LIMIT="${2:-1800}"

cd "$ROOT/work/myv8" || exit 1
export PATH="$ROOT/work/opensimh/BIN:$PATH"

cleanup() {
    [[ -n "${EXP_PID:-}" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

command -v vax780 >/dev/null || { echo "$NAME: vax780 not on PATH"; exit 1; }
# Probes live in tools/; image-editing scripts live in work/ beside the media
# they operate on. Both want the same watchdog and the same pkill on the way
# out, so accept either.
SCRIPT="$ROOT/tools/$NAME.exp"
[[ -f "$SCRIPT" ]] || SCRIPT="$ROOT/work/$NAME.exp"
[[ -f "$SCRIPT" ]] || { echo "$NAME: no such script in tools/ or work/"; exit 1; }

rm -f "$NAME.log"
expect "$SCRIPT" &
EXP_PID=$!

for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$EXP_PID" 2>/dev/null || break
    sleep 1
done

if kill -0 "$EXP_PID" 2>/dev/null; then
    echo "$NAME: TIMEOUT after ${LIMIT}s — last log lines:"; tail -30 "$NAME.log"; exit 2
fi

wait "$EXP_PID"; rc=$?
echo "$NAME: expect exited $rc"
grep -oE 'N[0-9]+[A-Z]?-[a-z-]*' "$NAME.log" 2>/dev/null | sort -u
exit $rc
