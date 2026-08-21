#!/usr/bin/env python3
"""
Every prebuilt Tenth Edition command, and where to put it.

    tools/v10-prebuilt.py             # regenerate v10/mk/gen/prebuilt.txt
    tools/v10-prebuilt.py --check     # fail if it is stale

WHY A QUICK-AND-DIRTY IMAGE IS WORTH HAVING FIRST.  The tape carries 483
linked binaries.  Installing the ones that are recognisably commands gives a
usable Tenth Edition now, months before a from-source userland -- and, more
importantly, gives the from-source userland something to be CHECKED AGAINST.
That is the same argument that keeps the 46 prebuilt command units as an
oracle rather than a shortcut, applied to the whole disk.

WHAT COUNTS AS A COMMAND.  A 0413 executable under `src/cmd/` whose basename
matches a source unit -- either a loose `cmd/<name>.c` or a `cmd/<name>/`
directory.  That rule finds 59, and three of them are impostors:

    src/cmd/lcc/ph/cpp        lcc's preprocessor, not the system's
    src/cmd/cyntax/cyn/ccom   cyntax's compiler
    blit/lib/ccom             the Blit's WE32100 cross-compiler

A basename match is a hypothesis, not a fact.  The system `cpp` and `ccom`
live at `cmd/cpp/` and `cmd/ccom/vax/comp`, and only the second of those is
prebuilt -- which is why B1 built `cpp` from source and was right to.

INSTALL PATHS, AND WHICH ARE GUESSES.  `tools/v10-where.py` resolves a path
from V10's own manual where the manual states one, and from V8's measured
disk where it does not.  Everything it leaves unresolved goes to
`/usr/bin` here, and the third column says `default` so nobody later mistakes
a guess for a citation.  Track S has the scar: `yacc` and `strip` installed
to the wrong directory reached the toolchain and never the system, and no
boot test could see it.
"""
import argparse
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "work/v10/src")
OUT = os.path.join(ROOT, "v10/mk/gen/prebuilt.txt")

# Basename matches a command, but the binary is something else's.
IMPOSTORS = {
    "src/cmd/lcc/ph/cpp":      "lcc's preprocessor, not the system cpp",
    "src/cmd/cyntax/cyn/ccom": "cyntax's compiler, not the system ccom",
}

# Where the toolchain goes, which the manual does not describe as commands.
# `sed' WAS HERE AND SAID /bin, AND IT WAS WRONG.  Removed 2026-08-21 on two
# independent sources that both say /usr/bin -- the tape's own install rule
# (cmd/sed/makefile: `cp sed /usr/bin') and v8/mk/where.txt, measured on a real
# Eighth Edition disk.  It was never evidence: these six were hardcoded when
# v10-where.py could not see units whose directory holds no <name>.c, so the
# file had no row for any of them.  The makefile scanner now reads all six and
# agrees with the five that remain, which is why they stay -- as a live control
# rather than as an answer.  Nothing needs sed before /usr mounts: /etc/rc is
# four lines and uses only /etc/mount and cat.
TOOLCHAIN = {"as": "/bin", "ranlib": "/usr/bin", "lex": "/usr/bin",
             "make": "/bin", "sh": "/bin"}


def load_where():
    w = {}
    p = os.path.join(ROOT, "v10/mk/where.txt")
    if not os.path.exists(p):
        return w
    for line in open(p):
        if line.startswith("#") or not line.strip():
            continue
        f = line.rstrip("\n").split("\t")
        if f[1]:
            w[f[0]] = (f[1], f[2])
    return w


def units():
    cmd = os.path.join(SRC, "cmd")
    u = set()
    for f in os.listdir(cmd):
        if f.endswith(".c"):
            u.add(f[:-2])
        elif os.path.isdir(os.path.join(cmd, f)):
            u.add(f)
    return u


def build():
    known, where = units(), load_where()
    rows, skipped = [], []
    for line in open(os.path.join(ROOT, "v10/MANIFEST")):
        if line.startswith("#") or not line.strip():
            continue
        f = line.rstrip("\n").split("\t")
        if f[0] != "exec":
            continue
        size, path = int(f[2]), f[4]
        name = os.path.basename(path)
        if name not in known or "/cmd/" not in path:
            continue
        if path in IMPOSTORS:
            skipped.append((name, path, IMPOSTORS[path]))
            continue
        # a linked userland program, not a kernel
        try:
            with open(os.path.join(ROOT, "work/v10", path), "rb") as fh:
                if struct.unpack("<H", fh.read(2))[0] != 0x10b:
                    skipped.append((name, path, "not 0413 ZMAGIC"))
                    continue
        except OSError:
            skipped.append((name, path, "unreadable"))
            continue

        if name in TOOLCHAIN and name not in where:
            # ONLY WHERE where.txt IS SILENT.  TOOLCHAIN predates
            # v10-where.py's makefile scanner: before it, the file had no row
            # for as, make, sh, sed or lex -- their directories hold no
            # <name>.c, so commands() never saw them -- and these six were
            # hardcoded here to fill the hole.  The scanner now reads the tape's
            # own install rules, and it AGREES with five of the six.  It
            # disagrees about `sed', where this table said /bin and both the
            # tape (cmd/sed/makefile: `cp sed /usr/bin') and V8's measured disk
            # say /usr/bin -- so the hardcoded value was simply wrong, and
            # deferring to the evidence fixes it.  Exactly CLAUDE.md's "a
            # component list that appears twice will disagree, silently".
            d, src = TOOLCHAIN[name], "toolchain"
        elif name in where:
            d, src = where[name]
        else:
            d, src = "/usr/bin", "default"
        rows.append((name, d.lstrip("/") + "/" + name, path, src, size))

    # AND WHERE BOTH SPEAK, THEY MUST AGREE.  Five of the six overlap, so this
    # is a live control: if the scanner regresses or someone re-hardcodes a
    # path, one of them moves and this fires rather than one silently winning.
    for name, d in sorted(TOOLCHAIN.items()):
        if name in where and where[name][0] != d and where[name][1] != "default":
            sys.exit("v10-prebuilt: %s -- TOOLCHAIN says %s, but where.txt says "
                     "%s on %s authority.\n  Two lists of the same thing have "
                     "disagreed.  Fix one; do not let ordering choose."
                     % (name, d, where[name][0], where[name][1]))

    rows.sort()
    counts = {}
    for r in rows:
        counts[r[3]] = counts.get(r[3], 0) + 1
    head = (
        "# Prebuilt Tenth Edition commands, and where each is installed.\n"
        "#\n"
        "# Generated by tools/v10-prebuilt.py; check with --check.  A row is a\n"
        "# 0413 executable under src/cmd/ whose basename matches a source unit.\n"
        "#\n"
        "# The fourth column says how the path was decided, and they are not of\n"
        "# equal authority:\n"
        "#   man        V10's own manual said so\n"
        "#   v8         inferred from V8's measured disk\n"
        "#   toolchain  placed by us, because the manual documents these as\n"
        "#              parts of cc rather than as commands\n"
        "#   default    UNRESOLVED -- /usr/bin because it had to go somewhere\n"
        "#\n"
        "# fields: name<TAB>install<TAB>source<TAB>how<TAB>size\n"
        "#\n"
        "# %d commands, %s\n"
        "#\n" % (len(rows), ", ".join("%d %s" % (v, k)
                                      for k, v in sorted(counts.items()))))
    body = "".join("%s\t%s\t%s\t%s\t%d\n" % r for r in rows)
    note = "".join("# skipped %-10s %-28s %s\n" % s for s in sorted(skipped))
    return head + note + "#\n" + body, len(rows), counts, skipped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    if not os.path.isdir(SRC):
        sys.exit("v10-prebuilt: no %s -- run tools/v10-import.py" % SRC)

    text, n, counts, skipped = build()
    old = open(OUT).read() if os.path.exists(OUT) else None
    if args.check:
        if old != text:
            print("stale, re-run tools/v10-prebuilt.py")
            return 1
        print("v10/mk/gen/prebuilt.txt is up to date")
        return 0
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    if old != text:
        open(OUT, "w").write(text)
    print("v10/mk/gen/prebuilt.txt: %d commands (%s)"
          % (n, ", ".join("%d %s" % (v, k) for k, v in sorted(counts.items()))))
    for name, path, why in sorted(skipped):
        print("  skipped %-10s %s" % (name, why))
    return 0


if __name__ == "__main__":
    sys.exit(main())
