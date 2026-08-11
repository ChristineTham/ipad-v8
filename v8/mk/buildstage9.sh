#!/bin/sh
# Stage 9: the system we built rebuilds the toolchain, under chroot.
#
#	sh $SRC/mk/buildstage9.sh [srcdir] [blddir] [destdir]
#
# Defaults: /n/src /b /b/root
#
# THE QUESTION THIS ANSWERS is not "does the compiler run" -- stage 6 installed
# it and boot-newdisk.sh already ran it. It is whether the system in DESTDIR is
# COMPLETE: whether it holds every tool, header and library needed to produce
# itself again, with nothing borrowed from the machine that built it.
#
# chroot is the only honest way to ask, and cc(1) is the reason. `-B' is a
# RUNTIME option: the cc that stage 6 installed into DESTDIR still carries
# /lib/ccom as its compiled-in default pass directory. Invoked from outside
# with no -B it silently uses the BUILDING system's ccom, cpp, c2, as and ld,
# and reports success for a DESTDIR that might contain none of them. Under
# chroot, $DESTDIR/lib/ccom *is* /lib/ccom -- so a missing pass is a failure
# instead of a borrowed one. That is also why no -B and no -t are passed
# below, where every other stage passes both: here the defaults are the test.
#
# The share has to be mounted INSIDE the new root before we enter it, because
# after chroot there is no path to anywhere else. $DESTDIR/n/src is that mount
# point, and the caller is expected to have put the share there.

SRC=${1-/n/src}
BLD=${2-/b}
DEST=${3-/b/root}

test -x $DEST/etc/chroot || {
	echo "stage9: no $DEST/etc/chroot -- stage 6 first" 1>&2; exit 1; }
test -x $DEST/bin/cc || {
	echo "stage9: no $DEST/bin/cc -- stage 6 installs the toolchain" 1>&2; exit 1; }
test -f $DEST/n/src/mk/build1.sh || {
	echo "stage9: the share is not mounted at $DEST/n/src" 1>&2
	echo "stage9: chroot cannot reach outside the new root, so it has to be"  1>&2
	echo "stage9: mounted inside it BEFORE we enter" 1>&2
	exit 1; }

# $DEST/bin/yacc, not $DEST/usr/bin/yacc: stage1.order installs yacc and make
# into bin and only lex into usr/bin. Reading the order file beats remembering.
echo "=== stage 9: what DESTDIR has to build with ==="
ls -l $DEST/bin/cc $DEST/lib/ccom $DEST/lib/cpp $DEST/lib/c2 \
      $DEST/lib/as $DEST/lib/ld $DEST/lib/libc.a $DEST/lib/crt0.o \
      $DEST/bin/make $DEST/bin/yacc $DEST/usr/bin/lex 2>&1

# /tmp inside the new root: cc writes its temporaries there and names them
# after its own pid, so a missing /tmp is a compiler that fails on every file
# for a reason that has nothing to do with the file.
mkdir $DEST/tmp 2>/dev/null
chmod 777 $DEST/tmp

# AND /dev/null, which is the one file a chroot cannot do without and the one
# nobody lists. DESTDIR is assembled by buildcmds.sh, which makes bin, etc,
# usr, usr/bin and usr/lib -- there is no /dev, so every `> /dev/null' in
# every script inside the chroot becomes
#
#	build1.sh: /dev/null: cannot create
#
# repeated once per redirection, which reads like a permissions problem in
# the build rather than a missing device. /dev/tty for the same reason.
mkdir $DEST/dev 2>/dev/null
if test -c $DEST/dev/null
then :
else
	rm -f $DEST/dev/null $DEST/dev/tty
	/etc/mknod $DEST/dev/null c 3 2
	/etc/mknod $DEST/dev/tty  c 40 3
	chmod 666 $DEST/dev/null $DEST/dev/tty
fi
ls -l $DEST/dev

echo ""
echo "=== stage 9: rebuilding the toolchain inside $DEST ==="
# No -B, no -t, no TOOLDIR pointing anywhere else: inside the chroot the
# defaults ARE our tools, and that is the whole experiment.
#
# /build9 rather than `/' as the build directory. Passing `/' makes build1.sh
# compose "$BLD/obj9" as `//obj9', and V8's mkdir refuses that with
#
#	mkdir: cannot access //obj9/.
#
# on every component -- a path problem wearing the costume of a permissions
# problem. A named directory has no leading-slash edge case at all.
#
# The toolchain-to-build-WITH is passed as the EMPTY string, not as `/'.
# build1.sh only ever uses it as a prefix -- $T1/bin/cc, $T1/lib/ccom -- so ''
# composes /bin/cc and /lib/ccom exactly, while `/' composes //bin/cc and the
# same double slash that mkdir rejected. Empty is the honest spelling here
# anyway: inside the chroot the toolchain is not in a directory, it IS the
# system.
mkdir $DEST/build9 2>/dev/null
$DEST/etc/chroot $DEST /bin/sh -c \
	"sh /n/src/mk/build1.sh /n/src /build9 9 ''" 2>&1
rc=$?

echo ""
echo "=== stage 9: what came out ==="
ls -l $DEST/build9/tools9/bin 2>&1 | head -20

n=0
for t in yacc make lex cc ar ranlib nm size strip
do
	if test -f $DEST/build9/tools9/bin/$t
	then n=`expr $n + 1`
	else echo "  missing $t"
	fi
done
echo "stage 9 rebuilt $n of 9 checked tools"

if test $rc = 0 -a $n = 9
then echo "STAGE9 OK"
else echo "STAGE9 INCOMPLETE"; exit 1
fi
