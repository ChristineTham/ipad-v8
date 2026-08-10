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

# -f as the first argument forces a full copy.
FORCE=""
if test "$1" = "-f"
then
	FORCE=yes
	shift
fi
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
df /
df /usr
free=`df /usr | awk 'NR==2 {print $5}'`
echo "stage: $free KB free on /usr, need about 30000"
if test "$free" -lt 30000
then
	echo "stage: not enough room -- refusing to half-fill a filesystem" 1>&2
	exit 1
fi

# A root partition with no space left is not a slow system, it is a system
# where open(2) fails on files that plainly exist -- including files on the
# netfs share, which is how the first run of this presented: `ls /n/src` fine,
# every read "cannot open".  Clear the wreckage of any earlier attempt.
rootfree=`df / | awk 'NR==2 {print $5}'`
if test "$rootfree" -lt 500
then
	echo "stage: / has only $rootfree KB free -- clearing /bld if it is ours"
	rm -rf /bld
	df /
fi

echo "stage: $SHARE -> $DEST"
mkdir /usr/bld 2>/dev/null

# INCREMENTAL.  A full copy is ~25 minutes over netfs, which is fine once and
# indefensible on every run when what changed was one shell script.  There is no
# rsync here and never will be, so tree.list (written by tools/gen-tree-list.py
# on the host) carries a size per file and one stamp over the lot:
#
#   stamp matches   -> nothing changed, do nothing at all
#   no tree yet     -> one tar stream, which beats 7819 separate cp's
#   otherwise       -> copy only the files whose size differs
#
# Size, not mtime, on purpose: the guest's TODR starts in 1976 until someone
# sets it, so mtime comparison would call every file stale forever.  Size misses
# an edit that happens to preserve length -- rare in source, and `stage.sh -f`
# forces a full copy when it matters.
STAMP=`sed 1q $SHARE/mk/tree.list`
HAVE=""
if test -f $DEST/.stamp
then
	HAVE=`cat $DEST/.stamp`
fi

if test "$FORCE" = ""  -a  "$STAMP" = "$HAVE"  -a  -d $DEST/usr/src
then
	echo "stage: unchanged ($STAMP) -- nothing to do"
	exit 0
fi

if test ! -d $DEST/usr/src -o "$FORCE" != ""
then
	echo "stage: full copy"
	FULL=yes
	rm -rf $DEST
	mkdir $DEST || exit 1
	# usr first: it is the bulk and the part everything else needs, so if
	# space does run out we find out on the member that matters.
	(cd $SHARE; tar cf - usr mk etc bin jerq blit proto-dev) | (cd $DEST; tar xf -)
else
	echo "stage: incremental against $HAVE"
	FULL=no
	# stored is how the share spells it, true is how the staged tree does;
	# compare against true, copy from stored.
	sed 1d $SHARE/mk/tree.list | while read size stored true
	do
		have=`ls -l $DEST/$true 2>/dev/null | awk '{print $5}'`
		if test "$have" != "$size"
		then
			echo "  update $true"
			d=`echo $true | sed 's|/[^/]*$||'`
			test -d $DEST/$d || sh $SHARE/mk/mkdirp.sh $DEST/$d
			cp $SHARE/$stored $DEST/$true
		fi
	done
fi
echo "$STAMP" > $DEST/.stamp

# Only after a full copy.  An incremental pass writes true names directly, so
# there is nothing escaped left to rename and every line would report "missing".
if test "$FULL" = "yes"
then
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
fi

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
