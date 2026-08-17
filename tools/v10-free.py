#!/usr/bin/env python3
"""How much room is left in a Tenth Edition filesystem, read from the host.

    tools/v10-free.py <image> [partition]     default partition c
    tools/v10-free.py <image> c --need 20000  exit 1 unless that many free

WHY THIS EXISTS, AND WHY NO GUEST-SIDE PROBE CAN REPLACE IT.  A full V10
filesystem does not fail -- it HANGS.  lsys/fs/alloc.c prints `file system
full' and sleeps, waiting for space that is never coming, so the process
blocks in the kernel instead of returning an error.  That defeats every
guest-side guard by construction: the compile never fails, so a
count-consecutive-failures detector never counts, and a `dd'/`cat' probe would
block in exactly the same place as the thing it is meant to protect.  Twice
now a run has been launched at an image whose /usr was already nearly full --
once at `.stage1.s2.s3', which carries four toolchain installs and two object
trees, and once at `.stage1' -- and both times the symptom was a simulator at
100% CPU with a kernel message repeating every few seconds.

So the check has to happen before the boot, on the host, against the image
file.  That is the same argument tools/v8fs.py was written from: "read a disk
from the host -- don't boot one to look".

SELF-VALIDATING, BECAUSE A STRUCT OFFSET COMPUTED FROM A HEADER IS A GUESS
UNTIL SOMETHING CONFIRMS IT.  The field offsets below are computed from
lsys/sys/filsys.h and VAX alignment, and then checked against two things the
superblock itself must satisfy: s_fsize has to match the partition's declared
size, and s_fsmnt has to hold a plausible mount name.  If either fails the tool
refuses to answer rather than reporting a number derived from the wrong bytes.
"""

import os
import struct
import sys

# ra_sizes[] from lsys/io/ra.c, in 512-byte SECTORS.  Partition c is where
# every V10 filesystem this project makes lives; d and e are unused space of
# the same size, which is what makes them the answer to "where do the objects
# go" once V10 writes its own filesystems (K11).
RA_SIZES = {
    "a": (10240, 0),
    "b": (20480, 10240),
    "c": (249848, 30720),
    "d": (249848, 280568),
    "e": (249848, 530416),
    "g": (749544, 30720),
}

# A bitmapped (4K) filesystem: BSIZE(dev) is 4096 when the minor has bit 64
# set, and every V10 filesystem here is made that way -- see mkbitfs.c and
# CLAUDE.md's note that minor 74 means "bitmapped" to V10 and "unit 1" to V8 at
# the same time.
BSIZE = 4096
SUPERB = 1          # param.h: block number of the super block
NICINOD = 100       # param.h
SECTOR = 512


def offsets():
    """Byte offsets of the fields we read, from filsys.h and VAX alignment.

    struct filsys, in declaration order, with longs aligned to 4:

        0   unsigned short s_isize
        4   daddr_t        s_fsize          (long, so 2 bytes of padding at 2)
        8   short          s_ninode
        10  ino_t          s_inode[100]     (unsigned short each -> 200 bytes)
        210 char           s_flock, s_ilock, s_fmod, s_ronly
        214 (pad to 4)
        216 time_t         s_time
        220 daddr_t        s_tfree
        224 ino_t          s_tinode
        226 short          s_dinfo[2]
        230 char           s_fsmnt[14]
        244 ino_t          s_lasti
        246 ino_t          s_nbehind
    """
    o = {}
    p = 0
    o["s_isize"] = p; p += 2
    p += 2                              # pad: daddr_t wants a 4-byte boundary
    o["s_fsize"] = p; p += 4
    o["s_ninode"] = p; p += 2
    o["s_inode"] = p; p += 2 * NICINOD
    o["s_flock"] = p; p += 4            # flock, ilock, fmod, ronly
    if p % 4:                           # pad before time_t
        p += 4 - (p % 4)
    o["s_time"] = p; p += 4
    o["s_tfree"] = p; p += 4
    o["s_tinode"] = p; p += 2
    o["s_dinfo"] = p; p += 4
    o["s_fsmnt"] = p; p += 14
    o["s_lasti"] = p; p += 2
    o["s_nbehind"] = p; p += 2
    # The union.  The B arm -- bitmap IN the superblock -- is
    #   char S_valid; char S_flag; long S_bfree[BITMAP]
    # with S_bfree needing a 4-byte boundary.  248 + 4 + 961*4 = 4096 exactly,
    # which is a strong confirmation the offsets above are right: the struct
    # fills one 4K block to the byte, as a superblock must.
    o["S_valid"] = p
    o["S_flag"] = p + 1
    q = p + 2
    if q % 4:
        q += 4 - (q % 4)
    o["S_bfree"] = q
    o["_end"] = q + 4 * 961
    return o


def read_super(image, part):
    """The superblock bytes of one partition."""
    if part not in RA_SIZES:
        sys.exit("v10-free: no partition %r in ra_sizes[]" % part)
    nsect, off = RA_SIZES[part]
    base = off * SECTOR
    where = base + SUPERB * BSIZE
    size = os.path.getsize(image)
    if where + BSIZE > size:
        sys.exit("v10-free: %s is too small for partition %s" % (image, part))
    with open(image, "rb") as fh:
        fh.seek(where)
        return fh.read(BSIZE), nsect


def free_blocks(image, part="c"):
    """(free, total, mount name) in 4K blocks, or exit if the bytes disagree."""
    sb, nsect = read_super(image, part)
    o = offsets()
    isize = struct.unpack_from("<H", sb, o["s_isize"])[0]
    fsize = struct.unpack_from("<i", sb, o["s_fsize"])[0]
    tfree = struct.unpack_from("<i", sb, o["s_tfree"])[0]
    name = sb[o["s_fsmnt"]:o["s_fsmnt"] + 14].split(b"\0")[0]
    try:
        name = name.decode("ascii")
    except UnicodeDecodeError:
        name = repr(name)

    # THE TWO CHECKS THAT MAKE THIS TRUSTWORTHY.  A wrong offset yields a
    # plausible-looking integer, and a plausible-looking integer is exactly what
    # this project's worst measurement bugs have been made of.
    cap = nsect // (BSIZE // SECTOR)
    if not (0 < fsize <= cap):
        sys.exit("v10-free: s_fsize reads %d, which is not a size partition %s "
                 "can hold (max %d) -- the field offsets are wrong, so no "
                 "number from this superblock means anything"
                 % (fsize, part, cap))
    if not (0 <= tfree <= fsize):
        sys.exit("v10-free: s_tfree reads %d against s_fsize %d -- impossible, "
                 "so the offsets are wrong" % (tfree, fsize))
    if not all(32 <= b < 127 for b in sb[o["s_fsmnt"]:o["s_fsmnt"] + 1]):
        sys.exit("v10-free: s_fsmnt does not begin with a printable byte -- "
                 "the offsets are wrong")
    if o["_end"] != BSIZE:
        sys.exit("v10-free: struct filsys computes to %d bytes, not one %d-byte "
                 "block -- the offsets are wrong" % (o["_end"], BSIZE))

    # THE BITMAP IS THE TRUTH AND s_tfree IS A HINT, which is the whole reason
    # this is here.  alloc.c maintains s_tfree incrementally and, when an
    # allocation fails, simply assigns `fp->s_tfree = 0' under a commented-out
    # line reading "but it would be wrong FIX" -- Bell Labs' own note that the
    # counter is not trusted.  So a filesystem can report megabytes free in
    # s_tfree while bitfsalloc() finds no free bit and the kernel prints `file
    # system full'.  Counting the bits is the only honest answer.
    valid = sb[o["S_valid"]]
    flag = sb[o["S_flag"]]
    bits = 0
    if flag == 0:                       # B arm: the bitmap is here
        for i in range(961):
            w = struct.unpack_from("<I", sb, o["S_bfree"] + 4 * i)[0]
            bits += bin(w).count("1")
    else:
        bits = None                     # N arm: the bitmap is in its own blocks
    return tfree, fsize, isize, name, bits, valid, flag


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    image = args[0]
    part = args[1] if len(args) > 1 and not args[1].startswith("-") else "c"
    need = None
    if "--need" in args:
        need = int(args[args.index("--need") + 1])
    if not os.path.exists(image):
        sys.exit("v10-free: no %s" % image)

    tfree, fsize, isize, name, bits, valid, flag = free_blocks(image, part)
    mb = lambda n: n * BSIZE / 1048576.0
    print("%s partition %s" % (os.path.basename(image), part))
    print("  mounted as        %s" % name)
    print("  filesystem size   %6d blocks  %6.1f MB" % (fsize, mb(fsize)))
    print("  i-list            %6d blocks" % isize)
    print("  s_tfree (a HINT)  %6d blocks  %6.1f MB" % (tfree, mb(tfree)))
    print("  bitmap valid=%d flag=%d  (flag 1 = bitmap outside the superblock)"
          % (valid, flag))
    if bits is None:
        print("  free by bitmap    (N arm -- bitmap is in its own blocks)")
    else:
        print("  FREE BY BITMAP    %6d blocks  %6.1f MB   <- the truth"
              % (bits, mb(bits)))
        if bits != tfree:
            print("  s_tfree disagrees with the bitmap by %d blocks"
                  % (tfree - bits))
        tfree = bits
    if need is not None:
        print("  needed            %6d blocks  %6.1f MB" % (need, mb(need)))
        if tfree < need:
            print("  VERDICT: NOT ENOUGH ROOM.  A full V10 filesystem HANGS -- "
                  "alloc() sleeps rather than failing -- so this must be caught "
                  "here and not by the guest.")
            return 1
        print("  VERDICT: enough room")
    return 0


if __name__ == "__main__":
    sys.exit(main())
