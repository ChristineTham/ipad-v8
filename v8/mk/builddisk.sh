#!/bin/sh
# Stage 8: a bootable disk, made from what stages 4 to 7 built.  Runs in V8.
#
#	sh $SRC/mk/builddisk.sh [srcdir] [destdir] [unit] [type] [mnt]
#
# Defaults: /n/src /b/root 2 rp07 /mnt
#
# `unit' is the SIMH drive number the target image is attached to -- rp2 by
# convention, since rp0 is the running root and rp1 is the build filesystem.
#
# PARTITIONS COME FROM THE DRIVER, NOT FROM MEMORY.  usr/sys/dev/hp.c:
#
#	hp6_sizes	a 15884   b  33440  c  340670          g 291280
#	hp7_sizes	a 15884   b  64000  c 1008000  f 928000
#
# so /usr is partition g on an RP06 and partition f on an RP07, and d, e, f, h
# on an RP06 are ZERO LENGTH -- they are not small, they do not exist.  Root is
# 15884 sectors on both, which is what swapalice.c means by
# `rootdev = makedev(0, 0)'.
#
# THOSE NUMBERS ARE SECTORS AND mkfs WANTS BLOCKS, AND A BLOCK IS NOT A SECTOR.
# This file previously said, as a statement of fact, "mkfs takes 512-byte
# blocks and a sector is 512 bytes, so the sector counts are the block counts".
# usr/include/sys/param.h:
#
#	#define BSIZE(dev)      (BITFS(dev)? 4096: 1024)
#
# So a filesystem of 15884 blocks wants 31768 sectors out of a partition that
# has 15884, and mkfs walks off the end. Hence the divide by 2 below.
#
# The failure is worth knowing because it does not look like an overrun.  mkfs
# builds the free list DOWNWARD from the last block but only writes when its
# in-core list of 150 fills, so the first write lands 149 blocks below the top:
#
#	write error: 15734          (= 15883 - 149)
#
# which reads like a bad block 150 short of the end rather than a filesystem
# twice the size of its partition.
#
# The nodes for the target drive have to exist on the RUNNING system before
# any of this: minor is drive<<3 | partition, `hp' is block major 0 and char
# major 4, and mknod will not replace an existing node -- it prints "File
# exists" and leaves the old one, so a wrong node outlives the fix.

SRC=${1-/n/src}
DEST=${2-/b/root}
UNIT=${3-2}
TYPE=${4-rp07}
MNT=${5-/mnt}
# Where the golden image is mounted, read-only, so the commands the tape
# never shipped sources for can be copied. Optional: without it the disk
# still boots, it just has only what we build.
GOLD=${6-/gold}

case $TYPE in
rp06)	ROOTSEC=15884; USRPART=g; USRPARTNO=6; USRSEC=291280 ;;
rp07)	ROOTSEC=15884; USRPART=f; USRPARTNO=5; USRSEC=928000 ;;
*)	echo "builddisk: unknown drive type $TYPE (rp06 or rp07)" 1>&2; exit 1 ;;
esac

# sectors -> filesystem blocks.  BSIZE(dev) is 1024 and a sector is 512, so
# every partition holds half as many blocks as it does sectors.  Kept as an
# explicit divide with the two names spelled differently (SEC vs SZ) rather
# than pre-divided constants, because the numbers above are quoted from
# usr/sys/dev/hp.c and should stay quotable.
ROOTSZ=`expr $ROOTSEC / 2`
USRSZ=`expr $USRSEC / 2`

test -f $DEST/unix || { echo "builddisk: no $DEST/unix -- stage 7 first" 1>&2; exit 1; }
test -d $DEST/bin  || { echo "builddisk: no $DEST/bin -- stage 6 first" 1>&2; exit 1; }
test -f $SRC/mk/gen/makedev.sh || { echo "builddisk: no makedev.sh" 1>&2; exit 1; }

if test "$UNIT" = 0
then echo "builddisk: refusing to build over drive 0, which is the running root" 1>&2; exit 1
fi

ROOTB=/dev/rp$UNIT'a'; ROOTR=/dev/rrp$UNIT'a'
USRB=/dev/rp$UNIT$USRPART; USRR=/dev/rrp$UNIT$USRPART
AMIN=`expr $UNIT \* 8`
UMIN=`expr $UNIT \* 8 + $USRPARTNO`

echo "=== stage 8: $TYPE on drive $UNIT, root $ROOTSZ blocks ($ROOTSEC sectors), /usr $USRSZ blocks ($USRSEC sectors) ==="

# /etc/mknod, not mknod. There is no mknod on root's PATH -- where.txt says
# /etc -- and the first run of this script said so four times, in the middle
# of its own output, as `builddisk.sh: mknod: not found'.
#
# rm first: mknod does not replace, it complains and leaves what was there.
rm -f $ROOTB $ROOTR $USRB $USRR
/etc/mknod $ROOTB b 0 $AMIN
/etc/mknod $ROOTR c 4 $AMIN
/etc/mknod $USRB  b 0 $UMIN
/etc/mknod $USRR  c 4 $UMIN
ls -l $ROOTB $ROOTR $USRB $USRR

# AND THEN CHECK, because the failure that follows a missing node is not a
# failure. mkfs(8) does not require a special file: given a name that is not
# one it CREATES A REGULAR FILE and writes the filesystem into it. So four
# `mknod: not found' messages turned `mkfs /dev/rrp2f 928000' into a request
# to write 475 MB into a file on the RUNNING system's root -- which is 8 MB --
# and the diagnostic was `/: file system full', about the wrong filesystem
# entirely, three lines after a message nobody reads twice.
#
# This is the only guard that matters in this script: everything after it
# either works on a real device or refuses to start.
for n in $ROOTB $USRB
do
	test -b $n || { echo "builddisk: $n is not a block device -- refusing"; exit 1; }
done
for n in $ROOTR $USRR
do
	test -c $n || { echo "builddisk: $n is not a character device -- refusing"; exit 1; }
done

echo ""
echo "=== stage 8: mkfs ==="
/etc/mkfs $ROOTR $ROOTSZ || { echo "builddisk: mkfs root failed"; exit 1; }
/etc/mkfs $USRR  $USRSZ  || { echo "builddisk: mkfs usr failed"; exit 1; }

# Never mount an unverified filesystem: mounting a bad one panics the kernel
# outright and costs an image.  fsck on a fresh filesystem takes seconds and
# its exit status is the gate.
/etc/fsck -y $ROOTR || { echo "builddisk: fsck root failed"; exit 1; }
/etc/fsck -y $USRR  || { echo "builddisk: fsck usr failed"; exit 1; }

mkdir $MNT 2>/dev/null
/etc/mount $ROOTB $MNT || { echo "builddisk: mount root failed"; exit 1; }
mkdir $MNT/usr
/etc/mount $USRB $MNT/usr || { echo "builddisk: mount usr failed"; exit 1; }
df $MNT $MNT/usr

echo ""
echo "=== stage 8: the tree ==="
# V8 has no mkdir -p and no cp -r.  The directory list is explicit and the
# copies are one `cp src/* dst' per directory, so a failure names a directory
# rather than disappearing into a recursive walk.
# tmp/dump is not decoration: /etc/rc line 31 is `/etc/savecore /tmp/dump',
# savecore's argument is the DIRECTORY it saves a crash dump into, and without
# it every single boot opens with "/tmp/dump: No such file or directory".
# proc, because /etc/rc mounts it and V8's /proc is a real filesystem type --
# without the directory every boot prints
#	gmount(2, "/proc", 0) returned -1, errno = 2
# which is ENOENT for the MOUNT POINT, not for anything in the kernel.
# etc/skel holds the .profile a new account starts from; usr/jerq must
# exist before cpio -p is pointed at it as a destination directory.
for d in bin etc etc/skel lib tmp tmp/dump dev proc usr/adm \
	 usr/spool usr/tmp usr/jerq
do
	mkdir $MNT/$d 2>/dev/null
done
# ...and every directory the build installs into, which is generated rather
# than listed here because the list was wrong -- see gen/destdirs.txt.  It is
# sorted parents first, which is load-bearing: V8 has no mkdir -p.
for d in `grep -v '^#' $SRC/mk/gen/destdirs.txt`
do
	mkdir $MNT/$d 2>/dev/null
done
chmod 777 $MNT/tmp $MNT/usr/tmp

echo ""
echo "=== stage 8: carry what only the TUHS image has ==="
date
# THE ONE THING THAT MAKES RETIRING THAT IMAGE SAFE.  gen/carry.txt is the
# set of files that exist ONLY there: machine code the tape shipped without
# source, plus what the Labs (or we) put on it afterwards.  Everything else
# is built by stages 4-7 or stored as text in v8/ and proven by MANIFEST, so
# once these 1385 files are here the image holds nothing unique.
# tools/mkcarry.py generates the list; it is not maintained by hand.
#
# cpio, not a `cp' loop.  The loop this replaces spawned one process per
# file and stage 8 was dominated by fork/exec rather than by I/O -- 400
# copies took longer than the mkfs of a 475 MB filesystem.  cpio -p is one
# process for the whole set and reads its paths from stdin, which is exactly
# the shape of a generated manifest.
#
# No -v.  It would name all 1385 files down a 9600-baud console.
#
# $GOLD is that image's root, mounted read-only by the caller.  Without it
# the disk still boots -- everything we build is already here -- so a
# missing $GOLD is a warning, not a failure.
if test -d $GOLD/bin
then
	( cd $GOLD && grep -v '^#' $SRC/mk/gen/carry.txt | cpio -pdm $MNT )
	echo "  carried: /usr/jerq `ls $MNT/usr/jerq/bin | wc -l` in bin, `ls $MNT/usr/jerq/mbin | wc -l` in mbin"
else
	echo "  no golden image at $GOLD -- the disk will have only what we build"
	echo "  (mount rp3's root there, then this disk can replace it)"
fi

echo ""
echo "=== stage 8: the runtime trees ==="
date
# Everything a working system needs that is NOT a command and NOT unique to
# the reference image: nroff's macros, terminal tables, the manual, the
# games' data files, the 5620's fonts and icons.
#
# These are `source' rows in MANIFEST -- text on the tape, so v8/ holds them
# and v8/ is authoritative.  But 2263 of the 2264 are BYTE-IDENTICAL to the
# copy already on the mounted image, and mkcarry.py proves that with sha256
# every time it regenerates these lists.  So they come off the image, and
# only the ones that actually differ come over the wire.
#
# This is not a shortcut, it is the difference between a usable build and an
# abandoned one.  Pulling all 2264 over netfs costs a round trip per file
# through an emulated VAX, an emulated Interlan and SLiRP: measured at about
# 30 files a minute, so ninety minutes, of which eighty-nine deliver bytes
# the machine already had mounted.  cpio does the same set in six seconds.
if test -d $GOLD/bin
then
	( cd $GOLD && grep -v '^#' $SRC/mk/gen/fromgold.txt | cpio -pdm $MNT )
fi

# ...and the ones where we and the tape disagree, which is the whole reason
# the split is computed rather than assumed.  Two columns, because the tape
# says jerq/ where the image says /usr/jerq.
grep -v '^#' $SRC/mk/gen/fromsrc.txt |
while read s d
do
	dd=`dirname $MNT/$d`
	test -d $dd || mkdir $dd 2>/dev/null
	cp $SRC/$s $MNT/$d || echo "  cannot install $s"
done
echo "  /usr/man: `ls $MNT/usr/man | wc -l` sections, /usr/lib: `ls $MNT/usr/lib | wc -l` entries"

echo ""
echo "=== stage 8: what we built, last so that ours wins ==="
date
# LAST ON PURPOSE.  A command can be `excluded' on the tape and `build' for
# us at the same time -- the tape shipped /bin/ls as a binary and ls.c as
# source -- and mkcarry.py already drops those 206 from carry.txt.  Copying
# ours last makes that belt-and-braces: whatever order the passes above
# leave behind, the binary that ends up on the disk is the one this build
# produced.
#
# THE DIRECTORY LIST IS GENERATED, and that is the whole point of it.  It
# used to be written here by hand, and it was wrong twice over: usr/games
# was missing, so `bcd' -- the one game with source on the tape -- was built,
# reported built, and absent from the disk; and so were usr/include/CC and
# its two subdirectories, usr/include/chaos, usr/include/local and
# usr/lib/lex, another 34 files.  mkdep.py now scrapes the destinations out
# of the cp rules of the makefiles it generates, so a component that starts
# installing somewhere new appears here without anyone noticing it had to.
#
# Worth knowing that retire-check.py cannot catch this class: headers are
# `source' rows in MANIFEST, so it counts them as safe in git and never asks
# whether they are on the disk.
for d in `grep -v '^#' $SRC/mk/gen/destdirs.txt`
do
	if test -d $DEST/$d
	then
		cp $DEST/$d/* $MNT/$d 2>/dev/null
		echo "  $d: `ls $MNT/$d | wc -l` files"
	fi
done

echo ""
echo "=== stage 8: /dev ==="
sh $SRC/mk/gen/makedev.sh $MNT/dev

echo ""
echo "=== stage 8: the kernel and /etc ==="
cp $DEST/unix $MNT/unix
chmod 755 $MNT/unix
# The tape's own /etc config, from the repo rather than from the running
# machine: rc, ttys, passwd, group, fstab, termcap and the rest.
cp $SRC/etc/* $MNT/etc 2>/dev/null
echo "  /etc: `ls $MNT/etc | wc -l` files"

# The login environment, which V8 ships NONE of -- no /.profile, no /.login,
# no /etc/profile, which is why vi used to die with TERM unset.  Ours picks
# TERM from `tty` so that tty00 is the 5620 and tty07 the wide vt100, which
# is only correct because every DZ line has its own listen port (CLAUDE.md).
#
# Kept in v8/etc as ordinary files rather than written here by a here-
# document: they are configuration, they belong under review, and a shell
# script that echoes shell scripts gets the quoting wrong eventually.
cp $SRC/etc/profile.root $MNT/.profile
cp $SRC/etc/profile.skel $MNT/etc/skel/.profile
chmod 644 $MNT/.profile $MNT/etc/skel/.profile

# wmux is ours too (A4): three lines that point $MUXTERM at the widened
# muxterm before exec'ing mux, because on a 1152-wide screen stock mux
# downloads happily and then draws into the vacated 0x700000. It is not on
# the tape, so no MANIFEST row describes it and neither generated list
# picks it up -- it has to be named here or it silently does not ship.
cp $SRC/jerq/bin/wmux $MNT/usr/jerq/bin/wmux
chmod 755 $MNT/usr/jerq/bin/wmux
ls -l $MNT/unix $MNT/.profile

# fsck cannot reconnect an orphaned inode without one, and an autoboot fsck
# that needs to aborts to a single-user shell -- "Automatic reboot failed...
# help!" -- which is how a disk that looks finished turns out not to boot.
#
# cd, because /etc/mklost+found TAKES NO ARGUMENT. It is a shell script whose
# first line is `mkdir lost+found', in the current directory, and it ignores
# anything you pass it -- silently, and then prints the full path of what it
# made, which is the only reason this was caught:
#
#	drwxrwxr-x  2 root bin 4128 /tmp/lost+found
#
# after `/etc/mklost+found /mnt'.  The second call then said "mkdir: cannot
# make directory lost+found" because the first had already made it in /tmp,
# and stage 8 finished reporting success with neither filesystem having one.
( cd $MNT     && /etc/mklost+found )
( cd $MNT/usr && /etc/mklost+found )
ls -ld $MNT/lost+found $MNT/usr/lost+found

echo ""
echo "=== stage 8: unmount and verify ==="
cd /
sync; sync
/etc/umount $USRB
/etc/umount $ROOTB
/etc/fsck -y $ROOTR
rc=$?
/etc/fsck -y $USRR
urc=$?

echo ""
if test $rc = 0 -a $urc = 0
then echo "STAGE8 OK"
else echo "STAGE8 INCOMPLETE"; exit 1
fi
