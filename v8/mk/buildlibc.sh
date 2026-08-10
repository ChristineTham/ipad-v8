#!/bin/sh
# Build libc.a from our source.  Runs inside V8.
#
#	sh $SRC/mk/buildlibc.sh [srcdir] [blddir] [stage]
#
# Defaults: /n/src /b 2.
#
# This is the first thing in the build that is a *library* rather than a
# program, and it is the one the user's dependency rule is really about:
# changing libc.a invalidates every binary linked against it.  Everything in
# stages 6 and 7 links against this.
#
# STAGE 2 compiles with the stage-1 toolchain and installs into stage 1's lib,
# which is the one the stage table means by "libc, with stage 1".  It ran with
# the TAPE's cc until 2026-08-10 -- the script's third argument conflated "which
# compiler" with "which directory", and passing 1 for the directory silently
# also chose the compiler.  That made stage 3 "our toolchain, linked against a
# libc the tape's compiler produced", which is a weaker claim than the doc
# made and than the fixpoint test appears to make.
#
# Compiling libc with -t02palc is safe even though $T1/lib/libc.a and crt0.o
# are what this script is about to create: every rule here compiles with -c,
# and cc only looks at crt0.o or the C library on the link branch, which -c
# never reaches.  It builds the strings and never opens the files.
#
# STAGE 1 is kept for comparison -- libc as the tape's compiler makes it.
#
# It builds into $BLD/objlibc and installs libc.a, crt0.o and mcrt0.o into
# $TOOLDIR/lib.  It never touches /lib -- the tape's own install target begins
#
#	cp $(DESTDIR)/lib/libc.a liboc.a
#	cp libc.a $(DESTDIR)/lib/libc.a
#
# which replaces the C library you are compiling against, from a tree that may
# be half built, with the previous one saved under a name nothing looks for.

SRC=${1-/n/src}
BLD=${2-/b}
STAGE=${3-2}
MK=$SRC/mk/gen

T1=$BLD/tools
if test "$STAGE" = 1
then
	# The control: our libc source through the tape's compiler.
	TOOLDIR=$T1
	OBJ=$BLD/objlibc1
	MAKE=make
	EXTRA=
	STAGEMACS=
else
	# Stage 2 and later: compile with stage 1, install where stage 3 will
	# look.  TOOLDIR is stage 1's lib in both cases -- libc is not a
	# per-stage artefact, it is the library the next stage links against.
	TOOLDIR=$T1
	OBJ=$BLD/objlibc
	MAKE=$T1/bin/make
	EXTRA="CC=$T1/bin/cc -B$T1/lib/ -t02palc"
	STAGEMACS="CCPATH=$T1/bin/cc CCOM=$T1/lib/ccom CPP=$T1/lib/cpp C2=$T1/lib/c2 AS=$T1/lib/as LD=$T1/lib/ld AR=$T1/bin/ar RANLIB=$T1/usr/bin/ranlib"
fi

test -f $MK/libc.mk || { echo "buildlibc: no $MK/libc.mk" 1>&2; exit 1; }

# lorder is a shell script and tsort a program; both are needed to order the
# archive, and V8's ld is single pass so the order is correctness.  Say so up
# front rather than letting `ar cr libc.a` receive an empty list.
for t in lorder tsort
do
	if $t < /dev/null > /dev/null 2>&1
	then :
	else echo "buildlibc: $t is not usable -- archive order cannot be computed" 1>&2
	fi
done

rm -rf $OBJ
mkdir $BLD 2>/dev/null
mkdir $OBJ || { echo "buildlibc: cannot make $OBJ" 1>&2; exit 1; }
cd $OBJ || exit 1

echo "=== libc: stage $STAGE, 233 objects into $OBJ ==="
if test "$STAGE" = 1
then
	$MAKE -f $MK/libc.mk SRC=$SRC TOOLDIR=$TOOLDIR
	rc=$?
	test $rc = 0 && $MAKE -f $MK/libc.mk SRC=$SRC TOOLDIR=$TOOLDIR install
	irc=$?
else
	echo "libc: compiling with $T1"
	# $STAGEMACS is deliberately unquoted -- the shell splits it into one
	# argv element per macro.  $EXTRA is quoted because it has spaces.
	$MAKE -f $MK/libc.mk SRC=$SRC TOOLDIR=$TOOLDIR $STAGEMACS "$EXTRA"
	rc=$?
	test $rc = 0 && $MAKE -f $MK/libc.mk SRC=$SRC TOOLDIR=$TOOLDIR \
		$STAGEMACS "$EXTRA" install
	irc=$?
fi

echo ""
echo "=== libc: what got built ==="
ls -l $TOOLDIR/lib/libc.a $TOOLDIR/lib/crt0.o $TOOLDIR/lib/mcrt0.o
echo "members:"
$T1/bin/ar t $TOOLDIR/lib/libc.a 2>/dev/null | wc -l

echo ""
if test $rc = 0 -a $irc = 0
then echo "LIBC OK"
else echo "LIBC INCOMPLETE"
fi
