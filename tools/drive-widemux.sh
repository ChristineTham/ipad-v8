#!/bin/bash
# Drive a widened muxterm end to end and prove a layer can use the full screen
# (task #42).
#
#   tools/drive-widemux.sh [limit-seconds] [width]
#
# Boots work/myv8/rp06v8.wide on the desktop SIMH with the DZ on 8888, then
# runs tools/dmdbridge against it with a resized 5620 and `wmux` instead of
# `mux`. wmux sets $MUXTERM to /usr/jerq/lib/muxterm.w, the copy whose screen
# Bitmap was rewritten by tools/widen-jerq.exp.
#
# The question being asked: a muxterm that still believes the screen is 800
# wide cannot put a layer edge past x=800, so if the swept layer reaches the
# right-hand side of a 1152-pixel screen, the patch works. Shots land in
# work/shots-a4-widemux/ and the last one is the answer.
#
# Hard timeout, trap cleanup and pkill on the way out, same as run-v8exp.sh.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIMIT="${1:-900}"
WIDTH="${2:-1152}"
SHOTS="$ROOT/work/shots-a4-widemux"
BRIDGE="$ROOT/tools/dmdbridge/target/release/dmdbridge"

cd "$ROOT/work/myv8" || exit 1
export PATH="$ROOT/work/opensimh/BIN:$PATH"

EXP_PID=""
BR_PID=""
cleanup() {
    [[ -n "$BR_PID"  ]] && kill -9 "$BR_PID"  2>/dev/null
    [[ -n "$EXP_PID" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

command -v vax780 >/dev/null || { echo "vax780 not on PATH"; exit 1; }
[[ -x "$BRIDGE" ]] || { echo "build it first: (cd tools/dmdbridge && cargo build --release)"; exit 1; }
[[ -f rp06v8.wide ]] || { echo "no rp06v8.wide -- run tools/run-v8exp.sh widen-jerq first"; exit 1; }

# `set noasynch` is mandatory on the desktop open-simh build (it IS compiled
# with async I/O, unlike libsimh) or V8 corrupts RP06 transfers. Speed=*32 on
# the attach lifts SIMH's guest-speed throttle so the muxterm download is ~15 s
# rather than ~100 s -- the A3 finding. `-m` gives the line modem control, so
# the bridge connecting is what raises carrier and makes getty print `login:`.
cat > widemux.conf <<'EOF'
set noasynch
set tto 7b
set cpu idle=4.1BSD
set dz lines=8
att dz -m Speed=*32,8888
set rp0 rp06
at rp0 rp06v8.wide
set tu0 te16
load -o bootV8 0
run 2
EOF

rm -rf "$SHOTS"; mkdir -p "$SHOTS"
rm -f widemux-boot.log widemux-bridge.log

echo "== booting rp06v8.wide (DZ on 8888) =="
expect "$ROOT/tools/widemux-boot.exp" >/dev/null 2>&1 &
EXP_PID=$!

# Wait for multiuser, not merely for the port: SIMH binds 8888 at `att`, long
# before any getty exists to answer on it.
for ((i = 0; i < 300; i++)); do
    grep -q "login:" widemux-boot.log 2>/dev/null && break
    kill -0 "$EXP_PID" 2>/dev/null || { echo "boot died early"; tail -20 widemux-boot.log; exit 2; }
    sleep 1
done
grep -q "login:" widemux-boot.log 2>/dev/null || { echo "no multiuser in 300s"; tail -20 widemux-boot.log; exit 2; }
echo "== V8 at multiuser; starting the bridge (${WIDTH}x1024, wmux) =="

DMD_W="$WIDTH" DMD_MUX="${DMD_MUX:-/usr/jerq/bin/wmux}" "$BRIDGE" "$SHOTS" > widemux-bridge.log 2>&1 &
BR_PID=$!

for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$BR_PID" 2>/dev/null || break
    sleep 1
done

if kill -0 "$BR_PID" 2>/dev/null; then
    echo "TIMEOUT after ${LIMIT}s — last bridge output:"; tail -30 widemux-bridge.log; exit 2
fi
wait "$BR_PID"; rc=$?
echo "== bridge exited $rc =="
grep -E "screen |self-test done|login prompt|shell prompt|download complete|summary:" widemux-bridge.log
echo "== shots =="; ls -1 "$SHOTS" | tail -8
exit $rc
