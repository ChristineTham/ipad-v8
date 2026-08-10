#!/bin/bash
# Mount a macOS directory inside Research Unix V8 and prove it works. N5 + N6.
#
#   tools/drive-netfs.sh [limit-seconds] [port]
#
# Builds netfsd, lays out a known export under work/netfs-share, starts the
# server on 127.0.0.1, boots work/myv8/rp07v8.net with SLiRP, and runs
# tools/n6-netfs.exp inside it. The guest reaches the server as 10.0.2.2:PORT
# -- nothing is forwarded, because SLiRP redirects every address inside its
# virtual network to the host's loopback (slirp/tcp_subr.c, "It's an alias").
#
# Hard timeout, trap cleanup, and both the simulator and the server are killed
# on the way out.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIMIT="${1:-2400}"
PORT="${2:-9200}"
# Cap on each NREAD reply. A short but non-zero reply is legal --
# naread() loops while (u_count != 0 && n > 0) -- so this costs round
# trips and nothing else. 0 means "as much as was asked".
MAXREAD="${3:-0}"
SHARE="$ROOT/work/netfs-share"
NETFSD="$ROOT/netfs/.build/release/netfsd"

EXP_PID=""
SRV_PID=""
cleanup() {
    [[ -n "$SRV_PID" ]] && kill -9 "$SRV_PID" 2>/dev/null
    [[ -n "$EXP_PID" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    pkill -9 -f "netfsd .*netfs-share" 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) || exit 1
[[ -x "$NETFSD" ]] || { echo "netfsd did not build"; exit 1; }

# ---------------------------------------------------------------- the export
# Fixed content, so the checksums below are reproducible.
echo "== laying out $SHARE =="
rm -rf "$SHARE"
mkdir -p "$SHARE/src/deep" "$SHARE/empty"
printf 'hello from macOS, 2026\n' > "$SHARE/README"
printf 'main(){ printf("v10 or bust\\n"); }\n' > "$SHARE/src/hello.c"
python3 -c "
import sys
sys.stdout.write(''.join('line %05d\n' % i for i in range(1200)))
" > "$SHARE/src/big.dat"
printf 'nested\n' > "$SHARE/src/deep/leaf"
ln -s README "$SHARE/link-to-readme"
printf 'the whole name did not fit\n' > "$SHARE/a-name-that-is-far-too-long-for-v8"

# V8's sum(1) is the V7 rotate-and-add over 16 bits, printed as %05u then the
# 1024-byte block count. Reproducing it here rather than trusting `cksum` is
# the only way to compare host and guest directly.
read -r WANT_SUM WANT_BLK < <(python3 - "$SHARE/src/big.dat" <<'PY'
import sys
s, n = 0, 0
with open(sys.argv[1], 'rb') as f:
    for b in f.read():
        s = 0xffff & ((s >> 1) + b + 0x8000) if s & 1 else 0xffff & ((s >> 1) + b)
        n += 1
print("%05u" % s, (n + 1023) // 1024)
PY
)
WANT_BYTES=$(wc -c < "$SHARE/src/big.dat" | tr -d ' ')
echo "   big.dat: sum $WANT_SUM, $WANT_BLK blocks, $WANT_BYTES bytes"

# ---------------------------------------------------------------- the server
cd "$ROOT/work/myv8" || exit 1
export PATH="$ROOT/work/opensimh/BIN:$PATH"
command -v vax780 >/dev/null || { echo "vax780 not on PATH"; exit 1; }
[[ -f rp07v8.net ]] || { echo "no rp07v8.net -- run tools/n3-ilkernel.sh first"; exit 1; }

rm -f n6-netfs.log netfsd.log
echo "== starting netfsd on 127.0.0.1:$PORT (read-only, maxread=$MAXREAD) =="
"$NETFSD" -p "$PORT" -v -m "$MAXREAD" "$SHARE" > netfsd.log 2>&1 &
SRV_PID=$!
sleep 1
kill -0 "$SRV_PID" 2>/dev/null || { echo "netfsd died:"; cat netfsd.log; exit 1; }

# ---------------------------------------------------------------- the guest
echo "== booting rp07v8.net with SLiRP =="
expect "$ROOT/tools/n6-netfs.exp" "$PORT" > /dev/null 2>&1 &
EXP_PID=$!

for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$EXP_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$EXP_PID" 2>/dev/null; then
    echo "TIMEOUT after ${LIMIT}s -- last guest output:"
    tail -40 n6-netfs.log
    exit 2
fi
wait "$EXP_PID"; rc=$?
echo "== guest exited $rc =="

# ---------------------------------------------------------------- the verdict
fail=0
check() {           # check <description> <regex>
    if grep -qE "$2" n6-netfs.log; then
        echo "  ok    $1"
    else
        echo "  FAIL  $1"
        fail=$((fail + 1))
    fi
}
missing() {         # the opposite: this must NOT appear
    if grep -qE "$2" n6-netfs.log; then
        echo "  FAIL  $1"
        fail=$((fail + 1))
    else
        echo "  ok    $1"
    fi
}
# grep works a line at a time, so "X appears between markers A and B" has to
# cut the section out first. Written as one multi-line regex it silently never
# matches, which reads as a failed test rather than a broken one -- which is
# exactly how it read the first time round.
inrange() {         # inrange <description> <from> <to> <regex>
    if sed -n "/$2/,/$3/p" n6-netfs.log | grep -qE "$4"; then
        echo "  ok    $1"
    else
        echo "  FAIL  $1"; fail=$((fail + 1))
    fi
}

echo
echo "== verdict =="
check "V8 reached multiuser"            'N6-boot-ok'
check "nmount compiled"                 'N6-built'
check "TCP connected to the server"     'nmount: connected to 10\.0\.2\.2'
check "netfs handshake accepted"        'nmount: handshake ok'
check "mount reported success"          'mounted on /n/macos'
inrange "ls saw README"                 'N6-MOUNTED' 'N6-LS-DONE' 'README'
inrange "ls saw the src directory"      'N6-MOUNTED' 'N6-LS-DONE' ' src$'
inrange "ls reported real sizes"        'N6-MOUNTED' 'N6-LS-DONE' '23 .*README'
check "cat read the file"               'hello from macOS, 2026'
inrange "nested directory listed"       'N6-CAT-DONE' 'N6-NEST-DONE' 'hello\.c'
inrange "nested file read"              'N6-CAT-DONE' 'N6-NEST-DONE' '^nested'
inrange "symlink followed by the client" 'N6-CAT-DONE' 'N6-NEST-DONE' 'hello from macOS'
check "remote sum matches the host"     "$WANT_SUM *$WANT_BLK /n/macos/src/big.dat"
check "copied-out sum matches"          "$WANT_SUM *$WANT_BLK /tmp/big.dat"
check "byte count matches"              "$WANT_BYTES /n/macos/src/big.dat"
check "truncated 14-byte name opens"    'the whole name did not fit'
check "read-only export refused a write" 'write-rc=[1-9]'
check "unmounted cleanly"               'dev 16384 unmounted'
check "ran to the end"                  'N6-DONE'
missing "no short-read failure"         'read -1 expected|expected [0-9]+$'
missing "no I/O errors"                 'I/O error'
missing "no kernel panic"               'panic:'
missing "no netfs client complaint"     'naget ino 0|nanami ino|sent [0-9]+ got'

echo
echo "== server log =="
grep -E "listening|mounted|connection|collision" netfsd.log | head -20
echo "   $(grep -c 'NNAMI\|NGET\|NREAD' netfsd.log) traced operations"

if [[ $fail -eq 0 ]]; then
    echo; echo "N6 PASS -- macOS is mounted inside Research Unix V8"
    exit 0
fi
echo; echo "N6 FAILED ($fail checks)"
exit 1
