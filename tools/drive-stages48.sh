#!/bin/bash
# Stages 4 to 8 against a build filesystem that already has stages 1 to 3.
#
#	tools/drive-stages48.sh [limit] [port] [first-stage] [last-stage] [ref-image] [rp06|rp07]
#
# first-stage defaults to 4.  Stages 4 to 7 leave their products on the build
# filesystem, so when only stage 8 has changed, `tools/drive-stages48.sh "" ""
# 8 8' reaches it in a couple of minutes instead of fifty.  Nothing is skipped
# silently: the summary below reports the skipped stages as such.
#
# last-stage defaults to 9.  Stage 9 is the chroot self-rebuild and costs the
# better part of an hour; iterating on what stage 8 puts ON the disk does not
# need the new system re-proved able to rebuild itself every time.
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
FROM="${3:-4}"
TO="${4:-9}"
# The reference image stage 8 lifts carry.txt off. Must match the --image
# tools/mkcarry.py generated the lists from; see docs/golden-disk.md.
REF="${5:-rp07new}"
# rp07 (the build and Track B disk) or rp06 (what the app can ship).
TARGET="${6:-rp07}"
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
# Same rule for the carry list: it decides what stage 8 lifts off the TUHS
# image, so a stale one silently ships the wrong disk.
python3 "$ROOT/tools/mkcarry.py" --check || {
    echo "s48: run tools/mkcarry.py"; exit 1; }

# The disk stage 8 builds.  1008000 sectors is hp7_sizes' partition c, the
# whole RP07 -- see v8/mk/builddisk.sh for why the sizes come from the driver.
# Sizes are hp6_sizes/hp7_sizes partition c -- the whole volume. See
# v8/mk/builddisk.sh for why they come from the driver and not from memory.
if [[ "$TARGET" == rp06 ]]; then TIMG=rp06new; TSEC=340670; else TIMG=rp07new; TSEC=1008000; fi
[[ -e $TIMG ]] || {
    echo "== making $TIMG ($((TSEC / 2048)) MB) =="
    dd if=/dev/zero of=$TIMG bs=512 count=$TSEC 2>/dev/null
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
expect "$ROOT/tools/drive-stages48.exp" "$PORT" "$FROM" "$TO" "$REF" "$TARGET" &
EXP_PID=$!
# The size cap is not tidiness. A SLiRP attach that cannot bind prints
# "Sockets: bind error 13 - Permission denied" and RETRIES, with no backoff
# and no give-up, so a run that failed on its very first command sat there
# writing the same line until it had produced 3.3 million of them and a 152 MB
# log. Nothing in the timeout logic notices, because the run is not hung --
# it is extremely busy.
MAXLOG=$((64 * 1024 * 1024))
for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$EXP_PID" 2>/dev/null || break
    if (( i % 10 == 0 )) && [[ $(stat -f %z "$LOG" 2>/dev/null || echo 0) -gt $MAXLOG ]]; then
        echo "s48: log passed 64 MB -- something is looping, stopping"
        tail -3 "$LOG"
        kill -9 "$EXP_PID" 2>/dev/null
        break
    fi
    sleep 1
done
wait "$EXP_PID" 2>/dev/null
rc=$?

# Drop expect's own timeout diagnostic before scoring. `must' prints the
# pattern it gave up on -- "never saw 'S48-MOUNTED-ok'" -- so the message
# announcing that a marker NEVER APPEARED contains that marker, and a plain
# grep then scores the stage as ok. It reported "share mounted at /n/src: ok"
# on a run that died because the share was not mounted.
#
# Same shape as the tty-echo trap the markers are spelled through a shell
# variable to avoid: the thing that talks about the marker is not the marker.
LOGC=$(tr -d '\r' < "$LOG" | grep -v 'FAILED: never saw')
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
echo "== stages $FROM to $TO =="
# A stage below FROM was not run, and says so: reporting it as ok would be a
# lie about this run, and omitting it would make a partial run look complete.
ckstage() {                             # ckstage <n> <label> <pattern>
    if [[ $1 -lt $FROM || $1 -gt $TO ]]; then printf '  --    %s (not run)\n' "$2"
    else ck "$2" "$3"; fi
}
ckstage 4 "4: headers"            'STAGE4 OK'
ckstage 5 "5: libraries"          'STAGE5 OK'
ckstage 6 "6: commands"           'STAGE6 OK'
ckstage 7 "7: the kernel"         'STAGE7 OK'
ckstage 8 "8: a disk"             'STAGE8 OK'
ckstage 9 "9: rebuilds itself"    'STAGE9-CHROOT OK'
grep -E '  BUILD FAILED |  INSTALL FAILED |Don.t know how to make' <<< "$LOGC" \
    | sed 's/^/  /' | head -20
sed -n '/=== stage 7: what got built ===/,$p' <<< "$LOGC" \
    | grep -E '^[0-9]+\+[0-9]+\+[0-9]+' | tail -1 | sed 's/^/  kernel size: /'

echo
if [[ $fail -eq 0 ]] && grep -q 'S48-DONE-ok' <<< "$LOGC"; then
    echo "STAGES 4-8 OK  ($LOG)"; exit 0
fi
echo "STAGES 4-8 FAILED (rc=$rc) -- $LOG"; exit 1
