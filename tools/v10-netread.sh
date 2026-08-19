#!/usr/bin/env bash
# Does a V10 netfs read return the WHOLE file?  One boot, one question.
#
#	bash tools/v10-netread.sh [k13-image]
#
# K15 died on `"32ld.c":214:syntax error / saw EOF' over a 295-line file, and
# netfsd's trace showed one NREAD of 4096 bytes serving a 5870-byte file with no
# second read anywhere.  Byte 4096 of that file falls on line 213.  So the read
# really did stop after one block, and the failure presented as a defect in Bell
# Labs' source.
#
# THREE THINGS ARE MEASURED, and until now none of them was:
#   * truncation, by `wc -c' against the host's own stat -- no compiler involved.
#   * WHERE THE TIME GOES.  "~9.6 s per request" was K15's elapsed time divided by
#     399 requests, which is a request RATE: a guest compiling between requests
#     produces that number just as readily as a slow server does.  netfsd now
#     reports its own service time separately from time spent waiting on the
#     guest, so the two readings cannot be confused again.
#   * dropped frames, via `show il statistics' at the halt -- pdp11_il.c drops a
#     received frame outright when the guest has no buffer posted, and counts it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"

for fn in no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || {
        echo "v10-netread: $fn is not defined -- a tools/*.sh source line is missing."
        exit 2
    }
done

GOLD="${1:-ipnx-v10-ra81.img.stage1.k102.k7.k13}"
TPORT="${TPORT:-9320}"
NETFSD="$ROOT/netfs/.build/release/netfsd"
LOG="$ROOT/work/v10-netread.log"
LIST="$ROOT/work/netread.list"
TRACE="$ROOT/work/netfs-netread.log"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-netread: no $GOLD -- bash tools/v10-netboot.sh builds it."
    exit 1
}

# TRUNCATE BOTH LOGS FIRST.  A predicate a stale file can satisfy is how a
# complete, consistent, forty-minute-old report gets read as this run's.
: > "$LOG"; : > "$TRACE"

# ===================== the file list, with HOST-SIDE truth ==================
# Sizes come from stat, never from a number written down here: a list that
# restates a measurement will disagree with it.  The set deliberately straddles
# the 4096 boundary in both directions, and includes the two files K15 and K14
# already measured -- 32ld.c, which failed, and a two-block file that worked.
FILES=(
    blit/include/ctype.h                              # 744    one block
    src/history/ix/src/jerq/mux/proto/psend.c         # 1905   one block
    blit/include/mpx.h                                # 4900   two, KNOWN GOOD
    src/history/ix/src/jerq/mux/32ld.c                # 5870   two, KNOWN BAD
    src/history/ix/src/jerq/mux/proto/precv.c         # 6289   two
    src/history/ix/src/jerq/mux/term/control.c        # 12961  four
    src/history/ix/src/jerq/mux/mux.c                 # 23747  six
)
: > "$LIST"
for f in "${FILES[@]}"; do
    p="$ROOT/work/v10/$f"
    [[ -f "$p" ]] || { echo "v10-netread: no $f under work/v10 -- tools/v10-import.py"; exit 1; }
    printf '%s\t%s\n' "$f" "$(stat -f%z "$p")" >> "$LIST"
done
echo "== $(wc -l < "$LIST" | tr -d ' ') files, sizes measured host-side =="
cat "$LIST" | awk -F'\t' '{printf "   %8s  %s\n", $2, $1}'

echo "== building netfsd =="
( cd "$ROOT/netfs" && swift build -c release ) >/dev/null || exit 1

"$NETFSD" -p "$TPORT" -v "$ROOT/work/v10" > "$TRACE" 2>&1 &
NPID=$!
sleep 1
kill -0 "$NPID" 2>/dev/null || { echo "netfsd died"; tail -5 "$TRACE"; exit 1; }
trap 'kill "$NPID" 2>/dev/null' EXIT

no_overlap "$ROOT/work/v10gold/$GOLD" || exit 1
IMG=$(v10_clone "$GOLD" netread) || exit 1

echo "== reading each file three times over netfs =="
expect "$ROOT/tools/v10-netread.exp" "$IMG" "$TPORT" "$LIST" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# ===================== the host's own count, from the transcript =============
# Unanchored, because v10_run's first line of output shares a line with the tty's
# echo of the command that produced it; `sort -u' is not wanted here because a
# repeat IS a datum (three passes per file).
nfiles=$(wc -l < "$LIST" | tr -d ' ')
want=$(( nfiles * 3 ))          # per reader
cnt() { tr -d '\r' < "$LOG" | grep -cE "$1" || true; }

wsame=$(cnt 'NRSAME W[0-9]+');  wshort=$(cnt 'NRSHORT W[0-9]+ ')
csame=$(cnt 'NRSAME C[0-9]+');  cshort=$(cnt 'NRSHORT C[0-9]+ ')
nsame=$(( wsame + csame )); nshort=$(( wshort + cshort ))

echo
echo "== reads, BY READER -- this is the whole point of the probe =="
printf '   %-34s %s full, %s SHORT  (of %s)\n' \
       "wc  -- one read(2) of 65536"  "$wsame" "$wshort" "$want"
printf '   %-34s %s full, %s SHORT  (of %s)\n' \
       "cat -- repeated read(2) of 4096" "$csame" "$cshort" "$want"
echo
echo "   wc exercises naread()'s own loop; cat exercises a SECOND read(2) on an"
echo "   open netfs file, which is cpp's pattern and what K15 died on.  A split"
echo "   between these two rows localises the fault; one reader could not."

# AN INTERNAL CONSISTENCY CHECK, because two readings agreeing is not two
# readings being right when both count the same tokens.  This one compares a sum
# against a number that came from neither grep.
# AN INTERNAL CONSISTENCY CHECK, because two readings agreeing is not two readings
# being right when both count the same tokens.  This compares a sum against a
# number that came from neither grep.
if [[ $(( nsame + nshort )) -ne $(( want * 2 )) ]]; then
    echo "   INCOMPLETE: $(( nsame + nshort )) verdicts for $(( want * 2 )) reads --"
    echo "   the run did not finish, or lines were lost.  Read $LOG before"
    echo "   believing either row above."
    rc=1
fi

if [[ "$nshort" != "0" ]]; then
    echo
    echo "== every short read: reader+pass, and the length it stopped at =="
    tr -d '\r' < "$LOG" | grep -oE 'NRSHORT [WC][0-9]+ [0-9]+' | sort | uniq -c
fi

# ===================== where the time went ==================================
echo
echo "== netfsd's own accounting =="
grep -E 'connection closed after' "$TRACE" || echo "   (no connection summary -- did the guest mount?)"
printf '   NREAD requests served: %s\n' "$(grep -cE '^#[0-9]+ NREAD' "$TRACE")"

echo
echo "== the card's own counters (from the halt) =="
sed -n '/show il statistics/,/sim>/p' "$LOG" | sed -e 's/^/   /' | head -20

echo
echo "v10-netread exit $rc"
exit $rc
