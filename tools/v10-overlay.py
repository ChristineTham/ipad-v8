#!/usr/bin/env python3
"""
Our corrections to Tenth Edition source, as a derived overlay.

    tools/v10-overlay.py            # regenerate v10/src/ and v10/src/PATCHES.md
    tools/v10-overlay.py --check    # fail if either is stale

WHY AN OVERLAY RATHER THAN AN IN-PLACE PATCH.  `v10/MANIFEST` is the record
that our copy of the TUHS tarballs is complete and unaltered -- 25,682 files,
every one hashed, re-checkable in about fifteen seconds.  Editing a file in
`work/v10/` would break that, and the ability to say "this is exactly what
Bell Labs shipped" is worth more than the convenience.  So the tree stays
pristine and our changed files live here, in git, served beside it.

WHY GENERATED RATHER THAN HAND-EDITED COPIES.  A checked-in copy of a
2,036-line file records the result and loses the change: a later reader
cannot see what we did without diffing against a tarball they may not have
unpacked.  Worse, it can drift -- someone edits the copy, and nothing says it
no longer corresponds to anything upstream.  Here each entry names the
pristine file, asserts its sha256, and applies a stated substitution.  A
changed base file fails loudly instead of being silently re-patched.

WHAT THE MAKEFILES DO WITH IT.  `v10/mk/mkdep.py` points a patched component
at `$(OURS)` instead of `$(SRC)`, so the provenance is visible in the
generated rule itself: a line reading $(SRC) is Bell Labs', a line reading
$(OURS) is ours.
"""
import argparse
import difflib
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "work/v10/src")
OUT = os.path.join(ROOT, "v10/src")
DOC = os.path.join(OUT, "PATCHES.md")

# Each edit is (old, new) applied once, and `count' says how many times the
# old text must occur -- so a substitution that would hit an unintended second
# site fails rather than making two changes.
EDITS = [
    dict(
        path="libc/stdio/printf.c",
        sha="0e79acc3ba7378d31b6ded487907194cc9c6a498bd9b47e06da03d7fb2fac86f",
        title="printf.c: an ANSI definition pcc2 cannot parse (B2.2c)",
        why="""\
One of nine `printf`/`scanf` members that compile under **neither** of the
tree's two compilers, which is the clearest single symptom of V10's unfinished
V9-to-V10 port.

	printf.c:5: syntax error; found `args' expecting `;'        (lcc)
	"printf.c":5:syntax error                                   (pcc2)

pcc2 cannot parse `int printf(const char *fmt, ...)`, and lcc cannot find
`va_list` because `stdio/iolib.h` includes `<stdarg.h>` only `#ifdef sgi` --
its branches cover *V10 without stdarg*, *pANS with stdarg* and *SGI*, and not
*V10 with stdarg on a VAX*.

**The conversion direction is ANSI to K&R, and that is deliberate.** V10 keeps
the 1989 language; V11 is where the tree becomes ANSI (roadmap D-A4). And it is
possible without touching the body because `include/lcc/stdarg.h` is itself
K&R-compatible -- `typedef char *va_list;` plus macros built from casts and
`sizeof` -- so `cc` can use the two-argument ANSI `va_start(args, fmt)` as it
stands. The alternative, `varargs.h`, would have forced `va_alist`/`va_dcl` and
a rewritten body.

So two changes: include the header the file actually needs, and give the
definition an old-style parameter list. `...` is dropped because K&R varargs is
implicit -- the macros walk the stack from the last named parameter either way.""",
        edits=[
            ('#include "iolib.h"\nint printf(const char *fmt, ...){\n',
             '#include "iolib.h"\n#include <stdarg.h>\t/* ipnx: iolib.h has it only #ifdef sgi */\n'
             'printf(fmt)\t\t/* ipnx: K&R, see PATCHES.md */\n'
             '\tchar *fmt;\n{\n', 1),
        ],
    ),
    dict(
        path="cmd/fsck.c",
        sha="49fafbce4812db9512234ba83727d44c9f47676957345ead28e0830b5fde5ff8",
        title="fsck.c: `#include <stat.h>` names a header the archive has not",
        why="""\
The only boot-path command that failed against BOTH header sets
(`tools/v10-bootpath.sh`):

	fsck.c: 22: Can't find include file stat.h

No bare `stat.h` exists in the r70 include tree or in either 1995 kernel tree
-- `sys/sys/stat.h` and `lsys/sys/stat.h` are both under `sys/` -- and every
other command in the tree writes `<sys/stat.h>`.

**This is not a typo, and the fix is not a guess: the line we want is sitting
there commented out.**

	#include <sys/inode.h>
	/* #include <sys/stat.h> */
	#include <stat.h>

fsck.c is a file caught mid-port. Three other includes are commented out the
same way -- `<ansi.h>`, `<posix.h>`, `<sys/dinode.h>` -- so someone was moving
it towards a different header environment and stopped, or moved it and never
moved it back. Whatever they were compiling against had a flat `stat.h`; the
Tenth Edition archive does not, and neither did the machine this is being
built for. Restoring their own commented-out line is the smallest correct
change and the one they had already written down.

(Related, for B2.2: `include/CC/sys/stat.h` and `include/oCC/sys/stat.h` are
alternative copies at 1089 and 961 bytes against the main tree's 959, so the
r70 reconstruction preserves more than one header environment. Worth knowing
before assuming a single answer to "which stat.h".)
""",
        edits=[("#include <stat.h>", "#include <sys/stat.h>", 1),
               # Fixing the header let ccom reach the body, which is where
               # the REAL obstacle was: fsck.c carries ANSI prototypes, and
               # the 1985 compiler rejects one outright --
               #     "fsck.c":230:syntax error / expected a NAME in list
               #     "fsck.c":230:saw TYPE
               # the signature CLAUDE.md already records for V8's cc.  Same
               # story as the commented-out <ansi.h> and <posix.h>: this file
               # was half-ported to an ANSI compiler and left there.
               #
               # Three declarations, no definitions, so dropping the
               # parameter types is exactly what the pre-ANSI line said and
               # changes nothing a K&R compiler can observe.  V10 does ship
               # an ANSI compiler (cmd/lcc) and pointing fsck at it is the
               # other option -- rejected for now because it would mean two
               # toolchains in one build to save three lines.
               ("void\tcatch(int);", "void\tcatch();", 1),
               ("void ltol3(char *, long *, int);", "void ltol3();", 1),
               ("void l3tol(long *, char *, int);", "void l3tol();", 1),
               # ...and catch()'s DEFINITION, which the first pass missed
               # because the scan that found the declarations required a
               # trailing `;'.  Fixing only the declarations moved the error
               # from line 230 to line 1996 and looked, for a moment, like
               # the patch not having taken.  Search for the parameter list,
               # not for the statement.
               #
               # ltol3() and l3tol() are NOT here even though they have the
               # same prototype form at 2006 and 2022: both definitions sit
               # inside a `/* ... */` block, so the compiler never sees them
               # and libc supplies the real ones.  Patching them would be
               # invisible to the build and would make this file's diff
               # claim a change that does nothing.
               ("catch(int signo)\n", "catch(signo)\nint signo;\n", 1),
               # THIRD LAYER, and the one that got through a green test.
               # fsck.c calls S_ISBLK(), S_ISCHR() and S_ISREG() at seven
               # sites.  V10's sys/stat.h defines S_IFBLK, S_IFCHR and
               # S_IFREG -- the type CONSTANTS -- and none of the POSIX test
               # MACROS, so cpp leaves the calls alone and ld reports
               #     Undefined: _S_ISBLK _S_ISCHR _S_ISREG
               # (grep for `S_IS' in that header and you get three hits that
               # look reassuring and are S_ISUID, S_ISGID and S_ISYNC.)
               #
               # Same half-finished POSIX port as the prototypes and the
               # commented-out <posix.h>.  Supplying the three macros keeps
               # fsck.c's code exactly as written and is what <posix.h>
               # would have provided; the alternative is rewriting seven
               # call sites into `(m & S_IFMT) == S_IFBLK'.
               ("#include <fstab.h>",
                "#include <fstab.h>\n"
                "\n"
                "/* ipnx: V10's <sys/stat.h> has the type constants but not\n"
                "   the POSIX test macros this file was ported to use. */\n"
                "#ifndef S_ISBLK\n"
                "#define\tS_ISBLK(m)\t(((m) & S_IFMT) == S_IFBLK)\n"
                "#define\tS_ISCHR(m)\t(((m) & S_IFMT) == S_IFCHR)\n"
                "#define\tS_ISREG(m)\t(((m) & S_IFMT) == S_IFREG)\n"
                "#endif\n", 1)],
    ),
    dict(
        path="cmd/mv.c",
        sha="08f40882d633fc99757e7b93cf580ada4da8d5da0a61de84a1fc3abba3898337",
        title="mv.c: uses ROOTINO and includes nothing that defines it",
        why="""\
`ROOTINO` is in `sys/param.h`, which mv.c does not include directly or
transitively.  It compiles against V8's headers only because **V8's**
`sys/types.h` includes `sys/param.h`.

That looked like r70 having dropped a line, and it is not: the tarball ships
its own 1995 copy of the header, and

	src/sys/sys/types.h  ==  include/sys/types.h     byte-identical

so the 1997 reconstruction is faithful and the source is the defect.  mv is
one of the ~237 command units with no prebuilt binary, which is consistent --
nobody had compiled it in place when the tape was cut.

**Adding `<sys/param.h>` is not enough, and the first attempt failed
instructively.**  V10's `sys/param.h` ends with `#include "sys/types.h"` and
V10's `sys/types.h` has **no include guard**, so a file that includes both
parses every typedef twice:

	"/usr/v10/include/sys/types.h":33:illegal type combination

So param.h REPLACES types.h rather than joining it.  `signal.h` goes the same
way for the same reason -- param.h already includes it, behind its own
`#ifndef NSIG`, and mv.c's copy would be the second.  Two lines out, one in,
and everything mv.c used still arrives.
""",
        edits=[("#include <sys/types.h>", "#include <sys/param.h>", 1),
               ("#include <sys/dir.h>\n#include <signal.h>",
                "#include <sys/dir.h>", 1)],
    ),
    dict(
        path="cmd/mkbitfs.c",
        sha="",
        title="mkbitfs.c: the BITFS check asks about the wrong machine",
        why="""\
`mkbitfs` makes the bitmapped 4096-byte filesystem `seki` boots from -- the
one `mkfs` cannot make, because `mkfs` is a Berkeley 4.2 file that writes only
the `S_free[]` list while BITFS keeps free space in `S_bfree[BITMAP]`.

It refuses to run unless its target has bit 6 set in the minor number. That is
right on a V10 machine, where `BITFS(dev) = ((dev) & 64)` is how a device
declares which variant it holds -- `seki`'s root is `ra 0100`, and 0100 octal
is 64.

**It cannot be satisfied on the Eighth Edition host.** V8's `hp` driver reads
the same bit as part of the drive number (`unit = minor(dev) >> 3`,
`sys/dev/hp.c:562`), so a minor with bit 6 set names drive 8 -- and SIMH's RP
has units 0 to 7. There is no node that both passes the check and reaches a
real disk.

The check asks about the machine doing the writing, when what decides the
format is the machine that will read it. The author's own `/* doubtful */`
sits on that line. So it becomes a warning: the diagnostic still prints, and
the caller stays responsible for pointing this at an image the *target* kernel
will see as BITFS.

\
V10 added 64-bit file offsets and `mkbitfs` uses them:

	off = Llmul(ltoL(size-1), BCOUNT);
	llseek(fd, off, 0);

V8's libc has none of that, so the link fails:

	Undefined:
	_ltoL
	_Llmul
	_llseek

**Linking V10's libc.a instead would be much worse than a build failure.**
`llseek` is system call slot **11**, and on a V8 kernel slot 11 is `exec` --
the one V7 vestige V10 reused. A V10 binary calling llseek on V8 does not
fail; it execs.

The filesystem this makes is 25,000 blocks of 4096 = 102 MB, and the largest
this tool can address in 32 bits is 2 GB, so the wide arithmetic buys nothing
here. `off` becomes a `long` and the seek an ordinary `lseek`.
""",
        edits=[('\tif(!BITFS(statbuf.st_rdev)) {\t/* doubtful */\n\t\tfprintf(stderr, "%s device %d, 0%o can\'t have a 4k filesystem\\n",\n\t\t\targv[1], major(statbuf.st_rdev), minor(statbuf.st_rdev));\n\t\texit(1);\n\t}\n',
                '\t/* ipnx: warn, do not exit.  The build host numbers its devices\n\t   differently from the machine that will mount this; see\n\t   v10/src/PATCHES.md. */\n\tif(!BITFS(statbuf.st_rdev)) {\t/* doubtful */\n\t\tfprintf(stderr, "%s device %d, 0%o is not BITFS on this host\\n",\n\t\t\targv[1], major(statbuf.st_rdev), minor(statbuf.st_rdev));\n\t}\n', 1),
               ('\tllong_t off;\n\tlong atol();\n\textern llong_t Llmul(), ltoL();\n',
                '\tlong off;\t\t\t/* ipnx: 32-bit, see PATCHES.md */\n\tlong atol();\n', 1),
               ('\toff = Llmul(ltoL(size-1), BCOUNT);\n\tllseek(fd, off, 0);\n',
                '\toff = (long)(size-1) * BCOUNT;\n\tlseek(fd, off, 0);\n', 1),
               ('\t\tfprintf(stderr, "size %ld too large (lseek [%d,%d], read %d)\\n",\n\t\t\tsize, Lsign(off), Ltol(off), j);\n',
                '\t\tfprintf(stderr, "size %ld too large (lseek %ld, read %d)\\n",\n\t\t\tsize, off, j);\n', 1)],
    ),
    dict(
        path="cmd/cc.c",
        sha="6c0faa5a16675805e6168fc7591f3540a25751aed3bb3032385a023ef7732068",
        title="cc.c: uses BUFSIZE without including <sys/param.h>",
        why="""\
`cc' is the difference between a machine with a compiler on it and a machine
that can compile, and it would not build:

	"cc.c":42:BUFSIZE undefined
	"cc.c":42:integer constant expected

Line 42 is `char errbuf[BUFSIZE];` and `BUFSIZE` is `sys/param.h`'s -- not
`stdio.h`'s `BUFSIZ`, which is a different name for the same 4096. cc.c
includes `sys/types.h`, `stdio.h`, `ctype.h`, `signal.h` and `dir.h`, and
none of them reaches `param.h`.

**This is `mv.c` again.** Same defect, same edition, a different constant: a
1995 source using something from `sys/param.h` without including it. Two of
the ~283 command units do this, and both are ones with no prebuilt binary --
consistent with nobody having compiled them in place when the tape was cut.

And it needs the same fix rather than an added include, for the same reason:
`sys/param.h` ends with `#include "sys/types.h"` and guards a `signal.h` with
`#ifndef NSIG`, while V10's `types.h` and `signal.h` have no guards of their
own. A file that includes `param.h` **and** either of those parses their
typedefs twice --

	"/usr/v10/include/sys/types.h":33:illegal type combination

-- so `param.h` replaces `types.h`, and `signal.h` goes because `param.h`
already brought it. Two lines out, one in, and everything cc.c used still
arrives.
""",
        edits=[('#include <sys/types.h>\n',
                '#include <sys/param.h>\n', 1),
               ('#include <signal.h>\n#include <dir.h>\n',
                '#include <dir.h>\n', 1)],
    ),
]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def build():
    """-> {relpath: text}, doc text, list of (path, note) problems."""
    files, docs, problems = {}, [], []
    for e in EDITS:
        src = os.path.join(SRC, e["path"])
        if not os.path.exists(src):
            problems.append((e["path"], "not in work/v10/src"))
            continue
        raw = open(src, "rb").read()
        got = sha256(raw)
        if e["sha"] not in ("", got):
            problems.append((e["path"],
                             "base file changed: expected %s, got %s"
                             % (e["sha"][:12], got[:12])))
            continue
        text = raw.decode("latin-1")
        new = text
        for old, repl, count in e["edits"]:
            n = new.count(old)
            if n != count:
                problems.append((e["path"],
                                 "found %d occurrences of %r, expected %d"
                                 % (n, old, count)))
                break
            new = new.replace(old, repl, count)
        else:
            files[e["path"]] = new
            diff = "".join(difflib.unified_diff(
                text.splitlines(keepends=True), new.splitlines(keepends=True),
                fromfile="tarball/" + e["path"], tofile="ours/" + e["path"],
                n=2))
            docs.append((e, got, diff))

    out = ["# Our corrections to Tenth Edition source\n\n",
           "Generated by `tools/v10-overlay.py` -- do not edit; edit the tool.\n\n",
           "The tarball stays pristine (`v10/MANIFEST` proves it), so every file\n"
           "here is derived from a named upstream file with a stated sha256 and\n"
           "one stated substitution. A changed base fails the tool rather than\n"
           "being silently re-patched.\n\n"]
    for e, got, diff in docs:
        out.append("## %s\n\n" % e["title"])
        out.append("`%s`, sha256 `%s`\n\n" % (e["path"], got[:16]))
        out.append(e["why"])
        out.append("\n```diff\n%s```\n\n" % diff)
    return files, "".join(out), problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(SRC):
        sys.exit("v10-overlay: no %s -- run tools/v10-import.py" % SRC)

    files, doc, problems = build()
    for path, note in problems:
        print("v10-overlay: %s: %s" % (path, note), file=sys.stderr)

    stale = []
    for rel, text in files.items():
        dest = os.path.join(OUT, rel)
        old = open(dest, encoding="latin-1").read() if os.path.exists(dest) else None
        if args.check:
            if old != text:
                stale.append(rel)
        elif old != text:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            open(dest, "w", encoding="latin-1").write(text)
    old = open(DOC).read() if os.path.exists(DOC) else None
    if args.check:
        if old != doc:
            stale.append("PATCHES.md")
    elif old != doc:
        os.makedirs(OUT, exist_ok=True)
        open(DOC, "w").write(doc)

    if problems:
        return 1
    if args.check:
        if stale:
            print("stale, re-run tools/v10-overlay.py: " + " ".join(stale))
            return 1
        print("v10/src is up to date with the tarball")
        return 0
    print("v10/src: %d file(s) patched from the pristine tree" % len(files))
    for rel in sorted(files):
        print("  %s" % rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
