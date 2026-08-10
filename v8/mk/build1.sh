#!/bin/sh
# Stage 1: build the bootstrap toolchain.  Runs inside V8.
#
#	sh /usr/bld/src/mk/build1.sh [srcdir] [tooldir]
#
# Defaults: /usr/bld/src, /usr/bld/tools.
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
TOOLDIR=$BLD/tools
MK=$SRC/mk/gen

if test ! -f $MK/stage1.order
then
	echo "build1: no $MK/stage1.order -- is $SRC really the share?" 1>&2
	exit 1
fi

# V8's mkdir makes one level at a time; there is no -p.
mkdir $BLD			2>/dev/null
mkdir $BLD/obj			2>/dev/null
mkdir $TOOLDIR			2>/dev/null
mkdir $TOOLDIR/bin		2>/dev/null
mkdir $TOOLDIR/lib		2>/dev/null
mkdir $TOOLDIR/usr		2>/dev/null
mkdir $TOOLDIR/usr/bin		2>/dev/null
mkdir $TOOLDIR/usr/lib		2>/dev/null
mkdir $TOOLDIR/usr/lib/lex	2>/dev/null

# Stage 1 compiles with the running system's compiler -- that is what a
# bootstrap is.  Later stages pass CC='cc -B$TOOLDIR/ -t02p' to compile with
# the ccom we just built instead; cc.c has had that since 1985.
fail=0
for t in `sed 's/	.*//' $MK/stage1.order`
do
	dir=`grep "^$t	" $MK/stage1.order | sed 's/^[^	]*	//; s/	.*//'`
	echo ""
	echo "=== stage1: $t   ($dir) ==="
	# Objects land here, never in the source tree -- which is read-only
	# anyway, so the share enforces the out-of-tree build for us.
	obj=$BLD/obj/$t
	rm -rf $obj
	mkdir $obj || { echo "  cannot make $obj"; fail=1; continue; }
	cd $obj || { fail=1; continue; }

	# `prepare` exists only where the tape needs a file staged before the
	# first compile -- ccom wants y.debug in place for cgram.o.
	make -f $MK/$t.mk SRC=$SRC TOOLDIR=$TOOLDIR prepare 2>/dev/null

	if make -f $MK/$t.mk SRC=$SRC TOOLDIR=$TOOLDIR
	then
		if make -f $MK/$t.mk SRC=$SRC TOOLDIR=$TOOLDIR install
		then echo "  installed"
		else echo "  INSTALL FAILED $t"; fail=1
		fi
	else
		echo "  BUILD FAILED $t"
		fail=1
	fi
done

echo ""
echo "=== stage1: what got built ==="
ls -l $TOOLDIR/bin $TOOLDIR/lib $TOOLDIR/usr/bin

echo ""
if test $fail = 0
then echo "STAGE1 OK"
else echo "STAGE1 INCOMPLETE"
fi
