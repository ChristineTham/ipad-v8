#!/bin/sh
# Stage 4: install our headers.  Runs inside V8.
#
#	sh $SRC/mk/buildhdrs.sh [srcdir] [destdir]
#
# Defaults: /n/src /b/root
#
# Nothing is compiled.  This stage exists because every stage after it must
# compile against the headers in this repo rather than the ones on the disk
# it is running from, and that is a property of where -I points -- so it has
# to happen before stage 5, and it has to happen into a directory of ours.
#
# It writes only under $DEST.  It does NOT touch /usr/include: the running
# system's headers are what stages 1 to 3 were built against, and replacing
# them mid-build would silently change what a later stage compiles against
# with no way to tell which files got which.

SRC=${1-/n/src}
DEST=${2-/b/root}
MK=$SRC/mk/gen

test -f $MK/headers.mk || { echo "buildhdrs: no $MK/headers.mk" 1>&2; exit 1; }

case $DEST in
/usr|/usr/|/) echo "buildhdrs: refusing to install over $DEST" 1>&2; exit 1;;
esac

# V8's mkdir makes one level at a time; headers.mk makes the rest.
mkdir $DEST		2>/dev/null
mkdir $DEST/usr		2>/dev/null

echo "=== stage 4: headers -> $DEST/usr/include ==="
# The running system's make, deliberately, and it is the only stage that uses
# it after stage 1.  Every rule here is a `cp`, so which make walks the graph
# cannot affect a single byte of the output -- and requiring stage 1 first
# would make the headers depend on the toolchain, which they do not.
make -f $MK/headers.mk SRC=$SRC DESTDIR=$DEST install
rc=$?

echo ""
echo "=== stage 4: what got installed ==="
n=`ls $DEST/usr/include $DEST/usr/include/sys $DEST/usr/include/sys/inet \
      $DEST/usr/include/CC $DEST/usr/include/CC/common $DEST/usr/include/CC/sys \
      $DEST/usr/include/chaos $DEST/usr/include/local 2>/dev/null | \
      grep -v ':' | grep -v '^$' | wc -l`
echo "files: $n"

echo ""
if test $rc = 0
then echo "STAGE4 OK"
else echo "STAGE4 INCOMPLETE"
fi
