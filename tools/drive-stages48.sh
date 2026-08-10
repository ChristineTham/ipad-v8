#!/bin/bash
# Stages 4 to 8 against a build filesystem that already has stages 1 to 3.
#
#	tools/drive-stages48.sh [limit-seconds] [port]
#
# tools/drive-stage1.sh spends about fifty minutes rebuilding the toolchain
# before it reaches anything you are iterating on.  rp06build is a FILE and it
# survives the run that made it, so stages 4 onward can be re-run against it
# directly -- about fifteen minutes instead of eighty.
#
# Use drive-stage1.sh when the toolchain, libc or the fixpoint has changed.
# Use this when only stages 4 to 8 have.  It deliberately does NOT recreate or
# mkfs rp06build: if /b/tools3 is not there, the stage scripts say so and stop.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)/.."
ROOT="$(cd "$ROOT" && pwd)"
WORK="$ROOT/work/myv8"
LIMIT="${1:-14400}"
PORT="${2:-9370}"
LOG="$WORK/stages48.log"
NETFSD="$ROOT/netfs/.build/release/netfsd"

cd "$WORK" || exit 1
export PATH="$ROOT/work/opensimh/BIN:$PATH"

command -v vax780 >/dev/null || { echo "s48: vax780 not on PATH"; exit 1; }
[[ -e rp06build ]] || {
    echo "s48: no rp06build -- run tools/drive-stage1.sh first, it makes one"
    exit 1
}
[[ -e rp07v8.net ]] || { echo "s48: no rp07v8.net"; exit 1; }
if pgrep -x vax780 >/dev/null; then
    echo "s48: a vax780 is already running -- wait for it"; exit 1
fi

# The generator has to be in step with the tree, exactly as the full driver
# insists: a stale makefile is the one failure that looks like a source bug.
python3 "$ROOT/v8/mk/mkdep.py" --check || {
    echo "s48: regenerate first"; exit 1; }

# The disk stage 8 builds.  1008000 sectors is hp7_sizes' partition c, the
# whole RP07 -- see v8/mk/builddisk.sh for why the sizes come from the driver.
[[ -e rp07new ]] || {
    echo "== making rp07new (516 MB) =="
    dd if=/dev/zero of=rp07new bs=512 count=1008000 2>/dev/null
}

cleanup() {
    [[ -n "${EXP_PID:-}" ]] && kill -9 "$EXP_PID" 2>/dev/null
    [[ -n "${NETFSD_PID:-}" ]] && kill -9 "$NETFSD_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

[[ -x "$NETFSD" ]] || { echo "s48: no netfsd at $NETFSD"; exit 1; }
"$NETFSD" -p "$PORT" -v "$ROOT/v8" > "$ROOT/work/netfsd-stages48.log" 2>&1 &
NETFSD_PID=$!
sleep 1

: > "$LOG"
expect "$ROOT/tools/drive-stages48.exp" "$PORT" &
EXP_PID=$!
for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$EXP_PID" 2>/dev/null || break
    sleep 1
done
wait "$EXP_PID" 2>/dev/null
rc=$?

LOGC=$(tr -d '\r' < "$LOG")
fail=0
ck() {
    if grep -qE "$2" <<< "$LOGC"; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n' "$1"; fail=1; fi
}

echo
echo "== preconditions =="
ck "share mounted at /n/src"      'S48-MOUNTED-ok'
ck "stage 3 present in /b"        'S48-STAGE3-present-ok'

echo
echo "== stages 4 to 8 =="
ck "4: headers"                   'STAGE4 OK'
ck "5: libraries"                 'STAGE5 OK'
ck "6: commands"                  'STAGE6 OK'
ck "7: the kernel"                'STAGE7 OK'
ck "8: a disk"                    'STAGE8 OK'
grep -E '  BUILD FAILED |  INSTALL FAILED |Don.t know how to make' <<< "$LOGC" \
    | sed 's/^/  /' | head -20
sed -n '/=== stage 7: what got built ===/,$p' <<< "$LOGC" \
    | grep -E '^[0-9]+\+[0-9]+\+[0-9]+' | tail -1 | sed 's/^/  kernel size: /'

echo
if [[ $fail -eq 0 ]] && grep -q 'S48-DONE-ok' <<< "$LOGC"; then
    echo "STAGES 4-8 OK  ($LOG)"; exit 0
fi
echo "STAGES 4-8 FAILED (rc=$rc) -- $LOG"; exit 1
