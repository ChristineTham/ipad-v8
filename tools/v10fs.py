#!/usr/bin/env python3
"""Read a V10 bitmapped filesystem out of a SIMH RA81 image, from the host.

	tools/v10fs.py ls    <image>[:part] [path]
	tools/v10fs.py find  <image>[:part] [path]
	tools/v10fs.py stat  <image>[:part] <path>
	tools/v10fs.py cat   <image>[:part] <path>
	tools/v10fs.py sum   <image>[:part] [path]
	tools/v10fs.py prov  <image>[:part] [path]

This is `tools/v8fs.py' for the Tenth Edition, and it exists for the reason
CLAUDE.md gives for that one: it turns "what is actually on that disk?" from a
five-minute boot into a one-second question.  Rung 10 has to decide what a
shippable v10.disk carries and then prove the disk carries it, and neither
question should cost a simulator run -- especially since a V10 guest cannot be
trusted to answer it (`ls' exits 0 for a file that does not exist, and a full
filesystem SLEEPS rather than failing).

EVERY CONSTANT IS QUOTED FROM THE TAPE, because a struct offset computed from a
header is a guess until something confirms it -- v10-free.py's own rule:

  struct dinode       lsys/sys/ino.h      64 bytes, 13 packed 3-byte addresses
  struct direct       lsys/sys/dir.h      DIRSIZ 14, so 16 bytes
  NADDR 13            lsys/sys/inode.h:12
  10 direct + 3       lsys/os/subr.c      bmap(): `bn < NADDR-3' direct, then
                                          single, double, triple indirect
  BSIZE  4096         lsys/sys/param.h:77 BITFS(dev)? 4096: 1024
  INOPB  64           lsys/sys/param.h:78
  NINDIR 1024         lsys/sys/param.h:81 BSIZE/sizeof(daddr_t)
  NMASK  1023         lsys/sys/param.h:82 01777
  NSHIFT 10           lsys/sys/param.h:83
  itod/itoo           lsys/sys/param.h:86 (x + 2*INOPB - 1) / INOPB
  fsbtodb  b*8        lsys/sys/param.h:88 a 4K block is eight 512-byte sectors
  IFMT et al          lsys/sys/inode.h:93

TWO ENCODINGS OF THE SAME ADDRESS, WHICH IS THE TRAP THIS FILE EXISTS TO GET
RIGHT.  The INODE packs 13 addresses at 3 bytes each and `l3tol' unpacks them --
and its **vax** arm is three bytes little-endian with a zero high byte, where the
pdp11 arm of the very same file packs the identical bytes in a different order
(CLAUDE.md: "pick wrong and the inode addresses look almost plausible").  The
INDIRECT BLOCKS hold full 4-byte daddr_t, because bmap() reads them as
`bp->b_un.b_daddr' and sizes them `BSIZE/sizeof(daddr_t)'.  So the same logical
block number is encoded one way in an inode and another way one level down.

AND IT REFUSES TO ANSWER WHEN THE BYTES DISAGREE WITH THEMSELVES, on
v10-free.py's argument: a reader whose constants are subtly wrong produces
almost-plausible output, which is worse than no output.  check() below asserts
the root inode is a directory whose first two entries are `.' and `..' both
naming ROOTINO, and every walk rejects an inode number outside the i-list.
"""

import os
import struct
import sys
import time

# ra_sizes[] from lsys/io/ra.c, in 512-byte SECTORS -- the same table
# tools/v10-free.py carries, and for the same reason: `h' is the whole drive and
# overlaps `b', so a filesystem there swaps over its own data blocks (K14).
RA_SIZES = {
    "a": (10240, 0),
    "b": (20480, 10240),
    "c": (249848, 30720),
    "d": (249848, 280568),
    "e": (249848, 530416),
    "g": (749544, 30720),
    "h": (891072, 0),
}

BSIZE = 4096
SECTOR = 512
SUPERB = 1
INOPB = 64
NADDR = 13
NINDIR = 1024
NMASK = 1023
NSHIFT = 10
ROOTINO = 2
DIRSIZ = 14
DIRSZ = 16                  # sizeof(struct direct): ino_t + char[14]
DINODE = 64                 # sizeof(struct dinode)

IFMT = 0o170000
IFDIR = 0o040000
IFCHR = 0o020000
IFBLK = 0o060000
IFREG = 0o100000
IFLNK = 0o120000
ISUID = 0o4000
ISGID = 0o2000


def itod(x):
    """lsys/sys/param.h:86 -- which filesystem block holds inode x."""
    return (x + 2 * INOPB - 1) // INOPB


def itoo(x):
    """lsys/sys/param.h:87 -- which slot within that block."""
    return (x + 2 * INOPB - 1) % INOPB


class Fs(object):
    def __init__(self, path, part="a"):
        if part not in RA_SIZES:
            sys.exit("v10fs: no partition %r in ra_sizes[] (have %s)"
                     % (part, " ".join(sorted(RA_SIZES))))
        if not os.path.exists(path):
            sys.exit("v10fs: no such image: %s" % path)
        self.path = path
        self.part = part
        nsect, off = RA_SIZES[part]
        self.base = off * SECTOR
        self.nblocks = nsect // 8
        self.fh = open(path, "rb")
        size = os.path.getsize(path)
        if self.base + BSIZE * 2 > size:
            sys.exit("v10fs: %s is too small for partition %s" % (path, part))
        self._super()
        self.check()

    # ---- raw access -------------------------------------------------------

    def block(self, bno):
        """One 4096-byte filesystem block, by filesystem block number."""
        if bno <= 0 or bno >= self.nblocks:
            return b"\0" * BSIZE
        self.fh.seek(self.base + bno * BSIZE)
        b = self.fh.read(BSIZE)
        return b + b"\0" * (BSIZE - len(b))

    def _super(self):
        """s_isize and s_fsize, which is all the walk needs from the superblock.

        The full struct filsys is v10-free.py's business; here we want only the
        i-list bound (so a bad inode number can be rejected) and the volume
        size.  Offsets: s_isize at 0 as an unsigned short, then two bytes of pad
        because daddr_t wants a 4-byte boundary, then s_fsize.
        """
        sb = self.block(SUPERB)
        self.isize = struct.unpack_from("<H", sb, 0)[0]
        self.fsize = struct.unpack_from("<i", sb, 4)[0]
        self.fsmnt = sb[230:244].split(b"\0")[0].decode("ascii", "replace")
        # The i-list runs from block 2 to s_isize, so this is the highest inode
        # number the filesystem can possibly hold.
        self.maxino = max(0, (self.isize - 2)) * INOPB + 1

    # ---- inodes -----------------------------------------------------------

    def inode(self, ino):
        """(mode, nlink, uid, gid, size, [13 block numbers], atime, mtime, ctime)."""
        if ino < 1 or (self.maxino and ino > self.maxino):
            raise ValueError("inode %d is outside the i-list (max %d)"
                             % (ino, self.maxino))
        blk = self.block(itod(ino))
        off = itoo(ino) * DINODE
        raw = blk[off:off + DINODE]
        if len(raw) < DINODE:
            raise ValueError("short read for inode %d" % ino)
        mode, nlink, uid, gid, size = struct.unpack_from("<HhhhI", raw, 0)
        addr = self.l3tol(raw[12:52], NADDR)
        atime, mtime, ctime = struct.unpack_from("<III", raw, 52)
        return dict(ino=ino, mode=mode, nlink=nlink, uid=uid, gid=gid,
                    size=size, addr=addr, atime=atime, mtime=mtime, ctime=ctime)

    @staticmethod
    def l3tol(buf, n):
        """libc/gen/l3tol.c, the **vax** arm: 3 bytes little-endian, high byte 0.

        The pdp11 arm of the same file packs the identical bytes in a different
        order; picking wrong gives addresses that look almost plausible, which
        is exactly how this goes wrong silently.
        """
        out = []
        for i in range(n):
            b = buf[i * 3:i * 3 + 3]
            out.append(b[0] | (b[1] << 8) | (b[2] << 16))
        return out

    def bmap(self, ino, bn):
        """lsys/os/subr.c bmap(), read side only: logical block -> physical."""
        if bn < 0:
            return 0
        addr = ino["addr"]
        if bn < NADDR - 3:                      # 0..9 direct
            return addr[bn]
        # addresses 10, 11, 12 are single, double and triple indirect.  This is
        # bmap()'s own loop: peel one NSHIFT per level until bn fits.
        sh = 0
        nb = 1
        bn -= NADDR - 3
        for j in (3, 2, 1):
            sh += NSHIFT
            nb <<= NSHIFT
            if bn < nb:
                break
            bn -= nb
        else:
            return 0                            # past the triple indirect
        blk = addr[NADDR - j]
        while j <= 3:
            if blk == 0:
                return 0
            data = self.block(blk)
            sh -= NSHIFT
            i = (bn >> sh) & NMASK
            # Indirect blocks hold 4-byte daddr_t, NOT packed 3-byte addresses.
            blk = struct.unpack_from("<i", data, i * 4)[0]
            j += 1
        return blk

    def read(self, ino):
        """A file's bytes, truncated to di_size as the kernel would."""
        out = bytearray()
        want = ino["size"]
        bn = 0
        while len(out) < want:
            phys = self.bmap(ino, bn)
            chunk = self.block(phys) if phys else b"\0" * BSIZE
            out += chunk
            bn += 1
            if bn > 1 + (want // BSIZE) + NINDIR:   # runaway guard
                break
        return bytes(out[:want])

    # ---- directories ------------------------------------------------------

    def readdir(self, ino):
        """[(name, ino)] for a directory, skipping free (ino 0) slots."""
        if (ino["mode"] & IFMT) != IFDIR:
            raise ValueError("inode %d is not a directory" % ino["ino"])
        data = self.read(ino)
        ents = []
        for off in range(0, len(data) - DIRSZ + 1, DIRSZ):
            num = struct.unpack_from("<H", data, off)[0]
            if num == 0:
                continue
            name = data[off + 2:off + 2 + DIRSIZ].split(b"\0")[0]
            ents.append((name.decode("ascii", "replace"), num))
        return ents

    def lookup(self, path):
        """Resolve an absolute path to an inode dict."""
        cur = self.inode(ROOTINO)
        if path in ("", "/", "."):
            return cur
        for part in [p for p in path.split("/") if p and p != "."]:
            if (cur["mode"] & IFMT) != IFDIR:
                sys.exit("v10fs: not a directory on the way to %s" % path)
            hit = dict(self.readdir(cur)).get(part)
            if hit is None:
                sys.exit("v10fs: no such file or directory: %s" % path)
            cur = self.inode(hit)
        return cur

    # ---- the self-check ---------------------------------------------------

    def check(self):
        """Refuse to answer if the bytes disagree with themselves.

        v10-free.py's discipline: a reader with subtly wrong constants produces
        almost-plausible output.  Four cheap assertions catch every constant
        this file depends on -- a wrong itod/itoo, a wrong l3tol arm or a wrong
        DIRSZ all fail at least one of them.
        """
        why = []
        if self.isize < 2 or self.isize >= self.fsize:
            why.append("s_isize %d is not inside s_fsize %d"
                       % (self.isize, self.fsize))
        if self.fsize <= 0 or self.fsize > self.nblocks:
            why.append("s_fsize %d does not fit partition %s (%d blocks)"
                       % (self.fsize, self.part, self.nblocks))
        if not why:
            try:
                root = self.inode(ROOTINO)
            except ValueError as e:
                why.append(str(e))
            else:
                if (root["mode"] & IFMT) != IFDIR:
                    why.append("inode 2 has mode %07o, which is not a directory"
                               % root["mode"])
                elif root["size"] % DIRSZ:
                    why.append("root's size %d is not a multiple of %d"
                               % (root["size"], DIRSZ))
                else:
                    ents = self.readdir(root)[:2]
                    got = [(n, i) for n, i in ents]
                    if got != [(".", ROOTINO), ("..", ROOTINO)]:
                        why.append("root's first two entries are %r, not "
                                   "'.' and '..' both naming inode 2" % (got,))
        if why:
            sys.exit("v10fs: refusing to read %s:%s --\n   %s\n"
                     "   Either this is not a V10 bitmapped filesystem or a\n"
                     "   constant above is wrong.  An almost-plausible answer\n"
                     "   is worse than none." % (self.path, self.part,
                                                 "\n   ".join(why)))

    # ---- walking ----------------------------------------------------------

    def walk(self, path="/"):
        """Yield (path, inode) for everything under path, depth first.

        Cycles are impossible in a consistent tree but a damaged one can carry
        them, so visited inodes are remembered -- otherwise this is the harness
        that hangs instead of the filesystem.
        """
        start = self.lookup(path)
        seen = set()
        stack = [(path.rstrip("/") or "", start)]
        while stack:
            here, ino = stack.pop()
            yield (here or "/", ino)
            if (ino["mode"] & IFMT) != IFDIR:
                continue
            if ino["ino"] in seen:
                continue
            seen.add(ino["ino"])
            kids = []
            for name, num in self.readdir(ino):
                if name in (".", ".."):
                    continue
                try:
                    kids.append(("%s/%s" % (here, name), self.inode(num)))
                except ValueError as e:
                    sys.stderr.write("v10fs: %s/%s: %s\n" % (here, name, e))
            stack.extend(reversed(kids))


def modestr(m):
    kind = {IFDIR: "d", IFCHR: "c", IFBLK: "b", IFREG: "-", IFLNK: "l"}.get(
        m & IFMT, "?")
    bits = ""
    for shift in (6, 3, 0):
        p = (m >> shift) & 7
        bits += "r" if p & 4 else "-"
        bits += "w" if p & 2 else "-"
        bits += "x" if p & 1 else "-"
    if m & ISUID:
        bits = bits[:2] + "s" + bits[3:]
    if m & ISGID:
        bits = bits[:5] + "s" + bits[6:]
    return kind + bits


def stamp(t):
    """V10 disks routinely carry 1976 and 1995 dates; UTC keeps it honest."""
    try:
        return time.strftime("%Y-%m-%d %H:%M", time.gmtime(t))
    except (ValueError, OSError):
        return "????-??-?? ??:??"


def split(arg):
    """`image:part', defaulting to partition a (root) -- K14's own layout."""
    if ":" in arg:
        img, part = arg.rsplit(":", 1)
        return img, part
    return arg, "a"


AR_MAGIC = b"!<arch>\n"


def ar_fingerprint(body):
    """A hash of an archive's MEMBERS, blind to `__.SYMDEF' and to mtimes.

    AN ARCHIVE THAT IS THE TAPE'S IN EVERY MEMBER READS AS "NOT THE TAPE'S" IF
    YOU HASH THE FILE.  The golden's /lib/libc.a differs from the tape's in
    exactly TEN BYTES, all of them the `__.SYMDEF' member's ar-header timestamp
    -- 743340498 (mid-1993) against 1786908310 (2026) -- because CLAUDE.md
    requires re-`ranlib'ing an archive at its destination: `cp' bumps the mtime,
    and that alone demotes a good archive to V10 ld's single-pass case 3.  So the
    re-ranlib is CORRECT, and a whole-file hash calls the correct thing foreign.

    Hashing (member name, member bytes) with __.SYMDEF dropped answers the
    question actually being asked -- is this Bell Labs' code? -- and is the same
    per-member-witness discipline tools/v10-stage2.sh uses on libc.
    """
    import hashlib
    h = hashlib.sha256()
    p = len(AR_MAGIC)
    n = 0
    while p + 60 <= len(body):
        name = body[p:p + 16].rstrip(b" ")
        try:
            size = int(body[p + 48:p + 58].strip() or b"0")
        except ValueError:
            return None                       # not an archive we understand
        p += 60
        data = body[p:p + size]
        if len(data) < size:
            return None                       # truncated
        if name not in (b"__.SYMDEF", b"__.SYMDEF SORTED"):
            h.update(name + b"\0")
            h.update(data)
            n += 1
        p += size + (size & 1)                # members are padded to even
    return ("ar%d:" % n) + h.hexdigest() if n else None


def fingerprints(body):
    """Every identity a file answers to: its bytes, and if an archive, its members."""
    import hashlib
    out = [hashlib.sha256(body).hexdigest()]
    if body.startswith(AR_MAGIC):
        f = ar_fingerprint(body)
        if f:
            out.append(f)
    return out


def tape_index(root="work/v10"):
    """sha256 -> [paths] for every file in the imported tape.

    PROVENANCE COMES FROM WHERE A THING WAS BUILT, NEVER FROM GREPPING IT
    (CLAUDE.md: `vaxpcc2' in a binary does NOT mean it came from V10 -- V8's own
    /bin/echo carries the same .stabs string).  A HASH is the exception: a file
    on the disk whose bytes appear in the tape IS the tape's, because nothing we
    compile reproduces Bell Labs' 1989-95 objects -- stage 2 measured that at 143
    of 261 libc members and K15 at 0 of 7 mux objects.
    """
    import hashlib
    idx = {}
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            p = os.path.join(dirpath, name)
            try:
                with open(p, "rb") as fh:
                    body = fh.read()
            except (OSError, IOError):
                continue
            # AN EMPTY FILE IS NOT EVIDENCE OF ANYTHING, and it read as evidence
            # of the strongest possible kind: /etc/mtab and /etc/utmp are both
            # zero bytes on the golden, every empty file has the same sha256, and
            # the tape happens to carry one (blit/demo/mpx/.jciferr) -- so the
            # oracle credited Bell Labs with two files this project truncated.
            # An error in the flattering direction, which is the sort that
            # survives review.
            if not body:
                continue
            for f in fingerprints(body):
                idx.setdefault(f, []).append(p)
    return idx


def provenance(fs, path, root="work/v10"):
    """Split the disk's regular files into the tape's and ours."""
    import hashlib
    idx = tape_index(root)
    tape, ours = [], []
    for p, ino in fs.walk(path):
        if (ino["mode"] & IFMT) != IFREG:
            continue
        body = fs.read(ino)
        hit = None
        for f in fingerprints(body):
            hit = idx.get(f)
            if hit:
                break
        (tape if hit else ours).append((p, ino["size"], hit[0] if hit else None))
    return tape, ours


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip().split("\n\n")[1].strip())
    verb = sys.argv[1]
    img, part = split(sys.argv[2])
    path = sys.argv[3] if len(sys.argv) > 3 else "/"
    fs = Fs(img, part)
    # SAY WHICH FILESYSTEM WAS READ, ON STDERR, EVERY TIME.  An RA81 image holds
    # two filesystems and answering about the wrong one is indistinguishable from
    # a correct answer about a missing file -- K11's "a guest can report success
    # about the wrong disk", host-side.  It is not hypothetical: in zsh
    #
    #	K=work/v10gold/ipnx-v10-ra81.img.stage1.k102.k7.k13
    #	python3 tools/v10fs.py stat "$K:c" /bin/lex
    #
    # SILENTLY DROPS THE `:c' -- `$K:c' is a history modifier, so the argument
    # arrives with no partition, defaults to root, and the tool truthfully
    # reports that /bin/lex is not there.  Nine files read as MISSING when all
    # nine existed.  `${K}:c' is the fix in the shell; this line is the fix here,
    # because the next person will make the same mistake and a banner is the only
    # thing that shows it.  stderr, so a pipeline parsing `find' is unaffected.
    sys.stderr.write("v10fs: %s partition %s (%s), %d blocks of %d\n"
                     % (os.path.basename(img), part, fs.fsmnt or "unnamed",
                        fs.fsize, BSIZE))

    if verb == "ls":
        ino = fs.lookup(path)
        if (ino["mode"] & IFMT) != IFDIR:
            print("%s %2d %4d %4d %9d %s %s" % (
                modestr(ino["mode"]), ino["nlink"], ino["uid"], ino["gid"],
                ino["size"], stamp(ino["mtime"]), path))
            return
        for name, num in sorted(fs.readdir(ino)):
            k = fs.inode(num)
            print("%s %2d %4d %4d %9d %s %s" % (
                modestr(k["mode"]), k["nlink"], k["uid"], k["gid"],
                k["size"], stamp(k["mtime"]), name))
    elif verb == "find":
        for p, ino in fs.walk(path):
            print("%s %9d %s" % (modestr(ino["mode"]), ino["size"], p))
    elif verb == "stat":
        ino = fs.lookup(path)
        print("path    %s" % path)
        print("inode   %d" % ino["ino"])
        print("mode    %07o  %s" % (ino["mode"], modestr(ino["mode"])))
        print("nlink   %d" % ino["nlink"])
        print("uid/gid %d/%d" % (ino["uid"], ino["gid"]))
        print("size    %d" % ino["size"])
        print("atime   %s" % stamp(ino["atime"]))
        print("mtime   %s" % stamp(ino["mtime"]))
        print("ctime   %s" % stamp(ino["ctime"]))
        used = [a for a in ino["addr"] if a]
        print("addr    %s" % (" ".join(str(a) for a in used) or "(none)"))
    elif verb == "cat":
        ino = fs.lookup(path)
        sys.stdout.buffer.write(fs.read(ino))
    elif verb == "prov":
        tape, ours = provenance(fs, path)
        print("%s:%s -- %d files are the tape's byte for byte, %d are not"
              % (img, part, len(tape), len(ours)))
        print("\n  BELL LABS' OWN BYTES (the oracle):")
        for p, n, where in sorted(tape):
            print("    %-28s %8d  %s" % (p, n, where.replace("work/v10/", "")))
        print("\n  NOT ON THE TAPE (ours, or rebuilt, or data):")
        for p, n, _ in sorted(ours):
            print("    %-28s %8d" % (p, n))
    elif verb == "sum":
        n = {"d": 0, "-": 0, "c": 0, "b": 0, "l": 0, "?": 0}
        total = 0
        for _p, ino in fs.walk(path):
            n[modestr(ino["mode"])[0]] += 1
            if (ino["mode"] & IFMT) == IFREG:
                total += ino["size"]
        print("%s:%s  (%s)" % (img, part, fs.fsmnt or "unnamed"))
        print("  s_isize %d blocks, s_fsize %d blocks of %d" %
              (fs.isize, fs.fsize, BSIZE))
        print("  %d directories, %d regular files, %d char, %d block, %d link"
              % (n["d"], n["-"], n["c"], n["b"], n["l"]))
        print("  %d bytes of regular-file content (%.1f MB)"
              % (total, total / 1048576.0))
    else:
        sys.exit("v10fs: unknown verb %r -- ls, find, stat, cat, sum, prov" % verb)


if __name__ == "__main__":
    main()
