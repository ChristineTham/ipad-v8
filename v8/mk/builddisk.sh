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
for d in bin etc lib tmp tmp/dump dev proc usr/bin usr/lib usr/include \
	 usr/include/sys usr/include/sys/inet usr/adm usr/spool usr/tmp
do
	mkdir $MNT/$d 2>/dev/null
done
chmod 777 $MNT/tmp $MNT/usr/tmp

for d in bin etc lib usr/bin usr/lib usr/include usr/include/sys \
	 usr/include/sys/inet
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
ls -l $MNT/unix

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
