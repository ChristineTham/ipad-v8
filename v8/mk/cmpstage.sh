#!/bin/sh
# Compare two stage trees, binary by binary.  Runs inside V8.
#
#	sh $SRC/mk/cmpstage.sh [srcdir] [treeA] [treeB] [scratch]
#
# Defaults: /n/src /b/tools /b/tools2 /b/cmp
#
# This is the fixpoint test, and it is the only one that can tell us the
# toolchain in our repo is self-consistent rather than merely buildable.
#
# Stage 1 compiles our sources with the 1985 system compiler.  Stage 2 compiles
# the SAME sources with the stage-1 result.  If the two agree, then the
# compiler our source describes produces itself -- the classic bootstrap
# fixpoint.  If they differ, the system's /lib/ccom and our ccom.c disagree
# about code generation, and every binary in every later stage inherits
# whichever one happened to run.
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
B=${3-/b/tools2}
W=${4-/b/cmp}
MK=$SRC/mk/gen

rm -rf $W
mkdir $W || { echo "cmpstage: cannot make $W" 1>&2; exit 1; }

same=0
diff=0
miss=0

echo "=== stage1 vs stage2, stripped ==="
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
then echo "TOOLCHAIN-FIXPOINT-ok"
else echo "TOOLCHAIN-NOT-A-FIXPOINT"
fi
