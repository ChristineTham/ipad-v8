#!/bin/bash
# Serve the repo's v8/ tree to the guest and build the bootstrap toolchain from it.
#
#	tools/drive-stage1.sh [limit-seconds] [port]
#
# The share is the repo directory itself, mounted read-only at /n/src and
# compiled straight off the wire.  Nothing is copied to guest disk: only build
# products land there, on their own filesystem.  The read-only mount is what
# guarantees a failed build cannot reach back and touch our source.
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
python3 "$ROOT/tools/ipnx-release.py" --check || exit 1

cd "$ROOT/work/myv8" || exit 1
# A blank RP06 for build products.  Recreated per run: it holds nothing we
# want to keep, and a fresh filesystem is one less variable.
rm -f rp06build && dd if=/dev/zero of=rp06build bs=512 count=340670 2>/dev/null
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

# Patterns below are deliberately UNANCHORED.
#
# The tty echoes typed characters as they arrive and they interleave into
# whatever is printing, so a marker routinely lands mid-line -- the last run
# logged "echC3-CASE-clean" and "echoC3-CLOCK-ok", and every ^-anchored check
# scored them as failures on a run where they had in fact passed.
#
# Unanchored is only safe because the guest spells each marker with a shell
# variable (echo C3-CLOCK$OK), so the echo contains "C3-CLOCK$OK" and the
# output contains "C3-CLOCK-ok"; nothing but the result can match the full
# string.  Do not "simplify" a marker back to a literal.
echo
echo "== share =="
ck "mounted /n/src"                'C2-MOUNTED-ok'
ck "CASEMAP readable over netfs"   'C3-CASEMAP-ok'
# The two directory pairs that cannot coexist on macOS at all.  netfsd's
# CaseMap serves them under their true names, so the guest must see both --
# and must never see an escaped one, which would not fit a 14-byte direct.
ck "Mail and mail both visible"    'C3-CASE-Mail-ok'
ck "C and c both visible"          'C3-CASE-C-ok'
# Not a blanket grep for '%': CASEMAP's own contents are full of escaped names
# and we print them deliberately above.  This asks the guest to look for them
# in a *directory listing*, where the answer must be none.
ck "no escaped name in a listing"  'C3-CASE-clean-ok'

echo
echo "== clock =="
ck "guest clock set past 2000"     'C3-CLOCK-ok'

echo
echo "== build filesystem =="
ck "mkfs + fsck clean on rp1g"     'BUILDFS-ok'
ck "mounted on /b"                 '/dev/rp1g|rp1g +[0-9]'

echo
echo "== stage 1 toolchain =="
for t in yacc make lex cpp ccom c2 as ld ar ranlib nm size strip cc; do
    if grep -qE "=== stage1: $t " <<< "$LOGC"; then
        if grep -A40 "=== stage1: $t " <<< "$LOGC" | grep -qE 'BUILD FAILED|INSTALL FAILED'; then
            printf '  FAIL  %s\n' "$t"; fail=1
        else printf '  ok    %s\n' "$t"; fi
    else printf '  ----  %s (never reached)\n' "$t"; fail=1; fi
done

echo
echo "== the new compiler =="
# t.c prints this via %s, so "newcc-ok" cannot appear in the echo of the line
# that writes t.c -- which is how an earlier unanchored grep reported a working
# compiler that had never been built.
ck "it runs and compiles"          'newcc-ok'
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
if [[ $fail -eq 0 ]] && grep -q 'C2-DONE-ok' <<< "$LOGC"; then
    echo "STAGE 1 OK  ($LOG)"; exit 0
fi
echo "STAGE 1 FAILED (rc=$rc) -- $LOG"; exit 1
