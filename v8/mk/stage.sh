#!/bin/sh
# Stage the ipnx V8 source from the host share onto local disk.
#
#	sh /n/src/mk/stage.sh [share] [dest]
#
# Runs inside V8.  Defaults: share /n/src, dest /bld/src.
#
# The copy is deliberate, not a convenience.  Building directly off netfs would
# put a 40-minute compile at the mercy of one dropped TCP connection, and the
# guest has to own the tree anyway: two of its directory names cannot exist on
# the macOS side at all.
#
# WHY THE RENAMES
#
# The V8 tape distinguishes usr/src/cmd/Mail from usr/src/cmd/mail, and
# jerq/src/lib/C from jerq/src/lib/c.  macOS merges those; git cannot check out
# both either.  So the repo stores the loser of each pair percent-escaped, and
# this is where the true names come back -- V8's filesystem is case-sensitive
# and has no opinion about any of it.
#
# Parents are renamed before children, which is why CASEMAP is (directory,
# stored-name, true-name) rather than two full paths: once %4Dail has become
# Mail, no path recorded against the old spelling is valid any more.

SHARE=${1-/n/src}
DEST=${2-/bld/src}

if test ! -f $SHARE/CASEMAP
then
	echo "stage: $SHARE does not look like the ipnx v8 tree" 1>&2
	exit 1
fi

echo "stage: copying $SHARE -> $DEST"
rm -rf $DEST
mkdir /bld 2>/dev/null
mkdir $DEST || exit 1

# cp -r would follow the share one file at a time; tar keeps one stream open
# and moves ~100 KB/s, which is netfs's measured ceiling either way.
(cd $SHARE; tar cf - bin etc jerq blit proto-dev usr mk) | (cd $DEST; tar xf -)

echo "stage: restoring case-sensitive names"
n=0
grep -v '^#' $SHARE/CASEMAP | grep . | while read dir stored true
do
	if test -d $DEST/$dir -a -e "$DEST/$dir/$stored"
	then
		(cd $DEST/$dir && mv "$stored" "$true") || echo "  FAILED $dir/$stored"
		n=`expr $n + 1`
	else
		echo "  missing $dir/$stored"
	fi
done
echo "stage: renamed `grep -v '^#' $SHARE/CASEMAP | grep -c .` paths"

echo "stage: recreating empty directories"
grep -v '^#' $SHARE/EMPTYDIRS | grep . | while read d
do
	mkdir $DEST/$d 2>/dev/null
done

# The two directories that a Mac cannot hold at once are the whole point, so
# say plainly whether they made it.
echo "stage: checking the collisions that motivated all this"
for p in usr/src/cmd/Mail usr/src/cmd/mail jerq/src/lib/C jerq/src/lib/c
do
	if test -d $DEST/$p
	then echo "  ok      $p"
	else echo "  MISSING $p"
	fi
done

echo "stage: done -- source is at $DEST"
