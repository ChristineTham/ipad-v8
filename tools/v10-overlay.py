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
