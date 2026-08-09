#!/bin/bash
# N3 stage 1 driver: rebuild the V8 kernel with il0 and build the IP userspace.
# Works on rp07v8.net, a copy of the N0 image, so the golden stays clean.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/work/myv8"
cd "$WORK" || exit 1
export PATH="$ROOT/work/opensimh/BIN:$PATH"

LIMIT=${LIMIT:-4800}
LOG=n3-ilkernel.log

cleanup() {
    [[ -n "${EXP_PID:-}" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

command -v vax780 >/dev/null || { echo "n3: vax780 not on PATH"; exit 1; }
[[ -e rp07v8.golden ]] || { echo "n3: missing rp07v8.golden — run tools/rp07mig.sh first"; exit 1; }

# Only rebuild the working copy when asked, so a second stage can continue
# from where the first left off.
if [[ "${FRESH:-1}" == "1" || ! -e rp07v8.net ]]; then
    echo "=== copying rp07v8.golden -> rp07v8.net ==="
    rm -f rp07v8.net
    cp rp07v8.golden rp07v8.net
fi

: > "$LOG"
expect "$ROOT/tools/n3-ilkernel.exp" &
EXP_PID=$!

for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$EXP_PID" 2>/dev/null || break
    sleep 1
done

if kill -0 "$EXP_PID" 2>/dev/null; then
    echo "n3: TIMEOUT after ${LIMIT}s — last log lines:"; tail -30 "$LOG"; exit 2
fi

wait "$EXP_PID"; rc=$?
echo "n3: expect exited $rc"
echo "--- markers reached ---"
grep -o 'N3-[a-z-]*' "$LOG" | sort -u
exit $rc
