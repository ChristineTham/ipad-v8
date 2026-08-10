#!/bin/bash
# Serve the repo's v8/ tree to the guest and build the bootstrap toolchain from it.
#
#	tools/drive-stage1.sh [limit-seconds] [port]
#
# The share is the repo directory itself, read-only: the guest copies what it
# needs to local disk and builds there, so nothing the build does can reach back
# and touch our source.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIMIT="${1:-7200}"
PORT="${2:-9300}"
NETFSD="$ROOT/netfs/.build/release/netfsd"
LOG="$ROOT/work/myv8/c2-stage1.log"

EXP_PID=""; SRV_PID=""; WD=""
cleanup() {
    [[ -n "$SRV_PID" ]] && kill -9 "$SRV_PID" 2>/dev/null
    [[ -n "$EXP_PID" ]] && kill -9 "$EXP_PID" 2>/dev/null
    [[ -n "$WD" ]] && kill "$WD" 2>/dev/null
    pkill -9 -x vax780 2>/dev/null
    true
}
trap cleanup EXIT INT TERM

[[ -x "$NETFSD" ]] || { echo "build netfsd first:  (cd netfs && swift build -c release)"; exit 1; }

# regenerating first means the guest can never build from stale makefiles
python3 "$ROOT/v8/mk/mkdep.py" --check || {
    echo "regenerating..."; python3 "$ROOT/v8/mk/mkdep.py"; }

cd "$ROOT/work/myv8" || exit 1
: > c2-stage1.log
: > "$ROOT/work/netfsd-stage1.log"

# read-only: the build must not be able to write to the repo
"$NETFSD" -p "$PORT" -v "$ROOT/v8" > "$ROOT/work/netfsd-stage1.log" 2>&1 &
SRV_PID=$!
sleep 1
kill -0 "$SRV_PID" 2>/dev/null || { echo "netfsd died:"; cat "$ROOT/work/netfsd-stage1.log"; exit 1; }
echo "netfsd serving $ROOT/v8 on 127.0.0.1:$PORT (read-only, pid $SRV_PID)"

PATH="$ROOT/work/opensimh/BIN:$PATH" expect "$ROOT/tools/c2-stage1.exp" "$PORT" >/dev/null 2>&1 &
EXP_PID=$!
( sleep "$LIMIT"; kill -9 "$EXP_PID" 2>/dev/null; pkill -9 -x vax780 2>/dev/null ) &
WD=$!
wait "$EXP_PID"; rc=$?
kill "$WD" 2>/dev/null; WD=""

LOGC=$(tr -d '\r' < "$LOG")
fail=0
ck() {  # ck <label> <pattern>
    if grep -qE "$2" <<< "$LOGC"; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n' "$1"; fail=1; fi
}

echo
echo "== share =="
ck "mounted /n/src"                '^C2-MOUNTED'
ck "CASEMAP readable over netfs"   '^usr/src/cmd.*%4Dail'

echo
echo "== staging =="
ck "source copied"                 'stage: done'
ck "Mail and mail both present"    'ok      usr/src/cmd/Mail'
ck "C and c both present"          'ok      jerq/src/lib/C'
grep -qE 'MISSING' <<< "$LOGC" && { echo "  FAIL  something did not survive staging"; fail=1; }

echo
echo "== stage 1 toolchain =="
for t in yacc make lex cpp ccom c2 as ld ar ranlib nm size strip cc; do
    if grep -qE "^=== stage1: $t " <<< "$LOGC"; then
        if grep -A40 "^=== stage1: $t " <<< "$LOGC" | grep -qE 'BUILD FAILED|INSTALL FAILED'; then
            printf '  FAIL  %s\n' "$t"; fail=1
        else printf '  ok    %s\n' "$t"; fi
    else printf '  ----  %s (never reached)\n' "$t"; fail=1; fi
done

echo
echo "== the new compiler =="
# Anchored: the string also appears inside the echo that writes t.c, and an
# unanchored grep reported "ok" for a compiler that was never built.
ck "it runs and compiles"          '^newcc-ok'
v=$(grep -oE 'cmp-newcc-vs-oldcc=[0-9]+' <<< "$LOGC" | tail -1 | cut -d= -f2)
case "${v:-?}" in
    0) echo "  ok    new compiler reproduces the old one's output byte-for-byte" ;;
    "") echo "  ----  comparison never ran"; fail=1 ;;
    *) echo "  note  new and old compilers differ (exit $v) -- expected only if"
       echo "        the source has diverged from what built /lib/ccom" ;;
esac

echo
grep -E 'STAGE1 OK|STAGE1 INCOMPLETE' <<< "$LOGC" | tail -1 | sed 's/^/  /'
echo
if [[ $fail -eq 0 ]] && grep -q 'C2-DONE' <<< "$LOGC"; then
    echo "STAGE 1 OK  ($LOG)"; exit 0
fi
echo "STAGE 1 FAILED (rc=$rc) -- $LOG"; exit 1
