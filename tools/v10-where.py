#!/usr/bin/env python3
"""
Where does a Tenth Edition command belong?

    tools/v10-where.py            # regenerate v10/mk/where.txt
    tools/v10-where.py --check    # fail if it is stale

THE PROBLEM.  A build has to install what it makes, and "install" needs a
path.  For V8 that was a measurement: `tools/harvest-paths.sh` walked the
shipped TUHS image and wrote down where every binary actually was.  **V10 has
no shipped image** -- producing one is the whole of B3 -- so the same question
has to be answered from documents rather than from a disk.

THE ORACLE, IN ORDER OF AUTHORITY.

  man    V10's own manual.  A section-8 SYNOPSIS opens with the full path --
         `/etc/init', `/etc/mkfs', `/etc/fsck' -- because that is how the
         Research manual documented programs you would not have on PATH.
         This is Bell Labs stating the answer, and it is primary.

  v8     v8/mk/where.txt, measured off a real Eighth Edition disk, for
         commands that exist in both editions.  V10 is V8's successor on the
         same machine and the same lineage, so a command in the same place in
         both is the overwhelmingly likely case -- but it is INFERENCE, not
         documentation, and the column says so.

  --     Neither.  Recorded as unresolved rather than guessed at, because a
         command installed to the wrong directory is invisible until
         something cannot find it, and by then the disk is built.  Track S
         learned this the expensive way: `yacc' and `strip' installed to
         bin/ instead of /usr/bin reached the toolchain and never the system,
         which no boot test could see.

WHY A SECTION-1 PAGE IS NOT ENOUGH.  It gives a bare name, which says the
command is on PATH and not which of /bin and /usr/bin holds it.  That is
exactly the distinction V8's measured file can supply and the manual cannot,
which is why both sources are here rather than one.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
V10SRC = os.path.join(ROOT, "work/v10/src")
MAN = os.path.join(V10SRC, "man")
OUT = os.path.join(ROOT, "v10/mk/where.txt")
V8WHERE = os.path.join(ROOT, "v8/mk/where.txt")

# A troff SYNOPSIS path: /etc/init, /usr/lib/foo.  Anchored at a slash so a
# bare `init' cannot match, and stopped before troff's own escapes.
SYNPATH = re.compile(r'^\.?B?\s*(/(?:[A-Za-z0-9_.]+/)*[A-Za-z0-9_.]+)\s*$')


def man_paths():
    """command -> directory, from section-8 SYNOPSIS lines."""
    out = {}
    for sec in ("man8", "man1"):
        d = os.path.join(MAN, sec)
        if not os.path.isdir(d):
            continue
        for page in sorted(os.listdir(d)):
            if "." not in page:
                continue
            name = page.rsplit(".", 1)[0]
            if name in out:
                continue
            try:
                text = open(os.path.join(d, page), errors="replace").read()
            except OSError:
                continue
            # the SYNOPSIS block only, so a FILES entry cannot be mistaken
            # for the program's own path
            m = re.search(r'^\.SH\s+SYNOPSIS\s*$(.*?)^\.SH', text,
                          re.M | re.S)
            if not m:
                continue
            for line in m.group(1).splitlines():
                line = line.strip()
                if line.startswith(".B"):
                    line = line[2:].strip()
                pm = SYNPATH.match(line)
                if pm and "/" in pm.group(1):
                    p = pm.group(1)
                    if os.path.basename(p) == name:
                        # Absolute, matching v8/mk/where.txt: that file is
                        # what mkgen.load_where() reads for both editions, so
                        # the two sources have to agree on the convention or
                        # `etc' and `/etc' become different directories in a
                        # generated install rule.
                        out[name] = os.path.dirname(p)
                    break
    return out


def v8_paths():
    """command -> directory, as measured on a real V8 disk."""
    out = {}
    if not os.path.exists(V8WHERE):
        return out
    for line in open(V8WHERE):
        if line.startswith("#") or not line.strip():
            continue
        parts = line.rstrip("\n").split("\t")
        # A command found in two places on the V8 disk is not an answer for
        # V10; leave it unresolved rather than pick one.
        out.setdefault(parts[0], set()).add(parts[1])
    return {k: next(iter(v)) for k, v in out.items() if len(v) == 1}


def commands():
    """Every command V10 has source for: loose cmd/*.c plus cmd/*/ dirs."""
    cmd = os.path.join(V10SRC, "cmd")
    names = set()
    for f in os.listdir(cmd):
        p = os.path.join(cmd, f)
        if f.endswith(".c") and os.path.isfile(p):
            names.add(f[:-2])
        elif os.path.isdir(p) and os.path.exists(os.path.join(p, f + ".c")):
            names.add(f)
    return sorted(names)


def build():
    man = man_paths()
    v8 = v8_paths()
    rows, counts = [], {"man": 0, "v8": 0, "--": 0}
    for name in commands():
        if name in man:
            rows.append((name, man[name], "man"))
            counts["man"] += 1
        elif name in v8:
            rows.append((name, v8[name], "v8"))
            counts["v8"] += 1
        else:
            rows.append((name, "", "--"))
            counts["--"] += 1

    head = (
        "# Where each Tenth Edition command belongs.\n"
        "#\n"
        "# Generated by tools/v10-where.py; check with --check.  V10 has no\n"
        "# shipped image to measure -- making one is B3 -- so this is assembled\n"
        "# from documents.  The third column says which, and they are not of\n"
        "# equal authority:\n"
        "#\n"
        "#   man   V10's own manual, section 8 SYNOPSIS.  Bell Labs stating it.\n"
        "#   v8    v8/mk/where.txt, measured on a real V8 disk.  Inference from\n"
        "#         the previous edition of the same system on the same machine.\n"
        "#   --    neither.  UNRESOLVED, deliberately: a command installed to\n"
        "#         the wrong directory is invisible until something cannot find\n"
        "#         it, and by then the disk is built.\n"
        "#\n"
        "# fields: name<TAB>directory<TAB>source\n"
        "#\n"
        "# %d from the manual, %d inferred from V8, %d unresolved\n"
        "#\n" % (counts["man"], counts["v8"], counts["--"]))
    body = "".join("%s\t%s\t%s\n" % r for r in rows)
    return head + body, counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(MAN):
        sys.exit("v10-where: no %s -- run tools/v10-import.py" % MAN)

    text, counts = build()
    old = open(OUT).read() if os.path.exists(OUT) else None
    if args.check:
        if old != text:
            print("stale, re-run tools/v10-where.py")
            return 1
        print("v10/mk/where.txt is up to date")
        return 0

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    if old != text:
        open(OUT, "w").write(text)
    print("v10/mk/where.txt: %d from the manual, %d inferred from V8, "
          "%d unresolved" % (counts["man"], counts["v8"], counts["--"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
