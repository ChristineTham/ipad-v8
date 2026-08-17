#!/usr/bin/env bash
#
# K10.1: compile the world on V10 and compare the result with the host's
# prediction.
#
#	bash tools/v10-compile.sh [image] [src-image]
#
# Defaults to the most complete toolchain image -- stage 1's passes, stage 2's
# libc, stage 3's self-hosted generation -- and the world courier disk.
#
# THE MEASUREMENT IS THE DISAGREEMENT.  tools/v10-world.py predicts, host-side
# and free, which units can resolve every header they include; this run measures
# which ones V10's own compiler accepts.  Printing both and diffing them is the
# whole point: agreement means the survey can be trusted for the rest of K10,
# and each disagreement is a specific fact neither instrument could produce
# alone.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v10clone.sh"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/srcid.sh"

# GOLD is a bare name under work/v10gold and SRC is a FULL PATH, which looks
# inconsistent and is what stages 2 and 3 both do -- srcid_check appends `.id'
# to what it is given, so it needs the path.  Matching them exactly rather than
# tidying it, because a harness that differs from the proven ones in a small way
# is a harness whose failures are ambiguous.
# STAGE 1'S IMAGE, NOT THE MOST COMPLETE ONE, AND THE FIRST RUN FAILED ON EXACTLY
# THAT MISTAKE.  `.stage1.s2.s3' was chosen for having the whole toolchain -- and
# it carries /usr/s1, /usr/s2, /usr/s3, /usr/s3b AND stage 2's and stage 3's
# object trees, all on a 128 MB partition that was nearly full before this run's
# scratch directory existed.  22 units in, the kernel began printing
# `/mnt2: file system full' once every few seconds and the run ground on
# uselessly.
#
# Compiling needs the PASSES and nothing else -- no libc, because -c never
# links -- so stage 1's image is both sufficient and roomy.  "Most complete" was
# the wrong axis; the right one was "has room".
GOLD="${1:-ipnx-v10-ra81.img.stage1}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"
LOG="$ROOT/work/v10-compile.log"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-compile: no $GOLD in work/v10gold -- stages 1-3 build it."
    exit 1
}
[[ -f "$SRC" ]] || {
    echo "v10-compile: no $SRC -- run tools/v10-srcdisk.sh."
    exit 1
}

# THE GENERATED LISTS MUST MATCH THE TREE, or this measures the previous
# generation of the survey against the current source and reports a
# disagreement that is purely bookkeeping.
python3 "$ROOT/tools/v10-world.py" --check || {
    echo "v10-compile: the world lists are stale -- run tools/v10-world.py --write"
    exit 1
}

# AND THE DISK MUST MATCH THE LISTS.  This is the trap that cost a run: the V10
# source disk is a COPY, so regenerating v10/mk/gen/ changes nothing the guest
# sees, and three assertions failed for a week against a build that was already
# correct.  srcid_check refuses a disk stamped from different sources.
srcid_check "$SRC" || exit 1

# ROOM, CHECKED ON THE HOST, BECAUSE A FULL V10 FILESYSTEM HANGS RATHER THAN
# FAILING.  lsys/fs/alloc.c prints `file system full' and sleeps waiting for
# space that is not coming, so no guest-side probe can catch it -- the probe
# blocks in the same place as the thing it guards.  tools/v10-free.py reads the
# superblock out of the image file and counts the bitmap, on the same argument
# tools/v8fs.py was written from: read a disk from the host, don't boot one to
# look.
#
# 8,000 blocks is 31 MB, far above the survey's real peak (objects are removed
# per unit) and low enough that a normal stage image passes easily.
python3 "$ROOT/tools/v10-free.py" "$ROOT/work/v10gold/$GOLD" c --need 8000 || {
    echo "v10-compile: not enough room on the object filesystem."
    exit 1
}

no_overlap "$SRC" "$ROOT/work/v10gold/$GOLD" || exit 1

IMG=$(v10_clone "$GOLD" k10) || exit 1
SRCIMG=$(v10_clone "$SRC" k10src) || exit 1
echo "== compiling the world on $(basename "$IMG") =="

expect "$ROOT/tools/v10-compile.exp" "$IMG" "$SRCIMG" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# ---------------------------------------------------------------- the counts ---
#
# UNANCHORED, AND BY NAME.  `^'-anchored counting is what dropped `MMISS
# atof.o' and let a missing libc member hide for a week: v10_run fixes the body
# of a dump but never its first line, because the tty echoes the tail of the
# typed command into it.  The token is safe to match unanchored because the
# script spells it through a shell variable ($P/$Q/$N), so the echo of the
# command carries `$P' and only the answer carries CBUILT.
c10() { grep -oE "$1 [A-Za-z_0-9+./-]+" "$LOG" 2>/dev/null | wc -l | tr -d ' '; }
built=$(c10 CBUILT); failed=$(c10 CFAILED); nosrc=$(c10 CNOSRC)

# The guest counted the same lines with sed; if the two disagree the transcript
# lost data and no number here means anything.  Stage 2 printed a total that
# contradicted its own assertion four lines above and nothing compared them.
gb=$(grep -oE 'TALLYB [0-9]+' "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
gf=$(grep -oE 'TALLYF [0-9]+' "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')

echo
if grep -q 'NOSPACE' "$LOG" 2>/dev/null; then
    echo "== NO MEASUREMENT: the object filesystem has no room =="
    echo "   Pick an image whose /usr is not already carrying stage 2's and"
    echo "   stage 3's object trees; ipnx-v10-ra81.img.stage1 is the roomy one."
    sed -n '/NOSPACE/,+4p' "$LOG"
    echo "== v10-compile exit $rc =="
    exit 1
fi
# The kernel's own complaint, in case the probe passed and the survey then filled
# the disk anyway -- a partial run whose failures are all one cause must not be
# reported as 353 findings.
if grep -q 'file system full' "$LOG" 2>/dev/null; then
    echo "== NO MEASUREMENT: the filesystem filled DURING the survey =="
    echo "   Every unit after the first failure failed for that reason and not"
    echo "   for a reason about the Tenth Edition."
    grep -c 'file system full' "$LOG" | sed -e 's/^/   kernel complaints: /'
    echo "== v10-compile exit $rc =="
    exit 1
fi
if grep -q 'NOCANARY' "$LOG" 2>/dev/null; then
    echo "== NO MEASUREMENT: the canary did not compile =="
    echo "   halt.c is built by stage 1 on this machine, so the flags in"
    echo "   v10-compile.exp are wrong -- not the Tenth Edition."
    sed -n '/NOCANARY/,+6p' "$LOG"
    echo "== v10-compile exit $rc =="
    exit 1
fi
if [[ -z "$gb" ]]; then
    echo "== NO MEASUREMENT: the guest printed no tally =="
    echo "   The run did not reach the end of worldc.sh; the counts below would"
    echo "   be of a partial transcript."
    echo "== v10-compile exit $rc =="
    exit 1
fi
if [[ "$gb" != "$built" || "$gf" != "$failed" ]]; then
    echo "== NO MEASUREMENT: guest and host disagree =="
    echo "   guest counted built=$gb failed=$gf; host counted built=$built failed=$failed"
    echo "   A fidelity metric read out of a tty is only as good as the tty."
    echo "== v10-compile exit $rc =="
    exit 1
fi

echo "== K10.1: THE WORLD, COMPILED ON V10 =="
printf "   units compiled            %4s\n" "$built"
printf "   units that did not        %4s\n" "$failed"
printf "   units with no source      %4s\n" "$nosrc"

# ------------------------------------------------- host prediction vs machine ---
pred=$(mktemp); got=$(mktemp)
trap 'rm -f "$pred" "$got"' EXIT
grep -vE '^#' "$ROOT/v10/mk/gen/world.txt" | awk '$4=="ready"||$4=="variant"{print $1}' | sort > "$pred"
grep -oE "CBUILT [A-Za-z_0-9+./-]+" "$LOG" | awk '{print $2}' | sort -u > "$got"

echo
echo "   the host survey predicted   $(wc -l < "$pred" | tr -d ' ') units able to resolve every header"
echo "   the compiler accepted       $(wc -l < "$got" | tr -d ' ')"
echo
echo "   predicted ready, REJECTED by the compiler (a language fact the survey"
echo "   cannot see -- this is the porting work K10 actually has):"
comm -23 "$pred" "$got" | sed -e 's/^/      /' | head -40
echo
echo "   predicted blocked, ACCEPTED anyway (the survey's include model is"
echo "   wrong here, and the survey is what needs fixing):"
comm -13 "$pred" "$got" | sed -e 's/^/      /' | head -40

echo
echo "   the machine is $IMG"
echo "   full transcript $LOG"
echo "== v10-compile exit $rc =="
exit "$rc"
