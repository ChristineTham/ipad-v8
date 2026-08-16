#!/usr/bin/env bash
#
# The netfs latency measurement, as one command.
#
#	tools/netfs-latency.sh [image]
#
# Serves the repo's own V8 tree at /n/src -- the same share the world build
# uses -- and times a hundred small reads out of it. Files per minute is the
# number that decides whether building over the share is pleasant; bytes per
# second is not, because netfs costs a round trip per path COMPONENT.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-rp07new}"
PORT="${PORT:-9375}"
NETFSD="$ROOT/netfs/.build/release/netfsd"
SRV_PID=""

cleanup() {
    if [[ -n "$SRV_PID" ]] && kill -0 "$SRV_PID" 2>/dev/null; then
        kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) || exit 1

# THE SHARE IS LIVE. netfsd serves the working tree directly, so an edit to
# v8/ lands in a run already in flight. Harmless for a read-only measurement
# like this one; lethal during a two-hour world build. See CLAUDE.md.
echo "== serving $ROOT/v8 on 127.0.0.1:$PORT =="
"$NETFSD" -p "$PORT" "$ROOT/v8" > "$ROOT/work/netfs-latency.log" 2>&1 &
SRV_PID=$!
sleep 1
kill -0 "$SRV_PID" 2>/dev/null || {
    echo "netfsd died:"; cat "$ROOT/work/netfs-latency.log"; exit 1
}

expect "$ROOT/tools/netfs-latency.exp" "$IMG" "$PORT"
rc=$?
echo "== netfs-latency exit $rc =="
exit $rc
