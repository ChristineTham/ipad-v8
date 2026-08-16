#!/usr/bin/env python3
"""
The Tenth Edition /dev and /etc, generated.

    tools/v10-proto.py            # regenerate v10/mk/gen/{proto-dev,proto-etc}
    tools/v10-proto.py --check    # fail if either is stale

TWO REFERENCES, AND THEY AGREE.  The device majors come from V10's own
generated config, `lsys/astro/seki.c.c` -- the tables it links into the
kernel, so they cannot be wrong about the kernel.  The *shape* of the
directory comes from the V8 golden, read with `tools/v8fs.py`: 429 nodes, and
which of them a Research Unix actually wants.

Cross-checking one against the other is what makes this more than a guess,
and they line up better than expected:

	major   V10 cdevsw[]     present in V8's /dev
	  1     dz                 8 nodes
	  3     mm                 6
	 26     kmc                1
	 28     ra                24
	 31     kdi               95
	 40     fd               132
	 42     ip                 4
	 43     tcp               12
	 44     il                 2
	 50     udp               10

Same numbers, both editions.  V8 additionally has majors 18 and 22, which
V10's table leaves NULL -- those are V8's own devices and are deliberately
absent here.

WHY NOT JUST COPY V8's /dev.  Because two of its majors do not exist in V10,
its `hp' disks (block 0, char 4) are not V10's `ra', and a node naming a
driver the kernel does not have is a file that fails at open with a bare
ENXIO. The list is derived, not copied.

WHY THE COUNTS ARE SMALLER.  V8's 429 includes 95 kdi and 132 fd nodes,
which are per-channel and per-descriptor. This generates the ones a machine
needs to boot, log in, compile and talk IP; the rest can be made by
`/etc/mknod' on a running system, which is what it is for.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GEN = os.path.join(ROOT, "v10/mk/gen")

# name, type, major, minor, mode
#
# Majors are seki.c.c's:  cdevsw[]  cn 0, dz 1, ctu 2, mm 3, te16 5, sw 7,
#                                   kb 10, kmc 26, ra 28, kdi 31, fd 40,
#                                   ip 42, tcp 43, il 44, udp 50
#                         bdevsw[]  te16 1, sw 4, ra 7
DEV = []


def add(name, kind, major, minor, mode):
    DEV.append((name, kind, major, minor, mode))


# --- the console, which init opens before anything else --------------------
add("console", "c", 0, 0, "622")

# --- the DZ11 lines.  getty runs on these; /etc/ttys names them -----------
for n in range(8):
    add("tty%02d" % n, "c", 1, n, "622")

# --- memory.  V8 has six mm nodes; these are the three that get used -------
add("mem",  "c", 3, 0, "640")
add("kmem", "c", 3, 1, "640")
add("null", "c", 3, 2, "666")

# --- the file-descriptor device.  V8 puts stdin/stdout/stderr/tty on major
#     40 at minors 0..3, and V10's cdevsw has fd at 40 as well ------------
add("stdin",  "c", 40, 0, "666")
add("stdout", "c", 40, 1, "666")
add("stderr", "c", 40, 2, "666")
add("tty",    "c", 40, 3, "666")

# --- the root disk.  minor = BITFS | unit<<3 | partition, and bit 6 is set
#     on every one of these because they name bitmapped filesystems -- the
#     same bit seki's own `root regfs ra 0100' carries ---------------------
BITFS = 64
for unit in (0, 1):
    for i, part in enumerate("abcdefgh"):
        m = BITFS | (unit << 3) | i
        add("ra%d%s" % (unit, part),  "b", 7,  m, "640")
        add("rra%d%s" % (unit, part), "c", 28, m, "640")

# --- swap and tape ---------------------------------------------------------
add("swap", "b", 4, 1, "640")
add("drum", "c", 7, 0, "640")
add("mt0",  "b", 1, 0, "640")
add("rmt0", "c", 5, 0, "640")

# --- the network.  seki's kernel has ip, tcp, udp and the Interlan compiled
#     in, so the nodes exist even though nothing is attached yet.
#
#     TCP MINORS MUST BE ODD to be usable: tcp_device.c refuses an even one
#     whose socket is not already active, because even minors are the accept
#     side.  libin's tcp_sock() encodes this as `for(n = 01; n < 100; n += 2)'
#     and never says why.  V8's golden has both parities for the same reason.
add("il0", "c", 44, 0, "600")
for n in range(4):
    add("ip%d" % n, "c", 42, n, "600")
for n in range(12):
    add("tcp%02d" % n, "c", 43, n, "666" if n % 2 else "600")
for n in range(10):
    add("udp%02d" % n, "c", 50, n, "666")

# --- /etc, beyond the commands the build installs -------------------------
#
# V8's golden carries about 75 files here.  These are the ones a machine
# cannot come up without, plus the two tables that make it a machine rather
# than a kernel.
ETC = [
    ("passwd",  "644", "accounts"),
    ("group",   "644", "groups"),
    ("ttys",    "644", "which lines getty runs on, and at what speed"),
    ("rc",      "755", "run by init at multi-user"),
    ("motd",    "644", "printed by /etc/rc"),
    ("fstab",   "644", "what mount(8) reads with no arguments"),
    ("mtab",    "644", "what is mounted now; mount(8) appends"),
    ("utmp",    "644", "who is logged in; init truncates it at boot"),
    ("profile", "644", "read by every login shell"),
]


def build():
    out = ["# The Tenth Edition /dev, generated by tools/v10-proto.py.\n",
           "#\n",
           "# Majors are seki.c.c's own cdevsw[]/bdevsw[]; the shape of the\n",
           "# directory follows the V8 golden, read with tools/v8fs.py.\n",
           "#\n",
           "# fields: name<TAB>b|c<TAB>major<TAB>minor<TAB>mode\n#\n"]
    for name, kind, major, minor, mode in DEV:
        out.append("%s\t%s\t%d\t%d\t%s\n" % (name, kind, major, minor, mode))
    dev = "".join(out)

    out = ["# /etc's configuration files, generated by tools/v10-proto.py.\n",
           "# The commands in /etc are installed by the build; these are the\n",
           "# tables and the empty files a machine needs to come up.\n",
           "#\n# fields: name<TAB>mode<TAB>what it is\n#\n"]
    for name, mode, what in ETC:
        out.append("%s\t%s\t%s\n" % (name, mode, what))
    etc = "".join(out)
    return dev, etc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    dev, etc = build()
    os.makedirs(GEN, exist_ok=True)
    stale = []
    for fn, text in (("proto-dev", dev), ("proto-etc", etc)):
        p = os.path.join(GEN, fn)
        old = open(p).read() if os.path.exists(p) else None
        if args.check:
            if old != text:
                stale.append(fn)
        elif old != text:
            open(p, "w").write(text)

    if args.check:
        if stale:
            print("stale, re-run tools/v10-proto.py: " + " ".join(stale))
            return 1
        print("proto-dev and proto-etc are up to date")
        return 0

    kinds = {}
    for _, k, maj, _, _ in DEV:
        kinds[(k, maj)] = kinds.get((k, maj), 0) + 1
    print("v10/mk/gen/proto-dev: %d nodes" % len(DEV))
    for (k, maj), n in sorted(kinds.items(), key=lambda x: (-x[1], x[0])):
        print("    %2d  %s %d" % (n, k, maj))
    print("v10/mk/gen/proto-etc: %d files" % len(ETC))
    return 0


if __name__ == "__main__":
    sys.exit(main())
