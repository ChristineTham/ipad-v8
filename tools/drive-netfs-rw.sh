#!/bin/bash
# Write to macOS from inside Research Unix V8, and prove what landed is right.
# Phase N7.
#
#   tools/drive-netfs-rw.sh [limit-seconds] [port]
#
# The interesting assertion is the last one: a file assembled inside V8, summed
# by V8's own sum(1), copied out through netfs, and then summed again on the
# host with the same V7 algorithm. Equal sums mean every 4 KB NWRT round trip
# carried exactly what it claimed to.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIMIT="${1:-2400}"
PORT="${2:-9200}"
SHARE="$ROOT/work/netfs-share-rw"
NETFSD="$ROOT/netfs/.build/release/netfsd"

EXP_PID=""
SRV_PID=""
cleanup() {
    [[ -n "$SRV_PID" ]] && kill -9 "$SRV_PID" 2>/dev/null
    [[ -n "$EXP_PID" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

# V8's sum(1): the V7 rotate-and-add over 16 bits, then the 1024-byte block
# count. usr/src/cmd/sum.c.
v7sum() {
    python3 - "$1" <<'PY'
import sys
s, n = 0, 0
with open(sys.argv[1], 'rb') as f:
    for b in f.read():
        s = 0xffff & ((s >> 1) + b + 0x8000) if s & 1 else 0xffff & ((s >> 1) + b)
        n += 1
print("%05u %d" % (s, (n + 1023) // 1024))
PY
}

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) || exit 1

echo "== empty export at $SHARE =="
rm -rf "$SHARE"; mkdir -p "$SHARE"

cd "$ROOT/work/myv8" || exit 1
export PATH="$ROOT/work/opensimh/BIN:$PATH"
command -v vax780 >/dev/null || { echo "vax780 not on PATH"; exit 1; }
[[ -f rp07v8.net ]] || { echo "no rp07v8.net"; exit 1; }

rm -f n7-netfs-rw.log netfsd-rw.log
echo "== starting netfsd on 127.0.0.1:$PORT (READ/WRITE) =="
"$NETFSD" -p "$PORT" -w -v "$SHARE" > netfsd-rw.log 2>&1 &
SRV_PID=$!
sleep 1
kill -0 "$SRV_PID" 2>/dev/null || { echo "netfsd died:"; cat netfsd-rw.log; exit 1; }

echo "== booting rp07v8.net =="
expect "$ROOT/tools/n7-netfs-rw.exp" "$PORT" > /dev/null 2>&1 &
EXP_PID=$!
for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$EXP_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$EXP_PID" 2>/dev/null; then
    echo "TIMEOUT after ${LIMIT}s:"; tail -40 n7-netfs-rw.log; exit 2
fi
wait "$EXP_PID"; rc=$?
echo "== guest exited $rc =="

fail=0
check() {
    if grep -qE "$2" n7-netfs-rw.log; then echo "  ok    $1"
    else echo "  FAIL  $1"; fail=$((fail + 1)); fi
}
hostfile() {        # hostfile <description> <path> <regex the content must match>
    if [[ -f "$SHARE/$2" ]] && grep -qE "$3" "$SHARE/$2"; then
        echo "  ok    $1"
    else
        echo "  FAIL  $1 (host $SHARE/$2)"
        fail=$((fail + 1))
    fi
}

echo
echo "== verdict: what V8 said =="
check "booted"                       'RW-boot-ok'
check "mounted read/write"           'mounted on /n/macos'
check "created a file"               'written by Research Unix 8th Edition'
check "append worked"                'second line'
check "mkdir worked"                 'nested-by-v8'
check "chmod took effect"            '^-rw-------.*from-v8'
check "unlink removed it"            'rm-rc=0'
check "the deleted file is gone"     'gone-rc=[1-9]'
check "ran to the end"               'RW-DONE'
if grep -qE 'read -1 expected|I/O error|panic:' n7-netfs-rw.log; then
    echo "  FAIL  clean run"; grep -nE 'read -1 expected|I/O error|panic:' n7-netfs-rw.log | head -5
    fail=$((fail + 1))
else
    echo "  ok    clean run"
fi

echo
echo "== verdict: what actually landed on macOS =="
hostfile "from-v8 exists with its content" "from-v8" 'written by Research Unix'
hostfile "the appended line is there"      "from-v8" 'second line'
hostfile "fromv8dir/inner exists"          "fromv8dir/inner" 'nested-by-v8'
if [[ -f "$SHARE/doomed" ]]; then
    echo "  FAIL  the unlinked file is still on the host"; fail=$((fail + 1))
else
    echo "  ok    the unlinked file is gone from the host too"
fi
if [[ -f "$SHARE/from-v8" ]]; then
    mode=$(stat -f "%Lp" "$SHARE/from-v8")
    if [[ "$mode" == "600" ]]; then echo "  ok    chmod 600 reached APFS"
    else echo "  FAIL  host mode is $mode, expected 600"; fail=$((fail + 1)); fi
fi

# The integrity check. V8 summed /tmp/big.h before copying it out; we sum what
# arrived. Equal means the write path is byte-exact over many round trips.
guest_sum=$(sed -n '/RW-SUM-LOCAL/,$p' n7-netfs-rw.log | grep -oE '^[0-9]{5} +[0-9]+ /tmp/big.h' | head -1)
guest_sum=$(sed -n 's/^\([0-9]\{5\}\) *\([0-9]*\) \/tmp\/big.h$/\1 \2/p' n7-netfs-rw.log | head -1)
if [[ -f "$SHARE/big.h" ]]; then
    host_sum=$(v7sum "$SHARE/big.h")
    echo "  guest sum of /tmp/big.h : ${guest_sum:-<not found>}"
    echo "  host  sum of big.h      : $host_sum"
    if [[ -n "$guest_sum" && "$guest_sum" == "$host_sum" ]]; then
        echo "  ok    a $(wc -c < "$SHARE/big.h" | tr -d ' ')-byte file written by V8 is byte-identical on APFS"
    else
        echo "  FAIL  checksum mismatch"; fail=$((fail + 1))
    fi
else
    echo "  FAIL  big.h never arrived on the host"; fail=$((fail + 1))
fi

echo
echo "== the export as macOS sees it =="
ls -lR "$SHARE" | head -20
echo
echo "   $(grep -cE '^#[0-9]+ NWRT' netfsd-rw.log) NWRT, $(grep -cE '^#[0-9]+ NREAD' netfsd-rw.log) NREAD, $(grep -cE '^#[0-9]+ NNAMI' netfsd-rw.log) NNAMI"

if [[ $fail -eq 0 ]]; then echo; echo "N7 PASS -- Research Unix writes to macOS"; exit 0; fi
echo; echo "N7 FAILED ($fail checks)"; exit 1
