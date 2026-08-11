#!/usr/bin/env python3
"""Read a V8 filesystem out of a SIMH RP06/RP07 image, from the host.

	tools/v8fs.py ls    IMAGE[:PART] [path]
	tools/v8fs.py cat   IMAGE[:PART] path
	tools/v8fs.py stat  IMAGE[:PART]
	tools/v8fs.py diff  IMAGE_A[:PART] IMAGE_B[:PART] [path]

PART defaults to `a' (root).  Use `:g' for /usr on an RP06 and `:f' on an
RP07; the type is inferred from the file size.

WHY THIS EXISTS.  Every question of the form "what is actually on that
disk?" was previously answered by booting a VAX, waiting five minutes and
reading `find' output off a serial line.  The filesystem is a 1985 V7
derivative with no compression, no journal and no surprises, so the host
can read it directly and answer in a second.  Which matters most for the
one question Track S has to answer repeatedly: does the disk we BUILT
contain everything the disk we were GIVEN contains?

THE FORMAT, all of it quoted from the tree rather than from memory:

  usr/include/sys/param.h	BSIZE(dev) 1024, INOPB(dev) 16, SUPERB 1,
				ROOTINO 2, DIRSIZ 14,
				itod(x) = (x + 2*INOPB - 1) / INOPB
				itoo(x) = (x + 2*INOPB - 1) % INOPB
  usr/include/sys/ino.h		64-byte dinode, di_addr is "39 used; 13
				addresses of 3 bytes each"
  usr/include/sys/dir.h		16-byte direct: ino_t + char[14]
  usr/sys/sys/subr.c bmap	"blocks 0..NADDR-4 are direct blocks",
				so 10 direct, then single/double/triple
  usr/src/libc/gen/l3tol.c	on vax a 3-byte address is little-endian
				with a zero high byte -- NOT the pdp11
				order in the same file, which is the trap
  usr/sys/dev/hp.c		the partition tables, in SECTORS, with a
				CYLINDER offset; sectors per cylinder is
				nsect*ntrak from the same file's hpst[]

Sizes in hp.c are sectors and a sector is 512, but a filesystem block is
1024 -- the same factor of two that made stage 8's mkfs walk off the end
of the partition.  Here it only affects the reported block counts.
"""

import hashlib
import os
import stat as statmod
import sys
import time

BSIZE = 1024			# BSIZE(dev), the non-BITFS case
INOPB = 16			# INOPB(dev) to match
SUPERB = 1
ROOTINO = 2
DIRSIZ = 14
NADDR = 13

# name -> (sectors_per_cylinder, {partition: (size_in_sectors, cyl_offset)})
GEOM = {
    "rp06": (22 * 19, {
        "a": (15884, 0), "b": (33440, 38), "c": (340670, 0), "g": (291280, 118),
    }),
    "rp07": (50 * 32, {
        "a": (15884, 0), "b": (64000, 10), "c": (1008000, 0),
        "d": (504000, 0), "e": (504000, 315), "f": (928000, 50),
    }),
}
# Whole-drive size in bytes -> type.  c is the whole volume in both tables.
BYTYPE = {340670 * 512: "rp06", 1008000 * 512: "rp07"}

IFMT, IFDIR, IFCHR, IFBLK, IFREG, IFLNK = 0o170000, 0o40000, 0o20000, 0o60000, 0o100000, 0o120000


def u16(b, o):
    return b[o] | b[o + 1] << 8


def i16(b, o):
    v = u16(b, o)
    return v - 0x10000 if v & 0x8000 else v


def u32(b, o):
    return b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24


def addr3(b, o):
    # l3tol.c, the vax arm: three bytes little-endian, high byte zero.
    return b[o] | b[o + 1] << 8 | b[o + 2] << 16


class Inode(object):
    __slots__ = ("num", "mode", "nlink", "uid", "gid", "size", "addr",
                 "atime", "mtime", "ctime")

    @property
    def kind(self):
        t = self.mode & IFMT
        return {IFDIR: "d", IFCHR: "c", IFBLK: "b", IFLNK: "l", IFREG: "-"}.get(t, "?")

    @property
    def isdir(self):
        return (self.mode & IFMT) == IFDIR

    @property
    def isreg(self):
        return (self.mode & IFMT) == IFREG

    @property
    def isdev(self):
        return (self.mode & IFMT) in (IFCHR, IFBLK)

    @property
    def rdev(self):
        # A device's "size" is meaningless; its address 0 holds the dev_t,
        # major in the high byte of the low 16 bits.
        d = self.addr[0] & 0xFFFF
        return (d >> 8, d & 0xFF)


class V8FS(object):
    def __init__(self, path, part="a", dtype=None):
        self.path = path
        self.f = open(path, "rb")
        size = os.fstat(self.f.fileno()).st_size
        if dtype is None:
            dtype = BYTYPE.get(size)
            if dtype is None:
                # Not an exact whole-drive image; guess by which is closer.
                dtype = "rp07" if size > 400 * 1024 * 1024 else "rp06"
        self.dtype = dtype
        spc, parts = GEOM[dtype]
        if part not in parts:
            raise SystemExit("v8fs: %s has no partition %s (have %s)"
                             % (dtype, part, " ".join(sorted(parts))))
        nsec, cyl = parts[part]
        self.part = part
        self.base = cyl * spc * 512
        self.nblocks = nsec // 2
        self._icache = {}

    def block(self, n):
        self.f.seek(self.base + n * BSIZE)
        b = self.f.read(BSIZE)
        return b if len(b) == BSIZE else b + b"\0" * (BSIZE - len(b))

    def super(self):
        """s_isize, s_fsize, s_tfree, s_tinode, s_fsmnt -- see filsys.h.

        VAX alignment puts the first long on 4, not 2, which is the only
        thing here that is not a straight transcription of the struct."""
        b = self.block(SUPERB)
        return {
            "isize": u16(b, 0),
            "fsize": u32(b, 4),
            "time": u32(b, 216),
            "tfree": u32(b, 220),
            "tinode": u16(b, 224),
            "fsmnt": b[230:244].split(b"\0")[0].decode("ascii", "replace"),
        }

    def inode(self, num):
        if num in self._icache:
            return self._icache[num]
        blk = (num + 2 * INOPB - 1) // INOPB
        off = ((num + 2 * INOPB - 1) % INOPB) * 64
        b = self.block(blk)[off:off + 64]
        ip = Inode()
        ip.num = num
        ip.mode = u16(b, 0)
        ip.nlink = i16(b, 2)
        ip.uid = i16(b, 4)
        ip.gid = i16(b, 6)
        ip.size = u32(b, 8)
        ip.addr = [addr3(b, 12 + 3 * i) for i in range(NADDR)]
        ip.atime = u32(b, 52)
        ip.mtime = u32(b, 56)
        ip.ctime = u32(b, 60)
        self._icache[num] = ip
        return ip

    def bmap(self, ip, bn):
        """Logical block bn of ip -> physical block, or 0 for a hole."""
        if bn < NADDR - 3:			# 0..9 direct
            return ip.addr[bn]
        bn -= NADDR - 3
        nindir = BSIZE // 4
        for level in range(3):		# single, double, triple
            span = nindir ** (level + 1)
            if bn < span:
                nb = ip.addr[NADDR - 3 + level]
                for sh in range(level, -1, -1):
                    if nb == 0:
                        return 0
                    b = self.block(nb)
                    idx = (bn // (nindir ** sh)) % nindir
                    nb = u32(b, idx * 4)
                return nb
            bn -= span
        return 0

    def read(self, ip):
        out = bytearray()
        n = (ip.size + BSIZE - 1) // BSIZE
        for i in range(n):
            pb = self.bmap(ip, i)
            out += self.block(pb) if pb else b"\0" * BSIZE
        return bytes(out[:ip.size])

    def readdir(self, ip):
        """(name, inum) pairs, skipping . and .. and cleared slots."""
        data = self.read(ip)
        for o in range(0, len(data) - 15, 16):
            inum = u16(data, o)
            if inum == 0:
                continue
            name = data[o + 2:o + 16].split(b"\0")[0].decode("ascii", "replace")
            if name in (".", ".."):
                continue
            yield name, inum

    def walk(self, start="/"):
        """(path, inode) for everything under start, depth first, sorted.

        Loop-safe by inode: V8 has no symlink loops on a mounted tree, but
        a corrupt directory can point at its own parent and this is the
        tool you would use to find that out."""
        ip = self.lookup(start)
        if ip is None:
            raise SystemExit("v8fs: no %s on %s:%s" % (start, self.path, self.part))
        seen = set()
        stack = [(start.rstrip("/") or "", ip)]
        while stack:
            path, dirip = stack.pop()
            if dirip.num in seen:
                continue
            seen.add(dirip.num)
            kids = sorted(self.readdir(dirip), key=lambda e: e[0])
            for name, inum in reversed(kids):
                child = self.inode(inum)
                cpath = path + "/" + name
                yield cpath, child
                if child.isdir:
                    stack.append((cpath, child))

    def lookup(self, path):
        ip = self.inode(ROOTINO)
        for part in path.strip("/").split("/"):
            if not part:
                continue
            if not ip.isdir:
                return None
            for name, inum in self.readdir(ip):
                if name == part:
                    ip = self.inode(inum)
                    break
            else:
                return None
        return ip


def usrpart(path):
    """Which partition holds /usr on this image: `g' on an RP06, `f' on an
    RP07.

    Both drives put root on `a', so only /usr needs asking, and the answer
    is a property of the DRIVE rather than of the filesystem -- hp6_sizes
    gives partition g from cylinder 118 and hp7_sizes gives f from cylinder
    50 (usr/sys/dev/hp.c).  Every tool that walks a whole system needs this,
    and hardcoding `g' is exactly what broke when the reference image became
    our own RP07."""
    return "f" if V8FS(path, "a").dtype == "rp07" else "g"


def wholesystem(path):
    """The (partition, prefix) pairs that make up one system's namespace."""
    return (("a", ""), (usrpart(path), "/usr"))


def openspec(spec, default="a"):
    """IMAGE or IMAGE:PART."""
    if ":" in spec:
        path, part = spec.rsplit(":", 1)
    else:
        path, part = spec, default
    return V8FS(path, part)


def describe(ip):
    if ip.isdev:
        maj, mnr = ip.rdev
        return "%s %4o %3d %3d %5s" % (ip.kind, ip.mode & 0o7777, ip.uid, ip.gid,
                                       "%d,%d" % (maj, mnr))
    return "%s %4o %3d %3d %5d" % (ip.kind, ip.mode & 0o7777, ip.uid, ip.gid, ip.size)


def cmd_ls(args):
    fs = openspec(args[0])
    root = args[1] if len(args) > 1 else "/"
    for path, ip in fs.walk(root):
        line = "%s %s" % (describe(ip), path)
        if (ip.mode & IFMT) == IFLNK:
            line += " -> " + fs.read(ip).decode("ascii", "replace")
        print(line)


def cmd_stat(args):
    fs = openspec(args[0])
    sb = fs.super()
    print("%s:%s  %s" % (fs.path, fs.part, fs.dtype))
    print("  partition %d blocks (%d sectors)" % (fs.nblocks, fs.nblocks * 2))
    print("  s_fsize   %d blocks" % sb["fsize"])
    print("  s_isize   %d blocks (%d inodes)" % (sb["isize"], (sb["isize"] - 2) * INOPB))
    print("  s_tfree   %d blocks free (%.1f%% used)"
          % (sb["tfree"], 100.0 * (sb["fsize"] - sb["tfree"]) / sb["fsize"]))
    print("  s_tinode  %d inodes free" % sb["tinode"])
    print("  s_time    %s" % time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(sb["time"])))
    print("  s_fsmnt   %s" % sb["fsmnt"])
    nd = nf = nl = 0
    total = 0
    for _, ip in fs.walk("/"):
        if ip.isdir:
            nd += 1
        elif ip.isreg:
            nf += 1
            total += ip.size
        elif (ip.mode & IFMT) == IFLNK:
            nl += 1
    print("  contents  %d dirs, %d files (%d bytes), %d symlinks" % (nd, nf, total, nl))


def cmd_cat(args):
    fs = openspec(args[0])
    ip = fs.lookup(args[1])
    if ip is None:
        raise SystemExit("v8fs: no such file %s" % args[1])
    sys.stdout.buffer.write(fs.read(ip))


def digest(fs, ip):
    if ip.isdev:
        return "dev:%d,%d" % ip.rdev
    if ip.isdir:
        return "dir"
    return hashlib.md5(fs.read(ip)).hexdigest()[:12]


def cmd_diff(args):
    a = openspec(args[0])
    b = openspec(args[1])
    root = args[2] if len(args) > 2 else "/"
    amap = {p: ip for p, ip in a.walk(root)}
    bmap = {p: ip for p, ip in b.walk(root)}
    only_a = sorted(set(amap) - set(bmap))
    only_b = sorted(set(bmap) - set(amap))
    for p in only_a:
        print("only in A  %s %s" % (describe(amap[p]), p))
    for p in only_b:
        print("only in B  %s %s" % (describe(bmap[p]), p))
    same = differ = 0
    for p in sorted(set(amap) & set(bmap)):
        ia, ib = amap[p], bmap[p]
        if (ia.mode & IFMT) != (ib.mode & IFMT):
            print("type       %s (A %s, B %s)" % (p, ia.kind, ib.kind))
            differ += 1
        elif digest(a, ia) != digest(b, ib):
            print("content    %s (A %d, B %d bytes)" % (p, ia.size, ib.size))
            differ += 1
        else:
            same += 1
    print("")
    print("A only %d, B only %d, differ %d, identical %d"
          % (len(only_a), len(only_b), differ, same))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip())
    cmd, args = sys.argv[1], sys.argv[2:]
    try:
        {"ls": cmd_ls, "cat": cmd_cat, "stat": cmd_stat, "diff": cmd_diff}[cmd](args)
    except KeyError:
        sys.exit("v8fs: unknown command %s" % cmd)
    except BrokenPipeError:
        os._exit(0)


if __name__ == "__main__":
    main()
