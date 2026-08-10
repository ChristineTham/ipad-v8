#!/bin/sh
# Build libc.a from our source.  Runs inside V8.
#
#	sh $SRC/mk/buildlibc.sh [srcdir] [blddir] [stage]
#
# Defaults: /n/src /b 1.
#
# This is the first thing in the build that is a *library* rather than a
# program, and it is the one the user's dependency rule is really about:
# changing libc.a invalidates every binary linked against it.  Everything in
# stages 6 and 7 links against this.
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
STAGE=${3-1}
MK=$SRC/mk/gen

T1=$BLD/tools
if test "$STAGE" = 1
then
	TOOLDIR=$T1
	OBJ=$BLD/objlibc
	MAKE=make
	EXTRA=
else
	TOOLDIR=$BLD/tools$STAGE
	OBJ=$BLD/objlibc$STAGE
	MAKE=$T1/bin/make
	EXTRA="CC=$T1/bin/cc -B$T1/lib/ -t02p"
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

echo "=== libc: building 233 objects into $OBJ ==="
if test "$STAGE" = 1
then
	$MAKE -f $MK/libc.mk SRC=$SRC TOOLDIR=$TOOLDIR
	rc=$?
	test $rc = 0 && $MAKE -f $MK/libc.mk SRC=$SRC TOOLDIR=$TOOLDIR install
	irc=$?
else
	$MAKE -f $MK/libc.mk SRC=$SRC TOOLDIR=$TOOLDIR \
		CCPATH=$T1/bin/cc CCOM=$T1/lib/ccom \
		CPP=$T1/lib/cpp C2=$T1/lib/c2 "$EXTRA"
	rc=$?
	test $rc = 0 && $MAKE -f $MK/libc.mk SRC=$SRC TOOLDIR=$TOOLDIR \
		CCPATH=$T1/bin/cc CCOM=$T1/lib/ccom \
		CPP=$T1/lib/cpp C2=$T1/lib/c2 "$EXTRA" install
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
