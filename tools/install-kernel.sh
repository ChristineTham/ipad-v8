#!/bin/bash
# Install the stage-7 kernel onto the build machine and prove it boots.
#
#	tools/install-kernel.sh [limit-seconds]
#
# See tools/install-kernel.exp for why this is needed: stage 8 wants a third
# drive, and a conf that declares one only matters in a kernel that is
# running. This is also the first time anything stage 7 produced gets booted
# rather than merely linked.
#
# It takes a whole-image backup first. rp07v8.net is expensive to rebuild --
# it is the N-track machine, with the il0 kernel and the netfs stream fix --
# and an unbootable kernel would otherwise cost all of it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/work/myv8"
LIMIT=${1:-1800}
LOG="$WORK/install-kernel.log"

cd "$WORK" || exit 1
export PATH="$ROOT/work/opensimh/BIN:$PATH"

command -v vax780 >/dev/null || { echo "ik: vax780 not on PATH"; exit 1; }
for f in rp07v8.net rp06build rp07new bootV8; do
    [[ -e $f ]] || { echo "ik: no $f"; exit 1; }
done
if pgrep -x vax780 >/dev/null; then
    echo "ik: a vax780 is already running -- wait for it"; exit 1
fi

# Refuse rather than overwrite: a backup taken AFTER a bad kernel is installed
# is not a backup. If one exists it is from an earlier attempt and is the one
# worth keeping.
if [[ -e rp07v8.net.bak ]]; then
    echo "ik: keeping the existing rp07v8.net.bak (from an earlier attempt)"
else
    echo "== backing up rp07v8.net =="
    cp rp07v8.net rp07v8.net.bak || { echo "ik: backup failed"; exit 1; }
fi

cleanup() {
    [[ -n "${EXP_PID:-}" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

: > "$LOG"
expect "$ROOT/tools/install-kernel.exp" &
EXP_PID=$!
for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$EXP_PID" 2>/dev/null || break
    sleep 1
done
wait "$EXP_PID" 2>/dev/null
rc=$?

# Expect's own timeout message quotes the pattern it gave up on, so a run that
# NEVER saw a marker contains that marker in the log. Drop those lines before
# scoring or every failure reads as a success.
LOGC=$(tr -d '\r' < "$LOG" | grep -v 'GAVE UP')
fail=0
ck() {
    if grep -qE "$2" <<< "$LOGC"; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n' "$1"; fail=1; fi
}

echo
ck "stage 7 kernel present"        'IK-HAVE-KERNEL-ok'
ck "copied byte-for-byte"          'IK-COPY-ok'
ck "our kernel booted on its own"  'IK-DONE-ok'
ck "the new kernel can see drive 2" 'IK-DRIVE2-ok'
# The autoconfig prints its disk table at every boot, so the log carries the
# old kernel's ("hp0 ... hp1" and stop) and then the new one's. That is
# direct evidence of the conf change taking effect, and better than the dd
# probe above because it comes from the kernel rather than from a command.
ck "autoconfig reports four disks" '^hp3 at mba0 drive 3'
printf '  disks seen across both boots: %s\n' \
    "$(grep -oE '^hp[0-9] at mba0 drive [0-9]' <<< "$LOGC" | sort -u | tr '\n' ' ')"

echo
if [[ $fail -eq 0 ]]; then
    echo "KERNEL INSTALLED  ($LOG)"
    echo "the previous kernel is /ounix; the image backup is rp07v8.net.bak"
    exit 0
fi
echo "INSTALL FAILED (rc=$rc) -- $LOG"
echo "to recover: cp $WORK/rp07v8.net.bak $WORK/rp07v8.net"
exit 1
