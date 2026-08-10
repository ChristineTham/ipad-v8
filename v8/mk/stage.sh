#!/bin/sh
# Stage the ipnx V8 source from the host share onto local disk.
#
#	sh /n/src/mk/stage.sh [share] [dest]
#
# Runs inside V8.  Defaults: share /n/src, dest /usr/bld/src.
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
DEST=${2-/usr/bld/src}

if test ! -f $SHARE/CASEMAP
then
	echo "stage: $SHARE does not look like the ipnx v8 tree" 1>&2
	exit 1
fi

# /usr, not /.  V8's root partition on this disk is 7.6 MB with about 4 free,
# so an unqualified /bld gets a third of the way through jerq and dies with
# "HELP - extract write error" -- and tar's failure is per-file, so the
# remaining members (blit, proto-dev, usr, mk) are simply never written and
# the tree looks like it copied.  Check the space before spending five minutes
# discovering that again.
echo "stage: space check"
df /usr
free=`df /usr | sed -n '2p' | sed 's/.*  *\([0-9][0-9]*\)  *[0-9][0-9]*%*.*/\1/'`
echo "stage: $free KB free on /usr, need about 30000"

echo "stage: copying $SHARE -> $DEST"
rm -rf $DEST
mkdir /usr/bld 2>/dev/null
mkdir $DEST || exit 1

# cp -r would follow the share one file at a time; tar keeps one stream open
# and moves ~100 KB/s, which is netfs's measured ceiling either way.
# usr first: it is the bulk and the part everything else needs, so if space
# does run out we find out on the member that matters.
(cd $SHARE; tar cf - usr mk etc bin jerq blit proto-dev) | (cd $DEST; tar xf -)

echo "stage: restoring case-sensitive names"
# `test -e` does not exist in 1985 -- V7's test has -f, -d, -r, -w, -s and no
# more, so `-e` made every one of these look absent and silently skipped the
# whole point of the exercise.  -d or -f covers both kinds of collision.
grep -v '^#' $SHARE/CASEMAP | grep . | while read dir stored true
do
	if test -d "$DEST/$dir/$stored" -o -f "$DEST/$dir/$stored"
	then
		if (cd $DEST/$dir && mv "$stored" "$true")
		then echo "  renamed $dir/$true"
		else echo "  FAILED  $dir/$stored"
		fi
	else
		echo "  missing $dir/$stored"
	fi
done

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
