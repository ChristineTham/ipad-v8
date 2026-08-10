#!/bin/bash
# Apply the netfs-over-TCP kernel fix to work/myv8/rp07v8.net and rebuild.
#
#   tools/drive-streamfix.sh [limit-seconds]
#
# One-shot: patches usr/sys/sys/streamio.c's istread(), rebuilds the kernel,
# installs it as /unix (keeping the pre-fix one as /unix.n3) and halts.
# Rationale and the diagnosis are at the top of tools/n6-streamfix.exp.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIMIT="${1:-3600}"

EXP_PID=""
cleanup() {
    [[ -n "$EXP_PID" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

cd "$ROOT/work/myv8" || exit 1
export PATH="$ROOT/work/opensimh/BIN:$PATH"
command -v vax780 >/dev/null || { echo "vax780 not on PATH"; exit 1; }
[[ -f rp07v8.net ]] || { echo "no rp07v8.net"; exit 1; }

rm -f n6-streamfix.log
echo "== patching istread and rebuilding the kernel =="
expect "$ROOT/tools/n6-streamfix.exp" > /dev/null 2>&1 &
EXP_PID=$!

for ((i = 0; i < LIMIT; i++)); do
    kill -0 "$EXP_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$EXP_PID" 2>/dev/null; then
    echo "TIMEOUT after ${LIMIT}s:"; tail -30 n6-streamfix.log; exit 2
fi
wait "$EXP_PID"; rc=$?

fail=0
check() {
    if grep -qE "$2" n6-streamfix.log; then echo "  ok    $1"
    else echo "  FAIL  $1"; fail=$((fail + 1)); fi
}
# grep works a line at a time, so "X appears between markers A and B" has to
# cut the section out first. Writing it as one multi-line regex silently never
# matches, which reads as a failed test rather than a broken one.
inrange() {         # inrange <description> <from> <to> <regex>
    if sed -n "/$2/,/$3/p" n6-streamfix.log | grep -qE "$4"; then
        echo "  ok    $1"
    else
        echo "  FAIL  $1"; fail=$((fail + 1))
    fi
}
echo
echo "== verdict =="
check "booted"                       'SFIX-boot-ok'
check "ed applied the edit"          'SFIX-edited'
inrange "putbq is now inside istread" '^istread' '^\}' 'putbq\(RD\(stq->wrq\), bp\)'
inrange "the remainder is kept"       '^istread' '^\}' 'bp->rptr \+= n'
inrange "it waits for the full count" '^istread' '^\}' 'if \(count == 0\)'
inrange "a zero-length read returns 0" '^istread' '^\}' 'return\(0\);'
check "the QDELIM early return is gone" 'if \(stq->flag&HUNGUP\) \{'
check "kernel relinked"              'SFIX-made'
check "installed"                    'SFIX-DONE'
if grep -qE "Undefined|Error code|\*\*\*" n6-streamfix.log; then
    echo "  FAIL  the build reported errors"
    grep -nE "Undefined|Error code|\*\*\*" n6-streamfix.log | head -5
    fail=$((fail + 1))
else
    echo "  ok    no build errors"
fi

if [[ $fail -eq 0 ]]; then echo; echo "STREAM FIX APPLIED"; exit 0; fi
echo; echo "STREAM FIX FAILED ($fail checks)"; exit 1
