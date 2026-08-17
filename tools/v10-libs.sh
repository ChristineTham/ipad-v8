#!/usr/bin/env bash
#
# K10.2: build the Tenth Edition's libraries on V10, and compare the result with
# the host's prediction.
#
#	bash tools/v10-libs.sh [image] [src-image]
#
# THE MEASUREMENT IS THE DISAGREEMENT, exactly as in K10.1.  tools/v10-libs.py
# predicts host-side and free which of the 500 library members can resolve every
# header they include; this run measures which ones V10's own compiler accepts,
# which ones archive, and which archives reach /usr/lib.  Printing both and
# diffing them is the point: agreement means the survey can be trusted for the
# rest of K10, and each disagreement is a specific fact neither instrument could
# produce alone.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v10clone.sh"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/srcid.sh"

# GOLD is a bare name under work/v10gold and SRC is a FULL PATH, which looks
# inconsistent and is what stages 2, 3 and K10.1 all do -- srcid_check appends
# `.id' to what it is given, so it needs the path.  Matched exactly rather than
# tidied, because a harness that differs from the proven ones in a small way is
# a harness whose failures are ambiguous.
#
# STAGE 1'S IMAGE, for the reason K10.1 learned the hard way: `.stage1.s2.s3'
# carries four toolchain installs and two object trees on a 128 MB partition and
# has no room, while compiling needs the PASSES and nothing else.  "Most
# complete" was the wrong axis; "has room" is the right one.
GOLD="${1:-ipnx-v10-ra81.img.stage1}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"
LOG="$ROOT/work/v10-libs.log"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-libs: no $GOLD in work/v10gold -- stages 1-3 build it."
    exit 1
}
[[ -f "$SRC" ]] || {
    echo "v10-libs: no $SRC -- run tools/v10-srcdisk.sh."
    exit 1
}

# THE GENERATED LISTS MUST MATCH THE TREE, or this measures the previous
# generation of the survey against the current source and reports a disagreement
# that is purely bookkeeping.
python3 "$ROOT/tools/v10-libs.py" --check || {
    echo "v10-libs: the library lists are stale -- run tools/v10-libs.py --write"
    exit 1
}

# AND THE DISK MUST MATCH THE LISTS.  The trap that cost a run: the V10 source
# disk is a COPY, so regenerating v10/mk/gen/ changes nothing the guest sees, and
# three assertions failed for a week against a build that was already correct.
srcid_check "$SRC" || exit 1

# ROOM, CHECKED ON THE HOST, BECAUSE A FULL V10 FILESYSTEM HANGS RATHER THAN
# FAILING.  lsys/fs/alloc.c prints `file system full' and sleeps waiting for
# space that is not coming, so no guest-side probe can catch it -- the probe
# blocks in the same place as the thing it guards.
#
# 8,000 blocks is 31 MB.  This run's peak is lower than K10.1's (objects are
# removed per library, and the largest library is libF77's 113) but the archives
# are kept, so the same floor applies.
python3 "$ROOT/tools/v10-free.py" "$ROOT/work/v10gold/$GOLD" c --need 8000 || {
    echo "v10-libs: not enough room on the object filesystem."
    exit 1
}

no_overlap "$SRC" "$ROOT/work/v10gold/$GOLD" || exit 1

IMG=$(v10_clone "$GOLD" k102) || exit 1
SRCIMG=$(v10_clone "$SRC" k102src) || exit 1
echo "== building the libraries on $(basename "$IMG") =="

expect "$ROOT/tools/v10-libs.exp" "$IMG" "$SRCIMG" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# ---------------------------------------------------------------- the counts ---
#
# UNANCHORED, AND BY NAME.  `^'-anchored counting is what dropped `MMISS atof.o'
# and let a missing libc member hide for a week: v10_run fixes the body of a dump
# but never its first line, because the tty echoes the tail of the typed command
# into it.  The tokens are safe to match unanchored because the guest script
# spells them through shell variables ($P/$Q/$A/$Z), so the echo of the command
# carries `$P' and only the answer carries LBUILT.
c10() { grep -oE "$1 [A-Za-z_0-9+./-]+" "$LOG" 2>/dev/null | wc -l | tr -d ' '; }
built=$(c10 LBUILT); failed=$(c10 LFAILED)
arch=$(c10 LARCH);   noarch=$(c10 LNOARCH)

# The guest counted the same lines with sed; if the two disagree the transcript
# lost data and no number here means anything.  Stage 2 printed a total that
# contradicted its own assertion four lines above and nothing compared them.
gb=$(grep -oE 'TALLYB [0-9]+' "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
gf=$(grep -oE 'TALLYF [0-9]+' "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
ga=$(grep -oE 'TALLYA [0-9]+' "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
gm=$(grep -oE 'TALLYM [0-9]+' "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')

echo
if grep -q 'NOLSPACE\|LNOSPACE' "$LOG" 2>/dev/null; then
    echo "== NO MEASUREMENT: the object filesystem has no room =="
    echo "   ipnx-v10-ra81.img.stage1 is the roomy one; the s2/s3 image is not."
    echo "== v10-libs exit $rc =="
    exit 1
fi
# The kernel's own complaint, in case the probe passed and the build then filled
# the disk anyway -- a partial run whose failures are all one cause must not be
# reported as 26 findings.
if grep -q 'file system full' "$LOG" 2>/dev/null; then
    echo "== NO MEASUREMENT: the filesystem filled DURING the build =="
    grep -c 'file system full' "$LOG" | sed -e 's/^/   kernel complaints: /'
    echo "== v10-libs exit $rc =="
    exit 1
fi
if grep -q 'NOLCANARY' "$LOG" 2>/dev/null; then
    echo "== NO MEASUREMENT: a canary failed =="
    echo "   cc, ar or ranlib is not where this harness says it is -- that is a"
    echo "   fact about the arguments in v10-libs.exp, not about the Tenth Edition."
    sed -n '/NOLCANARY/,+6p' "$LOG"
    echo "== v10-libs exit $rc =="
    exit 1
fi
if [[ -z "$gb" ]]; then
    echo "== NO MEASUREMENT: the guest printed no tally =="
    echo "   The run did not reach the end of libsc.sh; the counts below would be"
    echo "   of a partial transcript."
    echo "== v10-libs exit $rc =="
    exit 1
fi
if [[ "$gb" != "$built" || "$gf" != "$failed" || "$ga" != "$arch" ]]; then
    echo "== NO MEASUREMENT: guest and host disagree =="
    echo "   guest built=$gb failed=$gf archived=$ga"
    echo "   host  built=$built failed=$failed archived=$arch"
    echo "   A fidelity metric read out of a tty is only as good as the tty."
    echo "== v10-libs exit $rc =="
    exit 1
fi

# The manifest is the denominator, and it is read rather than typed -- a
# component list that appears twice will disagree eventually and silently.
units=$(grep -vcE '^#' "$ROOT/v10/mk/gen/libs.units" | tr -d ' ')
members=$(grep -vcE '^#' "$ROOT/v10/mk/gen/libs.objs" | tr -d ' ')

echo "== K10.2: THE LIBRARIES, BUILT ON V10 =="
printf "   libraries in the manifest   %4s\n" "$units"
printf "   every member compiled       %4s\n" "$built"
printf "   some member did not         %4s\n" "$failed"
printf "   archive built and ranlib'd  %4s\n" "$arch"
printf "   archive NOT built           %4s\n" "$noarch"
printf "   members in the manifest     %4s\n" "$members"
printf "   members that did not build  %4s\n" "${gm:-?}"

# ------------------------------------------------- host prediction vs machine ---
pred=$(mktemp); got=$(mktemp)
trap 'rm -f "$pred" "$got"' EXIT
# Predicted-ready libraries: every member resolves its headers.  libs.txt column
# 5 is the member count and column 7 the header-OK count, so equality is the
# prediction -- read from the generated file rather than recomputed, so the two
# cannot drift.
grep -vE '^#' "$ROOT/v10/mk/gen/libs.txt" | awk '$5==$7 && $5>0 {print $1}' | sort > "$pred"
grep -oE "LBUILT [A-Za-z_0-9+./-]+" "$LOG" | awk '{print $2}' | sort -u > "$got"

echo
echo "   the host survey predicted   $(wc -l < "$pred" | tr -d ' ') libraries with every header resolvable"
echo "   the compiler accepted       $(wc -l < "$got" | tr -d ' ') in full"
echo
echo "   predicted ready, REJECTED by the compiler (a language fact the survey"
echo "   cannot see -- this is the porting work K10.2 actually has):"
comm -23 "$pred" "$got" | sed -e 's/^/      /' | head -30
echo
echo "   predicted blocked, ACCEPTED anyway (the survey's include model is wrong"
echo "   here, and the survey is what needs fixing):"
comm -13 "$pred" "$got" | sed -e 's/^/      /' | head -30

echo
echo "   the machine is $IMG"
echo "   full transcript $LOG"
echo "== v10-libs exit $rc =="
exit "$rc"
