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
One of eight `printf`/`scanf` members that compile under **neither** of the
tree's two compilers, which is the clearest single symptom of V10's unfinished
V9-to-V10 port.

	printf.c:5: syntax error; found `args' expecting `;'        (lcc)
	"printf.c":5:syntax error                                   (pcc2)

Two independent faults, and the tape's own siblings show it. `va_list` is
undeclared because `stdio/iolib.h` includes `<stdarg.h>` only `#ifdef sgi` --
its branches cover *V10 without stdarg*, *pANS with stdarg* and *SGI*, and not
*V10 with stdarg on a VAX*. And pcc2 cannot parse
`int printf(const char *fmt, ...)`.

**WHERE THE FIX BELONGS IS SETTLED BY THE TAPE, not by preference.** The two
members of this family that DO compile -- `vfprintf.c` and `vfscanf.c` -- carry
`#include <stdarg.h>` in the **.c file**, one line below `#include "iolib.h"`.
They are the only two in `libc/stdio` that do, and they are exactly the two
that build. So the convention in this tree is that the variadic source includes
the header itself, and these eight are simply missing that line: a per-file
omission, not a missing branch in a shared header. Restoring the line the
working siblings have is a smaller and better-evidenced change than rewriting
`iolib.h`'s `#ifdef` structure.

**THE DIRECTORY IN THE INCLUDE IS OURS, AND IT HAS TO BE.** `vfprintf.c` writes
a bare `<stdarg.h>`, which resolves only because `lcc` supplies its own include
path; **the r70 tree has no top-level `stdarg.h` at all** (only `lcc/`, `CC/`,
`olcc/`, `oCC/` and `cmd/gcc/`), so under `cc -I/usr/v10/include` a bare
`<stdarg.h>` finds nothing. `-I$(INCDIR)/lcc` is not the answer either: that
directory also holds `stdio.h`, `string.h` and `math.h`, and putting it on the
include path would silently shadow the system headers for every member. So the
subdirectory is named explicitly, in one line, shadowing nothing.

*This file shipped once with a bare `<stdarg.h>`* -- reasoning that named
`include/lcc/stdarg.h` over code that wrote a path finding nothing. It was
never tested, because the run that was supposed to test it read a source disk
that was being rewritten underneath it (see tools/norun.sh).

**The conversion direction is ANSI to K&R, and that is deliberate.** V10 keeps
the 1989 language; V11 is where the tree becomes ANSI (roadmap D-A4). It is
possible without touching the body because `include/lcc/stdarg.h` is itself
K&R-compatible -- `typedef char *va_list;` plus macros built from casts and
`sizeof` -- so `cc` can use the two-argument ANSI `va_start(args, fmt)` as it
stands. Its `((void)(...))` wrapper is safe: pcc2 accepts a cast to void, which
149 files in V8's own source tree rely on. The alternative, `varargs.h`, has a
ONE-argument `va_start(list)` and requires `va_alist`/`va_dcl`, so it would
have forced a rewritten parameter list and body.

So two changes: include the header the file's own working siblings include, and
give the definition an old-style parameter list. `...` is dropped because K&R
varargs is implicit -- the macros walk the stack from the last named parameter
either way -- and `const` because pcc2 has no such qualifier.""",
        edits=[
            ('#include "iolib.h"\nint printf(const char *fmt, ...){\n',
             '#include "iolib.h"\n#include <lcc/stdarg.h>\t/* ipnx: as vfprintf.c does; see PATCHES.md */\n'
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

# --------------------------------------------------------------------------
# THE OTHER SEVEN OF THE printf/scanf FAMILY (B2.2c).
#
# printf.c above carries the whole argument -- why the include line belongs in
# the .c file, why the directory has to be named explicitly, why the direction
# is ANSI to K&R, and why `varargs.h' will not do.  These seven are the same
# two edits against the same shape, so they are generated rather than restated:
# eight copies of a page of reasoning is eight chances for one copy to drift out
# of agreement with the others.
#
# THE PARAMETER LISTS ARE NOT GUESSED.  Each is the tape's own list with the
# types moved below the name, `const' dropped (pcc2 has no such qualifier) and
# `...' dropped (K&R varargs is implicit).  Nothing else in any of these files
# is touched -- not the #ifdef V10 blocks that build the string FILE by hand,
# not the `#define f &_strbuf' that stands in for a stream.
#
# WHY THE LAST NAMED PARAMETER MATTERS.  va_start(args, fmt) takes the address
# of `fmt' and steps one slot past it, so `fmt' must remain the LAST named
# parameter of every one of these.  It already is in all eight, which is why
# the conversion is mechanical -- but a "tidier" reordering would break them
# silently, producing a printf that reads its arguments one slot early.
_FAMILY = [
    # path                      sha256                    ANSI declaration -> K&R parameter list
    ("libc/stdio/fprintf.c",
     "c8124cdf9b073d821157741622fd0d257ef2279ef10dcc1cf14d2d772873cc59",
     "int fprintf(FILE *f, const char *fmt, ...){\n",
     "fprintf(f, fmt)\n\tFILE *f;\n\tchar *fmt;\n{\n"),
    ("libc/stdio/sprintf.c",
     "2fb37623be9a2b29cc4537c0aaad6981671081d6da9ec006699343d9b49c2354",
     "int sprintf(char *buf, const char *fmt, ...){\n",
     "sprintf(buf, fmt)\n\tchar *buf;\n\tchar *fmt;\n{\n"),
    ("libc/stdio/snprintf.c",
     "191803217770f62911783d533278bb17ae2e82fab82ce9fb35a6c1f7b19035ef",
     "int snprintf(char *buf, int len, const char *fmt, ...){\n",
     "snprintf(buf, len, fmt)\n\tchar *buf;\n\tint len;\n\tchar *fmt;\n{\n"),
    ("libc/stdio/vprintf.c",
     "5b2dd72072120ab5cea580e66ee3b6d7ba3070a7cebc6c2fa010f5c908a0cf21",
     "int vprintf(const char *fmt, va_list args){\n",
     "vprintf(fmt, args)\n\tchar *fmt;\n\tva_list args;\n{\n"),
    ("libc/stdio/scanf.c",
     "3cc5ae9da144071723d42b586e628c79fe07b94d5c2c17e6ef3b80365f515256",
     "int scanf(const char *fmt, ...){\n",
     "scanf(fmt)\n\tchar *fmt;\n{\n"),
    ("libc/stdio/fscanf.c",
     "cef49e2048c70948ea1982a2ab6c5bd7e80c9a1d98e8e63e4c880b06c572887c",
     "int fscanf(FILE *f, const char *fmt, ...){\n",
     "fscanf(f, fmt)\n\tFILE *f;\n\tchar *fmt;\n{\n"),
    ("libc/stdio/sscanf.c",
     "7cbe8d5f4d3edc7e8d3567bcbe78456eabcb9f7e33e9b97bd35bf6897777016a",
     "int sscanf(const char *s, const char *fmt, ...){\n",
     "sscanf(s, fmt)\n\tchar *s;\n\tchar *fmt;\n{\n"),
]

# vprintf.c takes an EXPLICIT va_list and no `...', so it needs the header but
# not the varargs machinery -- and it still fails, because `va_list' in the
# parameter list is undeclared exactly as `va_list args;' is in the others.
# One line's difference; the same two edits.
# --------------------------------------------------------------------------
# THE 1993 ANSI MEMBERS (B2.2d).  A different batch from the printf family and
# a different reason: these carry `/* Copyright AT&T Bell Laboratories, 1993 */'
# and were written against a header set that IS NOT IN /usr/include.  r70's top
# level has no `stddef.h', no `stdlib.h', and defines `size_t' nowhere at all --
# those live only under `include/lcc/' and `include/CC/'.  So they are not
# merely prototyped, they are addressed to a different C.
#
# Three of the eleven are small enough to convert mechanically and are done
# here.  The other eight -- _dtoa, _fconv, malloc, qsort, rdwr, strtod,
# vfprintf, vfscanf -- are real work and are left named rather than half-done;
# vfprintf.c alone is printf's whole engine.
#
# `void *' BECOMES `char *' AND `size_t' BECOMES `unsigned int', which is not a
# liberty: both pairs are the same width on the VAX, `char *' is K&R's spelling
# of a generic pointer, and it is how V8's own libc declares these very
# functions.  Nothing about the generated code changes.
_ANSI93 = [
    ("libc/stdio/fgets.c",
     "11a0f4ee411e523d65d2cd8eb2d09b44bf527e46bdc933154b3de6379c117555",
     [("char *\nfgets(char *ptr, int n, FILE *iop)\n{\n",
       "char *\nfgets(ptr, n, iop)\t\t/* ipnx: K&R, see PATCHES.md */\n"
       "\tchar *ptr;\n\tint n;\n\tFILE *iop;\n{\n", 1)]),
    ("libc/stdio/fputs.c",
     "243edc4ccaef7b68b5a382d3f020a2d4e2ed4c12da3eca8cb300245fcefbfb6e",
     [("fputs(const char *s, FILE *iop)\n{\n",
       "fputs(s, iop)\t\t\t/* ipnx: K&R, see PATCHES.md */\n"
       "\tchar *s;\n\tFILE *iop;\n{\n", 1)]),
    # qsort.c: three definitions and one include, and no forward prototypes at
    # all -- `swapfunc' and `med3' are both DEFINED above their first use, which
    # is what makes an 88-line file with a macro-heavy body mechanical to
    # convert.  The macros (SWAPINIT, swapcode, swap, vecswap) are untouched.
    ("libc/gen/qsort.c",
     "88290e37a65970ee72f61d83fcd60acbf7cedaf2b88cbcd1e44aaf1aaaeac337",
     [("#include <stddef.h>\nstatic void swapfunc(char *a, char *b, size_t n, int swaptype)\n",
       "/* ipnx: r70 has no <stddef.h>; K&R below -- see PATCHES.md */\n"
       "static void swapfunc(a, b, n, swaptype)\n"
       "\tchar *a; char *b; unsigned int n; int swaptype;\n", 1),
      ("static char *med3(char *a, char *b, char *c, int (*cmp)())\n",
       "static char *med3(a, b, c, cmp)\n"
       "\tchar *a; char *b; char *c; int (*cmp)();\n", 1),
      ("void qsort(char *a, size_t n, size_t es, int (*cmp)())\n",
       "void qsort(a, n, es, cmp)\t/* ipnx: K&R, see PATCHES.md */\n"
       "\tchar *a; unsigned int n; unsigned int es; int (*cmp)();\n", 1)]),
    # rdwr.c: fread and fwrite, two definitions in 52 lines.  `void *' -> `char
    # *' and `const void *' -> `char *'; the bodies already assign both to
    # `unsigned char *s', so K&R's generic pointer is what they wanted anyway --
    # `unsigned char *s = ptr;' from a `void *' is a diagnostic under ANSI rules
    # and silent here.
    ("libc/stdio/rdwr.c",
     "81fd95fa1bae514b7132fe93afbd02bcaea874edf6c68893cf786a2a8df624ac",
     [("fread(void *ptr, unsigned size, unsigned count, FILE *iop)\n",
       "fread(ptr, size, count, iop)\t/* ipnx: K&R, see PATCHES.md */\n"
       "\tchar *ptr; unsigned size; unsigned count; FILE *iop;\n", 1),
      ("fwrite(const void *ptr, unsigned size, unsigned count, FILE *iop)\n",
       "fwrite(ptr, size, count, iop)\t/* ipnx: K&R, see PATCHES.md */\n"
       "\tchar *ptr; unsigned size; unsigned count; FILE *iop;\n", 1),
      # AND THE CASTS, which the parameter change alone does not cover:
      #	  "rdwr.c":9:illegal pointer combination, op =
      # `unsigned char *s = ptr;' is legal from a `void *' under ANSI rules and
      # illegal from a `char *' under K&R's, so converting the parameter list
      # MOVED the error rather than removing it.  Both functions do it, both get
      # an explicit cast, and the generated code is identical either way.
      ("\tunsigned char *s = ptr;\n\tunsigned char *t;\n"
       "\tunsigned long n = (unsigned long)count*size;\n"
       "\tfor(;;) {\n\t\tl = iop->_cnt;\n\t\tif(l > n) l = n;\n"
       "\t\tt = iop->_ptr;\n\t\tiop->_cnt -= l;\n\t\tiop->_ptr += l;\n"
       "\t\tn -= l;\n\t\twhile(--l >= 0)\n\t\t\t*s++ = *t++;\n",
       "\tunsigned char *s = (unsigned char *)ptr;\t/* ipnx: K&R cast */\n"
       "\tunsigned char *t;\n"
       "\tunsigned long n = (unsigned long)count*size;\n"
       "\tfor(;;) {\n\t\tl = iop->_cnt;\n\t\tif(l > n) l = n;\n"
       "\t\tt = iop->_ptr;\n\t\tiop->_cnt -= l;\n\t\tiop->_ptr += l;\n"
       "\t\tn -= l;\n\t\twhile(--l >= 0)\n\t\t\t*s++ = *t++;\n", 1),
      ("\tunsigned char *s = ptr;\n\tunsigned char *t;\n"
       "\tunsigned long n = (unsigned long)count*size;\n"
       "\tfor(;;) {\n\t\tl = iop->_cnt;\n\t\tif(l > n) l = n;\n"
       "\t\tt = iop->_ptr;\n\t\tiop->_cnt -= l;\n\t\tiop->_ptr += l;\n"
       "\t\tn -= l;\n\t\twhile(--l >= 0)\n\t\t\t*t++ = *s++;\n",
       "\tunsigned char *s = (unsigned char *)ptr;\t/* ipnx: K&R cast */\n"
       "\tunsigned char *t;\n"
       "\tunsigned long n = (unsigned long)count*size;\n"
       "\tfor(;;) {\n\t\tl = iop->_cnt;\n\t\tif(l > n) l = n;\n"
       "\t\tt = iop->_ptr;\n\t\tiop->_cnt -= l;\n\t\tiop->_ptr += l;\n"
       "\t\tn -= l;\n\t\twhile(--l >= 0)\n\t\t\t*t++ = *s++;\n", 1)]),
    # malloc.c: 401 lines, and once <stdlib.h> is installed it is nothing but
    # prototypes -- eight declarations and ten definitions, no macro trickery in
    # any of them.  `void *' -> `char *' and `size_t' -> `unsigned int'
    # throughout, and every prototype loses its parameter list entirely, which is
    # what K&R has instead of a declaration that carries types.
    ("libc/gen/malloc.c",
     "e193faf74e6a06fc34b5d17681127708196953e1ea62ed6c0e2cb08922611118",
     [("botch(int n)\n", "botch(n)\n\tint n;\n", 1),
      ("extern	void *sbrk(int);\n", "extern	char *sbrk();\n", 1),
      ("static union store *stdmalloc(size_t);\n",
       "static union store *stdmalloc();\n", 1),
      ("static void stdfree(union store *);\n", "static void stdfree();\n", 1),
      ("static draincache(void);\n", "static draincache();\n", 1),
      ("int cached(union store *p);\n", "int cached();\n", 1),
      ("static int allock(union store *q);\n", "static int allock();\n", 1),
      ("extern void ialloc(void *, size_t);\n", "extern void ialloc();\n", 1),
      ("void *\nmalloc(size_t nbytes)\n",
       "char *\t\t\t\t/* ipnx: K&R, see PATCHES.md */\n"
       "malloc(nbytes)\n\tunsigned int nbytes;\n", 1),
      ("stdmalloc(register size_t nw)\n",
       "stdmalloc(nw)\n\tregister unsigned int nw;\n", 1),
      ("void\nfree(void *ap)\n", "void\nfree(ap)\n\tchar *ap;\n", 1),
      ("stdfree(register union store *p)\n",
       "stdfree(p)\n\tregister union store *p;\n", 1),
      ("draincache(void)\n", "draincache()\n", 1),
      ("void\nialloc(void *qq, size_t nbytes)\n",
       "void\nialloc(qq, nbytes)\n\tchar *qq;\n\tunsigned int nbytes;\n", 1),
      ("void *\nrealloc(void *pp, size_t nbytes)\n",
       "char *\t\t\t\t/* ipnx: K&R, see PATCHES.md */\n"
       "realloc(pp, nbytes)\n\tchar *pp;\n\tunsigned int nbytes;\n", 1),
      ("allock(union store *q)\n", "allock(q)\n\tunion store *q;\n", 1),
      ("void\nmstats(void)\n", "void\nmstats()\n", 1),
      ("int\ncached(union store *p)\n", "int\ncached(p)\n\tunion store *p;\n", 1),
      # AND THE LOCALS, which the declarations do not cover.  `size_t' is not
      # only a parameter type here -- five LOCAL variables use it, and pcc2
      # reports the first as
      #	  "malloc.c":104:syntax error / saw NAME    (register size_t nw;)
      # followed by `nw undefined' four lines later, which reads like a scoping
      # bug and is an unknown type.  Same lesson as rdwr.c: converting the
      # signature moves the error inward.
      # COUNT 2, and the generator is why that is known rather than assumed:
      # `malloc()' and `free()' open with the identical two lines, so an edit
      # written for one silently matched both.  The occurrence check refused it
      # -- "found 2 occurrences, expected 1" -- which is exactly the guard that
      # makes a context-anchored patch safe on a file nobody can eyeball.
      ("	register size_t nw;\n	register union store **cp;\n",
       "	register unsigned int nw;\n	register union store **cp;\n", 2),
      ("	register size_t temp;\n", "	register unsigned int temp;\n", 1),
      ("	register size_t nw;\n	size_t onw;\n",
       "	register unsigned int nw;\n	unsigned int onw;\n", 1),
      # AND THREE CASTS.  Third round on the same file and the same reason each
      # time: `union store *p = ap;' is legal from a `void *' and illegal from a
      # `char *', so every parameter that stopped being `void *' needs its
      # assignment made explicit.  pcc2 names them one round at a time --
      #	  "malloc.c":190:illegal pointer combination, op =
      # -- because it stops at the first error in each function.
      ("	register union store *p = ap, *q;\n",
       "	register union store *p = (union store *)ap, *q;\t/* ipnx: K&R cast */\n", 1),
      ("	q = qq;\n", "	q = (union store *)qq;\t\t/* ipnx: K&R cast */\n", 1),
      ("	register union store *p = pp;\n",
       "	register union store *p = (union store *)pp;\t/* ipnx: K&R cast */\n", 1)]),
    # fconv.h: Gay's shared header, and the door in front of THREE members --
    # _dtoa.c, _fconv.c and strtod.c all include it and nothing else does.
    #
    # `#define CONST const' becomes an EMPTY macro, which is the whole fix for
    # `const' in this subtree: CONST is used only in strtod.c (three times), so
    # emptying the definition converts all three without touching that file's
    # text.  Gay wrote the macro for exactly this -- a 1991 header meant to
    # build on pre-ANSI compilers too.
    #
    # AND IT HAS TO BE AN OVERLAY .h WITH OVERLAY .c FILES BESIDE IT.
    # `#include "fconv.h"' is quoted, so it resolves against the INCLUDING
    # file's directory: a pristine _dtoa.c in $(SRC)/libc/stdio/ would find the
    # tape's fconv.h no matter what we install elsewhere.  Our copies sit in
    # $(OURS)/libc/stdio/ and find ours first -- which is why the header and its
    # three users convert together or not at all.
    ("libc/stdio/fconv.h",
     "9332aed85806f8f8a45039f3dc995d3854bd7aa7b98f405109fe8e13fd7bdf5c",
     [("#define CONST const\n",
       "#define CONST\t\t/* ipnx: pcc2 has no const -- see PATCHES.md */\n", 1),
      ("extern Bigint	*_Balloc(int);\nextern void	_Bfree(Bigint *);\n"
       "extern Bigint	*_multadd(Bigint *, int, int);\n"
       "extern int	_hi0bits(unsigned long);\n"
       "extern Bigint	*_mult(Bigint *, Bigint *);\n"
       "extern Bigint	*_pow5mult(Bigint *, int);\n"
       "extern Bigint	*_lshift(Bigint *, int);\n"
       "extern int	_cmp(Bigint *, Bigint *);\n"
       "extern Bigint	*_diff(Bigint *, Bigint *);\n"
       "extern Bigint	*_d2b(double, int *, int *);\n"
       "extern Bigint	*_i2b(int);\n",
       "/* ipnx: K&R declarations -- see PATCHES.md */\n"
       "extern Bigint	*_Balloc();\nextern void	_Bfree();\n"
       "extern Bigint	*_multadd();\n"
       "extern int	_hi0bits();\n"
       "extern Bigint	*_mult();\n"
       "extern Bigint	*_pow5mult();\n"
       "extern Bigint	*_lshift();\n"
       "extern int	_cmp();\n"
       "extern Bigint	*_diff();\n"
       "extern Bigint	*_d2b();\n"
       "extern Bigint	*_i2b();\n", 1)]),
    # _dtoa.c: 745 lines and only THREE declarations, because Gay's style puts
    # everything else in macros.  The body is untouched.
    ("libc/stdio/_dtoa.c",
     "451cddacdadac850e39486af1aaa62668824a1d25f6998f681e4372f2097a66c",
     [("static int quorem(Bigint *, Bigint *);\n",
       "static int quorem();\t\t/* ipnx: K&R, see PATCHES.md */\n", 1),
      ("_dtoa(double darg, int mode, int ndigits, int *decpt, int *sign, char **rve)\n",
       "_dtoa(darg, mode, ndigits, decpt, sign, rve)\t/* ipnx: K&R */\n"
       "\tdouble darg;\n\tint mode;\n\tint ndigits;\n"
       "\tint *decpt;\n\tint *sign;\n\tchar **rve;\n", 1),
      ("quorem(Bigint *b, Bigint *S)\n",
       "quorem(b, S)\n\tBigint *b;\n\tBigint *S;\n", 1)]),
    # _fconv.c and strtod.c: the other two users of fconv.h.  They MUST be
    # overlay files even though their own ANSI surface is small, because
    # `#include "fconv.h"' is quoted and resolves next to the including source --
    # a pristine copy in $(SRC)/libc/stdio/ finds the TAPE's header no matter
    # what, and the run that converted only fconv.h and _dtoa.c proved it:
    #	"$(SRC)/libc/stdio/fconv.h":220:syntax error
    # still, from these two, while _dtoa.o built.  The header and its three
    # users convert together or not at all.
    ("libc/stdio/_fconv.c",
     "d7aaa4c59e24c5b82f273be23d9dbdab4e9f3c06a3342d48531cc88260b1dfbc",
     [("_Balloc(int k)\n", "_Balloc(k)\n\tint k;\n", 1),
      ("_Bfree(Bigint *v)\n", "_Bfree(v)\n\tBigint *v;\n", 1),
      ("_multadd(Bigint *b, int m, int a)	/* multiply by m and add a */\n",
       "_multadd(b, m, a)	/* multiply by m and add a */\n"
       "\tBigint *b;\n\tint m;\n\tint a;\n", 1),
      ("_hi0bits(register unsigned long x)\n",
       "_hi0bits(x)\n\tregister unsigned long x;\n", 1),
      ("lo0bits(unsigned long *y)\n", "lo0bits(y)\n\tunsigned long *y;\n", 1),
      ("_i2b(int i)\n", "_i2b(i)\n\tint i;\n", 1),
      ("_mult(Bigint *a, Bigint *b)\n", "_mult(a, b)\n\tBigint *a;\n\tBigint *b;\n", 1),
      ("_pow5mult(Bigint *b, int k)\n", "_pow5mult(b, k)\n\tBigint *b;\n\tint k;\n", 1),
      ("_lshift(Bigint *b, int k)\n", "_lshift(b, k)\n\tBigint *b;\n\tint k;\n", 1),
      ("_cmp(Bigint *a, Bigint *b)\n", "_cmp(a, b)\n\tBigint *a;\n\tBigint *b;\n", 1),
      ("_diff(Bigint *a, Bigint *b)\n", "_diff(a, b)\n\tBigint *a;\n\tBigint *b;\n", 1),
      ("_d2b(double darg, int *e, int *bits)\n",
       "_d2b(darg, e, bits)\n\tdouble darg;\n\tint *e;\n\tint *bits;\n", 1)]),
    ("libc/stdio/strtod.c",
     "a15e37af35e7c179faf4e04c7815b720a4f52fa2e9b1cb7531a8e17ed35aefd1",
     [("ulp(double xarg)\n", "ulp(xarg)\n\tdouble xarg;\n", 1),
      ("s2b(CONST char *s, int nd0, int nd, unsigned long y9)\n",
       "s2b(s, nd0, nd, y9)\n\tCONST char *s;\n\tint nd0;\n\tint nd;\n"
       "\tunsigned long y9;\n", 1),
      # b2d WAS MISSED ON THE FIRST PASS, and by a truncated grep rather than by
      # anything subtle: two files were listed in one `grep | head -24' and
      # _fconv.c's eleven definitions used up the lines.  The build named it at
      # once ("strtod.c":116:syntax error / saw *), so nothing was lost -- but
      # when enumerating what to convert, count the matches instead of reading a
      # window of them.
      ("b2d(Bigint *a, int *e)\n", "b2d(a, e)\n\tBigint *a;\n\tint *e;\n", 1),
      ("ratio(Bigint *a, Bigint *b)\n", "ratio(a, b)\n\tBigint *a;\n\tBigint *b;\n", 1),
      # CONST SURVIVES IN THE PARAMETER DECLARATIONS, and that is deliberate:
      # fconv.h's `#define CONST' is now empty, so `CONST char *s;' expands to
      # `char *s;'.  Gay put the macro there for pre-ANSI compilers and it is
      # doing exactly its job -- leaving it in place keeps this file closer to
      # the tape than spelling the expansion out would.
      ("strtod(CONST char *s00, char **se)\n",
       "strtod(s00, se)\t\t/* ipnx: K&R, see PATCHES.md */\n"
       "\tCONST char *s00;\n\tchar **se;\n", 1)]),
    # vfprintf.c: printf's ENGINE, 556 lines -- and far more tractable than its
    # reputation, because it is REGULAR.  Fourteen conversion routines share one
    # signature to the character, so two edits with a count of 14 do most of the
    # work and the occurrence check proves the count rather than trusting it.
    # Only ocvt_fixed and ocvt_flt differ, and the body is untouched throughout.
    ("libc/stdio/vfprintf.c",
     "917adc4a529c72891f59c86d9f47e4db786d6b06b0be8094b799968f78f59d5f",
     [("(FILE *, va_list *, int, int, int);\n", "();\n", 14),
      ("(FILE *f, va_list *args, int flags, int width, int precision)\n",
       "(f, args, flags, width, precision)\t/* ipnx: K&R */\n"
       "\tFILE *f;\n\tva_list *args;\n\tint flags;\n\tint width;\n"
       "\tint precision;\n", 14),
      ("vfprintf(FILE *f, const char *s, va_list args)\n",
       "vfprintf(f, s, args)\t\t/* ipnx: K&R, see PATCHES.md */\n"
       "\tFILE *f;\n\tchar *s;\n\tva_list args;\n", 1),
      ("ocvt_fixed(FILE *f, va_list *args, int flags, int width, int precision,\n"
       "	int radix, int sgned, char alphabet[], char *prefix)\n",
       "ocvt_fixed(f, args, flags, width, precision, radix, sgned, alphabet, prefix)\n"
       "\tFILE *f;\n\tva_list *args;\n\tint flags;\n\tint width;\n"
       "\tint precision;\n\tint radix;\n\tint sgned;\n\tchar alphabet[];\n"
       "\tchar *prefix;\n", 1),
      ("static int ocvt_flt(FILE *, va_list *, int, int, int, char);\n",
       "static int ocvt_flt();\n", 1),
      # THE DISPATCH TABLE, which is the one place the parameter types are part
      # of a TYPE rather than a declaration: a 256-entry array of function
      # pointers indexed by conversion character.  pcc2 reads the prototype as a
      # second declaration of the array's element --
      #	  "112:syntax error / saw STRUCT" then "121:redeclaration of ocvt_E"
      # -- so the pointer loses its parameter list like every other declaration
      # here.  The 256 entries below it are untouched.
      ("static int(*ocvt[])(FILE *, va_list *, int, int, int) = {\n",
       "static int (*ocvt[])() = {\t/* ipnx: K&R, see PATCHES.md */\n", 1),
      ("ocvt_flt(FILE *f, va_list *args, int flags, int width, int precision, char afmt)\n",
       "ocvt_flt(f, args, flags, width, precision, afmt)\n"
       "\tFILE *f;\n\tva_list *args;\n\tint flags;\n\tint width;\n"
       "\tint precision;\n\tchar afmt;\n", 1)]),
    ("libc/gen/memmove.c",
     "8de6bd16b4d961d41eb7330816e04068b4ba391cedd55fdf95b05ab81a2280db",
     [("#include <stddef.h>\n\nextern void *memcpy(void*, void*, size_t);\n\n"
       "void *\nmemmove(void *to, void *from, register size_t n)\n{\n",
       "/* ipnx: r70 has no <stddef.h> and defines size_t nowhere -- PATCHES.md */\n\n"
       "extern char *memcpy();\n\n"
       "char *\nmemmove(to, from, n)\t\t/* ipnx: K&R, see PATCHES.md */\n"
       "\tchar *to;\n\tchar *from;\n\tregister unsigned int n;\n{\n", 1)]),
]

for _p, _sha, _edits in _ANSI93:
    _name = os.path.basename(_p)
    EDITS.append(dict(
        path=_p,
        sha=_sha,
        title="%s: a 1993 ANSI member, converted to K&R (B2.2d)" % _name,
        why="""\
One of the eleven members that only `lcc` could build, and `lcc` cannot be
trusted to: the prebuilt driver hits the `bowell.c` defect
(`0: unknown flag -undef`) and emits **empty objects while exiting 0**, so
routing a member to it buys a silent hole in `libc.a` rather than a member.

These carry `/* Copyright AT&T Bell Laboratories, 1993 */` and are addressed to
a header set that is not installed: r70's `/usr/include` has no `stddef.h`, no
`stdlib.h`, and defines `size_t` nowhere. That is the same two-generations split
as the stdio family, one layer down -- not a prototype to strip but a different
C to translate out of.

`void *` becomes `char *` and `size_t` becomes `unsigned int`. Both pairs are
the same width on a VAX, `char *` is K&R's generic pointer, and it is how V8's
own libc declares these functions -- so the generated code is unchanged and only
the spelling moves back eight years.""",
        edits=_edits,
    ))

for _p, _sha, _ansi, _knr in _FAMILY:
    _name = os.path.basename(_p)
    EDITS.append(dict(
        path=_p,
        sha=_sha,
        title="%s: an ANSI definition pcc2 cannot parse (B2.2c)" % _name,
        why="""\
One of the eight `printf`/`scanf` members that compile under **neither** of the
tree's compilers. The argument, the evidence and the choice of
`<lcc/stdarg.h>` are all set out under `libc/stdio/printf.c` -- in short:
`vfprintf.c` and `vfscanf.c` are the only two members of this family that
include `<stdarg.h>` themselves and the only two that build, so the missing
line is a per-file omission; and the subdirectory is named explicitly because
r70 has no top-level `stdarg.h` and `-I.../lcc` would shadow the system
`stdio.h`.

	%s

becomes an old-style parameter list. `...` goes because K&R varargs is
implicit, `const` because pcc2 has no such qualifier, and `fmt` stays last
because `va_start(args, fmt)` steps one slot past its address.""" % _ansi.rstrip(),
        edits=[('#include "iolib.h"\n',
                '#include "iolib.h"\n'
                '#include <lcc/stdarg.h>\t/* ipnx: as vfprintf.c does; see PATCHES.md */\n', 1),
               (_ansi, _knr, 1)],
    ))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------------------
# FILES THE TAPE HAS LOST, RECONSTRUCTED FROM THE TAPE (B2.2b).
#
# NOT the same kind of thing as EDITS, and the difference is worth keeping in
# the type system rather than in a comment: an EDITS entry is a named upstream
# file plus one stated substitution, and its sha256 makes the tool FAIL if the
# base ever changes.  A NEWFILES entry has no base -- upstream lost the file --
# so nothing can be checked that way and the honesty has to come from the
# evidence instead.  Hence `evidence': every claim in the file cites the
# artefact it was measured from, and anything not measurable is left out.
#
# THE RULE APPLIED HERE.  A field appears only if the tape states it or Bell
# Labs' own compiled code proves it.  Where neither does -- `struct sh_consts'
# in <sys/share.h> -- the header is NOT written and the member that needs it is
# left unbuilt, with the reason recorded.  Guessing a struct layout that a
# system call writes through would compile, link, and silently overwrite the
# caller's stack.
_LNODE_H = '''\
/*
 * sys/lnode.h -- kernel user shares structure, for the Share scheduler.
 *
 * RECONSTRUCTED BY ipnx.  This file is not in the v10src tarball, and neither
 * is <sys/share.h> or <sys/retlim.h>, although lsys/os/limits.C includes all
 * three -- the kernel half of the Share scheduler's headers is lost with the
 * userland half.  Every declaration below is quoted from the tape's own
 * manual, lnode(5), which prints the header verbatim under the words "The
 * layout as given in the include file is:", and every offset and size is
 * confirmed against Bell Labs' 1989 objects in libc.a.  See
 * v10/src/PATCHES.md for the disassembly.
 */

typedef	short	uid_t;

/*
 * Structure for active shares
 */
struct lnode
{
	uid_t	l_uid;		/* real uid for owner of this node */
	u_short	l_flags;	/* (see below) */
	u_short	l_shares;	/* allocated shares */
	uid_t	l_group;	/* uid for this node's scheduling group */
	float	l_usage;	/* decaying accumulated costs */
	float	l_charge;	/* long term accumulated costs */
};

/*
 * Meaning of bits in l_flags
 */
#define	ACTIVELNODE	001	/* this lnode is on active list */
#define	LASTREF		002	/* set for L_DEADLIM if last reference */
#define	DEADGROUP	004	/* group account is dead */
#define	CHNGDLIMITS	020	/* this lnode's limits have changed */
#define	NOTSHARED	040	/* this lnode gets no share of the m/c */

/*
 * Kernel user share structure
 */
typedef struct kern_lnode *	KL_p;

struct kern_lnode
{
	KL_p	kl_next;	/* next in active list */
	KL_p	kl_prev;	/* prev in active list */
	KL_p	kl_parent;	/* group parent */
	KL_p	kl_gnext;	/* next in parent's group */
	KL_p	kl_ghead;	/* start of this group */
	struct lnode	kl;	/* user parameters (as above) */
	float	kl_gshares;	/* total shares for this group */
	float	kl_eshare;	/* effective share for this group */
	float	kl_norms;	/* share**2 for this lnode */
	float	kl_usage;	/* kl.l_usage / kl_norms */
	float	kl_rate;	/* active process rate for this lnode */
	float	kl_temp;	/* temporary for scheduler */
	float	kl_spare;	/* <spare> */
	u_long	kl_cost;	/* cost accumulating in current period */
	u_long	kl_muse;	/* memory pages used */
	u_short	kl_refcount;	/* processes attached to this lnode */
	u_short	kl_children;	/* lnodes attached to this lnode */
};

/*
 * limits(2) functions.  From the table in limits(2); the starred ones are
 * super-user only.  L_SETLIM's value 3 is confirmed by setlimits.o.
 */
#define	L_MYLIM		0	/* get user's own limits structure */
#define	L_OTHLIM	1	/* get limits associated with uid in lnode */
#define	L_ALLLIM	2	/* all active limits structures are returned */
#define	L_SETLIM	3	/* connect to a new limits structure */
#define	L_DEADLIM	4	/* wait for dead limits belonging to child */
#define	L_CHNGLIM	5	/* change limits fields in existing limits */
#define	L_DEADGROUP	6	/* pick up a dead limits structure */
#define	L_GETCOSTS	7	/* get contents of system shconsts table */
#define	L_SETCOSTS	8	/* set contents of system shconsts table */
#define	L_MYKN		9	/* get user's own kern_lnode structure */
#define	L_OTHKN		10	/* get structure associated with uid */
#define	L_ALLKN		11	/* all active structures are returned */
'''

_SHARES_H = '''\
/*
 * shares.h -- format of an /etc/shares record.
 *
 * RECONSTRUCTED BY ipnx.  Not in the v10src tarball, although six libc members
 * include it.  shares(5) names this file and <sys/lnode.h> as the two that
 * define the record, and gives their installed paths as /usr/include/shares.h
 * and /usr/include/sys/lnode.h.  Every constant below is measured out of Bell
 * Labs' own 1989 objects in libc.a -- see v10/src/PATCHES.md.
 */

/*
 * <sys/types.h> FIRST, and here rather than in sys/lnode.h.  lnode.h uses
 * u_short and u_long, which r70's sys/types.h defines and which nothing in
 * lnode(5)'s printed text declares -- and the kernel's own includer,
 * lsys/os/limits.C, reaches lnode.h only after sys/param.h has already brought
 * types.h in.  So lnode.h expecting the caller to have done it matches the one
 * include order the tape shows, and shares.h is the userland caller that has
 * to do it: setlimits.c and getshput.c include <shares.h> and nothing else at
 * all.
 *
 * Getting this wrong cost a run: without it,
 *	"/usr/include/sys/lnode.h":22:syntax error / saw NAME
 * on `u_short l_flags;' -- line 22, not the uid_t line above it, which is the
 * detail that named the cause.
 */
#include	<sys/types.h>
#include	<sys/lnode.h>

#define	SHAREFILE	"/etc/shares"	/* the data base; shares(5) */
#define	MAXUID		10000		/* largest uid with a shares record */

#ifndef	SYSERROR
#define	SYSERROR	(-1)
#endif

/*
 * One record of /etc/shares, indexed by uid.  20 bytes: the 16-byte lnode
 * followed by the expiry time.
 */
typedef struct
{
	struct lnode	l;		/* the user's shares */
	unsigned long	extime;		/* last active time, 0 if never */
} Share;

extern int		ShareFd;	/* openshares(3) leaves it here */

extern unsigned long	getshares();
extern unsigned long	getshput();
extern int		openshares();
extern void		closeshares();
extern void		sharesfile();
extern int		putshares();
extern int		setlimits();
extern int		limits();
'''

NEWFILES = [
    dict(
        path="include/sys/lnode.h",
        title="sys/lnode.h: reconstructed, because lnode(5) prints it verbatim (B2.2b)",
        text=_LNODE_H,
        why="""\
Six libc members include `<shares.h>`, which includes `<sys/lnode.h>`, and
**neither file is anywhere in the 25,682**. Their objects are in the tape's
`libc.a`, so both existed; what survived is a source tree with two headers
missing from it.

This was written down as an unreachable ceiling -- "six members cannot be built
by anything, so the ceiling from source is 255" -- and that was wrong, because
it treated the *source tree* as the only evidence. **The tape also carries its
own manual, and `lnode(5)` reproduces this header field by field**, under the
words:

	The layout as given in the include file is:

followed by `struct lnode`, the five `l_flags` bits, `typedef short uid_t`, and
`struct kern_lnode` complete with comments. `limits(2)` supplies the twelve
`L_*` function numbers in a table. So the header is not being invented from its
consumers -- it is being read out of the documentation, which is exactly the
rule this project already applies to member order: where the tape's own
artefacts can settle a question, they do.

**And the manual is then checked against the machine code**, because a manual
can drift from a header and a compiled object cannot. Every field's offset and
width is confirmed in Bell Labs' 1989 objects; the evidence is below.

`<sys/share.h>` and `<sys/retlim.h>` are missing too and are **not**
reconstructed: nothing on the tape states their layout. That costs exactly one
member -- see `setupshares` in the notes below.""",
        evidence="""\
Disassembled from the tape's own `libc.a` members (VAX, `0407`), which were
compiled against the real header in June 1989.

`putshares.o`, text 104 bytes:

	c2 14 5e            subl2 $20, sp          Share share;      -> sizeof(Share) = 20
	b1 6b 8f 10 27      cmpw  (r11), $10000    lp->l_uid > MAXUID -> MAXUID = 10000
	28 10 6b 60         movc3 $16, (r11), (r0) share.l = *lp;    -> sizeof(lnode) = 16
	d0 ac 08 ad fc      movl  8(ap), -4(fp)    share.extime      -> extime at offset 16
	32 6b 50            cvtwl (r11), r0        l_uid is a SIGNED word at offset 0
	c5 14 50            mull2 $20, r0          sizeof(Share) * uid
	dd 14               pushl $20              write(..., sizeof(Share))

`getshares.o`, text 152 bytes -- the six-field zeroing gives every offset at
once:

	b0 ac 08 6b         movw  8(ap), (r11)     lp->l_uid    = uid    offset  0, word
	b4 ab 02            clrw  2(r11)           lp->l_flags  = 0      offset  2, word
	b4 ab 04            clrw  4(r11)           lp->l_shares = 0      offset  4, word
	b4 ab 06            clrw  6(r11)           lp->l_group  = 0      offset  6, word
	50 ef 7c 00 00 00 ab 08   movf ..., 8(r11) lp->l_usage  = 0      offset  8, float
	50 ef 78 00 00 00 ab 0c   movf ..., 12(r11) lp->l_charge = 0     offset 12, float
	d1 ac 08 8f 10 27 00 00   cmpl 8(ap), $10000                     MAXUID again

`setlimits.o`, text 76 bytes:

	c2 10 5e            subl2 $16, sp          struct lnode gl;  -> sizeof(lnode) = 16
	b5 ab 06            tstw  6(r11)           lp->l_group != 0  -> offset 6, word
	dd 03 / dd 5b       pushl $3; pushl r11    limits(lp, L_SETLIM) -> L_SETLIM = 3

`openshares.o` carries the filename as a string constant: **`/etc/shares`**,
which is also what `shares(5)` and `openshares(3)` name under FILES.

Every one of `lnode(5)`'s six fields lands where the manual says it does, the
two sizes agree at five independent sites, and `L_SETLIM` agrees with
`limits(2)`'s table. The reconstruction is measured, not inferred.

**WHAT IS NOT RECONSTRUCTED, and why the sixth member stays unbuilt.**
`setupshares.c` also includes `<sys/share.h>` for a `struct sh_consts`, and
that struct is documented nowhere: `share(5)` describes the *algorithm* and
never prints the header, `limits(2)` mentions the name and no field, and
**`sh_consts` appears nowhere in `lsys/` or `sys/`** -- so even the kernel we
have does not reference it. `setupshares.o`'s prologue is `subl2 $144, sp`,
which bounds it but does not give a layout, and `setupshares()` uses no field of
it -- only `limits((struct lnode *)&shconsts, L_GETCOSTS)`, a call that has the
KERNEL write through that pointer. An opaque array of a guessed size would
compile, link, and overwrite the caller's stack if the size were wrong by a
single word. So it is left out, and the count is **260 of 261**, not 261.""",
    ),
    dict(
        path="include/shares.h",
        title="shares.h: reconstructed, with every constant measured (B2.2b)",
        text=_SHARES_H,
        why="""\
The header the six `libc/gen` share routines include. `shares(5)` names it --
"other scheduling data as defined in the files `<shares.h>` and
`<sys/lnode.h>`" -- and gives its installed path as `/usr/include/shares.h`,
which is where our build puts it; no makefile change is needed because
`$(INCS)` already names that directory.

Its contents are fixed by what the six sources use and by what the compiled
1989 objects prove:

  * `Share` -- `putshares.c` writes `share.l = *lp; share.extime = extime;` and
    seeks `sizeof(Share) * uid`, so it is a struct of an `lnode` and an
    `unsigned long`. The object gives 20 bytes with `extime` at offset 16,
    which is that layout exactly and no padding.
  * `MAXUID` -- compiled as an immediate `$10000` in both `putshares.o` and
    `getshares.o`.
  * `SHAREFILE` -- `openshares.c` initialises `ShareFile = SHAREFILE` and the
    object's only string is `/etc/shares`.
  * `SYSERROR` -- `(-1)`, the tree's own spelling (`cmd/hdr/defs.h`), guarded
    by `#ifndef` because `setupshares.c` defines it again itself.
  * the function declarations -- return types straight out of `getshares(3)`,
    `getshput(3)`, `openshares(3)`, `putshares(3)`, `sharesfile(3)` and
    `setlimits(3)`; all K&R, so no prototype and no parameter list, which is
    both what pcc2 accepts and what a 1989 header would have said.

The six sources are already pure K&R and need no conversion -- their failure
was never a language problem, which is why five of them come back the moment
the header exists.""",
        evidence="""\
See `sys/lnode.h` above: the same four objects prove `sizeof(Share) = 20`,
`extime` at offset 16, and `MAXUID = 10000`, and `openshares.o` carries
`/etc/shares` as its only string constant.

The one thing here that is a *convention* rather than a measurement is
`SYSERROR (-1)`: it is not visible in an object (`d0 8f ff ff ff ff 50` is
`movl $-1, r0`, which proves the value but not the spelling), and the tree
defines it identically in three other places -- `cmd/hdr/defs.h`,
`cmd/cyntax/cyn/defs.h`, `cmd/cyntax/cem/cem.h` -- plus a fourth time inside
`setupshares.c`. The `#ifndef` guard is there because of that fourth one.""",
    ),
]


def build():
    """-> {relpath: text}, doc text, list of (path, note) problems."""
    files, docs, problems = {}, [], []
    for n in NEWFILES:
        files[n["path"]] = n["text"]
        docs.append((n, None, None))
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
        if got is None:
            # A RECONSTRUCTION, and it says so in the heading rather than
            # looking like a patch.  There is no base sha256 to quote because
            # there is no base -- so the evidence is quoted instead, and the
            # file itself is shown whole rather than as a diff against nothing.
            out.append("**Reconstructed: upstream has no such file.** "
                       "`%s`\n\n" % e["path"])
            out.append(e["why"])
            out.append("\n\n### Evidence\n\n")
            out.append(e["evidence"])
            out.append("\n```c\n%s```\n\n" % e["text"])
        else:
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
