#!/bin/sh
# Stage 7: the kernel.  Runs inside V8.
#
#	sh $SRC/mk/buildkernel.sh [srcdir] [blddir] [destdir] [machine] [toolsdir]
#
# Defaults: /n/src /b /b/root ipnx /b/tools3
#
# THIS ONE COPIES THE SOURCE, and it is the only stage that does.  config(8)
# resolves its global data files by literal string concatenation --
#
#	strcpy(cp, "../conf/"); strcat(cp, file);	(config/main.c, gpath)
#
# -- and the makefile it generates compiles ../sys/*.c, ../dev/*.c, ../h/*.h.
# The whole kernel build is relative-path bound to a directory that sits
# beside conf/, sys/, dev/ and h/.  Nothing short of patching config and
# rewriting every generated path changes that, and neither is worth doing to
# avoid copying 350 small files.
#
# The invariant that actually matters is unaffected: NOTHING IS EVER WRITTEN
# TO THE SHARE.  The copy goes into $BLD, config runs there, and the source
# tree stays read-only -- which is also why the copy is made fresh every run
# rather than updated in place.
#
# The machine description is v8/usr/sys/$MACHINE/conf.  `ipnx' is ours:
# alice's VAX-11/780 hardware plus the Internet pseudo-devices research had,
# because neither of the tape's own machines is the one we emulate.

SRC=${1-/n/src}
BLD=${2-/b}
DEST=${3-/b/root}
MACHINE=${4-ipnx}
T3=${5-$BLD/tools3}

SYS=$BLD/sys

test -f $SRC/usr/sys/$MACHINE/conf || {
	echo "buildkernel: no $SRC/usr/sys/$MACHINE/conf" 1>&2
	exit 1
}
test -f $T3/bin/cc || {
	echo "buildkernel: no $T3/bin/cc -- stage 3 first" 1>&2
	exit 1
}
test -x $DEST/bin/config -o -x $DEST/etc/config || {
	echo "buildkernel: no config(8) in $DEST -- stage 6 first" 1>&2
	echo "buildkernel: (config needs yacc AND lex, so it cannot be a stage-1 tool)" 1>&2
	exit 1
}
CONFIG=$DEST/etc/config
test -x $CONFIG || CONFIG=$DEST/bin/config

echo "=== stage 7: copying usr/sys -> $SYS ==="
rm -rf $SYS
mkdir $BLD 2>/dev/null
mkdir $SYS || { echo "buildkernel: cannot make $SYS" 1>&2; exit 1; }

# One level of subdirectories, all flat.  V8 has no cp -r and no mkdir -p, and
# a tar pipe would work but hides which file failed.
for d in `cd $SRC/usr/sys; echo *`
do
	test -d $SRC/usr/sys/$d || continue
	mkdir $SYS/$d || { echo "  cannot make $SYS/$d"; exit 1; }
	cp $SRC/usr/sys/$d/* $SYS/$d 2>/dev/null
done
echo "copied: `ls $SYS | wc -l` directories, `find $SYS -type f -print | wc -l` files"

# config writes conf.c, ioconf.c, ubglue.s, a makefile and a pile of headers
# into the machine directory, so that directory has to be writable -- another
# reason the copy exists.
echo ""
echo "=== stage 7: config $MACHINE ==="
cd $SYS/$MACHINE || exit 1
$CONFIG
rc=$?
test $rc = 0 || { echo "buildkernel: config failed"; echo "STAGE7 INCOMPLETE"; exit 1; }
ls -l makefile conf.c ioconf.c ubglue.s

# The generated makefile has `rm locore.o` with no -f, so the first build in a
# clean directory fails on a file that was never there.  N3 hit this and fixed
# it with sed; doing it here keeps the fix in the build rather than in a
# one-off driver.
if grep 'rm locore' makefile > /dev/null
then
	echo "buildkernel: patching the generated makefile's bare \`rm locore'"
	sed 's/rm locore/rm -f locore/' makefile > mk.new
	cp mk.new makefile
	rm -f mk.new
fi

echo ""
echo "=== stage 7: make ==="
# The kernel is compiled by the stage-3 toolchain, sealed the same way
# everything since stage 3 has been.  C2, AS and LD are named separately
# because the generated makefile drives them by hand for the assembly passes
# and the final link, rather than going through cc.
#
# LD matters most and used to be impossible: config emitted a LITERAL `ld` for
# the one command whose output is the kernel, so a fully staged build compiled
# every object with our toolchain and then linked the result with the running
# system's loader.  mkmakefile.c now emits ${LD} and ${CC}, and conf/makefile
# defaults both -- V8's make has no built-in LD, only CC, AS, AR, YACC, LEX.
#
# STILL NOT SEALED HERE, and worth saying rather than implying: the generated
# rules pipe through `sed` (../sys/asm.sed) and ../conf/newvers.sh runs `date`
# and `sh`.  Those are the running system's until stage 6 grows past config.
$T3/bin/make CC="$T3/bin/cc -B$T3/lib/ -t02palc" C2=$T3/lib/c2 \
	AS=$T3/lib/as LD=$T3/lib/ld
rc=$?

echo ""
echo "=== stage 7: what got built ==="
ls -l unix

if test $rc = 0 -a -f unix
then
	mkdir $DEST 2>/dev/null
	cp unix $DEST/unix
	echo "installed $DEST/unix"
	echo "STAGE7 OK"
else
	echo "STAGE7 INCOMPLETE"
	exit 1
fi
