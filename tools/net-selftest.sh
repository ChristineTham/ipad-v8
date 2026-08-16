#!/usr/bin/env bash
#
# The whole network self-test, as one command.
#
#	tools/net-selftest.sh [image]
#
# net-selftest.exp drives the GUEST; it cannot serve itself the share it
# mounts. This builds netfsd, lays out an export with a file of known content,
# starts the server, runs the guest side against it and cleans up -- so the
# check is one command rather than a procedure someone has to remember.
#
# Everything lives under work/ and is disposable. The image is NOT: it is
# passed through untouched and the guest halts cleanly, so a pass leaves the
# disk exactly as it found it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-rp07new}"
PORT="${PORT:-9200}"
SHARE="$ROOT/work/netfs-selftest"
NETFSD="$ROOT/netfs/.build/release/netfsd"
SRV_PID=""

cleanup() {
    if [[ -n "$SRV_PID" ]] && kill -0 "$SRV_PID" 2>/dev/null; then
        kill "$SRV_PID" 2>/dev/null
        wait "$SRV_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) || exit 1
[[ -x "$NETFSD" ]] || { echo "netfsd did not build"; exit 1; }

echo "== laying out the export at $SHARE =="
rm -rf "$SHARE"; mkdir -p "$SHARE"
# Content the guest side asserts on, so a mount that succeeds but reads
# nothing cannot pass. An empty share would satisfy `test -f' never, and a
# wrong one would satisfy it with the wrong bytes.
echo "hello from the host, served over netfs" > "$SHARE/greeting.txt"

echo "== starting netfsd on 127.0.0.1:$PORT =="
"$NETFSD" -p "$PORT" "$SHARE" > "$ROOT/work/netfs-selftest.log" 2>&1 &
SRV_PID=$!
sleep 1
kill -0 "$SRV_PID" 2>/dev/null || {
    echo "netfsd died:"; cat "$ROOT/work/netfs-selftest.log"; exit 1
}

echo "== driving the guest =="
expect "$ROOT/tools/net-selftest.exp" "$IMG" "$PORT"
rc=$?
echo "== net-selftest exit $rc =="
exit $rc
