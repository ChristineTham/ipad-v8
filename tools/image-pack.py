#!/usr/bin/env python3
"""Pack the built ipnx disk into git, and get it back out.

	tools/image-pack.py pack   [--image F] [--out F]
	tools/image-pack.py unpack [--in F] [--image F]
	tools/image-pack.py check  [--in F]

Defaults: work/myv8/rp07new  <->  image/ipnx-v8-rp07.img.xz

WHY AN IMAGE IS IN GIT AT ALL, given that CLAUDE.md says big binaries never
are.  The rule is right and this is its one exception, so it is worth being
precise about what makes it one.

A fresh Track S build needs a reference image to lift 1406 files off -- the
machine code Bell Labs shipped without source (v8/mk/gen/carry.txt).  Until
now that reference was the TUHS image, which is someone else's artefact,
not reproducible by us, and not in the repo.  Committing OUR image closes
that loop: the build's only external input becomes the tapes it was
imported from, and the tapes are already accounted for by v8/MANIFEST.

The exception is deliberately narrow: exactly one path, our own output,
and only because it is the input to the next build.  Everything else --
work/, rp06build, the .tap files -- stays out.

WHY xz AND NOT gzip.  Measured on the dense 40 MB of a V8 image: gzip -9
14.3%, bzip2 -9 11.5%, xz 8.8%.  On the whole 516 MB RP07 the difference
is larger still, because most of the volume is free blocks and xz's longer
window swallows runs of zeros almost entirely.  Python's lzma is the same
compressor and is in the standard library, so this needs no xz(1) on the
host -- macOS does not ship one.

ZERO THE FILE BEFORE THE BUILD THAT MAKES THE ARTEFACT.  mkfs writes a
fresh i-list and free list but does NOT clear the data blocks, so a second
stage 8 over the same file leaves the previous run's contents in what the
new filesystem calls free space.  It is invisible to the guest and it is
not invisible to the compressor.  `pack' reports the fraction of the image
that is nonzero for exactly this reason: if it is far above what df says
is used, the file was reused and should be recreated from /dev/zero.
"""

import argparse
import hashlib
import lzma
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMAGE = os.path.join(REPO, "work", "myv8", "rp07new")
PACKED = os.path.join(REPO, "image", "ipnx-v8-rp07.img.xz")
CHUNK = 8 << 20

# Preset 9 with a 64 MB dictionary. The image is 516 MB of which the
# interesting part is scattered across the first 60 MB and the /usr
# partition 40 MB in, so the window wants to be big enough to see both.
FILTERS = [{"id": lzma.FILTER_LZMA2, "preset": 9 | lzma.PRESET_EXTREME}]


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024 or u == "GB":
            return "%.1f %s" % (n, u)
        n /= 1024.0


def cmd_pack(args):
    src, dst = args.image, args.out
    if not os.path.exists(src):
        sys.exit("image-pack: no %s -- run stage 8 first" % src)
    total = os.path.getsize(src)
    h = hashlib.sha256()
    nonzero = 0
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    zeros = bytes(CHUNK)
    with open(src, "rb") as f, lzma.open(dst, "wb", format=lzma.FORMAT_XZ,
                                         filters=FILTERS) as z:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
            # Cheap and good enough: a whole chunk of zeros is free space,
            # anything else counts as used. Only used to warn about a
            # reused file, never to decide anything.
            if b != zeros[:len(b)]:
                nonzero += len(b)
            z.write(b)
    digest = h.hexdigest()
    open(dst + ".sha256", "w").write("%s  %s\n" % (digest, os.path.basename(src)))
    packed = os.path.getsize(dst)
    print("packed  %s" % os.path.relpath(src, REPO))
    print("    ->  %s" % os.path.relpath(dst, REPO))
    print("  raw       %s" % human(total))
    print("  packed    %s  (%.2f%% of raw)" % (human(packed), 100.0 * packed / total))
    print("  nonzero   %s  (%.1f%% of the volume)" % (human(nonzero),
                                                      100.0 * nonzero / total))
    print("  sha256    %s" % digest)
    if nonzero > total * 0.25:
        print("")
        print("  NOTE: a quarter of the volume is nonzero. A V8 image this")
        print("  full is unlikely; more probably stage 8 reused the file and")
        print("  the previous run's data is sitting in what is now free")
        print("  space. rm the image and let the driver recreate it zeroed.")
    return 0


def cmd_unpack(args):
    src, dst = args.inp, args.image
    if not os.path.exists(src):
        sys.exit("image-pack: no %s" % src)
    h = hashlib.sha256()
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with lzma.open(src, "rb") as z, open(dst, "wb") as f:
        while True:
            b = z.read(CHUNK)
            if not b:
                break
            h.update(b)
            f.write(b)
    got = h.hexdigest()
    want = expected(src)
    print("unpacked %s -> %s (%s)" % (os.path.relpath(src, REPO),
                                      os.path.relpath(dst, REPO),
                                      human(os.path.getsize(dst))))
    if want and got != want:
        print("  sha256 MISMATCH\n    want %s\n    got  %s" % (want, got))
        return 1
    print("  sha256 ok  %s" % got)
    return 0


def expected(packed):
    p = packed + ".sha256"
    return open(p).read().split()[0] if os.path.exists(p) else None


def cmd_check(args):
    src = args.inp
    if not os.path.exists(src):
        sys.exit("image-pack: no %s" % src)
    h = hashlib.sha256()
    n = 0
    with lzma.open(src, "rb") as z:
        while True:
            b = z.read(CHUNK)
            if not b:
                break
            h.update(b)
            n += len(b)
    got, want = h.hexdigest(), expected(src)
    print("%s: %s decompresses to %s" % (os.path.relpath(src, REPO),
                                         human(os.path.getsize(src)), human(n)))
    if want is None:
        print("  no .sha256 beside it -- cannot verify")
        return 1
    if got != want:
        print("  sha256 MISMATCH\n    want %s\n    got  %s" % (want, got))
        return 1
    print("  sha256 ok  %s" % got)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=("pack", "unpack", "check"))
    ap.add_argument("--image", default=IMAGE)
    ap.add_argument("--out", default=PACKED)
    ap.add_argument("--in", dest="inp", default=PACKED)
    args = ap.parse_args()
    return {"pack": cmd_pack, "unpack": cmd_unpack, "check": cmd_check}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
