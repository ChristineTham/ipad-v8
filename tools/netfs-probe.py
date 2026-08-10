#!/usr/bin/env python3
"""
Exercise a netfs server the way the V8 kernel would, without booting a VAX.

    tools/netfs-probe.py [-p PORT] [PATH ...]

Phase N5's test instrument. A cold boot of V8 takes five minutes and answers
one question; this answers a dozen in under a second, and it answers them in
exactly the dialect `usr/sys/sys/neta.c` speaks -- same field offsets, same
framing, same order of operations. Anything this cannot do, the guest will not
be able to do either.

It is also the executable form of docs/netfs-protocol.md: if the document and
this script ever disagree, one of them is wrong and it is worth finding out
which.

Deliberately hand-rolled struct packing rather than `struct.pack`'s alignment
rules: the two holes at senda+14 and rcva+18 are compiler padding that pcc put
there in 1985, and expressing them as explicit pad bytes is the only honest way
to write them down.
"""

import argparse
import socket
import stat as statmod
import struct
import sys
import time

NETVERSION = 1

NSTAT, NWRT, NREAD, NFREE, NTRUNC, NUPDAT, NGET, NNAMI, NPUT = range(1, 10)
NROOT, NDEL, NLINK, NCREAT, NOMATCH, NSTART, NIOCTL = range(10, 17)

NAMES = {1: "NSTAT", 2: "NWRT", 3: "NREAD", 4: "NFREE", 5: "NTRUNC",
         6: "NUPDAT", 7: "NGET", 8: "NNAMI", 9: "NPUT", 10: "NROOT",
         11: "NDEL", 12: "NLINK", 13: "NCREAT", 14: "NOMATCH", 15: "NSTART"}

ROOTINO = 2
DIRSIZ = 14
SENDA = 52
RCVA = 48


def pack_senda(cmd=0, flags=0, trannum=0, uid=0, gid=0, dev=0, tag=0, mode=0,
               newuid=0, newgid=0, ino=0, count=0, offset=0, buf=0, ta=0, tm=0):
    """52 bytes, little-endian, offsets from docs/netfs-protocol.md."""
    b = bytearray(SENDA)
    b[0] = NETVERSION
    b[1] = cmd
    b[2] = flags
    # b[3] is `rsvd`, hand-written padding
    struct.pack_into("<i", b, 4, trannum)
    struct.pack_into("<HHH", b, 8, uid, gid, dev)
    # b[14:16] is a compiler hole, not a field
    struct.pack_into("<ii", b, 16, tag, mode)
    struct.pack_into("<HH", b, 24, newuid, newgid)
    struct.pack_into("<iiii", b, 28, ino, count, offset, buf)
    struct.pack_into("<ii", b, 44, ta, tm)
    return bytes(b)


class Rcva:
    def __init__(self, b):
        assert len(b) == RCVA, len(b)
        self.trannum, = struct.unpack_from("<i", b, 0)
        self.errno = b[4]
        self.flags = b[5]
        self.dev, = struct.unpack_from("<H", b, 6)
        self.size, = struct.unpack_from("<i", b, 8)
        self.mode, self.uid, self.gid = struct.unpack_from("<HHH", b, 12)
        # b[18:20] is a compiler hole
        self.tag, = struct.unpack_from("<i", b, 20)
        self.nlink, = struct.unpack_from("<H", b, 24)
        # b[26:28] is `rsvd`
        self.ino, self.count = struct.unpack_from("<ii", b, 28)
        self.tm = struct.unpack_from("<iii", b, 36)

    def __str__(self):
        f = {NROOT: " NROOT", NOMATCH: " NOMATCH"}.get(self.flags, "")
        return (f"errno={self.errno} ino={self.ino} tag={self.tag} "
                f"mode=0{self.mode:o} nlink={self.nlink} size={self.size} "
                f"count={self.count}{f}")


class Client:
    """The V8 kernel's half of the conversation."""

    def __init__(self, port, dev=64 * 256, debug=0):
        self.dev = dev
        self.trannum = 1000
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        # setup.c: one byte of version on its own, then a senda with NSTART
        # whose ta/uid/dev carry the clock, the debug level and the mount dev.
        self.s.sendall(bytes([NETVERSION]))
        self.s.sendall(pack_senda(cmd=NSTART, trannum=0, uid=debug,
                                  dev=dev, ta=int(time.time())))
        y = self.recv_rcva()
        if y.errno != 0 or y.trannum == -1:
            raise SystemExit(f"NSTART refused: {y}")

    def recvn(self, n):
        out = b""
        while len(out) < n:
            chunk = self.s.recv(n - len(out))
            if not chunk:
                raise SystemExit("server closed the connection")
            out += chunk
        return out

    def recv_rcva(self):
        return Rcva(self.recvn(RCVA))

    def send(self, payload=None, **kw):
        """send() from neta.c: header, optional request body, reply, optional
        reply body. The guard `x->cmd != NREAD` is why a read's count does not
        cause a request-side write."""
        self.trannum += 1
        kw.setdefault("trannum", self.trannum)
        kw.setdefault("dev", self.dev)
        self.s.sendall(pack_senda(**kw))
        if payload:
            self.s.sendall(payload)
        y = self.recv_rcva()
        body = b""
        if y.errno == 0 and kw.get("cmd") == NREAD and y.count > 0:
            body = self.recvn(y.count)
        return y, body

    # --- the operations the kernel actually emits -------------------------

    def get(self, ino):
        y, _ = self.send(cmd=NGET, ino=ino)
        return y

    def put(self, tag):
        y, _ = self.send(cmd=NPUT, tag=tag)
        return y

    def stat(self, tag):
        y, _ = self.send(cmd=NSTAT, tag=tag)
        return y

    def nami(self, tag, ino, name, flags=0, mode=0):
        """One component. The name is a payload, NUL-padded to DIRSIZ."""
        raw = name.encode()[:DIRSIZ]
        raw += b"\0" * (DIRSIZ - len(raw))
        y, _ = self.send(payload=raw, cmd=NNAMI, tag=tag, ino=ino,
                         count=DIRSIZ, flags=flags, mode=mode, buf=1)
        return y

    def read(self, tag, offset, count):
        y, body = self.send(cmd=NREAD, tag=tag, offset=offset, count=count, buf=1)
        return y, body

    def write(self, tag, offset, data):
        y, _ = self.send(payload=data, cmd=NWRT, tag=tag, offset=offset,
                         count=len(data), buf=1)
        return y

    def trunc(self, tag):
        y, _ = self.send(cmd=NTRUNC, tag=tag)
        return y

    # --- things the kernel builds out of them -----------------------------

    def walk(self, path):
        """namei: resolve a path one component at a time from the root."""
        y = self.get(ROOTINO)
        if y.errno:
            raise SystemExit(f"NGET(root) failed: {y}")
        for part in [p for p in path.split("/") if p]:
            y2 = self.nami(y.tag, y.ino, part)
            if y2.errno or y2.flags == NOMATCH:
                return None, part
            y = y2
        return y, None

    def readall(self, tag, size):
        """The kernel's read loop: one request per BUFSIZE until short."""
        out = b""
        while len(out) < size:
            y, body = self.read(tag, len(out), min(4096, size - len(out)))
            if y.errno:
                raise SystemExit(f"NREAD failed: {y}")
            if not body:
                break
            out += body
        return out

    def listdir(self, y):
        """A directory read is an ordinary NREAD of 16-byte struct directs."""
        raw = self.readall(y.tag, y.size)
        out = []
        for i in range(0, len(raw) - 15, 16):
            ino, = struct.unpack_from("<H", raw, i)
            name = raw[i + 2:i + 16].split(b"\0")[0].decode("utf-8", "replace")
            out.append((ino, name))
        return out


def typechar(mode):
    t = mode & 0o170000
    return {0o040000: "d", 0o100000: "-", 0o120000: "l",
            0o020000: "c", 0o060000: "b"}.get(t, "?")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-p", "--port", type=int, default=9200)
    ap.add_argument("-w", "--write", metavar="PATH",
                    help="prove the write side: create, write, read back, unlink")
    ap.add_argument("paths", nargs="*", default=["/"],
                    help="paths to resolve and show (default /)")
    args = ap.parse_args()

    c = Client(args.port)
    print(f"connected, mount dev {c.dev} (major {c.dev >> 8})")

    fail = 0
    for path in args.paths:
        y, missing = c.walk(path)
        if y is None:
            print(f"{path}: no such component {missing!r}")
            fail += 1
            continue
        kind = typechar(y.mode)
        print(f"\n{path}: {kind} ino={y.ino} mode=0{y.mode & 0o7777:o} "
              f"nlink={y.nlink} size={y.size} uid={y.uid} gid={y.gid}")

        st = c.stat(y.tag)
        if st.errno:
            print(f"  NSTAT failed: {st}")
            fail += 1
        else:
            print("  NSTAT times: " + " ".join(
                time.strftime("%Y-%m-%d %H:%M", time.localtime(t)) for t in st.tm))

        if kind == "d":
            entries = c.listdir(y)
            print(f"  {len(entries)} entries, {y.size} bytes of struct direct")
            for ino, name in entries[:20]:
                print(f"    {ino:5d}  {name}")
            if len(entries) > 20:
                print(f"    ... and {len(entries) - 20} more")
            if not entries or entries[0][1] != "." or entries[1][1] != "..":
                print("  !! a V8 directory must begin with . and ..")
                fail += 1
        elif kind == "l":
            _, body = c.read(y.tag, 0, 1024)
            print(f"  symlink -> {body.decode('utf-8', 'replace')}")
        else:
            data = c.readall(y.tag, y.size)
            print(f"  read {len(data)} of {y.size} bytes")
            if len(data) != y.size:
                print("  !! short read: size and content disagree")
                fail += 1
            head = data[:60].decode("utf-8", "replace").replace("\n", "\\n")
            print(f"  head: {head}")
        c.put(y.tag)

    if args.write:
        fail += prove_write(c, args.write)

    print("\nPROBE OK" if fail == 0 else f"\nPROBE FAILED ({fail} problems)")
    return 1 if fail else 0


def prove_write(c, path):
    """Create a file, write to it, read it back, then remove it."""
    print(f"\n=== write test in {path} ===")
    parent, _ = c.walk(path)
    if parent is None or typechar(parent.mode) != "d":
        print(f"  {path} is not a directory")
        return 1
    name = "n5probe"
    payload = b"Research Unix netfs, phase N7.\n" * 4

    y = c.nami(parent.tag, parent.ino, name, flags=NCREAT, mode=0o100644)
    if y.errno:
        print(f"  NCREAT failed: {y}")
        return 1
    print(f"  created {name} ino={y.ino} tag={y.tag}")

    w = c.write(y.tag, 0, payload)
    if w.errno:
        print(f"  NWRT failed: {w}")
        return 1
    print(f"  wrote {len(payload)} bytes")

    # Re-resolve the way the guest would, rather than trusting the handle.
    y2 = c.nami(parent.tag, parent.ino, name)
    if y2.errno or y2.flags == NOMATCH:
        print(f"  lookup after create failed: {y2}")
        return 1
    back = c.readall(y2.tag, y2.size)
    if back != payload:
        print(f"  !! read back {len(back)} bytes, expected {len(payload)}")
        return 1
    print(f"  read back {len(back)} bytes, identical")

    d = c.nami(parent.tag, parent.ino, name, flags=NDEL)
    if d.errno:
        print(f"  NDEL failed: {d}")
        return 1
    gone = c.nami(parent.tag, parent.ino, name)
    if gone.flags != NOMATCH:
        print(f"  !! still there after NDEL: {gone}")
        return 1
    print("  unlinked, and NNAMI now says NOMATCH")
    return 0


if __name__ == "__main__":
    sys.exit(main())
