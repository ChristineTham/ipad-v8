#!/bin/sh
# Compare two stage trees, binary by binary.  Runs inside V8.
#
#	sh $SRC/mk/cmpstage.sh [srcdir] [treeA] [treeB] [scratch]
#
# Defaults: /n/src /b/tools /b/tools3 /b/cmp
#
# This is the fixpoint test, and it is the only one that can tell us the
# toolchain in our repo is self-consistent rather than merely buildable.
#
# Stage 1 compiles our sources with the 1985 system compiler and links them
# against the 1985 libc.  Stage 3 compiles the SAME sources with the stage-1
# toolchain and links them against the libc stage 2 built -- so stage 3 is the
# first set of binaries in which every component came from our source.
#
# If the two agree, the system reproduces itself: the compiler our source
# describes, linked against the libc our source describes, produces the same
# fourteen binaries as the ones Bell Labs' tools produced from the same input.
# If they differ, something in our source disagrees with what built the tape's
# binaries, and every later stage inherits whichever one happened to run.
#
# A difference here is not automatically wrong -- it could be libc rather than
# ccom -- but it is always worth chasing before a userland is built on top.
#
# STRIP BOTH SIDES FIRST.  cc writes its temporary file names into the symbol
# table --
#	sprintf(tmp0, "/tmp/ctm%05.5d", getpid())
# -- so two compiles of one file differ at byte 16441 while the code is
# identical.  That was measured, not assumed; see docs/build-from-source.md.
# Comparing unstripped would report every binary as different and mean nothing.
#
# The list of things to compare is stage1.order's third column, so it cannot
# drift out of step with what the build installs.

SRC=${1-/n/src}
A=${2-/b/tools}
B=${3-/b/tools3}
W=${4-/b/cmp}
MK=$SRC/mk/gen

rm -rf $W
mkdir $W || { echo "cmpstage: cannot make $W" 1>&2; exit 1; }

same=0
diff=0
miss=0

echo "=== $A vs $B, stripped ==="
for p in `sed 's/^[^	]*	[^	]*	//' $MK/stage1.order`
do
	n=`echo $p | sed 's|.*/||'`
	if test ! -f $A/$p
	then
		echo "  MISSING-A  $p"
		miss=`expr $miss + 1`
		continue
	fi
	if test ! -f $B/$p
	then
		echo "  MISSING-B  $p"
		miss=`expr $miss + 1`
		continue
	fi
	cp $A/$p $W/a.$n
	cp $B/$p $W/b.$n
	strip $W/a.$n $W/b.$n 2>/dev/null
	if cmp -s $W/a.$n $W/b.$n
	then
		echo "  same       $p"
		same=`expr $same + 1`
	else
		echo "  DIFFER     $p"
		diff=`expr $diff + 1`
	fi
done

echo ""
echo "cmpstage: same=$same differ=$diff missing=$miss"
# A literal marker is safe here, unlike the ones the driver types: this string
# is printed by a script, and the command that starts the script does not
# contain it, so the tty echo cannot forge it.
if test $diff = 0 -a $miss = 0 -a $same != 0
then echo "TOOLCHAIN-FIXPOINT-ok"; exit 0
else echo "TOOLCHAIN-NOT-A-FIXPOINT"; exit 1
fi
