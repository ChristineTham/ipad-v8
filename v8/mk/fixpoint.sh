#!/bin/sh
# Does the toolchain reproduce itself?  Runs inside V8.
#
#	sh $SRC/mk/fixpoint.sh [srcdir] [blddir]
#
# Defaults: /n/src /b.  Assumes stage 1, stage 2 (libc) and stage 3 are built.
#
# There are two different questions here and only one of them is required.
#
# THE STRONG TEST is stage 1 against stage 3.  Stage 1 was compiled by the
# tape's cc, assembled by its as, linked by its ld against its libc; stage 3
# by ours, all the way down.  If those agree, our source describes the tools
# that built the tape, and the two toolchains are interchangeable.
#
# THE REQUIRED TEST is stage 3 against stage 3b -- the same sources once more,
# compiled by stage 3 instead of stage 1.  This is the classic three-stage
# bootstrap comparison (gcc compares stage2 with stage3 for exactly this
# reason) and it asks the weaker, sufficient question: are our tools a
# fixpoint of themselves?  A compiler can be a perfectly good compiler and
# still not reproduce a 1985 assembler's byte layout.
#
# So: run the strong test first, because it is free -- stage 3 already exists.
# If it passes, there is nothing left to prove and we stop, because stage 3b
# would cost another forty minutes to confirm something already implied.  If
# it fails, build stage 3b and run the required test, and report BOTH results
# so the difference between "we do not match the tape" and "we do not even
# match ourselves" is on the record.  The first is a curiosity.  The second
# means the toolchain is not usable for stages 4 onward.

SRC=${1-/n/src}
BLD=${2-/b}

echo "=== fixpoint: the strong test, stage 1 vs stage 3 ==="
if sh $SRC/mk/cmpstage.sh $SRC $BLD/tools $BLD/tools3 $BLD/cmp
then
	echo ""
	echo "FIXPOINT-STRONG-ok: our toolchain reproduces the tape's output."
	echo ""
	echo "Stage 3b is not needed, and the reason is worth stating.  The"
	echo "comparison above is stripped, so it says stage 1 and stage 3 have"
	echo "the same text and data; the symbol table is not loaded at exec"
	echo "time, so they are the same program.  Stage 3 was built BY stage 1."
	echo "Building it again by stage 3 is therefore building it by the same"
	echo "program from the same source, which cannot give a different answer."
	exit 0
fi

echo ""
echo "=== fixpoint: stage 1 != stage 3, so ask the weaker question ==="
echo "Building stage 3b: the same sources, compiled by STAGE 3."
sh $SRC/mk/build1.sh $SRC $BLD 3b $BLD/tools3 || {
	echo "FIXPOINT-NO: stage 3b did not build" 1>&2
	exit 1
}

echo ""
echo "=== fixpoint: the required test, stage 3 vs stage 3b ==="
if sh $SRC/mk/cmpstage.sh $SRC $BLD/tools3 $BLD/tools3b $BLD/cmp2
then
	echo ""
	echo "FIXPOINT-SELF-ok: the toolchain reproduces ITSELF but not the"
	echo "tape's binaries.  That is a working self-hosting system.  The"
	echo "difference against stage 1 is worth chasing -- most likely our as"
	echo "or ld rather than the compiler; compare the -t02p and -t02palc"
	echo "builds of one file to tell which -- but it does not block stage 4."
	exit 0
fi

echo ""
echo "FIXPOINT-NO: the toolchain does not reproduce itself.  Stage 4 must not"
echo "be built on this -- whatever it produces would depend on which stage"
echo "happened to run."
exit 1
