#!/bin/sh
# Stage 6: the commands.  Runs inside V8.
#
#	sh $SRC/mk/buildcmds.sh [srcdir] [blddir] [destdir] [toolsdir]
#
# Defaults: /n/src /b /b/root /b/tools3
#
# Driven by $MK/stage6.order, which is a LIST and not a directory scan.  The
# tape's 113 command makefiles are not a family -- awk's says outright that it
# is wrong, sed links with `cc -o sed -n *.o`, troff builds two programs from
# overlapping object sets -- so each entry is read from its makefile once and
# recorded in the generator.  The list starts with the commands later stages
# need and grows; docs/build-from-source.md keeps the count honest.
#
# Built with stage 3, against stage 4's headers, linked against stage 5's
# libraries BY PATH.  Never -l: V8's ld has no -L, so -ll would quietly
# resolve out of the running system's /usr/lib and the build would succeed
# while linking against the tape.

SRC=${1-/n/src}
BLD=${2-/b}
DEST=${3-/b/root}
T3=${4-$BLD/tools3}
MK=$SRC/mk/gen

test -f $MK/stage6.order || { echo "buildcmds: no $MK/stage6.order" 1>&2; exit 1; }

case $DEST in
/|/usr|/usr/) echo "buildcmds: refusing to install over $DEST" 1>&2; exit 1;;
esac

test -f $T3/bin/cc || {
	echo "buildcmds: no $T3/bin/cc -- run build1.sh 3 first" 1>&2; exit 1; }
test -f $DEST/usr/include/stdio.h || {
	echo "buildcmds: no $DEST/usr/include -- run buildhdrs.sh first" 1>&2; exit 1; }

OBJ=$BLD/obj6
mkdir $BLD 2>/dev/null
mkdir $OBJ 2>/dev/null
for d in $DEST $DEST/bin $DEST/etc $DEST/usr $DEST/usr/bin $DEST/usr/lib
do
	mkdir $d 2>/dev/null
done

MACROS="CC=$T3/bin/cc -B$T3/lib/ -t02palc"
# INCDIR is the one macro here that is not about the toolchain: it moves the
# angle-bracket search from the share to the headers stage 4 installed.  The
# generated rules already depend on $(INCDIR)/x.h, so this is also what makes
# "touch a header, rebuild what includes it" true across stages.
STAGEMACS="INCDIR=$DEST/usr/include YACC=$T3/bin/yacc YACCPATH=$T3/bin/yacc LEX=$T3/usr/bin/lex LEXPATH=$T3/usr/bin/lex CCPATH=$T3/bin/cc CCOM=$T3/lib/ccom CPP=$T3/lib/cpp C2=$T3/lib/c2 AS=$T3/lib/as LD=$T3/lib/ld AR=$T3/bin/ar RANLIB=$T3/usr/bin/ranlib LIBC=$T3/lib/libc.a"

# Our yacc reads this ahead of the compiled-in /usr/lib/yaccpar, so the parser
# text baked into every generated y.tab.c is the one in our tree.
YACCPAR=$T3/usr/lib/yaccpar
export YACCPAR

echo "stage 6: commands -> $DEST, compiled with $T3"

fail=0
n=0
for c in `sed 's/	.*//' $MK/stage6.order`
do
	echo ""
	echo "=== stage6: $c ==="
	obj=$OBJ/$c
	rm -rf $obj
	mkdir $obj || { echo "  cannot make $obj"; fail=1; continue; }
	cd $obj || { fail=1; continue; }

	$T3/bin/make -f $MK/$c.mk SRC=$SRC TOOLDIR=$T3 DESTDIR=$DEST \
		$STAGEMACS "$MACROS" prepare 2>/dev/null
	$T3/bin/make -f $MK/$c.mk SRC=$SRC TOOLDIR=$T3 DESTDIR=$DEST \
		$STAGEMACS "$MACROS"
	rc=$?
	test $rc = 0 && $T3/bin/make -f $MK/$c.mk SRC=$SRC TOOLDIR=$T3 \
		DESTDIR=$DEST $STAGEMACS "$MACROS" install
	irc=$?

	if test $rc = 0
	then
		if test $irc = 0
		then echo "  installed"; n=`expr $n + 1`
		else echo "  INSTALL FAILED $c"; fail=1
		fi
	else
		echo "  BUILD FAILED $c"
		fail=1
	fi
done

echo ""
echo "=== stage 6: what got built ==="
ls -l $DEST/bin $DEST/etc $DEST/usr/bin 2>/dev/null
echo "commands installed: $n"

echo ""
if test $fail = 0
then echo "STAGE6 OK"
else echo "STAGE6 INCOMPLETE"
fi
