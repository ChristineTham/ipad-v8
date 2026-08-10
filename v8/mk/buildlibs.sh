#!/bin/sh
# Stage 5: the libraries.  Runs inside V8.
#
#	sh $SRC/mk/buildlibs.sh [srcdir] [blddir] [destdir] [toolsdir]
#
# Defaults: /n/src /b /b/root /b/tools3
#
# Everything except libc, which is stage 2 -- it has to exist before the
# toolchain can be rebuilt against it, so it cannot wait for a stage that
# needs the toolchain.
#
# Built with STAGE 3, against the headers STAGE 4 installed.  Both of those
# are the point: a library compiled by the tape's compiler against the tape's
# headers is the tape's library no matter whose source it came from.
#
# Installs into $DEST/usr/lib and nowhere else.  Every tape makefile here
# installs into /usr/lib -- five of them with a bare `cp libX.a /usr/lib` and
# no DESTDIR at all, and libF77 and lib4014 use `mv`, so running the tape's
# install target twice does not even fail the same way twice.

SRC=${1-/n/src}
BLD=${2-/b}
DEST=${3-/b/root}
T3=${4-$BLD/tools3}
MK=$SRC/mk/gen

test -f $MK/stage5.order || { echo "buildlibs: no $MK/stage5.order" 1>&2; exit 1; }

case $DEST in
/usr|/usr/|/) echo "buildlibs: refusing to install over $DEST" 1>&2; exit 1;;
esac

# The same up-front check stage 3 has.  A missing pass gives "Don't know how
# to make $(TOOLS)" on every library at once, which reads like a broken
# generator rather than an absent file.
miss=
for f in ccom cpp c2 as ld crt0.o libc.a
do
	test -f $T3/lib/$f || miss="$miss $f"
done
if test -n "$miss"
then
	echo "buildlibs: $T3/lib is missing:$miss" 1>&2
	echo "buildlibs: stage 5 needs stage 3 -- run build1.sh 3 first" 1>&2
	exit 1
fi
if test ! -f $DEST/usr/include/stdio.h
then
	echo "buildlibs: no $DEST/usr/include -- run buildhdrs.sh first" 1>&2
	exit 1
fi

OBJ=$BLD/obj5
mkdir $BLD	2>/dev/null
mkdir $OBJ	2>/dev/null
mkdir $DEST	2>/dev/null
mkdir $DEST/usr	2>/dev/null
mkdir $DEST/usr/lib 2>/dev/null

MACROS="CC=$T3/bin/cc -B$T3/lib/ -t02palc"
STAGEMACS="CCPATH=$T3/bin/cc CCOM=$T3/lib/ccom CPP=$T3/lib/cpp C2=$T3/lib/c2 AS=$T3/lib/as LD=$T3/lib/ld AR=$T3/bin/ar RANLIB=$T3/usr/bin/ranlib"

echo "stage 5: libraries -> $DEST/usr/lib, compiled with $T3"

fail=0
for l in `sed 's/	.*//' $MK/stage5.order`
do
	echo ""
	echo "=== stage5: $l ==="
	obj=$OBJ/$l
	rm -rf $obj
	mkdir $obj || { echo "  cannot make $obj"; fail=1; continue; }
	cd $obj || { fail=1; continue; }

	$T3/bin/make -f $MK/$l.mk SRC=$SRC TOOLDIR=$T3 DESTDIR=$DEST \
		$STAGEMACS "$MACROS"
	rc=$?
	test $rc = 0 && $T3/bin/make -f $MK/$l.mk SRC=$SRC TOOLDIR=$T3 \
		DESTDIR=$DEST $STAGEMACS "$MACROS" install
	irc=$?

	if test $rc = 0
	then
		if test $irc = 0
		then echo "  installed"
		else echo "  INSTALL FAILED $l"; fail=1
		fi
	else
		echo "  BUILD FAILED $l"
		fail=1
	fi
done

echo ""
echo "=== stage 5: what got built ==="
ls -l $DEST/usr/lib

echo ""
if test $fail = 0
then echo "STAGE5 OK"
else echo "STAGE5 INCOMPLETE"
fi
