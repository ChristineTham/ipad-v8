#!/bin/bash
# Measure netfs read throughput into V8 -- the number B1 depends on.
#
#   tools/drive-throughput.sh [limit-seconds] [port] [megabytes]
#
# B1 ingests 14.87 MB of the V10 tree and the whole tree is 243 MB, so the
# useful output here is not "it works" but a rate, and an extrapolation from it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIMIT="${1:-2400}"
PORT="${2:-9200}"
MB="${3:-4}"
SHARE="$ROOT/work/netfs-share-tp"
NETFSD="$ROOT/netfs/.build/release/netfsd"

EXP_PID=""; SRV_PID=""
cleanup() {
    [[ -n "$SRV_PID" ]] && kill -9 "$SRV_PID" 2>/dev/null
    [[ -n "$EXP_PID" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

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

echo
echo "== throughput =="
# Timing lives in tools/netfs-timing.py: macOS bash has no mapfile, and
# counting `date` lines is wrong anyway because V8 prints one at boot.
tp() {              # tp <label> <start-marker> <stop-marker>
    local out secs kbs
    out=$("$ROOT/tools/netfs-timing.py" n8-throughput.log "$2" "$3" "$BYTES")
    if [[ "$out" == "?" ]]; then
        echo "  $1: could not find both timestamps"; fail=1; return
    fi
    secs=${out% *}; kbs=${out#* }
    echo "  $1: $BYTES bytes in ${secs}s = ${kbs} KB/s"
    python3 -c "k = $kbs * 1024; print('      B1 (14.87 MB): %.0f min   |   whole 243 MB tree: %.0f min' % (14870000/k/60, 243000000/k/60))"
}
fail=0
tp "cp to local disk " TP-START  TP-STOP
tp "cat to /dev/null" TP2-START TP2-STOP

LOG=$(tr -d '\r' < n8-throughput.log)

echo
echo "== integrity =="
got=$(sed -n 's|^\([0-9][0-9]*\)  *\([0-9][0-9]*\) /tmp/bulk$|\1 \2|p' <<< "$LOG" | head -1)
echo "  guest sum: ${got:-<not found>}"
echo "  host  sum: $WANT"
if [[ "$got" == "$WANT" ]]; then echo "  ok    $BYTES bytes arrived byte-exact"
else echo "  FAIL  checksum mismatch"; fail=1; fi

grep -qE 'istread:|read -1 expected|I/O error|panic:' <<< "$LOG" && { echo "  FAIL  errors in the log"; fail=1; } || echo "  ok    clean"

echo "   $(grep -cE '^#[0-9]+ NREAD' netfsd-tp.log) NREAD requests"
[[ $fail -eq 0 ]] && { echo; echo "THROUGHPUT OK"; exit 0; }
echo; echo "THROUGHPUT FAILED"; exit 1
