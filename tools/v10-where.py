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

  mk     the tape's own makefile install rule -- `cp comp /lib/ccom',
         `mv as ${DESTDIR}/bin'.  The build stating what it does with its own
         product, which is precisely the rule we are reimplementing, so it
         outranks a description of the finished system.  Where the manual
         also has an answer the two are ASSERTED equal, not silently
         preferred: a disagreement would be a real finding about the tape.

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


# An install rule in a recipe: `cp sh /bin/sh', `mv tp ${DESTDIR}/bin'.
# Anchored on the whole command, so an argument in the middle cannot match.
INSTALL = re.compile(
    r'^\s*-?\s*(?:cp|mv|install)\s+(?:-[A-Za-z]+\s+)*'
    r'([A-Za-z0-9_.]+)\s+(\S+)\s*$')

# $(DESTDIR)/bin, ${DESTDIR}/bin, $DESTDIR/bin -- all mean /bin here, because
# DESTDIR is where the system being built is rooted and we are asking where
# inside it the command goes.
DESTVAR = re.compile(r'^\$[({]?[A-Za-z_][A-Za-z0-9_]*[)}]?')

SYSDIRS = ("/bin", "/etc", "/lib", "/usr")


def mk_paths(names):
    """command -> (directory, the line that says so), from the tape's makefiles.

    THE STRONGEST EVIDENCE THERE IS, and it was going unread.  where.txt used to
    carry five hand-quoted install rules in MK and infer everything else, so a
    unit whose directory holds no <name>.c -- cmd/sh's main is main.c, cmd/make's
    is main.c, cmd/sed's is sed0.c -- got no row at all and world.link defaulted
    it to /usr/bin.  For `sh' that is not a cosmetic error: /etc/init execs
    `/bin/sh' (measured, in the golden's own binary), and /etc/rc -- which init
    runs THROUGH that shell -- is what mounts /usr.  A shell only in /usr/bin
    does not exist at the moment it is needed, which is V8 stage 8's disk that
    "walked 4,507 files and then stopped dead after autoconfig with the CPU
    idle".

    THE SOURCE TOKEN MUST BE THE PRODUCT'S OWN NAME, which is what separates an
    install from a backup.  cmd/sh/makefile:37 is

	mv /bin/sh /bin/osh;	cp sh /bin/sh;	strip /bin/sh

    -- three commands on one line, of which the FIRST would answer "/bin/osh"
    to a scanner that only looked at destinations.  Reading `cp sh ...', whose
    source is the bare product, gets it right and rejects `cp $(FILES)
    /usr/src/cmd/make' at the same time.

    Two more traps, both of them CLAUDE.md's:  a recipe is a BLOCK and a line
    may hold several commands, so split on `;'; and continuation lines are
    joined FIRST, because sh's $OFILES showed what reading them separately does.
    """
    out = {}
    cmd = os.path.join(V10SRC, "cmd")
    for name in names:
        for mf in ("makefile", "Makefile", "mkfile"):
            path = os.path.join(cmd, name, mf)
            if not os.path.exists(path):
                continue
            try:
                text = open(path, errors="replace").read()
            except OSError:
                continue
            text = text.replace("\\\n", " ")          # join continuations FIRST
            for line in text.splitlines():
                for piece in line.split(";"):
                    m = INSTALL.match(piece)
                    if not m or m.group(1) != name:
                        continue
                    dst = m.group(2)
                    dst = DESTVAR.sub("", dst) or dst   # $(DESTDIR)/bin -> /bin
                    if os.path.basename(dst) == name:   # /bin/make -> /bin
                        dst = os.path.dirname(dst)
                    dst = dst.rstrip("/")
                    if dst.startswith(SYSDIRS) and name not in out:
                        out[name] = (dst, "cmd/%s/%s: %s"
                                     % (name, mf, piece.strip()))
            if name in out:
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


# Paths the tape's OWN makefiles state, with the line that states them.
#
# This is the strongest evidence there is -- stronger than the manual, which
# describes where a command sits on a finished system, where these describe
# what the build itself does with its product.  We are reimplementing exactly
# those install rules, so where they disagree with an inference, they win.
#
# It is also the only evidence available for these five.  None of them is
# found by commands() below, because a toolchain component is a DIRECTORY of
# sources with no <name>.c in it -- cmd/as holds asmain.c, cmd/yacc holds
# y1.c, cmd/ccom holds vax/ and common/ -- so the heuristic that finds every
# ordinary command finds none of the compiler.
#
# cpp is here as a CONTROL rather than because it was missing: the manual
# already puts it in /lib, and cmd/cpp/mkfile says `cp cpp /lib'.  Two
# independent sources agreeing is worth more than one more row.
MK = {
    "ccom": ("/lib",     "cmd/ccom/vax/makefile: cp comp /lib/ccom"),
    "c2":   ("/lib",     "cmd/c2/Makefile: cp c2 $(DESTDIR)/lib"),
    "as":   ("/bin",     "cmd/as/Makefile: mv as ${DESTDIR}/bin"),
    "yacc": ("/usr/bin", "cmd/yacc/Makefile: mv yacc $(DESTDIR)/usr/bin"),
    "cpp":  ("/lib",     "cmd/cpp/mkfile: cp cpp /lib"),
}


def commands():
    """Every command V10 has source for: loose cmd/*.c plus cmd/*/ dirs."""
    cmd = os.path.join(V10SRC, "cmd")
    names = set()
    for f in os.listdir(cmd):
        p = os.path.join(cmd, f)
        if f.endswith(".c") and os.path.isfile(p):
            names.add(f[:-2])
        elif os.path.isdir(p):
            # ANY .c, NOT <name>.c.  The old test was `does cmd/X hold X.c',
            # which is the same blind spot the MK comment below records for the
            # toolchain -- and it silently dropped cmd/sh (main.c), cmd/make
            # (main.c) and cmd/sed (sed0.c) among 92 others, so where.txt had no
            # row and world.link defaulted them to /usr/bin.  A `--' row is
            # honest; an absent row is invisible, which is the failure this
            # file's own header warns about.
            try:
                if any(g.endswith(".c") for g in os.listdir(p)):
                    names.add(f)
            except OSError:
                pass
    return sorted(names)


def build():
    man = man_paths()
    v8 = v8_paths()
    names = sorted(set(commands()) | set(MK))
    mkscan = mk_paths(names)
    rows = []
    counts = {"mk": 0, "mkfile": 0, "man": 0, "v8": 0, "--": 0}
    # WHERE THE SCANNED RULE DISAGREES WITH AN INFERENCE, IT WINS AND SAYS SO.
    # Not silently: a makefile contradicting the manual or V8 is a finding about
    # the tape, and letting one win by ordering buries it.  Hand-written MK still
    # HALTS on a disagreement (five entries, each read by a human); a scan over
    # 350 units reports instead, because a hard stop there would make the
    # generator hostage to one odd recipe.
    notes = []
    for name in sorted(mkscan):
        got = mkscan[name][0]
        for other, label in ((man.get(name), "the manual"), (v8.get(name), "V8")):
            if other and other != got:
                notes.append("# DISAGREES  %-12s makefile says %-10s %s says %s"
                             % (name, got, label, other))
    # THE HAND-TRANSCRIBED RULES AND THE SCANNED ONES MUST AGREE, and four of
    # the five overlap, so this is a real control rather than a formality: if
    # the scanner regresses or a transcription is wrong, one of them moves and
    # this fires.  (ccom is the fifth and is deliberately not found by the scan
    # -- its rule is `cp comp /lib/ccom', whose source token is `comp', not the
    # product name.  A scanner that accepted it would also accept
    # `mv /bin/sh /bin/osh'.)
    for name in sorted(set(MK) & set(mkscan)):
        if MK[name][0] != mkscan[name][0]:
            sys.exit("v10-where: %s -- transcribed as %s from\n  %s\nbut the "
                     "scan reads %s from\n  %s\nOne of them is wrong; fix it "
                     "rather than choosing."
                     % (name, MK[name][0], MK[name][1],
                        mkscan[name][0], mkscan[name][1]))

    # MK's keys are unioned in: the toolchain components are directories with
    # no <name>.c, so commands() cannot see them.
    for name in names:
        if name in MK:
            # Assert rather than prefer, where both exist.  If the manual and
            # the makefile ever disagreed about a path that would be a real
            # finding about the tape, and silently taking one would bury it.
            if name in man and man[name] != MK[name][0]:
                sys.exit("v10-where: %s -- manual says %s, %s\n"
                         "  Resolve this deliberately; do not let one win by ordering."
                         % (name, man[name], MK[name][1]))
            rows.append((name, MK[name][0], "mk"))
            counts["mk"] += 1
        elif name in mkscan:
            rows.append((name, mkscan[name][0], "mkfile"))
            counts["mkfile"] += 1
        elif name in man:
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
        "#   mk    the tape's OWN makefile install rule, quoted in\n"
        "#         tools/v10-where.py.  The build stating what it does with\n"
        "#         its own product, which is the rule we reimplement.\n"
        "#   mkfile  the same thing, READ rather than transcribed: the unit's\n"
        "#         own makefile, scanned for `cp <name> <dir>'.  Equal\n"
        "#         authority to mk and far wider -- it is what finally placed\n"
        "#         sh in /bin, where /etc/init actually execs it.\n"
        "#   man   V10's own manual, section 8 SYNOPSIS.  Bell Labs stating it.\n"
        "#   v8    v8/mk/where.txt, measured on a real V8 disk.  Inference from\n"
        "#         the previous edition of the same system on the same machine.\n"
        "#   --    neither.  UNRESOLVED, deliberately: a command installed to\n"
        "#         the wrong directory is invisible until something cannot find\n"
        "#         it, and by then the disk is built.\n"
        "#\n"
        "# fields: name<TAB>directory<TAB>source\n"
        "#\n"
        "# %d transcribed from the tape's makefiles, %d read from them, %d from\n"
        "# the manual, %d inferred from V8, %d unresolved\n"
        "#\n%s" % (counts["mk"], counts["mkfile"], counts["man"], counts["v8"],
                   counts["--"],
                   ("#\n" + "\n".join(notes) + "\n#\n") if notes else ""))
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
    print("v10/mk/where.txt: %d transcribed + %d read from the tape's makefiles, "
          "%d from the manual, %d inferred from V8, %d unresolved"
          % (counts["mk"], counts["mkfile"], counts["man"], counts["v8"],
             counts["--"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
