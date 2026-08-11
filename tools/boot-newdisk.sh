#!/bin/bash
# Boot the disk stage 8 built and report what it is.
#
#	tools/boot-newdisk.sh [seconds]
#
# See tools/boot-newdisk.exp: the image is booted ALONE, so nothing it needs
# can be satisfied from another drive.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/work/myv8"
LIMIT=${1:-900}
LOG="$WORK/boot-newdisk.log"

cd "$WORK" || exit 1
export PATH="$ROOT/work/opensimh/BIN:$PATH"

command -v vax780 >/dev/null || { echo "bn: vax780 not on PATH"; exit 1; }
[[ -e rp07new ]] || { echo "bn: no rp07new -- run stage 8 first"; exit 1; }
[[ -e bootV8 ]]  || { echo "bn: no bootV8"; exit 1; }
if pgrep -x vax780 >/dev/null; then
    echo "bn: a vax780 is already running -- wait for it"; exit 1
fi

cleanup() {
    [[ -n "${EXP_PID:-}" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

: > "$LOG"
expect "$ROOT/tools/boot-newdisk.exp" &
EXP_PID=$!
for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$EXP_PID" 2>/dev/null || break
    sleep 1
done
wait "$EXP_PID" 2>/dev/null
rc=$?

# Expect's timeout message quotes the pattern it gave up on, so a failed run
# contains every marker it was looking for. Drop those lines before scoring.
LOGC=$(tr -d '\r' < "$LOG" | grep -v 'GAVE UP')
fail=0
ck() {
    if grep -qE "$2" <<< "$LOGC"; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n' "$1"; fail=1; fi
}

echo
echo "== the disk we built, booted alone =="
ck "the boot block found a kernel" 'hp\(0,0\)unix'
ck "our kernel's autoconfig ran"   '^hp0 at mba0 drive 0'
ck "init, /etc/rc and getty"       'login:'
ck "a root shell"                  'BN-SHELL-ok'
ck "cc is installed"               'BN-HAVE-CC-ok'
ck "and it compiles and runs"      'BN-COMPILED-ok'
ck "mux and muxterm are there"     'BN-MUX-ok'
ck "and the widened pair (A4)"     'BN-WMUX-ok'
ck "games: fortune and bcd"        'BN-GAMES-ok'
ck "the manual and tmac"           'BN-MAN-ok'
ck "yacc and strip in /usr/bin"    'BN-YACC-ok'
ck "login read /.profile"          'term=vt100'
ck "clean halt"                    'BN-DONE-ok'

echo
sed -n '/new%%% df/,/new%%% ls -l \/unix/p' <<< "$LOGC" | grep -E '^/|kbytes' | sed 's/^/  /'
grep -E '^[0-9]+$' <<< "$LOGC" | tail -2 | sed 's/^/  files in bin, usr\/bin: /'

echo
if [[ $fail -eq 0 ]]; then echo "THE DISK BOOTS  ($LOG)"; exit 0; fi
echo "BOOT FAILED (rc=$rc) -- $LOG"; exit 1
