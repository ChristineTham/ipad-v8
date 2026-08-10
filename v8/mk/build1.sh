#!/bin/sh
# Build the bootstrap toolchain.  Runs inside V8.
#
#	sh $SRC/mk/build1.sh [srcdir] [blddir] [stage]
#
# Defaults: /n/src, /b, stage 1.
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
# as, ld and crt0.o are NOT redirected in later stages, because cc has no -B for
# them (cc.c substitutes only passes 0, 2 and p).  So stage 3 is our cpp, ccom
# and c2 driving the system's assembler and loader, and the macros below say
# so rather than pretending otherwise -- a dependency on a binary the build
# does not actually run is a lie make will act on.
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
MK=$SRC/mk/gen

T1=$BLD/tools
if test "$STAGE" = 1
then
	TOOLDIR=$T1
	OBJ=$BLD/obj
	MAKE=make
	MACROS=
	NEWLIBC=/lib/libc.a
else
	TOOLDIR=$BLD/tools$STAGE
	OBJ=$BLD/obj$STAGE
	MAKE=$T1/bin/make
	# One argv element per macro; V8's make takes NAME=value from the
	# command line and it overrides the makefile's own assignment.
	MACROS="CC=$T1/bin/cc -B$T1/lib/ -t02p"
	# The point of a later stage: link against the libc WE built.  Without
	# this the fourteen binaries would come out linked to the tape's
	# /lib/libc.a again and the stage would prove nothing new.
	NEWLIBC=$T1/lib/libc.a
fi

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
			YACC=$T1/bin/yacc YACCPATH=$T1/bin/yacc \
			LEX=$T1/usr/bin/lex LEXPATH=$T1/usr/bin/lex \
			CCPATH=$T1/bin/cc CCOM=$T1/lib/ccom \
			CPP=$T1/lib/cpp C2=$T1/lib/c2 LIBC=$NEWLIBC \
			"$MACROS" prepare 2>/dev/null
		$MAKE -f $MK/$t.mk SRC=$SRC TOOLDIR=$TOOLDIR \
			YACC=$T1/bin/yacc YACCPATH=$T1/bin/yacc \
			LEX=$T1/usr/bin/lex LEXPATH=$T1/usr/bin/lex \
			CCPATH=$T1/bin/cc CCOM=$T1/lib/ccom \
			CPP=$T1/lib/cpp C2=$T1/lib/c2 LIBC=$NEWLIBC \
			"$MACROS"
		rc=$?
		test $rc = 0 && $MAKE -f $MK/$t.mk SRC=$SRC TOOLDIR=$TOOLDIR \
			YACC=$T1/bin/yacc YACCPATH=$T1/bin/yacc \
			LEX=$T1/usr/bin/lex LEXPATH=$T1/usr/bin/lex \
			CCPATH=$T1/bin/cc CCOM=$T1/lib/ccom \
			CPP=$T1/lib/cpp C2=$T1/lib/c2 LIBC=$NEWLIBC \
			"$MACROS" install
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
