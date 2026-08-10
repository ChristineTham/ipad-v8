#!/bin/bash
# Is V8's cc reproducible?  One boot, four questions -- see tools/c1-determinism.exp.
#
#   tools/drive-determinism.sh [limit-seconds]
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIMIT="${1:-1800}"
LOG="$ROOT/work/myv8/c1-determinism.log"

EXP_PID=""
cleanup() {
    [[ -n "$EXP_PID" ]] && kill -9 "$EXP_PID" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

cd "$ROOT/work/myv8" || exit 1
: > c1-determinism.log
PATH="$ROOT/work/opensimh/BIN:$PATH" expect "$ROOT/tools/c1-determinism.exp" >/dev/null 2>&1 &
EXP_PID=$!

# watchdog: never let a wedged emulator outlive the run
( sleep "$LIMIT"; kill -9 "$EXP_PID" 2>/dev/null; pkill -9 -x vax780 2>/dev/null ) &
WD=$!
wait "$EXP_PID"; rc=$?
kill "$WD" 2>/dev/null

LOGC=$(tr -d '\r' < "$LOG")

say() { printf '  %-26s %s\n' "$1" "$2"; }
echo
echo "== compiler determinism =="
for k in cmp-ls cmp-ls-stripped cmp-self; do
    v=$(grep -oE "^$k=[0-9]+" <<< "$LOGC" | tail -1 | cut -d= -f2)
    case "${v:-?}" in
        0) say "$k" "IDENTICAL" ;;
        "") say "$k" "(no result -- see $LOG)" ;;
        *) say "$k" "differs (exit $v)" ;;
    esac
done

echo
echo "== sizes =="
grep -E 'ls\.new|ls\.str|/bin/ls' <<< "$LOGC" | grep -E '^-r' | sed 's/^/  /' | head -6

echo
echo "== differing bytes (stripped vs shipped) =="
grep -A1 'cmp -l ls.str /bin/ls | wc -l' <<< "$LOGC" | tail -1 | sed 's/^/  /'

echo
echo "== did the makefile-driven build work? =="
grep -qE 'Error|\*\*\*|not found' <<< "$LOGC" && echo "  errors present -- read the log" || echo "  no obvious errors"

echo
if grep -q 'DET-DONE' <<< "$LOGC"; then echo "PROBE COMPLETE  ($LOG)"; exit 0; fi
echo "PROBE DID NOT FINISH (rc=$rc) -- $LOG"; exit 1
