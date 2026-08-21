#!/usr/bin/env bash
# K10.3: link and install the Tenth Edition's world, and count what got there.
#
#	bash tools/v10-link.sh [k102-image] [src-image]
#
# The gates below are in the order they can fail cheaply: the generated lists
# first (host-side, instant), then the source disk's stamp, then room, then the
# no-overlap check, and only then a boot.
# -uo pipefail, and deliberately NOT -e, which is what the sibling drivers use.
# With -e this script DIED SILENTLY between the tally and the report: `grep -oE'
# exits 1 when it matches nothing, pipefail makes the whole c10() pipeline fail,
# and -e then killed the run -- so a completed 200-of-247 link printed no summary
# at all because CINSTALL happened to appear zero times.  Same family as the
# release script's `... | grep -q' failing on SIGPIPE and printing "hardened
# runtime is NOT enabled" under a line saying it was: a counter that cannot count
# to zero is not a counter.  c10() now floors at 0 as well.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/norun.sh"
source "$ROOT/tools/v10clone.sh"
source "$ROOT/tools/srcid.sh"

# A GUARD THAT CANNOT RUN MUST NOT REPORT ITS OWN SUBJECT AS THE FAULT.  This
# script was missing the srcid.sh source, so `srcid_check' was not a function and
# bash answered `command not found' -- nonzero -- and the `|| { ...; exit 1; }'
# below then announced "the source disk is stale" about a disk that had been
# rebuilt four minutes earlier.  The same shape as `... | grep -q' failing on
# SIGPIPE under pipefail and printing "hardened runtime is NOT enabled" under a
# line saying it was.  So the functions this script depends on are checked for
# EXISTENCE first, by name, and a missing one says so.
for fn in srcid_check no_overlap v10_clone; do
    declare -F "$fn" >/dev/null || {
        echo "v10-link: $fn is not defined -- a tools/*.sh source line is"
        echo "   missing, so the guard that uses it would fail and be read as"
        echo "   its subject failing.  Fix the sourcing, not the disk."
        exit 2
    }
done

# K10.2'S OUTPUT IMAGE, NOT STAGE 1'S, AND THAT IS THE WHOLE PRECONDITION.  This
# run links, so it needs /usr/lib carrying the 26 archives K10.2 built and
# installed -- on a .stage1 clone every link fails on -lm, which 51 units ask
# for, and 0 links would read as a finding about the Tenth Edition.  Stages 2 and
# 3 chain the same way: .stage1 -> .stage1.s2 -> .stage1.s2.s3.
GOLD="${1:-ipnx-v10-ra81.img.stage1.k102}"
SRC="${2:-$ROOT/work/v10gold/ipnx-v10-src.img}"
LOG="$ROOT/work/v10-link.log"

[[ -f "$ROOT/work/v10gold/$GOLD" ]] || {
    echo "v10-link: no $GOLD in work/v10gold."
    echo "   K10.3 links against the libraries K10.2 installs, so it needs that"
    echo "   run's output image.  Build it with:"
    echo "       bash tools/v10-libs.sh"
    echo "   which leaves ipnx-v10-ra81.img.stage1.k102 behind."
    exit 1
}

# THE GENERATED LISTS MUST MATCH THE TREE, or this measures the previous
# generation of the survey against the current source and reports a disagreement
# that is purely bookkeeping.
python3 "$ROOT/tools/v10-world.py" --check || {
    echo "v10-link: the world lists are stale -- run tools/v10-world.py --write"
    exit 1
}
python3 "$ROOT/tools/v10-libs.py" --check || {
    echo "v10-link: libs.units is stale, and world.link's -l answers are read"
    echo "   from it -- run tools/v10-libs.py --write"
    exit 1
}

# AND THE DISK MUST MATCH THE LISTS.  The V10 source disk is a COPY, so a
# regenerated makefile changes nothing the guest sees: libc.ord went from 261
# names to 260 and three assertions kept failing on a build that was already
# correct.  tools/srcid.sh stamps it at build time and this refuses a
# disagreeing one.
srcid_check "$SRC" || {
    echo "v10-link: the source disk is stale -- rebuild it with"
    echo "       bash tools/v10-srcdisk.sh"
    exit 1
}

# Room, host-side, before the boot.  A FULL V10 FILESYSTEM HANGS INSTEAD OF
# FAILING -- lsys/fs/alloc.c prints `file system full' and then sleeps, waiting
# for space that is not coming -- so no guest-side probe can guard against it and
# this reads the superblock out of the image file instead.  ~300 binaries at
# ~30 KB plus the objects, with margin.
python3 "$ROOT/tools/v10-free.py" "$ROOT/work/v10gold/$GOLD" c --need 12000 || {
    echo "v10-link: not enough room on $GOLD for the staged world."
    exit 1
}

no_overlap "$SRC" "$ROOT/work/v10gold/$GOLD" || exit 1

IMG=$(v10_clone "$GOLD" k103) || exit 1
SRCIMG=$(v10_clone "$SRC" k103src) || exit 1
echo "== linking the world on $(basename "$IMG") =="
echo "   source disk $(basename "$SRCIMG")"

expect "$ROOT/tools/v10-link.exp" "$IMG" "$SRCIMG" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# ---------------------------------------------------------------- the counts ---
#
# UNANCHORED, AND BY NAME.  `^'-anchored counting is what dropped `MMISS atof.o'
# and let a missing libc member hide for a week: v10_run fixes the body of a dump
# but never its first line, because the tty echoes the tail of the typed command
# into it.  The tokens are safe unanchored because worldc.sh spells them through
# shell variables ($P/$Q/$L/$I), so the echo of the command carries `$L' and only
# the answer carries CLINKED.
# `|| true' so a token that appears ZERO times counts as 0 rather than failing.
c10() { { grep -oE "$1 [A-Za-z_0-9+./-]+" "$LOG" 2>/dev/null || true; } | wc -l | tr -d ' '; }
built=$(c10 CBUILT); failed=$(c10 CFAILED)
linked=$(c10 CLINKED); nolink=$(c10 CNOLINK)
inst=$(c10 CINSTALL); noinst=$(c10 CNOINST)

# The guest counted the same lines with sed; if the two disagree the transcript
# lost data and no number here means anything.  Stage 2 printed a total that
# contradicted its own assertion four lines above and nothing compared them.
gt() { grep -oE "TALLY$1 [0-9]+" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}'; }
gb=$(gt B); gf=$(gt F); gl=$(gt L); gi=$(gt I)

echo
for pat in NOSPACE 'file system full' NOCANARY; do
    if grep -q "$pat" "$LOG" 2>/dev/null; then
        echo "== NO MEASUREMENT: '$pat' appears in the transcript =="
        echo "   Every unit after the first such failure failed for that reason"
        echo "   and not for a reason about the Tenth Edition."
        grep -m3 -A3 "$pat" "$LOG" | sed -e 's/^/   /'
        echo "== v10-link exit $rc =="
        exit 1
    fi
done
if [[ -z "$gl" ]]; then
    echo "== NO MEASUREMENT: the guest printed no link tally =="
    echo "   Either the run did not reach the end of worldc.sh, or it was given"
    echo "   no DESTDIR and quietly ran K10.1's compile survey instead."
    echo "== v10-link exit $rc =="
    exit 1
fi
if [[ "$gb" != "$built" || "$gf" != "$failed" || "$gl" != "$linked" \
      || "$gi" != "$inst" ]]; then
    echo "== NO MEASUREMENT: guest and host disagree =="
    echo "   guest  built=$gb failed=$gf linked=$gl installed=$gi"
    echo "   host   built=$built failed=$failed linked=$linked installed=$inst"
    echo "   A metric read out of a tty is only as good as the tty."
    echo "== v10-link exit $rc =="
    exit 1
fi
# AN INTERNAL CONSISTENCY CHECK, WHICH IS NOT THE SAME AS TWO INSTRUMENTS
# AGREEING.  v10-libs' first run had the guest and the host counting the same
# tokens and both were wrong; what was missing was a relation between different
# numbers.  Nothing can link that did not compile, and nothing can install that
# did not link.
if (( linked > built )) || (( inst > linked )); then
    echo "== NO MEASUREMENT: the run contradicts itself =="
    echo "   linked=$linked built=$built installed=$inst -- a unit cannot link"
    echo "   without compiling, nor install without linking."
    echo "== v10-link exit $rc =="
    exit 1
fi
# AND THE COMPILE HALF MUST AGREE WITH K10.1, because it is the same lines of
# worldc.sh doing it.  A difference is a fault in one of the two runs and not a
# finding -- most likely a different image, a different header set, or a stale
# source disk.
k1="$ROOT/work/v10-compile.log"
if [[ -f "$k1" ]]; then
    k1b=$(grep -oE 'TALLYB [0-9]+' "$k1" 2>/dev/null | tail -1 | awk '{print $2}')
    if [[ -n "$k1b" && "$k1b" != "$built" ]]; then
        echo "   NOTE: K10.1 compiled $k1b units and this run compiled $built."
        echo "   The same lines of worldc.sh do the compiling in both, so this is"
        echo "   a difference between the RUNS -- image, headers or source disk --"
        echo "   and not a finding about the tape."
        echo
    fi
fi

echo "== K10.3: THE WORLD, LINKED AND INSTALLED ON V10 =="
printf "   units compiled            %4s\n" "$built"
printf "   units that did not        %4s\n" "$failed"
printf "   of those compiled, LINKED %4s\n" "$linked"
printf "   compiled but did not link %4s\n" "$nolink"
printf "   installed into the tree   %4s\n" "$inst"
printf "   linked but not installed  %4s\n" "$noinst"

# world.link's own exclusions, which are a decision and not a failure -- `ed/'
# and `sort/', the tape's second generation of each, whose names carry a trailing
# slash.  Printed because a silent skip is how a unit goes missing.
nodest=$(c10 CNODEST)
if [[ "${nodest:-0}" != 0 ]]; then
    printf "   skipped, no row in world.link %s: %s\n" "$nodest" \
        "$(grep -oE 'CNODEST [A-Za-z_0-9+./-]+' "$LOG" | awk '{print $2}' \
           | sort -u | tr '\n' ' ')"
fi

# ------------------------------------------------- which -l flags cannot be met ---
#
# A LINK FAILURE OVER AN ABSENT LIBRARY IS A FACT ABOUT THE MAKEFILE, NOT ABOUT
# V10.  Thirteen of the -l names the command tree asks for exist nowhere in the
# tarball -- -lbsd (13 uses), -lport (7), -lether, -lmodel, -lgc, -ld (4 each),
# -lresolv, -ltroff, -layout, -lcoexpr, -large, -lsocket, -lpost -- the
# fingerprint of makefiles written for other machines.  Separating those from
# genuine link errors is the difference between work to do and work that cannot
# be done.
have=$(mktemp); want=$(mktemp); trap 'rm -f "$have" "$want"' EXIT
awk '!/^#/{for(i=6;i<=NF;i++) print $i}' "$ROOT/v10/mk/gen/libs.units" \
    | sed -e 's/^lib//' -e 's/\.a$//' | sort -u > "$have"
echo c >> "$have"; sort -u -o "$have" "$have"
grep -vE '^#' "$ROOT/v10/mk/gen/world.link" | awk '{for(i=4;i<=NF;i++) print $i}' \
    | grep -oE '^-l.*' | sed -e 's/^-l//' | sort -u > "$want"
missing=$(comm -13 "$have" "$want" | tr '\n' ' ')
if [[ -n "${missing// /}" ]]; then
    echo
    echo "   -l names the tree asks for that NOTHING in the tarball provides:"
    echo "      $missing"
    echo "   Those units cannot link, and that is a property of the makefiles."
fi

# ------------------------------------- what this survey does NOT claim to build ---
#
# 39 units have a REAL generated makefile under v10/mk/gen/ -- the boot path and
# the toolchain -- and those are built by stages 1 to 3 and tools/v10-make.sh,
# from each unit's own dependencies and flags.  This survey uses one generic
# recipe for everything, so where the two overlap the makefile is the authority
# and a failure here is not news.  Stating the overlap is what stops a number
# from this run being read as the project's coverage of the world.
mk=$(ls "$ROOT"/v10/mk/gen/*.mk 2>/dev/null | wc -l | tr -d ' ')
echo
echo "   units with a generated makefile        $mk  <- built properly by stages 1-3;"
echo "                                              this run's generic flags are weaker"
echo "   units world.link SKIPS, with a reason  $(grep -cE '^# SKIPPED' "$ROOT/v10/mk/gen/world.link")"
echo "      -- 71 of them carry more than one main(): a cmd/ directory is not"
echo "         necessarily a command.  cmd/worm has 22 programs in it, qsnap 17,"
echo "         uucp 11.  Which objects belong to which program is in each unit's"
echo "         own makefile, so they are named rather than guessed at."

# ------------------------------------------- one generic recipe, and its limit ---
#
# A UNIT'S DIRECTORY HOLDS FILES ITS BUILD DOES NOT USE, and this survey compiles
# every .c it finds -- so one such file fails the whole unit.  `sh' is the case
# that matters: it dies on
#
#	"cmd/sh/profile.c":18: illegal pointer/integer combination, op =
#
# and profile.c is not in sh's $OFILES.  The tape says so twice: the macro lists
# 24 objects without it, and it is the ONE source in that directory with no .o
# beside it while the other 24 all have one -- these are developers' working
# directories, so what was compiled in place is evidence of what the build uses.
# Closing this means reading each unit's own object list, which is mkdep.py's
# job and not a generic recipe's.
# `sh$' DOES NOT MATCH `sh\r', AND THIS PRINTED A FALSEHOOD ABOUT ITS OWN RUN.
# CLINKED is echoed by the GUEST, so it arrives through the tty as "CLINKED sh\r\n"
# -- and BSD grep's `$' anchors after the \r, not before it.  So the test was
# permanently true and the report said "sh did NOT build" in a run whose log said
# CLINKED sh three lines apart, and whose staged root holds a 57,494-byte
# /w10/bin/sh.  The anchor cannot simply be dropped: unanchored, `CLINKED sh'
# also matches `CLINKED showq'.  [[:space:]]*$ keeps the anchor and tolerates the
# carriage return.
#
# THE DISTINCTION THAT MATTERS, since four sibling harnesses anchor on `$' and are
# all correct: those match lines EXPECT printed with `puts' (\n only).  This one
# matches a line the GUEST printed.  Anchor freely on our own output; never on the
# guest's without allowing for the \r.
#
# It also hid because my interactive shell's `grep' is a ugrep shim, which treats
# \r\n as the terminator and DOES match -- so checking the pattern by hand
# confirmed the opposite of what the harness saw.  Test with the tool that runs.
if ! grep -qE 'CLINKED sh[[:space:]]*$' "$LOG" 2>/dev/null; then
    echo
    echo "   sh did NOT build, and it is the generic recipe's limit rather than"
    echo "   a fact about the tape: cmd/sh/profile.c is not in sh's \$OFILES and"
    echo "   is the one source there with no .o beside it.  The golden's own"
    echo "   prebuilt /bin/sh is unaffected -- this run installs nothing over it."
fi

# ---------------------------------------------- the oracle, where there is one ---
#
# 46 of the command units ship a linked 1995 binary.  They are the ORACLE and
# never a shortcut: what is compared here is that we produced something for the
# same names, which is the weakest useful form of the check and the only one
# available without a byte comparison this run does not attempt.
orc=$(mktemp); got=$(mktemp)
trap 'rm -f "$have" "$want" "$orc" "$got"' EXIT
grep -vE '^#' "$ROOT/v10/mk/gen/prebuilt.txt" | awk '{print $1}' | sort -u > "$orc"
grep -oE "CLINKED [A-Za-z_0-9+./-]+" "$LOG" | awk '{print $2}' | sort -u > "$got"
echo
echo "   units with a prebuilt oracle          $(wc -l < "$orc" | tr -d ' ')"
echo "   of those, linked by us                $(comm -12 "$orc" "$got" | wc -l | tr -d ' ')"
echo "   with an oracle that did NOT link:"
comm -23 "$orc" "$got" | sed -e 's/^/      /' | head -20

echo
echo "   the machine is $IMG"
echo "   full transcript $LOG"
echo "== v10-link exit $rc =="
exit "$rc"
