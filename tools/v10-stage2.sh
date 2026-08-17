#!/usr/bin/env bash
#
# Stage 2 of the Tenth Edition bootstrap: libc, built on V10.
#
#	tools/v10-stage2.sh [stage1-image] [src-image]
#
# The stage order is V8's, from docs/build-from-source.md:
#
#	1  the toolchain
#	2  libc                          <-- this
#	3  the toolchain again, with stage 2's libc -- the fixpoint
#	4  headers   5  libraries   6  commands   7  kernel   8  disk
#	9  the new system rebuilds itself under chroot
#
# IT STARTS FROM THE STAGE-1 MACHINE, NOT THE GOLDEN.  Stage 1 left its
# compiler under /usr/s1 and installed ar, cmp, ed and tail into the running
# system; this stage needs all of them, and it asserts each one before it
# builds anything so that a run started from the wrong image says so in one
# line rather than in 261 confusing ones.
#
# THE CLONE RULE APPLIES, and harder than on V8: there is no committed V10
# image to restore from, and recovery is a half-hour tools/v10-golden.sh
# followed by a stage-1 run.  See tools/v10clone.sh.
#
# THE SOURCE DISK IS CLONED TOO, and it did not used to be.  The comment here
# used to read "the source disk is NOT cloned -- it is mounted read-write but
# only read", which was true of THIS run and irrelevant, because the hazard was
# never this run writing it.  tools/v10-srcdisk.sh REBUILDS that path with
# `dd if=/dev/zero of=$GOLD/ipnx-v10-src.img', and on 2026-08-17 it did so
# while a stage-2 run had the file attached as rq1.  Both exited 0 and every
# number the stage-2 run produced was measured against an image that changed
# mid-run.  See tools/norun.sh.
#
# `cp -c' is free on APFS, so "we only read it" was never worth the exposure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/v10clone.sh"
source "$ROOT/tools/norun.sh"

GOLD="${1:-ipnx-v10-ra81.img.stage1}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"
LOG="$ROOT/work/v10-stage2.log"

[[ -f "$SRC" ]] || { echo "v10-stage2: no $SRC -- run tools/v10-srcdisk.sh"; exit 1; }
[[ -f "$ROOT/work/v10boot/uda750" ]] || { echo "v10-stage2: no uda750 -- run tools/v10-uda750.py"; exit 1; }

# EVERY simulator, not just a vax750.  The check that stood here was
# `pgrep -f BIN/vax750', which is blind to the vax780 the source-disk builder
# runs -- and that is exactly the overlap that voided a run.
no_overlap "$SRC" "$ROOT/work/v10gold/$GOLD" || exit 1

python3 "$ROOT/v10/mk/mkdep.py" --check || { echo "regenerate the makefiles first"; exit 1; }

IMG=$(v10_clone "$GOLD" s2) || exit 1
SRCIMG=$(v10_clone "$SRC" s2src) || exit 1
echo "== stage 2 on $(basename "$IMG") =="
echo "   source disk $(basename "$SRCIMG")"
echo

expect "$ROOT/tools/v10-stage2.exp" "$IMG" "$SRCIMG" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# ------------------------------------------------------------ the measurement ---
#
# Counted here and not on the guest: V10 has no wc and no grep, and its shell
# has no arithmetic.  The guest's job was to print one line per differing
# member; counting them is the host's.
#
# THIS IS A MEASUREMENT, NOT A PASS/FAIL.  The tape's mkfile builds ten of the
# 261 with `lcc' and we build all 261 with pcc2, so some difference is
# expected and the interesting number is HOW MANY and WHICH.  A hard assertion
# on "all 261 identical" would be a guess dressed as a check.
echo
# A MEASUREMENT OF NOTHING READS AS PERFECTION, so refuse to print one.
# When the source disk failed to mount, `libc.ord' was unreadable, so the
# guest's `for f in `cat libc.ord`' loops zero times, `miss' and `d.lst' both
# come out EMPTY, and this summary computed
#	byte-identical, our cc   261
# -- a flawless result from a run that compiled not one object.  Same family as
# every other trap this stage has hit: a count derived from an empty list.
if grep -q 'source disk mounts  *NO' "$LOG" 2>/dev/null; then
    echo "== NO MEASUREMENT: the source disk did not mount =="
    echo "   Every count below would be computed from an empty member list and"
    echo "   would read as 261/261.  Fix the mount and re-run."
    sed -n '/V10 STAGE 2 RESULTS/,$p' "$LOG" | grep 'NO$' | head -6
    echo "== v10-stage2 exit $rc =="
    exit 1
fi
echo "== stage 2 against the tape's libc.a =="
# NOT ANCHORED AT `^', AND THAT COST A ROUND.  The claim that stood here --
# "the guest prints these under v10_run, so no marker echo is spliced through
# them" -- is false for the FIRST line of every dump, and structurally so.
# v10_run sends the command and then reads; the tty echoes the tail of what was
# typed INTO the program's first line of output, so the log carried
#
#	MMISS atof.o
#
# and `^MISS' dropped it.  Stage 2 then reported one missing member when there
# were two, CLAUDE.md recorded "the only member that does not build is
# setupshares", and the first thing to notice was STAGE 3 failing to link ccom
# and as with `Undefined: _atof'.
#
# So match the token wherever it sits in the line.  Safe because no command
# this stage sends contains the literal `MISS <name>.o' or `DIFF <name>.o' --
# the loops that generate them say `echo MISS \$f', which does not match.
# `sort -u' because a name must count once however often it appears.
miss=$(tr -d '\r' < "$LOG" | grep -oE 'MISS [A-Za-z_0-9]+\.o' | sort -u | grep -c . || true)
diff=$(tr -d '\r' < "$LOG" | grep -oE 'DIFF [A-Za-z_0-9]+\.o' | sort -u | grep -c . || true)
total=$(grep -c . "$ROOT/v10/mk/gen/libc.ord")
: "${miss:=0}" "${diff:=0}"
# THE TWO SETS OVERLAP, and the first version of this subtracted both and
# printed a negative count.  A member that did not compile has no file, so
# `cmp' against the tape's copy fails for it too -- every MISS is also a DIFF.
# So identical = total - diff, and `miss' is a breakdown of diff, not a
# separate column to subtract.
lccm=$(tr -d '\r' < "$LOG" | grep -oE 'LCCMATCH [A-Za-z_0-9]+\.o' | sort -u | grep -c . || true)
noom=$(tr -d '\r' < "$LOG" | grep -oE 'NOOMATCH [A-Za-z_0-9]+\.o' | sort -u | grep -c . || true)
tcm=$(tr -d '\r' < "$LOG" | grep -oE 'TAPECCMATCH [A-Za-z_0-9]+\.o' | sort -u | grep -c . || true)
: "${lccm:=0}" "${noom:=0}" "${tcm:=0}"

# THE GUEST'S OWN ASSERTION IS AN INDEPENDENT WITNESS, so make the two agree or
# say nothing.  The guest counts the object files it produced and asserts "all
# 261 members compiled"; the host counts MISS lines out of a tty transcript.
# When the anchored grep above dropped a member those two disagreed -- assertion
# NO, host count 0 -- and nothing in the run noticed, because each number was
# printed by a different piece of code and neither read the other.
#
# This is the same guard as the empty-member-list one below it, generalised: a
# count is only trustworthy when something else in the run agrees with it.
if grep -q 'all 261 members compiled  *NO' "$LOG" 2>/dev/null && (( miss == 0 )); then
    echo "== NO MEASUREMENT: the guest says a member is missing and the host found none =="
    echo "   The guest asserted 'all 261 members compiled: NO' while this script"
    echo "   counted 0 MISS lines, so the parse below is wrong and every number"
    echo "   derived from it would be too.  Look for a spliced line in $LOG:"
    tr -d '\r' < "$LOG" | grep -n 'MISS' | head -8
    echo "== v10-stage2 exit $rc =="
    exit 1
fi
echo "   members expected                 $total"
echo "   byte-identical, our cc           $(( total - diff ))"
echo "   byte-identical, lcc instead      $lccm"
echo "   byte-identical, cc WITHOUT -O    $noom"
echo "   byte-identical, the TAPE's ccom  $tcm"
echo "   ACCOUNTED FOR                    $(( total - diff + lccm + noom + tcm ))"
echo "   still unexplained                $(( diff - lccm - noom - tcm ))"
echo "     of which: did not compile      $miss"
echo "     of which: compiled, differ     $(( diff - miss ))"
if (( tcm )); then
    echo
    echo "   members the TAPE's OWN ccom reproduces but stage 1's does not:"
    tr -d '\r' < "$LOG" | grep -hoE 'TAPECCMATCH [A-Za-z_0-9]+\.o' | sed 's/^TAPECCMATCH /     /' \
        | sort -u | tr '\n' ' '
    echo
    echo "   -> cmd/ccom/vax/ SOURCE is not the compiler that built this archive."
fi
if (( noom )); then
    echo
    echo "   members whose bytes are cc WITHOUT -O:"
    tr -d '\r' < "$LOG" | grep -hoE 'NOOMATCH [A-Za-z_0-9]+\.o' | sed 's/^NOOMATCH /     /' \
        | sort -u | tr '\n' ' '
    echo
fi
if (( lccm )); then
    echo
    echo "   members whose bytes are LCC's, not cc's:"
    tr -d '\r' < "$LOG" | grep -hoE 'LCCMATCH [A-Za-z_0-9]+\.o' | sed 's/^LCCMATCH /     /' \
        | sort -u | tr '\n' ' '
    echo
    echo "   -> these belong in LIBC_LCC in v10/mk/mkdep.py: the tape's own"
    echo "      archive says Bell Labs compiled them with lcc."
fi
# THE LISTS MUST USE THE SAME PATTERN AS THE COUNTS, and for a while they did
# not: the five display greps kept their `^' after the counters lost theirs, so
# the report printed
#
#	  of which: did not compile      1
#	members that did not compile:
#	                                       <- nothing
#
# the exact inverse of the bug that hid atof, and just as quiet.  A count and a
# list derived from one log by two different patterns will disagree eventually.
if (( diff )); then
    echo
    echo "   differing members:"
    grep -hoE 'DIFF [A-Za-z_0-9]+\.o' "$LOG" | sed 's/^DIFF /     /' | tr -d '\r' | sort | tr '\n' ' '
    echo
fi
if (( miss )); then
    echo
    echo "   members that did not compile:"
    grep -hoE 'MISS [A-Za-z_0-9]+\.o' "$LOG" | sed 's/^MISS /     /' | tr -d '\r' | sort | tr '\n' ' '
    echo
fi

echo
echo "   the stage-2 machine is $IMG"
echo "   sha256 $(shasum -a 256 "$IMG" | cut -c1-16)"
echo "== v10-stage2 exit $rc =="
exit "$rc"
