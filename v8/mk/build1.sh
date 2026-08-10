#!/bin/sh
# Build the bootstrap toolchain.  Runs inside V8.
#
#	sh $SRC/mk/build1.sh [srcdir] [blddir] [stage] [withdir]
#
# Defaults: /n/src, /b, stage 1, and $blddir/tools as the toolchain to build
# WITH.  `stage` is a suffix, not a number: it names the output directory
# ($BLD/tools3, $BLD/tools3b) and nothing else, so a comparison stage can be
# added without colliding with the numbered stages in the doc's table.
#
# Builds, in the order the source dictates and nothing else:
#
#	yacc  ->  make lex cpp ccom  ->  c2 as ld ar ranlib nm size strip cc
#
# yacc is first because make/gram.y, lex/parser.y, cpp/cpy.y and -- the one
# that matters -- ccom/common/cgram.y are all yacc grammars.  The C compiler
# IS a yacc grammar, so yacc really is the root of the tool graph and a build
# that gets this order wrong produces a compiler built by a compiler it then
# replaces.
#
# STAGE 1 builds with the running system's compiler -- that is what a bootstrap
# is -- and installs into $BLD/tools.
#
# STAGE 3 builds the same sources again with the stage-1 toolchain AND the libc
# stage 2 produced, into $BLD/tools3.  That ordering is the whole point: every
# stage-1 binary is linked against the TAPE's libc.a, because that is the only
# one in existence when stage 1 runs.  Rebuilding the toolchain before libc
# gives fourteen binaries still carrying the old library, which have to be
# built again anyway -- a wasted round.  Stage 3 is the first set in which
# every component came from our source.
#
# as, ld, crt0.o and libc.a USED to stay hardwired in later stages, because
# stock cc substitutes only passes 0, 2 and p -- so "stage 3" was our cpp, ccom
# and c2 driving the system's assembler and loader and quietly linking against
# the system's C library.  S5 closed that: cc.c now takes -t a, -t l and -t c
# as well, all off the same -B prefix, so -B$T1/lib/ -t02palc names one
# directory holding every program cc executes plus crt0.o and libc.a.  See
# docs/build-from-source.md, "Stage isolation".
#
# $YACCPAR is the same problem one level up.  yaccpar is copied verbatim into
# every y.tab.c, so it is part of yacc's OUTPUT, and a stage whose yacc emits
# the tape's parser text has borrowed from the tape.  y1.c reads $YACCPAR
# ahead of the compiled-in default, so the path is a property of the run and
# not of the binary -- which is what keeps stage 1's yacc and stage 3's yacc
# byte-identical.
#
# NOTHING HERE WRITES OUTSIDE $TOOLDIR.
#
# That is not a stylistic preference.  The tape's own ccom makefile contains
#
#	install: comp
#		cp /lib/ccom comp.sv
#		cp comp /lib/ccom
#
# which overwrites the compiler you are compiling with, from a half-built tree,
# with no way back if it is wrong.  We never run the tape's install targets;
# v8/mk/gen/*.mk install into $(TOOLDIR) and nowhere else.

# SRC is the read-only netfs share.  Nothing is ever copied out of it: each
# component is built in its own directory on the build filesystem, compiling
# $(SRC)/... straight off the wire.  That is what the share is for, and it is
# why there is no staging step here any more -- there was one, it copied 7840
# files for 25 minutes per run, and it existed only because I put it there.
SRC=${1-/n/src}
BLD=${2-/b}
STAGE=${3-1}
# T1 is the toolchain we compile WITH, which is stage 1 for stages 2 and 3 and
# stage 3 for the 3b comparison.  It is a separate argument from the stage
# because "which compiler" and "which output directory" are different
# questions -- conflating them is exactly how stage 2 spent a week being built
# by the tape's cc while the doc said stage 1.
T1=${4-$BLD/tools}
MK=$SRC/mk/gen

if test "$STAGE" = 1
then
	TOOLDIR=$BLD/tools
	OBJ=$BLD/obj
	MAKE=make
	MACROS=
	NEWLIBC=/lib/libc.a
else
	TOOLDIR=$BLD/tools$STAGE
	OBJ=$BLD/obj$STAGE
	MAKE=$T1/bin/make
	# One argv element per macro; V8's make takes NAME=value from the
	# command line and it overrides the makefile's own assignment.  This
	# one has spaces in it, so it is the only one that must stay quoted.
	MACROS="CC=$T1/bin/cc -B$T1/lib/ -t02palc"
	# The point of a later stage: link against the libc WE built.  Without
	# this the fourteen binaries would come out linked to the tape's
	# /lib/libc.a again and the stage would prove nothing new.
	NEWLIBC=$T1/lib/libc.a
	# Read by our yacc; harmless to the tape's, which ignores it.
	YACCPAR=$T1/usr/lib/yaccpar
	export YACCPAR
fi

# The macros that are one word each.  Unquoted below, so the shell splits them
# into separate argv elements -- which is what make wants, and why none of
# them may ever contain a space.
STAGEMACS="YACC=$T1/bin/yacc YACCPATH=$T1/bin/yacc LEX=$T1/usr/bin/lex LEXPATH=$T1/usr/bin/lex CCPATH=$T1/bin/cc CCOM=$T1/lib/ccom CPP=$T1/lib/cpp C2=$T1/lib/c2 AS=$T1/lib/as LD=$T1/lib/ld LIBC=$NEWLIBC"

if test ! -f $MK/stage1.order
then
	echo "build1: no $MK/stage1.order -- is $SRC really the share?" 1>&2
	exit 1
fi

# V8's mkdir makes one level at a time; there is no -p.
mkdir $BLD			2>/dev/null
mkdir $OBJ			2>/dev/null
mkdir $TOOLDIR			2>/dev/null
mkdir $TOOLDIR/bin		2>/dev/null
mkdir $TOOLDIR/lib		2>/dev/null
mkdir $TOOLDIR/usr		2>/dev/null
mkdir $TOOLDIR/usr/bin		2>/dev/null
mkdir $TOOLDIR/usr/lib		2>/dev/null
mkdir $TOOLDIR/usr/lib/lex	2>/dev/null

echo "build: stage $STAGE, tools -> $TOOLDIR, objects -> $OBJ"
test "$STAGE" = 1 || echo "build: compiling with $T1"
# Fail here, not fourteen times over.  Every component's $(TOOLS) names these,
# so a missing one gives "Don't know how to make /b/tools/lib/as" on all of
# them at once -- which reads like fourteen broken makefiles rather than one
# absent file.  Seen for real: a stage-1 tree built before as and ld gained
# their second install into lib/.
if test "$STAGE" != 1
then
	miss=
	for f in ccom cpp c2 as ld crt0.o libc.a
	do
		test -f $T1/lib/$f || miss="$miss $f"
	done
	if test -n "$miss"
	then
		echo "build: $T1/lib is missing:$miss" 1>&2
		echo "build: stage $STAGE cannot run -- rebuild the stage before it" 1>&2
		exit 1
	fi
fi

fail=0
for t in `sed 's/	.*//' $MK/stage1.order`
do
	dir=`grep "^$t	" $MK/stage1.order | sed 's/^[^	]*	//; s/	.*//'`
	echo ""
	echo "=== stage$STAGE: $t   ($dir) ==="
	# Objects land here, never in the source tree -- which is read-only
	# anyway, so the share enforces the out-of-tree build for us.
	obj=$OBJ/$t
	rm -rf $obj
	mkdir $obj || { echo "  cannot make $obj"; fail=1; continue; }
	cd $obj || { fail=1; continue; }

	if test "$STAGE" = 1
	then
		# `prepare` exists only where the tape needs a file staged
		# before the first compile -- ccom wants y.debug for cgram.o.
		make -f $MK/$t.mk SRC=$SRC TOOLDIR=$TOOLDIR prepare 2>/dev/null
		make -f $MK/$t.mk SRC=$SRC TOOLDIR=$TOOLDIR
		rc=$?
		test $rc = 0 && make -f $MK/$t.mk SRC=$SRC TOOLDIR=$TOOLDIR install
		irc=$?
	else
		$MAKE -f $MK/$t.mk SRC=$SRC TOOLDIR=$TOOLDIR \
			$STAGEMACS "$MACROS" prepare 2>/dev/null
		$MAKE -f $MK/$t.mk SRC=$SRC TOOLDIR=$TOOLDIR \
			$STAGEMACS "$MACROS"
		rc=$?
		test $rc = 0 && $MAKE -f $MK/$t.mk SRC=$SRC TOOLDIR=$TOOLDIR \
			$STAGEMACS "$MACROS" install
		irc=$?
	fi

	if test $rc = 0
	then
		if test $irc = 0
		then echo "  installed"
		else echo "  INSTALL FAILED $t"; fail=1
		fi
	else
		echo "  BUILD FAILED $t"
		fail=1
	fi
done

echo ""
echo "=== stage$STAGE: what got built ==="
ls -l $TOOLDIR/bin $TOOLDIR/lib $TOOLDIR/usr/bin

echo ""
if test $fail = 0
then echo "STAGE$STAGE OK"
else echo "STAGE$STAGE INCOMPLETE"
fi
