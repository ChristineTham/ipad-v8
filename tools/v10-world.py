#!/usr/bin/env python3
"""K10: survey the Tenth Edition's WORLD before trying to build it.

    tools/v10-world.py                  the summary
    tools/v10-world.py --units          every unit, one per line
    tools/v10-world.py --headers        which headers are missing, and to whom
    tools/v10-world.py --unit NAME      everything known about one unit
    tools/v10-world.py --write          write v10/mk/gen/world.txt
    tools/v10-world.py --check          ... or fail if it is out of date

WHY A HOST-SIDE SURVEY COMES FIRST.  B1 and B2.0 were both won by putting the
decisive measurement ahead of the machinery, and the same argument applies with
more force here: K10 is ~283 commands, so a guest run that compiles the world
costs hours, while the question "which of these can even find their headers"
is a one-second question on the host.  tools/v10-syscalls.py is the model --
it answered "which syscalls does a V10 program get wrong on a V8 kernel" from
two tables and saved a boot per answer.

WHAT THIS CAN AND CANNOT TELL YOU.  It resolves #include directives against
the header set we actually install, so a unit reported MISSING will certainly
fail, and for a stated reason.  A unit reported OK has only cleared that one
hurdle -- it may still fail to parse.  That asymmetry is deliberate: this tool
exists to shrink the guest run, not to predict its result.

THE ANSI COLUMN IS A HEURISTIC AND IS LABELLED AS ONE.  CLAUDE.md's rule --
"a failure under compiler X is not evidence that compiler Y would succeed" --
has a corollary: a REGEX is not evidence that either compiler fails.  jterm.o
spent two runs listed as an lcc member on exactly this kind of inference.  So
the ANSI count is printed as a hint about where the conversion work will land
and is never used to exclude a unit from the build.

THE INCLUDE SCAN USES THE LOOSE REGEX, WHICH IS NOT OPTIONAL.  V10's cpp.c
opens with `# include <libc.h>' -- a space after the hash, ordinary 1970s
style and common in this tree.  A scan matching a bare "#include" misses those
and then reports every header present, which cost a whole boot once.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "work", "v10", "src")
CMD = os.path.join(SRC, "cmd")
R70 = os.path.join(ROOT, "work", "v10", "include")
# The 5620's include tree, from the v10blit tarball rather than v10src.
# tools/v10-srcdisk.exp already copies all 21 headers to the source disk and
# the machine sees them at /usr/jerq/include -- which is why jterm.c's absolute
# "/usr/jerq/include/jioctl.h" resolves there.  Leaving this out made the
# survey report dict, dis, view2d and omovie as blocked over files we ship.
JERQ = os.path.join(ROOT, "work", "v10", "blit", "include")
JERQ_INC = "/usr/jerq/include"
OURS = os.path.join(ROOT, "v10", "src")
GEN = os.path.join(ROOT, "v10", "mk", "gen")

# The space after the hash is the whole point -- see the module docstring.
#
# THE ANCHORING BUG THIS TOOL SHIPPED WITH, and why re.M is no longer what
# protects against it.  The first version scanned each file with finditer() and
# no re.M, so `^' anchored to offset 0 of the whole file and an include was
# found only in a file whose very FIRST character began one.  Every other file
# reported zero includes, hence zero missing headers, hence "clean" -- it
# announced 348 of 351 commands able to resolve every header when the figure
# was 327 and most files had not been read at all.  Same failure family as the
# ^-anchored grep that dropped `MMISS atof.o' and the spliced tty that inflated
# the byte-identical count: the error ran in the FLATTERING direction, which is
# why it read as a result instead of a bug.
#
# includes_of() now walks line by line, and .match() anchors at the start of
# the string it is given, so the flag is inert here -- kept only so the pattern
# reads correctly if it is ever used against whole text again.  What actually
# prevents a recurrence is sanity(), which refuses to PRINT a measurement taken
# through a scan that read implausibly little.  A guard beats a comment.
INCLUDE = re.compile(r'^[ \t]*#[ \t]*include[ \t]*([<"])([^>"]+)[>"]', re.M)

# The same loose-hash rule, applied to the conditionals, because an include
# inside a block that is never compiled is not a missing header.
#
# cmd/sh/service.c:555 includes "acctdef.h", which exists NOWHERE on the tape
# -- and it sits inside `#ifdef ACCT', process accounting, off in any ordinary
# build.  Counting it as missing made the shell look unbuildable when the tape
# ships a working prebuilt binary of it.  So every include is recorded with the
# conditional depth it was found at, and only depth-0 includes can block a
# unit.  This error ran PESSIMISTIC, the opposite way from the re.M bug, which
# is safer and still wrong.
COND_IF = re.compile(r'^[ \t]*#[ \t]*(if|ifdef|ifndef)\b[ \t]*(.*)$')
COND_END = re.compile(r'^[ \t]*#[ \t]*endif\b')

# A command is a unit with a main().  K&R style, so the definition may be
# `main(argc, argv)' or `main()' at the start of a line, optionally preceded
# by a return type on the same line.
MAIN = re.compile(r'^(?:int[ \t]+|void[ \t]+)?main[ \t]*\(', re.M)

# Constructs V10's pcc2 cannot parse.  A HINT, never a verdict.
ANSI_HINTS = [
    (re.compile(r',[ \t]*\.\.\.[ \t]*\)'), "varargs prototype"),
    (re.compile(r'\bvoid[ \t]*\*'),        "void *"),
    (re.compile(r'\bconst\b'),             "const"),
    (re.compile(r'\bsize_t\b'),            "size_t"),
    (re.compile(r'\bvolatile\b'),          "volatile"),
    (re.compile(r'^[ \t]*#[ \t]*include[ \t]*<stdarg\.h>', re.M), "<stdarg.h>"),
]

# Headers stage 2 installs into /usr/include from r70's variant directories,
# on the argument recorded in CLAUDE.md: the tape ships four copies of each and
# the job is to pick the one pcc2 parses, not to write one.  Listed here so the
# survey resolves exactly what the machine will have, not what r70 contains.
#
# K10.1b EXTENDS THE SAME DECISION PAST libc's THREE, and the extension is
# smaller than the candidate list because most of the candidates are not C.
# Measured, one variant at a time, with installable() below rather than by eye:
#
#   stddef.h  7 units   lcc/  CC/  olcc/     all three parse; lcc's is chosen
#                       because it GUARDS its size_t typedef (_SIZE_T/_SIZE_T_)
#                       and the other two typedef unconditionally -- so lcc's
#                       is the only one that can be installed beside another
#                       header doing the same without a redeclaration error.
#   limits.h  3 units   lcc/  CC/           both parse; lcc's is chosen on
#                       correctness -- CC's says `INT_MIN 0x80000000', which is
#                       an UNSIGNED constant in C, where lcc's says
#                       `(-INT_MAX-1)'.
#   u.h       1 unit    olcc/  libc/        olcc's parses; libc's declares an
#                       ANONYMOUS STRUCT inside a union, which pcc2 has no
#                       syntax for.  cmd/lp uses the typedefs and not `Length',
#                       so olcc's macro form of it costs nothing.
#
# AND FOUR CANDIDATES ARE NOT A LAYOUT QUESTION AT ALL, which is the finding
# rather than a shortfall -- r70's only copy of each is written in a language
# this compiler does not speak, so they need converting like the printf family
# and are deliberately absent from this table:
#
#   malloc.h  2 units   CC/ only, and it is C++     -- `extern "C" {'
#   memory.h  2 units   CC/ only, and it is C++     -- `extern "C" {' + void *
#   sysent.h  1 unit    CC/ is C++, oCC/ is ANSI prototypes throughout
#   locale.h  1 unit    lcc/ only, ANSI prototypes  -- `char *setlocale(int,
#                                                      const char *);'
INSTALLED_EXTRA = {
    "stdlib.h": "CC/stdlib.h",
    "float.h": "lcc/float.h",
    # CC's, not lcc's, and the reason is one character -- lcc's va_arg macro
    # says `3U' and pcc2 lexes the ANSI suffix as an identifier.  Recorded in
    # full in tools/v10-stage2.exp; this table said `lcc/stdarg.h' for a week
    # while the machine had CC's, which is the kind of drift inc_extra() and the
    # cross-check in sanity() now make impossible.
    "stdarg.h": "CC/stdarg.h",
    "stddef.h": "lcc/stddef.h",
    "limits.h": "lcc/limits.h",
    "u.h": "olcc/u.h",
    # `ours:' is a path under v10/src/, not a choice among r70's copies: these
    # two are reconstructions from the tape's own manual (lnode(5), limits(2),
    # shares(5)) checked against Bell Labs' machine code.  sys/lnode.h is here
    # even though no unit includes it directly -- shares.h does, and a header
    # the machine has must be a header this table knows about, or the
    # cross-check below has a hole exactly the size of the drift it exists to
    # catch.
    "shares.h": "ours:include/shares.h",
    "sys/lnode.h": "ours:include/sys/lnode.h",
}
OURS_PREFIX = "ours:"

# What disqualifies a variant header from being installed, as a test instead of
# a judgement.  CLAUDE.md's rule is that a failure under one compiler is no
# evidence about another, and its corollary is that a REGEX is not evidence
# either -- so this is not used to predict a unit's fate.  It is used for one
# narrow thing: to refuse to ADD a header to INSTALLED_EXTRA that pcc2 provably
# cannot read, because that decision is ours and it lands on all 356 units at
# once.  sanity() asserts every entry above passes it.
NOT_C = [
    (re.compile(r'extern[ \t]+"C"'),                  'extern "C" -- C++'),
    (re.compile(r'\bvoid[ \t]*\*'),                   "void *"),
    (re.compile(r'\bconst\b'),                        "const"),
    # A prototype: a declarator whose parameter list holds a TYPE rather than
    # bare K&R names.  Anchored on the opening paren so `foo(a, b)' does not
    # match and `foo(int a, char *b)' does.
    (re.compile(r'\w[ \t]*\([ \t]*(?:const[ \t]+)?'
                r'(?:void|char|short|int|long|float|double|unsigned|signed|'
                r'size_t|FILE)\b[^)]*\)[ \t]*;'),     "an ANSI prototype"),
    # A tagless `struct { ... };' as a union member -- pcc2 has no syntax for
    # it.  \s and not [ \t]: libc/u.h puts the brace on the NEXT LINE, and with
    # the tighter class this test passed a header it should have rejected.
    (re.compile(r'\bstruct\s*\{[^}]*\}\s*;', re.S), "an anonymous struct"),
    # AN ANSI `U' SUFFIX, WHICH THIS TEST WOULD OTHERWISE MISS ENTIRELY, and
    # stage 2 found it the hard way.  lcc/stdarg.h is pure #defines and so
    # PARSES by every test above -- but its macro body says
    #   _littleendian_va_arg(list, mode, 3U)
    # and pcc2 lexes `3U' as 3 followed by the identifier U.  The header
    # compiles; the EXPANSION fails, hundreds of lines away in whichever source
    # used va_arg, reported as `syntax error / saw NAME'.  `L' is deliberately
    # not matched: K&R has the long suffix, and lcc/limits.h's 0xffffffffL is
    # fine.  This is the one place where the test reaches past the header's own
    # syntax, and it is here because a measurement demanded it.
    (re.compile(r'\b0[xX][0-9a-fA-F]+[uU]|\b[0-9]+[uU]'), "an ANSI U suffix"),
]


def installable(text):
    """None if pcc2 could read this header, else why not.

    Comments are stripped first: `/* extern const char* ctermid(...) */' in
    oCC/sysent.h is commented out on the tape and would otherwise disqualify a
    header on the strength of a line no compiler ever sees.
    """
    live = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    for pat, why in NOT_C:
        if pat.search(live):
            return why
    return None

# r70 keeps several headers ONLY inside a compiler's variant directory --
# include/lcc/, include/CC/, include/olcc/, include/oCC/, include/libc/ -- and
# never at top level.  A unit wanting one of those is not blocked by a missing
# file: it is asking a SYSTEM-LAYOUT question, exactly the one stdlib.h asked
# and INSTALLED_EXTRA answered.  Reporting those separately from genuinely
# absent headers is the difference between "convert this source" and "decide
# which of the tape's four copies belongs at /usr/include", which are entirely
# different pieces of work.
VARIANT_DIRS = ["lcc", "CC", "olcc", "oCC", "libc"]

# ---------------------------------------------------------------- generators ---
# yacc and lex, which the survey did not run and therefore could not survey.
#
# csources() takes .c files, so a unit whose grammar is a .y was measured with
# the grammar left out -- and nine units then reported `missing:y.tab.h', a
# header yacc WRITES.  That is not a fact about the tape; it is the survey
# declining to run step one of the build.
#
# FOUR SUFFIXES, NOT TWO, and the fourth is why this is driven off the makefiles
# rather than off a suffix list alone: cmd/ratfor's grammar is `r.g' and
# cmd/ipa's lexer is `ipa_trans.lex'.  A scan looking for *.y and *.l finds
# neither, and ratfor's makefile says `yacc -d r.g' in as many words.
GEN_SUF = (".y", ".l", ".g", ".lex")

# Files the generators need that are not source and have no suffix at all, so
# neither sources() nor the copy manifest would carry them.
#
# lex's DRIVER SKELETON.  lex emits `#include "ncform"'-worth of table-driven
# machinery by copying /usr/lib/lex/ncform, and the golden has no /usr/lib/lex at
# all -- so every lex row failed with
#
#	(Error) Lex driver missing, file /usr/lib/lex/ncform
#
# and the harness's install of it failed one line earlier with `No such file or
# directory', because world.cpio carries only .c/.h/.s and grammars.  Two
# failures, one cause, and the second was invisible behind the first.  yacc needs
# no equivalent here: its skeleton is already on the golden.
GEN_DATA = ["lex/ncform"]
BUILD_FILES = ["mkfile", "makefile", "Makefile"]
MACRO_DEF = re.compile(r'^([A-Za-z_][A-Za-z_0-9]*)[ \t]*=[ \t]*(.*)$')
MACRO_USE = re.compile(r'\$\{([A-Za-z_][A-Za-z_0-9]*)\}'
                       r'|\$\(([A-Za-z_][A-Za-z_0-9]*)\)'
                       r'|\$([A-Za-z_][A-Za-z_0-9]*)')

# THE TAPE'S OWN FLAGS, AND THEY ARE UNIFORM.  Sixteen makefiles write
# `yacc -d' and four write `$YACC $YFLAGS' over `YFLAGS = -d'; not one asks for
# anything else.  So -d is the tape's answer and not our preference -- which
# matters, because -d is exactly what makes y.tab.h appear.
YACC_DEFAULT = "-d"
LEX_DEFAULT = ""

# The names yacc and lex write.  Used to tell a recipe that TRANSFORMS the
# generated source from one that merely renames it.
GEN_OUT = re.compile(r'\b(y\.tab\.[ch]|lex\.yy\.c)\b')


def macros_of(text):
    """Top-level NAME = value definitions, ignoring recipe lines."""
    out = {}
    for line in text.splitlines():
        if line.startswith("\t") or line.lstrip().startswith("#"):
            continue
        mo = MACRO_DEF.match(line)
        if mo:
            out[mo.group(1)] = mo.group(2)
    return out


def expand(s, macros, depth=0):
    """Substitute ${X}, $(X) and bare $X, bounded against a cycle."""
    if depth > 6 or "$" not in s:
        return s
    def sub(mo):
        name = mo.group(1) or mo.group(2) or mo.group(3)
        return macros.get(name, "")
    return expand(MACRO_USE.sub(sub, s), macros, depth + 1)


def gen_recipes(d):
    """Every yacc/lex invocation the unit's build files actually contain.

    Returns {basename: (tool, flags, redirected)}.

    THE TOOL MUST BE THE COMMAND, NOT MERELY A WORD ON THE LINE.  The first
    version matched any token whose basename was `yacc' or `lex', which found
    three links -- `cc lmain.o y.tab.o ... -o lex' in cmd/lex, and
    `$(CC) -o yacc y?.o' in cmd/yacc and cmd/picasso.  Every one of those is the
    program being LINKED, and reading them as generator invocations would have
    had the survey run `lex' over a unit that has no lexer.  A tool name in
    argument position is not a tool being run.
    """
    out = {}
    # THE UNIT ROOT IS NOT WHERE THE MAKEFILE ALWAYS IS.  cmd/ccom holds only
    # common/ and vax/, and it is vax/makefile that carries the yacc recipe --
    # with the `sed' that makes cgram.c.  Reading the root alone found no recipe
    # at all, fell back to the default, and emitted a plain yacc row for a unit
    # whose generated source is post-processed; our own ccom.mk has done it
    # correctly since stage 1.  Same bounded set sources() walks, for the same
    # reason: any other machine's directory is another machine's build.
    dirs = [d] + machine_dirs(d)
    for b, d0 in [(b, x) for x in dirs for b in BUILD_FILES]:
        p = os.path.join(d0, b)
        if not os.path.isfile(p):
            continue
        text = read(p)
        macros = macros_of(text)
        # A RECIPE IS A BLOCK, NOT A LINE, and reading it line by line missed
        # the whole point in two units.  cmd/ccom runs `yacc $M/cgram.y' and
        # then `sed s_^# line .*_/* & */_ y.tab.c >cgram.c' on the NEXT line;
        # cmd/2500 runs yacc and then edits y.tab.c with `ed'.  Judged one line
        # at a time both look like a plain yacc invocation, and the survey would
        # have compiled a generated source the tape never compiles.
        for block in blocks_of(text):
            lines = [expand(x, macros) for x in block]
            whole = "\n".join(lines)
            hit = None
            for body in lines:
                if body.startswith("#"):
                    continue
                toks = body.split()
                # A recipe may open with make's own prefixes, and V10's mk uses
                # them: `-' ignore-status, `@' quiet.
                if toks and toks[0][0] in "-@" and len(toks[0]) > 1:
                    toks = [toks[0].lstrip("-@")] + toks[1:]
                while toks and toks[0] in ("-", "@", "-@", "@-"):
                    toks = toks[1:]
                if not toks:
                    continue
                tool = os.path.basename(toks[0])
                if tool not in ("yacc", "lex"):
                    continue
                infile, flags = None, []
                for t in toks[1:]:
                    if t.startswith(">"):
                        break
                    if t.endswith(GEN_SUF):
                        infile = t
                    elif t.startswith("-"):
                        flags.append(t)
                if infile is not None:
                    hit = (os.path.basename(infile), tool, " ".join(flags), body)
                    break
            if hit is None:
                continue
            base, tool, flags, invocation = hit
            # WHAT DISQUALIFIES A ROW IS A CHANGED FILE, NOT A CHANGED NAME, and
            # the first version of this test could not tell them apart: it
            # flagged any `>' anywhere in the block, which caught cmd/cpp's
            # `mv y.tab.c cpy.c'.  A rename is nothing -- our own cpp.mk does
            # exactly that, and compiling the same bytes under either name tests
            # the same thing.  A `sed' or an `ed' over the generated source is
            # everything, because then the file the compiler sees is not the
            # file the generator wrote.
            post = None
            if ">" in invocation:
                # The tool's own output redirected -- cmd/2500's
                # `lex -t lex.l > lex.c', where -t makes lex write to stdout.
                post = "redirects its output"
            else:
                for line in lines:
                    if not GEN_OUT.search(line):
                        continue
                    verb = os.path.basename(line.split()[0]) if line.split() else ""
                    if verb in ("sed", "ed"):
                        post = "passes the output through " + verb
                        break
            out.setdefault(base, (tool, flags, post))
    return out


def blocks_of(text):
    """Recipe blocks: the runs of tab-indented lines that follow a target.

    Bounded to contiguous runs, which is what make itself does -- a
    non-indented line ends the recipe.
    """
    out, cur = [], []
    for line in text.splitlines():
        if line.startswith("\t"):
            cur.append(line.strip())
        elif cur:
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def generators(u):
    """The unit's generator inputs, as (tool, file, flags, object, note).

    Suffix scan for the FILES, makefiles for the FLAGS -- and in that order,
    because most of this tree has no explicit yacc line at all: awk, eqn, grap,
    hoc, pic and make all leave it to make's built-in .y suffix rule, so a
    makefile-only scan finds a third of them and reports the rest as having no
    grammar.  Where a recipe does exist it governs, since it is the tape stating
    what it does with its own source.
    """
    if not u.root:
        return []
    recipes = gen_recipes(u.root)
    out = []
    for p in u.paths:
        if not p.endswith(GEN_SUF):
            continue
        base = os.path.basename(p)
        tool, flags, post = recipes.get(
            base, ("yacc" if base.endswith((".y", ".g")) else "lex", None, None))
        if flags is None:
            flags = YACC_DEFAULT if tool == "yacc" else LEX_DEFAULT
        elif tool == "yacc" and "-d" not in flags.split():
            # y.tab.h is what -d writes, and six units include it.  A makefile
            # omitting -d is building only the .c; adding it costs nothing and
            # is what the other twenty makefiles ask for.
            flags = (flags + " " + YACC_DEFAULT).strip()
        # THE OBJECT IS THE GENERATOR'S NATURAL OUTPUT, NOT A NAME WE INVENT.
        # The first version wrote `<grammar>.o', and cmd/config proves that
        # wrong twice over: its OBJS line names `y.tab.o' and `lex.yy.o'
        # outright, and deriving from the grammar gave config.y and config.l
        # the SAME object -- a collision that would have had one silently
        # overwrite the other.  Units that do rename (eqn's `mv y.tab.o
        # eqn.o') only matter to a LINK, and this survey does not link.
        obj = "y.tab.o" if tool == "yacc" else "lex.yy.o"
        note = post + " -- needs its own recipe" if post else "-"
        # A UNIT WITH A GENERATED MAKEFILE ALREADY HAS ITS GENERATOR STEP
        # DESCRIBED, correctly, and by something stronger than this.  ccom, cpp
        # and yacc are in tc.order and are built by stages 1 to 3 from
        # v10/mk/gen/<name>.mk, which carries the tape's own recipe -- ccom.mk
        # runs yacc and then seds y.tab.c into cgram.c, cpp.mk renames it to
        # cpy.c.  A generic row here is strictly weaker and, for those two,
        # simply wrong.
        #
        # It also removes the one row this survey had no business emitting:
        # cmd/ccom/common/sty.y, a grammar named in NO object list in ccom's
        # makefile.  Its row turned a unit that had compiled cleanly for two
        # phases into a failure -- 241 units became 232 -- which is a harness
        # artefact dressed as a regression.  The row is reported as skipped and
        # not dropped, because a silent drop is how a unit goes missing.
        if os.path.exists(os.path.join(GEN, u.name + ".mk")):
            note = "v10/mk/gen/%s.mk describes this properly" % u.name
        out.append((tool, os.path.relpath(p, u.root), flags, obj, note))
    rows = sorted(out, key=lambda r: r[1])
    # A second grammar in one unit writes over the first's y.tab.c.  Only two
    # units do it -- cmd/gcc (cexp.y, parse.y) and cmd/ccom (cgram.y, sty.y) --
    # and both are named rather than merged, because "compile them in sequence
    # and see" produces one object from two grammars and no warning.
    kept, taken = [], {}
    for tool, f, flags, obj, note in rows:
        if note == "-" and obj in taken:
            note = ("a second %s source; %s already writes %s"
                    % (tool, taken[obj], obj))
        elif note == "-":
            taken[obj] = f
        kept.append((tool, f, flags, obj, note))
    return kept

# Directories under cmd/ that are plainly not a single command.  Kept as data
# with a reason each, because "it has no main()" already classifies most of
# them and these are the ones where that test alone would mislead.
NOT_A_COMMAND = {
    "lost+found": "an fsck artefact that came out on the tape",
    "hdr": "shared headers for the commands, not a program",
    "Admin": "release paperwork",
    "dist": "the Datakit distribution system, its own subtree",
    "odist": "the previous generation of the same",
}


def read(path):
    """Text of a file, tolerating the tape's stray 8-bit bytes."""
    try:
        with open(path, "rb") as fh:
            return fh.read().decode("latin-1")
    except (IOError, OSError):
        return ""


def sources(d):
    """The .c/.h/.s and generator files of one directory, not recursing.

    `.g' and `.lex' are here for exactly two files -- cmd/ratfor/r.g and
    cmd/ipa/ipa_trans.lex -- and both are load-bearing: without them the copy
    manifest leaves the grammar behind and the unit fails on the guest for a
    reason the host cannot see.
    """
    out = []
    try:
        for n in sorted(os.listdir(d)):
            if n.endswith((".c", ".h", ".s") + GEN_SUF):
                p = os.path.join(d, n)
                if os.path.isfile(p):
                    out.append(p)
    except OSError:
        pass
    return out


def machine_dirs(d):
    """Subdirectories that hold a unit's OWN sources.

    Three conventions in this tree, and each is here because a unit needs it:
      vax, vax-v9   the machine's code -- cmd/ccom/vax/, cmd/adb/vax/.
                    Anything else (mips, sun, 3b, cray, 68v) is another
                    machine's and is deliberately NOT scanned or copied.
      common        shared between machines -- cmd/ccom/common/, whose own
                    makefile says `INCLIST=-I. -I../common'.
      src           matlab and netnews keep everything under src/.

    Bounded on purpose: a recursive walk would drag in six other
    architectures' code and make every count meaningless.
    """
    out = []
    for n in ("vax", "vax-v9", "common", "src"):
        p = os.path.join(d, n)
        if os.path.isdir(p):
            out.append(p)
    return out


class Unit(object):
    """One buildable thing under cmd/ -- a loose file or a directory."""

    def __init__(self, name, kind, paths, root=None):
        self.name = name
        self.kind = kind              # "file" or "dir"
        self.root = root              # unit directory, for sibling includes
        self.paths = paths            # the source files we scanned
        self.includes = []            # (bracket, header) as written
        self.missing = []             # UNCONDITIONALLY absent -- blocks the unit
        self.conditional = []         # (header, guard) absent but behind an #if
        self.foreign = []             # (header, where) only in another unit
        self.variant = []             # only under r70's lcc/CC/... -- a decision
        self.hints = []               # ANSI constructs found, by label
        self.has_main = False
        self.mains = []               # the .c files carrying a main()
        self.overlay = False          # do we already carry a patched copy?
        self.gen = []                 # (tool, file, flags, object, note)
        self.made = set()             # headers the generators WRITE

    @property
    def ok(self):
        return not self.missing


def resolve(header, bracket, unit_dirs, unit_root=None, made=()):
    """Where would the guest find this header?  None if nowhere.

    The search order is cc's: for "..." the including file's own directory
    first, then the system path; for <...> the system path only.  The system
    path is r70's /usr/include plus the headers stage 2 installs there.

    SIBLING DIRECTORIES ARE PART OF THE CONVENTION, NOT AN EXCEPTION, and
    leaving them out made this tool report ccom as unbuildable -- a component
    stage 3 proves is a FIXPOINT.  cmd/ccom/vax/makefile says
    `INCLIST=-I. -I../common' in its own words, and adb (comm/), lint
    (../pcc1/mip) and several others do the same.  So a unit's search path is
    its own directory plus its siblings, and the return value names which one,
    because that string IS the -I the makefile needs.
    """
    # A header the unit's OWN generators write, which is where the nine
    # `missing:y.tab.h' verdicts came from.  This is checked before anything
    # else because the generated copy is the one the build compiles against:
    # eight units also ship a stale y.tab.h beside the grammar (a build
    # artefact that came out on the tape, the same reading the 46 prebuilt
    # binaries get), and the recipe regenerates it either way.
    if header in made:
        return "generated"
    if header.startswith("/"):
        # /usr/include/... is the SYSTEM path spelled the long way, and it
        # resolves on a real guest -- cmd/strings.c writes
        # "/usr/include/a.out.h" where every other unit writes <a.out.h>.
        # Missing this made a buildable command look blocked.
        if header.startswith("/usr/include/"):
            rest = header[len("/usr/include/"):]
            if os.path.exists(os.path.join(R70, rest)):
                return "r70 (absolute /usr/include)"
            return None
        # The 5620 tree, which the source disk installs -- see JERQ.
        if header.startswith(JERQ_INC + "/"):
            rest = header[len(JERQ_INC) + 1:]
            if os.path.exists(os.path.join(JERQ, rest)):
                return "v10blit (absolute %s)" % JERQ_INC
            return None
        # Any other absolute path is into another tree -- jterm.c's
        # "/usr/jerq/include/jioctl.h" is the known case, and it is in the
        # v10blit tarball rather than v10src, so no include path can help.
        rel = header.lstrip("/")
        for base in (SRC, os.path.join(ROOT, "work", "v10")):
            if os.path.exists(os.path.join(base, rel)):
                return "absolute: " + header
        return None
    if bracket == '"':
        for d in unit_dirs:
            if os.path.exists(os.path.join(d, header)):
                return "local"
        # Siblings, in a bounded walk of the unit's own directory only.
        if unit_root and os.path.isdir(unit_root):
            for base, _dirs, files in os.walk(unit_root):
                if header in files:
                    return "-I" + os.path.relpath(base, unit_root)
        # NOTE: the search across OTHER units happens at the very end, after
        # the system path.  Putting it here -- which is where it started --
        # resolved ccom's `#include "stdio.h"' to
        # cmd/lcc/include/sparc_sun/stdio.h, a SUN header, and did the same for
        # cbt, cflow, cfront, chuck, dimpress, du and btree.  54 units were
        # resolved only that way and most of those resolutions were nonsense,
        # so the survey reported them ready on the strength of a file no build
        # would ever reach.  cpp searches the including file's directory and
        # then the SYSTEM path; it does not search other programs' source
        # directories.  See foreign_include().
    if header in INSTALLED_EXTRA:
        return "installed: " + INSTALLED_EXTRA[header]
    if os.path.exists(os.path.join(R70, header)):
        return "r70"
    # Our own overlay ships include/ too (shares.h today).
    if os.path.exists(os.path.join(OURS, "include", header)):
        return "ours"
    # The 5620 headers are on the machine but NOT on cc's default path, so a
    # unit reaching for <jerq.h> needs the -I spelled out -- same shape as
    # -I../common, and the return value is the flag to write.
    if os.path.exists(os.path.join(JERQ, header)):
        return "-I" + JERQ_INC + " (v10blit)"
    # Only inside a compiler's variant directory: a layout decision, not an
    # absent file.  See VARIANT_DIRS.
    for v in VARIANT_DIRS:
        if os.path.exists(os.path.join(R70, v, header)):
            return "VARIANT: r70 include/%s/%s" % (v, header)
    # The kernel trees carry 1995 copies of several headers.  Reaching them
    # needs a -I, so this is reported distinctly rather than as a plain hit.
    for k in ("lsys", "sys"):
        if os.path.exists(os.path.join(SRC, k, header)):
            return "kernel-tree (needs -I)"
    # LAST, AND REPORTED AS ITS OWN CLASS.  Some units really do include across
    # the tree -- lint takes `manifest' and `mfile1' from pcc1/mip -- but a file
    # merely EXISTING somewhere under cmd/ is not something a build can find,
    # and treating it as a hit is what let a Sun stdio.h satisfy ccom.  So this
    # runs only once everything a compiler would actually search has failed,
    # and its answer is a lead to follow, not a resolution.
    if bracket == '"':
        who = foreign_include(header)
        if who:
            return "FOREIGN: only in cmd/%s" % who
    return None


def foreign_include(header):
    """Where else under cmd/ does this header exist?  Relative path or None."""
    for n in sorted(os.listdir(CMD)):
        p = os.path.join(CMD, n)
        if not os.path.isdir(p):
            continue
        for base, _dirs, files in os.walk(p):
            if header in files:
                return os.path.relpath(base, CMD)
    return None


def includes_of(text):
    """Every include in one file, as (bracket, header, guard).

    guard is None for an include the compiler always sees, or the text of the
    innermost #if/#ifdef controlling it.  No attempt is made to EVALUATE the
    condition -- we do not know what the makefile defines -- so this separates
    "always needed" from "maybe needed" and no more than that.
    """
    out = []
    stack = []
    for line in text.splitlines():
        m = COND_IF.match(line)
        if m:
            stack.append(m.group(2).strip()[:40] or m.group(1))
            continue
        if COND_END.match(line):
            if stack:
                stack.pop()
            continue
        m = INCLUDE.match(line)
        if m:
            out.append((m.group(1), m.group(2), stack[-1] if stack else None))
    return out


def scan(unit):
    """Fill in a unit's generators, includes, missing headers, hints and main()."""
    unit.gen = generators(unit)
    for tool, _f, _fl, _o, note in unit.gen:
        # ONLY THE ROWS THE GUEST WILL ACTUALLY RUN.  A skipped generator writes
        # nothing, so counting its output as present is the same drift that had
        # this tool resolving stdlib.h against a machine that did not have it --
        # the host's model must be what the guest does, not what it could do.
        if note != "-":
            continue
        if tool == "yacc":
            # -d writes both, and several units include the .h under an alias
            # they cp it to -- prevy.tab.h (awk, eqn, grap) and x.tab.h (hoc).
            # Those are the same file under another name, so the recipe that
            # makes y.tab.h makes them too.
            unit.made |= set(["y.tab.h", "y.tab.c",
                              "prevy.tab.h", "x.tab.h"])
        else:
            unit.made.add("lex.yy.c")
    dirs = sorted(set(os.path.dirname(p) for p in unit.paths))
    seen = set()
    for p in unit.paths:
        text = read(p)
        if MAIN.search(text):
            unit.has_main = True
            if p.endswith(".c"):
                unit.mains.append(os.path.basename(p))
        for pat, label in ANSI_HINTS:
            if pat.search(text) and label not in unit.hints:
                unit.hints.append(label)
        for bracket, header, guard in includes_of(text):
            key = (bracket, header)
            if key in seen:
                continue
            seen.add(key)
            unit.includes.append(key)
            where = resolve(header, bracket, dirs, unit.root, unit.made)
            if where is None or where.startswith("FOREIGN"):
                # A FOREIGN hit is not a resolution -- see resolve().  It is
                # recorded so the reason is visible, and still counts against
                # the unit, because a build cannot reach it as written.
                if guard is None:
                    if header not in unit.missing:
                        unit.missing.append(header)
                    if where and header not in unit.foreign:
                        unit.foreign.append((header, where))
                elif header not in unit.conditional:
                    unit.conditional.append((header, guard))
            elif where.startswith("VARIANT") and header not in unit.variant:
                unit.variant.append(header)
    unit.missing.sort()
    unit.variant.sort()


def overlay_paths():
    """Files we already carry a corrected copy of, relative to src/."""
    out = set()
    for base, _dirs, files in os.walk(OURS):
        for f in files:
            rel = os.path.relpath(os.path.join(base, f), OURS)
            out.add(rel)
    return out


def inventory():
    """Every command unit under cmd/, classified."""
    if not os.path.isdir(CMD):
        sys.exit("v10-world: no %s -- run tools/v10-import.py" % CMD)
    over = overlay_paths()
    units = []
    # TWO GENERATIONS OF THE SAME COMMAND LIVE SIDE BY SIDE, and naming them
    # both `ed' made one silently shadow the other in every count.
    #
    # cmd/ed.c and cmd/ed/ are both on the tape, and mkdep.py already recorded
    # which is which: the loose file "has no prototype in it, so pcc2 can
    # compile it, while the cmd/ed/ version is the POSIX rewrite".  Same for
    # sort.  This is the libc two-generations-of-stdio pattern appearing in the
    # command tree, so it is a finding to report rather than an ambiguity to
    # resolve by picking one.  A directory whose name collides with a loose .c
    # is therefore named `ed/', and collisions() prints them.
    loose = set(n[:-2] for n in os.listdir(CMD)
                if n.endswith(".c") and os.path.isfile(os.path.join(CMD, n)))
    for n in sorted(os.listdir(CMD)):
        p = os.path.join(CMD, n)
        if os.path.isfile(p) and n.endswith(".c"):
            u = Unit(n[:-2], "file", [p])
            u.overlay = os.path.join("cmd", n) in over
            units.append(u)
        elif os.path.isdir(p) and n not in NOT_A_COMMAND:
            paths = sources(p)
            for md in machine_dirs(p):
                paths += sources(md)
            if not paths:
                continue
            u = Unit(n + "/" if n in loose else n, "dir", paths, root=p)
            u.overlay = any(x.startswith(os.path.join("cmd", n) + os.sep)
                            for x in over)
            units.append(u)
    for u in units:
        scan(u)
    return units


def sanity(units):
    """Refuse to report a measurement taken through a broken scan.

    tools/v10-syscalls.py refuses to run on a short parse for exactly this
    reason: a scan that understands less than it thinks reports a clean result,
    and a clean result is indistinguishable from a real one.  This tool has
    already made that mistake once -- a missing re.M turned "almost no file was
    read" into "348 of 351 commands are fine".

    Two independent checks, because either alone can be satisfied by accident:
    a C program essentially always includes something, and this tree's units
    average many includes each.  Both thresholds are far below any plausible
    real value, so they catch a broken scan without being sensitive to which
    units exist.
    """
    total = sum(len(u.includes) for u in units)
    silent = [u for u in units if not u.includes]
    problems = []
    if total < 2 * len(units):
        problems.append("only %d includes across %d units (under 2 each) -- the "
                        "scan is not reading the sources" % (total, len(units)))
    if len(silent) > len(units) // 4:
        problems.append("%d of %d units report NO includes at all"
                        % (len(silent), len(units)))
    # Every variant header we claim the machine will have must be one pcc2 can
    # actually read.  This decision lands on all 356 units at once -- an
    # unparseable /usr/include/stddef.h fails every unit that includes it and
    # would read as a language fact about the tape -- so it is asserted here
    # rather than trusted to the comment above the table.
    for h, src in sorted(INSTALLED_EXTRA.items()):
        if src.startswith(OURS_PREFIX):
            p = os.path.join(OURS, src[len(OURS_PREFIX):])
            if not os.path.exists(p):
                problems.append("INSTALLED_EXTRA names %s, which the overlay "
                                "does not carry" % src)
            continue                      # ours, so its own review governs it
        p = os.path.join(R70, src)
        if not os.path.exists(p):
            problems.append("INSTALLED_EXTRA names %s, which r70 does not have"
                            % src)
            continue
        why = installable(read(p))
        if why:
            problems.append("INSTALLED_EXTRA installs %s as <%s> and it carries "
                            "%s -- pcc2 cannot read it" % (src, h, why))
    # THE OBJECT NAME IS A BASENAME, so two sources of the same name in two of a
    # unit's directories compile to ONE object and the second silently overwrites
    # the first.  Today that is cmd/ccom alone -- memcpy.c, printx.c and reader.c
    # exist in both common/ and vax/ -- and ccom has a generated makefile that
    # names each explicitly, so nothing is measured wrongly.  The guard is here
    # for the day that stops being true: a silent overwrite would show up as a
    # unit that compiles and a program that behaves oddly, with nothing in
    # between to read.
    for u in units:
        if os.path.exists(os.path.join(GEN, u.name + ".mk")):
            continue                       # its own makefile names each source
        seen = {}
        for rel in csources(u):
            seen.setdefault(os.path.basename(rel), []).append(rel)
        for b, where in sorted(seen.items()):
            if len(where) > 1:
                problems.append("%s has %d sources called %s (%s) and no "
                                "generated makefile -- they would compile to one "
                                "object, silently"
                                % (u.name, len(where), b, ", ".join(where)))

    # And it must agree with the copies stage 2 actually performs.  This table
    # said `lcc/stdarg.h' while the machine had CC's for a week; both parse, so
    # nothing failed and nothing said so.  Only the headers stage 2 touches are
    # compared -- it predates the extension and is not expected to install
    # stddef.h, limits.h or u.h.
    s2 = dict((dst, src) for src, dst in STAGE2_CP.findall(read(STAGE2)))
    for dst, src in sorted(s2.items()):
        want = INSTALLED_EXTRA.get(dst)
        if want is None:
            problems.append("v10-stage2.exp installs <%s> and INSTALLED_EXTRA "
                            "does not list it" % dst)
        elif not want.startswith(OURS_PREFIX) and want != src:
            problems.append("v10-stage2.exp installs %s as <%s>, this table says "
                            "%s -- one of them is describing a machine that does "
                            "not exist" % (src, dst, want))
    if problems:
        sys.stderr.write("v10-world: NO MEASUREMENT --\n")
        for p in problems:
            sys.stderr.write("  %s\n" % p)
        sys.stderr.write("  A survey that reads nothing reports everything as "
                         "clean.  Fix the scan, not the threshold.\n")
        sys.exit(2)
    return total, silent


def prebuilt():
    """Basenames with a prebuilt 1995 binary -- the oracle, from the generator."""
    out = set()
    p = os.path.join(GEN, "prebuilt.txt")
    for line in read(p).splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.add(line.split()[0])
    return out


def report(units, pre):
    total, silent = sanity(units)
    cmds = [u for u in units if u.has_main]
    libs = [u for u in units if not u.has_main]
    ok = [u for u in cmds if u.ok]
    bad = [u for u in cmds if not u.ok]

    print("=== the Tenth Edition's world, as it stands on the tape ===")
    print("  units under cmd/            %4d  (%d loose .c, %d directories)"
          % (len(units),
             len([u for u in units if u.kind == "file"]),
             len([u for u in units if u.kind == "dir"])))
    print("  of those, with a main()     %4d  <- commands" % len(cmds))
    print("  without one                 %4d  (libraries, subsystems, data)"
          % len(libs))
    print("  carrying a prebuilt binary  %4d  <- the oracle, never a shortcut"
          % len([u for u in cmds if u.name in pre]))
    print("  we already patch             %4d" % len([u for u in units if u.overlay]))
    print("  #include lines read        %6d  (%d units include nothing)"
          % (total, len(silent)))
    dup = sorted(u.name for u in units if u.name.endswith("/"))
    if dup:
        print("  the tape ships TWICE        %4d  %s"
              % (len(dup), " ".join(d[:-1] for d in dup)))
        print("      -- a loose .c AND a directory of the same name.  mkdep.py "
              "builds the")
        print("         loose one for ed: K&R, which pcc2 parses; the directory "
              "is the POSIX")
        print("         rewrite.  Two generations in one tree, as with stdio in "
              "libc.")
    print()
    var = [u for u in cmds if u.variant]
    print("=== can each command find its headers? ===")
    print("  every #include resolves     %4d  of %d" % (len(ok), len(cmds)))
    print("  at least one does not       %4d" % len(bad))
    print("  needs a VARIANT header      %4d  <- a layout decision, not a "
          "missing file" % len(var))
    print("  absent only behind an #if   %4d  <- not blocked; e.g. sh's "
          "#ifdef ACCT" % len([u for u in cmds if u.conditional]))
    print()
    if var:
        print("=== headers r70 keeps only under lcc/ CC/ olcc/ oCC/ libc/ ===")
        vh = {}
        for u in var:
            for h in u.variant:
                vh.setdefault(h, []).append(u.name)
        for h, who in sorted(vh.items(), key=lambda kv: (-len(kv[1]), kv[0])):
            print("  %-22s %3d  %s" % (h, len(who), " ".join(sorted(who)[:8])))
        print("  Same question stdlib.h asked and INSTALLED_EXTRA answered.")
        print()

    # The histogram is the actionable half: one missing header usually blocks
    # many units, exactly as stdlib.h blocked six libc members.
    hist = {}
    for u in bad:
        for h in u.missing:
            hist.setdefault(h, []).append(u.name)
    print("=== the missing headers, worst first ===")
    for h, who in sorted(hist.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:15]:
        names = " ".join(sorted(who)[:6])
        more = "" if len(who) <= 6 else " +%d more" % (len(who) - 6)
        print("  %-22s %3d  %s%s" % (h, len(who), names, more))
    print()

    hh = {}
    for u in cmds:
        for label in u.hints:
            hh[label] = hh.get(label, 0) + 1
    print("=== ANSI constructs, a HINT and not a verdict ===")
    for label, n in sorted(hh.items(), key=lambda kv: -kv[1]):
        print("  %-22s %3d commands" % (label, n))
    print()
    clean = [u for u in cmds if u.ok and not u.hints]
    print("  commands with resolvable headers AND no ANSI hint  %4d" % len(clean))
    print("  -- the set most likely to compile untouched, and where K10 starts")


def csources(u):
    """The unit's .c files, deduplicated, relative to src/."""
    return sorted(set(os.path.relpath(p, SRC)
                      for p in u.paths if p.endswith(".c")))


def status(u):
    """One word for where a unit stands, plus the reason.

    `nosrc' exists so a unit whose sources this model does not find can never
    be reported as passing.  A compile survey that runs `cc -c' over an empty
    file list succeeds trivially, which is the same shape as the empty objects
    lcc produced while exiting 0 -- and CLAUDE.md's rule there applies here:
    an absent failure is not a success.
    """
    if not csources(u) and not u.gen:
        return "nosrc", "no .c found under the unit -- not surveyed"
    if u.missing:
        return "blocked", "missing:" + ",".join(u.missing)
    if u.variant:
        return "variant", "variant:" + ",".join(u.variant)
    return "ready", "-"


def world_txt(units, pre):
    """The survey as a generated file: reviewable in a diff, greppable in a run.

    Same convention as v10/mk/gen/prebuilt.txt and libc.ord -- a generator
    plus --check, so the repo's copy cannot silently drift from the tree it
    describes.  Kept to one kind of thing per file, after the destdirs.txt
    lesson: a name, three columns, no second meaning smuggled in by a tab.
    """
    out = [
        "# The Tenth Edition's world: every command unit under cmd/.",
        "#",
        "# Generated by tools/v10-world.py; check with --check.  Columns are",
        "# name, kind, whether a prebuilt 1995 binary exists as an ORACLE, and",
        "# status -- ready / variant / blocked, with the reason.",
        "#",
        "# `variant' is not a defect: r70 keeps the header only inside a",
        "# compiler's directory (include/lcc/, include/CC/, ...), so it is the",
        "# system-layout question stdlib.h asked and stage 2 answered.",
        "# A name ending in `/' is a DIRECTORY unit whose name also exists as a",
        "# loose .c -- the tape ships two generations, and they are not the",
        "# same program.",
        "#",
    ]
    for u in sorted(units, key=lambda x: x.name):
        st, why = status(u)
        out.append("%-18s %-5s %-4s %-8s %s"
                   % (u.name, u.kind, "yes" if u.name in pre else "no", st, why))
    return "\n".join(out) + "\n"


def world_cpio(units):
    """The copy manifest: every file the survey needs, relative to src/cmd.

    Fed to `cpio -p' on its stdin, which is exactly the shape of a generated
    manifest -- one process for the whole tree instead of 353.  The same
    argument v8/mk retired 400 individual `cp's with.

    Paths are relative to src/cmd because that is where cpio is run from, and
    `-d' then creates every subdirectory that appears in the list, so no mkdir
    loop is needed either.
    """
    want = set()
    for u in units:
        for p in u.paths:
            want.add(os.path.relpath(p, CMD))
    # The generators' data files -- see GEN_DATA.  Added by name and checked to
    # exist, because a manifest naming a file the tape does not have makes cpio
    # fail for the whole set rather than for that one entry.
    for rel in GEN_DATA:
        if os.path.exists(os.path.join(CMD, rel)):
            want.add(rel)
        else:
            sys.exit("v10-world: GEN_DATA names cmd/%s, which the tape does not "
                     "have -- cpio would fail for the whole manifest" % rel)
    return "\n".join(sorted(want)) + "\n"


def world_units(units):
    """One row per unit: name, directory, then its .c files.

    THREE FIELDS AND A TAIL, WHICH IS ONE KIND OF THING PER ROW.  v8's
    destdirs.txt held two kinds told apart by a leading tab, and the 1985 shell
    split on IFS before the marker was ever seen -- 458 files became empty
    directories.  Here every row is a unit with the same shape, so
    `while read name dir srcs' is reading what it looks like it is reading and
    there is no second meaning hiding in the whitespace.

    Units with no .c are omitted rather than emitted empty: a row the guest
    would turn into `cc -c' with no arguments is a trivial pass.
    """
    out = [
        "# Every surveyed command unit: name, directory under src/cmd, sources.",
        "#",
        "# Generated by tools/v10-world.py; check with --check.  Read by the",
        "# guest as `while read name dir srcs', so the row is three fields and",
        "# a tail -- see the function comment for why that matters here.",
        "#",
        "# A `.' directory means a loose .c directly under cmd/.  A name ending",
        "# in `/' is a directory unit colliding with a loose .c of the same",
        "# name -- two generations, not one program.",
        "#",
    ]
    for u in sorted(units, key=lambda x: x.name):
        srcs = csources(u)
        d = "." if u.kind == "file" else os.path.relpath(u.root, CMD)
        if not srcs:
            # A unit whose ONLY source is a grammar -- cmd/expr is expr.y and a
            # header, cmd/ipa is ipa_trans.lex.  These had no row at all, so the
            # survey never visited them: not reported as failing, simply absent,
            # which is the quietest way for a measurement to be incomplete.
            # `-' rather than an empty tail, because a row that ends after two
            # fields cannot be told from a truncated one.
            if not u.gen:
                continue
            out.append("%s %s -" % (u.name, d))
            continue
        rel = [os.path.relpath(os.path.join(SRC, s), os.path.join(CMD, d))
               for s in srcs]
        out.append("%s %s %s" % (u.name, d, " ".join(sorted(rel))))
    return "\n".join(out) + "\n"


LFLAG = re.compile(r'-l([A-Za-z0-9_]+)')
WHERE = os.path.join(ROOT, "v10", "mk", "where.txt")
LIBS_UNITS = os.path.join(GEN, "libs.units")
# Unresolved in where.txt, and the file says why it is left that way: "a command
# installed to the wrong directory is invisible until something cannot find it,
# and by then the disk is built."  A staged install still has to put it
# somewhere, so the destination is /usr/bin and the row records that the choice
# was ours -- which is what lets the report count the guesses.
DEST_DEFAULT = "/usr/bin"


def where():
    """{command: (directory, provenance)} from v10/mk/where.txt."""
    out = {}
    for line in read(WHERE).splitlines():
        if not line or line.startswith("#"):
            continue
        f = line.split("\t")
        if len(f) < 3:
            continue
        out[f[0]] = (f[1] or DEST_DEFAULT, f[2] if f[1] else "default")
    return out


def answerable():
    """The -l names /usr/lib can answer, read off K10.2's own install column.

    Not typed out here: v10/mk/gen/libs.units is generated by tools/v10-libs.py
    and carries every name each archive is installed under -- libtermlib alone
    answers both -ltermcap and -ltermlib from one build.  A second list of the
    same thing is a list that will disagree, which cost a stage-1 run when
    BUILDTOOLS appeared in both mkdep.py and v10-stage1.exp.
    """
    out = set(["c"])                       # libc, which stage 2 built
    for line in read(LIBS_UNITS).splitlines():
        if not line or line.startswith("#"):
            continue
        for inst in line.split()[5:]:
            m = re.match(r'lib([A-Za-z0-9_]+)\.a$', inst)
            if m:
                out.add(m.group(1))
    return out


def link_libs(u):
    """The -l flags this unit's own build files ask for, in the order written.

    A MAKEFILE'S -l LIST IS NO MORE A STATEMENT ABOUT V10 THAN ITS CC LINE IS,
    which K10.2 measured rather than assumed: thirteen of the names the command
    tree asks for exist nowhere in the tarball -- -lbsd (13 uses), -lport (7),
    -lether, -lmodel, -lgc, -ld (4 each), -lresolv, -ltroff, -layout, -lcoexpr,
    -large, -lsocket, -lpost -- the fingerprint of makefiles written for other
    machines, the same evidence as cmd/lcc/include/sparc_sun/.  So the flags are
    recorded as the tape writes them and the report says which can be answered;
    they are not filtered here, because a link that fails for a named absent
    library is a finding and a link quietly missing a library is a defect.
    """
    if not u.root:
        return []
    order = []
    for d in [u.root] + machine_dirs(u.root):
        for b in BUILD_FILES:
            p = os.path.join(d, b)
            if not os.path.isfile(p):
                continue
            text = read(p)
            macros = macros_of(text)
            for line in text.splitlines():
                if not line.startswith("\t"):
                    continue
                body = expand(line.strip(), macros)
                if not is_link(body):
                    continue
                for name in LFLAG.findall(body):
                    if name not in order:
                        order.append(name)
    return order


# Commands that take a -l flag and are not linking.  Both of these were found in
# the output rather than reasoned about, which is why the list is short and
# specific rather than a guess at what else might exist.
NOT_LINKERS = ("lint", "pr", "lex", "yacc", "nm", "size", "ar", "ranlib")


def is_link(body):
    """Is this recipe line a LINK?

    A -l ON A LINE THAT IS NOT A LINK IS NOT A LIBRARY, and taking every -l in
    the makefile gave two false positives immediately:

        cmd/config   pr -l57 main.c config.y ... | netlpr -c vpr
        cmd/efl      lint -p *.c -lS

    `pr -l57' is a page length and `lint -lS' names a lint library.  Recorded as
    -l57 and -lS they would have been reported as libraries the tarball does not
    provide -- two more entries in a list whose whole value is that every name in
    it is real.  Same shape as reading `cc ... -o lex' as an invocation of lex:
    the flag is in argument position to something else.

    The test is the COMMAND, with one fallback: a makefile that never defines CC
    leaves `$(CC)' expanding to nothing, so the first token becomes an object
    file.  In that case a line carrying `-o' and not `-c' is a link.
    """
    toks = body.split()
    if toks and toks[0][0] in "-@" and len(toks[0]) > 1:
        toks = [toks[0].lstrip("-@")] + toks[1:]
    while toks and toks[0] in ("-", "@", "-@", "@-"):
        toks = toks[1:]
    if not toks:
        return False
    cmd = os.path.basename(toks[0])
    if cmd in NOT_LINKERS:
        return False
    if cmd in ("cc", "ld", "CC"):
        return "-c" not in toks
    return "-o" in toks and "-c" not in toks


def world_link(units):
    """What each unit links against and where it is installed.

    THREE FIELDS AND A TAIL, again: name, destination directory, how the
    destination was decided, then the -l flags.  The OBJECT list is deliberately
    absent -- it is world.units plus world.gen, both of which the guest already
    reads, and restating it here would be the third copy of a list this project
    has already watched disagree with itself.

    `-' for a unit with no -l flags at all, which is most of them: the loose .c
    files under cmd/ have no makefile, and cat, ls, mv and their kind need
    nothing but libc.
    """
    dest = where()
    out = [
        "# What each command links against, and where it installs.",
        "#",
        "# Generated by tools/v10-world.py; check with --check.  Read by the",
        "# guest as `while read name dir how libs' -- the flags are the tail.",
        "#",
        "# The destination comes from v10/mk/where.txt, whose third column says",
        "# on whose authority: mk (the tape's own install rule), man (V10's",
        "# manual), v8 (measured off a real Eighth Edition disk) or default",
        "# (ours, because it had to go somewhere).  The install is STAGED under a",
        "# DESTDIR, so nothing here overwrites the golden's own binaries -- the",
        "# 46 prebuilt commands stay available as the oracle they are.",
        "#",
    ]
    skipped = []
    for u in sorted(units, key=lambda x: x.name):
        if not csources(u) and not u.gen:
            continue
        if u.name.endswith("/"):
            # THE SECOND GENERATION, WHICH IS NOT A PROGRAM WE BUILD.  The tape
            # ships `ed' and `sort' twice -- a loose .c and a directory of the
            # same name -- and mkdep.py builds the loose one, which is K&R and
            # which pcc2 parses; the directory is the POSIX rewrite.  Two
            # generations, not one program, exactly as with stdio in libc.
            #
            # A ROW WOULD ALSO BREAK THE LINK MECHANICALLY, and that is the part
            # worth stating: the name carries a trailing slash, so `cc -o ed/'
            # writes to a directory that does not exist and `cp ed/ .../ed/'
            # cannot work either.  The failure would be reported as a unit that
            # would not link -- a harness artefact dressed as a finding, which is
            # the error this project keeps having to unpick.  And they would
            # install over the loose one's binary besides.
            skipped.append("# SKIPPED %-10s the second generation of `%s'; "
                           "mkdep.py builds the loose .c"
                           % (u.name, u.name.rstrip("/")))
            continue
        if len(u.mains) > 1:
            # A cmd/ DIRECTORY IS NOT NECESSARILY A COMMAND, and this is the
            # measurement that says so: 71 of the units carry more than one
            # main() among their .c files.  cmd/worm has 22, cmd/qsnap 17,
            # cmd/uucp 11 -- these are subsystems, not programs, and `compact'
            # is the small clear case (compact.c and uncompact.c, two programs
            # with no shared code).
            #
            # LINKING ALL THE OBJECTS TOGETHER WOULD FAIL on `multiply defined
            # _main', and that failure would be reported as a unit that will not
            # link -- a harness artefact dressed as a finding.  The obvious
            # repair is worse than the skip: pairing each main with ALL the
            # unit's other objects would give cmd/awk a `maketab' carrying the
            # whole of awk, because ld pulls in every .o it is named.  Which
            # objects belong to which program is in each unit's own makefile, and
            # writing those out is mkdep.py-scale work -- which is exactly why
            # the boot path has generated makefiles and this survey does not.
            #
            # So they are named, with the count, and left for the phase that
            # generates a makefile per program.
            skipped.append("# SKIPPED %-10s %d main() functions -- a subsystem, "
                           "not a program: %s"
                           % (u.name, len(u.mains), " ".join(sorted(u.mains))))
            continue
        if not u.mains and not u.gen:
            # No main() at all: nothing to link into a program.  The generator
            # exception matters -- cmd/expr's main IS its grammar, so its main()
            # is in expr.y and no .c carries one.
            skipped.append("# SKIPPED %-10s no main() in any .c -- not a program"
                           % u.name)
            continue
        d, how = dest.get(u.name, (DEST_DEFAULT, "default"))
        libs = link_libs(u)
        out.append("%s %s %s %s" % (u.name, d, how,
                                    " ".join("-l" + x for x in libs) or "-"))
    if skipped:
        out.append("#")
        out.extend(skipped)
    return "\n".join(out) + "\n"


# The survey's guest half.  Generated rather than hand-written because it has
# to live in v10/mk/gen/ to reach the source disk, and everything in there is
# generated and --check'd; a hand-edited file among them is one mkdep.py could
# overwrite without anyone noticing.
#
# FIVE THINGS IN HERE ARE SCAR TISSUE, each from a documented failure:
#   * no grep, no wc, no tail -- the V10 golden has none of them (measured
#     against prebuilt.txt).  sed does the filtering.
#   * markers spelled through shell variables, so the tty's echo of the command
#     carries `$P' and only the RESULT carries the token.  An echoed literal
#     defeats matching either way round.
#   * objects are written to $OBJ, never beside the source: the source disk is
#     a courier and a build that writes to it changes its srcid, so the next
#     stage would refuse it.
#   * every .o is removed per unit, so 353 units cost no more space than one.
#   * A CANARY RUNS FIRST.  If the compiler flags are wrong, all 353 units fail
#     and that reads like a finding about V10 rather than a mistake in the
#     harness -- so one file known to build is compiled before the loop, and a
#     failure there prints NOCANARY and stops.  Same argument as sanity() on
#     the host side: a measurement taken through a broken instrument must
#     refuse to print a number.
WORLDC = r'''#!/bin/sh
# K10.1: compile every surveyed command unit and say which ones built.
# GENERATED by tools/v10-world.py -- do not edit here.
#
#	sh worldc.sh <srcroot> <objdir> <ccpath> <bprefix> <yacc> <lex> [destdir]
#
# srcroot  the mounted courier disk, e.g. /n/v10
# objdir   scratch on a WRITABLE filesystem, e.g. /usr/k10obj
# ccpath   the driver, /bin/cc
# bprefix  stage 1's passes, e.g. /usr/s1/lib/
# yacc     stage 1 builds it -- /usr/s1/bin/yacc
# lex      the golden's prebuilt one -- /usr/bin/lex (there is no lex source
#          pass in stage 1, and prebuilt.txt records the binary at usr/bin/lex)
# destdir  K10.3 ONLY.  Given, each unit that compiles is then LINKED and
#          INSTALLED under this prefix; absent, this is K10.1's compile-only
#          survey and behaves exactly as it did.
#
# ONE SCRIPT, TWO PHASES, for the reason v10-boot780.sh gives for one harness
# driving two simulators: the assertions cannot drift between "it compiles" and
# "it compiles and links" if the compiling is done by the same lines.  It also
# buys a cross-check nothing else provides -- K10.3's built count must equal
# K10.1's, and any difference is a fault in one of the two runs rather than a
# finding.
SRC=$1
OBJ=$2
CCP=$3
BP=$4
YACC=$5
LEX=$6
DEST=$7
UD=$SRC/src/cmd
JQ=$SRC/jerq
CF="-O -c"
CC="$CCP -B$BP -t02p"
# NO -c, AND NO -B EITHER, AND THE SECOND HALF IS NOT AN OVERSIGHT.  V10's cc
# has three -t letters -- 0 (ccom), 2 (c2) and p (cpp) -- and that is all
# cmd/cc.c handles; a, l and c were added to V8's cc.c by this project in S5.
# So on V10 there is no way to point cc at another `ld', `crt0.o' or `libc.a',
# and a link here necessarily uses the system's.  That is stated rather than
# worked around: the question K10.3 asks is whether the commands link against
# the libraries K10.2 built and installed in /usr/lib, and they do so through
# the machine's own ld.  -B is kept for the compile passes, where it does work.
CCL="$CCP -B$BP -t02p"

P=CBUILT
Q=CFAILED
N=CNOSRC
K=CANARY
SP=SPACE
G=CGEN
L=CLINKED
LN=CNOLINK
I=CINSTALL
IN=CNOINST
ND=CNODEST

rm -rf $OBJ
mkdir $OBJ
cd $OBJ

# ----------------------------------------------------------------- space ---
# A SECOND CANARY, FOR ROOM, because the first run of this survey died of a
# full filesystem 22 units in and kept going for hours -- the kernel printing
# `/mnt2: file system full' every few seconds while every remaining unit failed
# for a reason that had nothing to do with the Tenth Edition.  A wrong image is
# as fatal as wrong flags and was not being checked.
#
# AND THE FIRST VERSION OF THIS PROBE USED `dd', WHICH THIS MACHINE DOES NOT
# HAVE.  `dd: not found' -- the golden is missing it exactly as it is missing
# ar, cmp, tail, grep and wc, which is why mkdep.py builds `v10dd' as an FSTOOL.
# The probe failed SAFE (it reported no room rather than passing) but its
# diagnosis was wrong, and a synthetic probe built on tools this machine may not
# have is the wrong design however carefully it is written.
#
# So there is no synthetic probe.  The detector is the SURVEY ITSELF: a full
# filesystem makes every remaining unit fail, and twenty consecutive failures is
# something no real distribution of defects produces when 315 of 353 units are
# predicted to compile.  It costs nothing, needs no tool at all, and catches
# every systemic cause rather than just this one -- a full disk, a lost mount, a
# vanished compiler.
#
# Counted with a string and `case' because 1985 sh has no $(( )) and `expr' is
# no more guaranteed present here than dd was.
FAILRUN=""

# ---------------------------------------------------------------- canary ---
# halt.c is built by stage 1 on this very machine, so if it fails here the
# flags are wrong and no number below means anything.
#
# EVERY EXIT FROM THIS SCRIPT MUST PRINT THE END MARKER, and the first version
# did not.  v10_run sends a command and then waits for the program's own closing
# output, so a script that exits without printing `WORLDC-done' leaves the
# driver blocked for its full 18,000-second timeout -- which is precisely what
# happened: the dd probe failed, this script exited, and a vax750 sat at 100% CPU
# for twenty minutes with no console and nothing to reap it.  CLAUDE.md's rule is
# that a harness must terminate itself and that needing to kill one IS the bug;
# a guest-side script that can exit silently breaks that rule from the inside.
#
# The runaway check further down does not need this, because it lives inside the
# `sed | while' pipeline and therefore in a SUBSHELL -- its exit ends the loop
# and the tallies below still run.  Only a top-level exit can strand the driver.
$CC $CF $UD/halt.c > can.log 2>&1
if test -s halt.o
then
	# A MARKER FILE, BECAUSE THE ABSENCE OF DIAGNOSTICS CANNOT BE ASSERTED.
	# v10-compile.exp tested `test -s can.log' and called that "the canary
	# compiled", which is inverted: a compile that SUCCEEDS writes nothing,
	# so the assertion was true only when the canary had failed.  K10.1 has
	# never exited 0 for this reason -- it reported 6/7 on a run in which 241
	# units compiled, which no wrong set of flags can do.  Same fault
	# v10-libs.sh hit and the same fix: assert a marker the success path
	# writes, never the presence or absence of a compiler's output.
	echo ok > can.mark
	echo "$K-ok"
else
	echo "NO$K"
	sed -e 5q can.log
	echo "WORLDC-done"
	exit 1
fi
rm -f halt.o

# ------------------------------------------------------------------ loop ---
sed -e '/^#/d' $SRC/mk/world.units | while read name dir srcs
do
	if test -z "$srcs"
	then
		echo "$N $name"
		continue
	fi
	SD=$UD/$dir
	ok=y
	rm -f u.log
	# EVERY GENERATED FILE GOES, AT THE TOP OF EVERY UNIT.  y.tab.h is
	# written into $OBJ and $OBJ is not emptied between units, so one unit's
	# grammar header would sit there satisfying the NEXT unit's
	# `#include "y.tab.h"' with another program's token numbers -- compiling
	# cleanly, and wrong.  That is the flattering direction again: it would
	# have raised the count.  Cleaning here rather than after the unit means
	# it also holds on the paths that `continue'.
	rm -f y.tab.c y.tab.h prevy.tab.h x.tab.h lex.yy.c
	# The four units that need more than the unit dir, common/ and vax/ --
	# adb/comm, f77/alt, mk/export, nupas/attin.  Absent from world.incs is
	# the usual case and adds nothing.
	XI=""
	for x in `sed -e "/^$name /!d" -e "s/^$name //" $SRC/mk/world.incs`
	do
		XI="$XI -I$SD/$x"
	done
	# ------------------------------------------------- yacc and lex first ---
	# STEP ONE OF THE BUILD, WHICH THIS SURVEY USED TO SKIP.  Nine units
	# reported `missing:y.tab.h' -- a header yacc writes -- and two more
	# (expr, ipa) were not surveyed at all because their only source is a
	# grammar.  Reading that as a fact about the tape is what a survey that
	# does not run the generators looks like from the outside.
	#
	# THE TALLY IS A FILE AND NOT A VARIABLE, and this is the one place in
	# this script where that distinction bites: 1970s sh forks for a compound
	# command carrying an input redirection, so `ok=n' set inside
	# `while read ... done < g.lst' would be assigned in a dead child and
	# lost -- exactly the fault that had v10-libs report 26 of 26 libraries
	# built while 42 members had not compiled.  A file is immune either way
	# and needs no theory about which shell forks when.
	rm -f gbad.cnt
	sed -e '/^#/d' -e "/^$name /!d" -e "s/^$name //" $SRC/mk/world.gen > g.lst
	while read tool gf gobj gflags
	do
		if test -z "$tool" ; then continue ; fi
		case "$tool" in
		yacc)	gsrc=y.tab.c ;;
		*)	gsrc=lex.yy.c ;;
		esac
		rm -f $gsrc
		# The generator reads from the courier disk and writes into $OBJ,
		# which is why this runs with $OBJ as the working directory: yacc
		# and lex both write their output to the current directory and
		# have no -o.  A build that wrote beside the source would change
		# the source disk's id and the next stage would refuse it.
		case "$tool" in
		yacc)	( $YACC $gflags $SD/$gf 2>&1 ; echo "GST=$?" ) \
				| sed -e 20q > g1.log ;;
		*)	( $LEX $gflags $SD/$gf 2>&1 ; echo "GST=$?" ) \
				| sed -e 20q > g1.log ;;
		esac
		gst=`sed -e '/^GST=/!d' -e 's/GST=//' -e 1q g1.log`
		if test "$gst" != 0 -o ! -s $gsrc
		then
			echo . >> gbad.cnt
			echo "$G-no $name $tool $gf" >> u.log
			sed -e 4q g1.log >> u.log
			continue
		fi
		# The tape's own aliasing, copied because the tape does it: awk,
		# eqn and grap cp y.tab.h to prevy.tab.h and hoc to x.tab.h, so
		# that a grammar whose tokens did not change does not force a
		# recompile.  Those are the names their .c files include.
		if test "$tool" = yacc -a -s y.tab.h
		then
			cp y.tab.h prevy.tab.h
			cp y.tab.h x.tab.h
		fi
		( $CC $CF -I. -I$SD -I$SD/common -I$SD/vax $XI -I$JQ $gsrc 2>&1
		  echo "CCST=$?" ) | sed -e 40q > g1.log
		gst=`sed -e '/^CCST=/!d' -e 's/CCST=//' -e 1q g1.log`
		gout=`echo $gsrc | sed -e 's|\.c$|.o|'`
		if test "$gst" != 0 -o ! -s $gout
		then
			echo . >> gbad.cnt
			echo "$G-cc $name $gf" >> u.log
			sed -e 4q g1.log >> u.log
		elif test "$gout" != "$gobj"
		then
			# world.gen's object column IS the generator's natural
			# output today, so this is normally a no-op -- and `mv x
			# x' is an ERROR, not a no-op, which is why it is
			# guarded rather than run unconditionally.  The column
			# stays because a link stage has to know the name.
			mv $gout $gobj
		fi
	done < g.lst
	if test -f gbad.cnt
	then
		ok=n
		sed -e 6q u.log
	fi
	# A grammar-only unit -- world.units writes `-' for its sources, since a
	# row that simply ends after two fields cannot be told from a truncated
	# one.  There is nothing further to compile.
	if test "$srcs" = "-"
	then
		srcs=""
	fi
	for f in $srcs
	do
		# THE COMPILER'S OUTPUT IS BOUNDED BY A PIPE, AND THAT IS A BUG
		# FIX, NOT TIDINESS.  This was `>> u.log', unbounded, and it
		# filled a 120 MB filesystem twice at the same unit -- `asd',
		# whose asd.h includes a config.h that does not exist.  The
		# transcript showed the message three times only because the
		# DISPLAY was `sed -e 3q'; u.log itself had no limit, so a cpp
		# that does not advance past a missing include writes the same
		# line until the disk is gone.  The kernel then printed
		# `/mnt2: file system full' every few seconds while alloc()
		# slept -- V10's allocator waits for space rather than failing --
		# so the run neither progressed nor died, twice.
		#
		# `sed -e 40q' closes the pipe after forty lines, which sends the
		# compiler EPIPE and kills it.  Structural, so no counting and no
		# truncation is needed, and it cannot be defeated by a faster
		# loop.
		#
		# BOTH TESTS SURVIVE, because either alone has lied here before:
		# the prebuilt lcc exits 0 while writing an EMPTY object, and
		# V10's ld writes its output file even with symbols undefined.
		# The status is carried through the pipe as its own line, since a
		# pipeline's status is sed's and 1985 sh has no PIPESTATUS.
		b=`echo $f | sed -e 's|.*/||' -e 's|\.c$|.o|'`
		rm -f $b
		# OUR OVERLAY WINS WHERE WE HAVE ONE, because the build we are
		# measuring is v10/src + the tape, not the tape alone.  Reading
		# only $UD made this survey report `mv' as failing on
		# `ROOTINO undefined' -- the exact one-line defect
		# v10/src/cmd/mv.c was written to patch and PATCHES.md records --
		# and the same for fsck, login, cc and mkbitfs.  A measurement
		# that ignores the corrections measures a tree nobody builds.
		S=$SD/$f
		if test -f $SRC/ours/cmd/$dir/$f
		then
			S=$SRC/ours/cmd/$dir/$f
		fi
		# -I. IS $OBJ, WHERE THE GENERATED HEADER IS.  It cannot shadow a
		# unit's own file: cpp searches the including file's directory
		# first for "..." regardless of -I order, so the eight units that
		# ship a y.tab.h beside the grammar still compile against their
		# own -- which is the tape's artefact and the right one to prefer.
		( $CC $CF -I. -I$SD -I$SD/common -I$SD/vax $XI -I$JQ $S 2>&1
		  echo "CCST=$?" ) | sed -e 40q > u1.log
		st=`sed -e '/^CCST=/!d' -e 's/CCST=//' -e 1q u1.log`
		if test "$st" != 0 -o ! -s $b
		then
			ok=n
			# ONLY THE FAILURES GO IN u.log, because the display is
			# `sed -e 3q u.log' and a unit with many sources fills
			# those three lines with `CCST=0' from the ones that
			# WORKED -- so cmd/sh reported CFAILED followed by three
			# zeroes and the actual error was never shown.  A
			# diagnostic that prints the successes is worse than
			# none: it looks like an answer.
			sed -e 6q u1.log >> u.log
		fi
		rm -f u1.log
	done
	if test $ok = y
	then
		echo "$P $name" >> $OBJ/res.log
		echo "$P $name"
		FAILRUN=""
		# ------------------------------------ K10.3: link and install ---
		# Only when a DESTDIR was given, so K10.1 is untouched.
		#
		# EVERY .o IN $OBJ BELONGS TO THIS UNIT, which is why `*.o' is
		# the object list and no third copy of it is needed: the loop
		# removes them per unit, and world.gen's outputs land here too.
		# world.link therefore carries only what is new -- the
		# destination and the -l flags.
		if test -n "$DEST"
		then
			LL=""
			# world.link SAYS WHETHER A UNIT IS BUILT AT ALL, and a
			# unit with no row is skipped rather than linked with
			# defaults.  `ed/' and `sort/' -- the tape's second
			# generation, whose names carry a trailing slash -- would
			# otherwise reach `cc -o ed/' and be reported as units
			# that would not link, which is a harness artefact
			# dressed as a finding.  The token makes the skip
			# visible, since a silent one is how a unit goes missing.
			for x in `sed -e '/^#/d' -e "/^$name /!d" \
				      -e 's/^[^ ]* [^ ]* [^ ]* //' -e 1q \
				      $SRC/mk/world.link`
			do
				if test "$x" != "-" ; then LL="$LL $x" ; fi
			done
			DD=`sed -e '/^#/d' -e "/^$name /!d" \
				-e 's/^[^ ]* //' -e 's/ .*//' -e 1q \
				$SRC/mk/world.link`
			if test -z "$DD"
			then
				echo "$ND $name" >> $OBJ/res.log
				echo "$ND $name"
				rm -f *.o
				continue
			fi
			rm -f $name
			( $CCL -o $name *.o $LL 2>&1
			  echo "LST=$?" ) | sed -e 30q > l1.log
			lst=`sed -e '/^LST=/!d' -e 's/LST=//' -e 1q l1.log`
			# THREE TESTS, BECAUSE V10'S ld WRITES ITS OUTPUT FILE
			# EVEN WHEN SYMBOLS ARE UNDEFINED -- it reports them and
			# clears the execute bits, so `test -s' passes on a
			# binary that cannot run.  A diagnostic added during
			# stage 3 reported SUCCESS for a component that had just
			# failed with `Undefined: _atof' for exactly this reason.
			# `Undefined' is looked for with sed because there is no
			# grep on this machine, and -x is not used because 1970s
			# test cannot be assumed to have it.
			sed -e '/Undefined/!d' -e 1q l1.log > lu.log
			if test "$lst" = 0 -a -s $name -a ! -s lu.log
			then
				echo "$L $name" >> $OBJ/res.log
				echo "$L $name"
				if test -d $DEST$DD
				then
					if cp $name $DEST$DD/$name
					then
						echo "$I $name" >> $OBJ/res.log
						# ECHOED AS WELL AS LOGGED, and
						# the omission cost a run: the
						# host counts from the
						# TRANSCRIPT and the guest from
						# res.log, so writing the
						# success only to the file made
						# them disagree 200 to 0 and
						# v10-link.sh refused to report
						# a run that had installed all
						# 200.  The guard was right and
						# the instrument was wrong.
						echo "$I $name"
					else
						echo "$IN $name $DEST$DD" \
						    >> $OBJ/res.log
						echo "$IN $name $DEST$DD"
					fi
				else
					echo "$IN $name $DEST$DD" >> $OBJ/res.log
					echo "$IN $name $DEST$DD"
				fi
			else
				echo "$LN $name" >> $OBJ/res.log
				echo "$LN $name"
				sed -e 3q l1.log
			fi
			rm -f $name l1.log lu.log
		fi
	else
		echo "$Q $name" >> $OBJ/res.log
		echo "$Q $name"
		sed -e 3q u.log
		FAILRUN="$FAILRUN."
	fi
	rm -f *.o
	# Twenty in a row is systemic, not twenty defects.  See the comment above
	# the loop: this replaces a synthetic space probe that needed `dd'.
	case "$FAILRUN" in
	....................*)
		echo "NO$SP"
		echo "twenty consecutive units failed -- something systemic"
		sed -e 3q u.log
		exit 1
		;;
	esac
done

# ---------------------------------------------------------------- tallies ---
# THE GUEST COUNTS TOO, so the host has something to disagree with.  Stage 2
# printed a member total that contradicted its own assertion four lines above
# and nothing compared them; v10-stage2.sh now refuses to report when those
# two disagree, and this is the same guard one layer earlier.
#
# There is no `wc' on this machine -- `sed -n $=' is the line count.  And the
# labels are spelled through $P/$Q/$N so the tty's echo of these very commands
# carries `$P' and not the token: a literal in the QUESTION would be counted as
# an answer, which is how `echo SAME $name' had to be written too.
# The labels are TALLYB/F/N and NOT the tokens themselves.  A tally printed as
# `TALLY-CBUILT 356' would be found by an unanchored host-side count of
# `CBUILT <word>' -- inside its own summary line -- and inflate the total by
# one per tally.  Anchoring the host pattern is not the fix, because that is
# what the tty splice defeats; using a different string is.
sed -e "/^$P /!d" $OBJ/res.log > $OBJ/t.log
n=`sed -n '$=' $OBJ/t.log`
if test -z "$n"; then n=0; fi
echo "TALLYB $n"
sed -e "/^$Q /!d" $OBJ/res.log > $OBJ/t.log
n=`sed -n '$=' $OBJ/t.log`
if test -z "$n"; then n=0; fi
echo "TALLYF $n"
sed -e "/^$N /!d" $OBJ/res.log > $OBJ/t.log
n=`sed -n '$=' $OBJ/t.log`
if test -z "$n"; then n=0; fi
echo "TALLYN $n"
if test -n "$DEST"
then
sed -e "/^$L /!d" $OBJ/res.log > $OBJ/t.log
	n=`sed -n '$=' $OBJ/t.log`
	if test -z "$n"; then n=0; fi
	echo "TALLYL $n"
sed -e "/^$I /!d" $OBJ/res.log > $OBJ/t.log
	n=`sed -n '$=' $OBJ/t.log`
	if test -z "$n"; then n=0; fi
	echo "TALLYI $n"
fi
echo "WORLDC-done"
'''


def world_incs(units):
    """Units needing an -I beyond the unit dir, common/ and vax/.

    ONLY THE FOUR THE SURVEY CAN NAME, and deliberately not "every
    subdirectory".  `asd' failing on config.h was the symptom that started
    this, and the tempting fix -- pass every immediate subdirectory of the unit
    as -I -- would reintroduce exactly the over-eager resolution that had
    ccom's "stdio.h" coming from cmd/lcc/include/sparc_sun: cmd/adb carries
    11v, 68v, cray, seq, v7 and v8 beside comm and vax, and a header present in
    two of them would be taken from whichever -I came first.

    Its own file rather than a fourth column, so `while read name dir srcs'
    keeps reading three fields and a tail -- the destrdirs.txt lesson is that a
    generated list read by 1985 shell must hold exactly one kind of thing.
    """
    out = [
        "# Extra -I directories, by unit, relative to the unit's directory.",
        "#",
        "# Generated by tools/v10-world.py; check with --check.  worldc.sh looks",
        "# a unit up here and adds nothing when it is absent, which is the usual",
        "# case: the unit's own directory plus common/ and vax/ covers all but a",
        "# handful.  Space-separated, because the guest turns them straight into",
        "# -I flags.",
        "#",
    ]
    for u in sorted(units, key=lambda x: x.name):
        if u.kind != "dir" or not u.root:
            continue
        dirs = sorted(set(os.path.dirname(p) for p in u.paths))
        extra = set()
        for b, h in u.includes:
            r = resolve(h, b, dirs, u.root)
            if r and r.startswith("-I") and not r.startswith("-I/"):
                d = r[2:]
                if d not in (".", "common", "vax"):
                    extra.add(d)
        if extra:
            out.append("%s %s" % (u.name, " ".join(sorted(extra))))
    return "\n".join(out) + "\n"


def world_gen(units):
    """Which units must run yacc or lex first, and with what.

    FIVE FIELDS AND A TAIL, and the flags are the tail on purpose: `lex' takes
    none in most of this tree, and a row read as `while read name tool file obj
    flags' with flags in the middle would shift every field left the moment one
    was empty.  Same discipline as world.units -- one kind of thing per row, and
    the variable-length part last.

    A unit whose recipe post-processes the generated source is emitted as a
    COMMENT rather than dropped silently.  cmd/2500 is the case: it runs
    `yacc -d -D gram.y' and then edits y.tab.c with `ed', and `lex -t lex.l >
    lex.c' and edits that too.  Running the generator without the edits would
    compile something the tape never compiled, and dropping the row without
    saying so would leave a unit quietly relying on the y.tab.c the tape happens
    to ship -- which is a build artefact from someone's working directory, the
    same reading the 46 prebuilt binaries get.  Naming it keeps that visible.
    """
    out = [
        "# Units whose build begins with yacc or lex, and the tape's own flags.",
        "#",
        "# Generated by tools/v10-world.py; check with --check.  Read by the",
        "# guest as `while read name tool file obj flags', so the flags are the",
        "# tail -- see the function comment.",
        "#",
        "# -d is not our preference: sixteen makefiles write `yacc -d' outright",
        "# and four more write $YFLAGS over `YFLAGS = -d'.  It is also what makes",
        "# y.tab.h exist, which nine units include.",
        "#",
    ]
    skipped = []
    for u in sorted(units, key=lambda x: x.name):
        for tool, f, flags, obj, note in u.gen:
            if note != "-":
                skipped.append("# SKIPPED %-10s %s %s -- %s" % (u.name, tool, f, note))
                continue
            out.append("%s %s %s %s %s" % (u.name, tool, f, obj, flags))
    if skipped:
        out.append("#")
        out.extend(skipped)
    return "\n".join(out) + "\n"


def inc_extra():
    """The headers a harness must install before it measures anything.

    THIS FILE EXISTS BECAUSE THE SURVEY AND THE MACHINE DISAGREED, and the
    disagreement ran in the flattering direction for a whole phase.
    INSTALLED_EXTRA describes what /usr/include holds, and resolve() has always
    consulted it -- but only tools/v10-stage2.exp ever performed the copies, on
    the .s2 image chain, while tools/v10-compile.sh runs on a .stage1 clone that
    has none of them.  So K10.1 surveyed a machine with stdlib.h and then
    compiled on a machine without it, and the resulting fourteen failures were
    written up as header facts about the tape:

        2500 awk ed eqn grap idiff join map pic sort zero   stdlib.h
        cb ed sum                                           stddef.h

    Eleven of those name a header whose variant was CHOSEN AND RECORDED by
    stage 2 in 2026-08-17.  Nothing was wrong with the decision; it simply never
    reached this machine.  Same shape as the app's `it is in the golden, it will
    arrive on Reset', and the same answer: put the list in one generated place
    and have every consumer read it.

    Three columns -- header, provenance, path -- and one kind of thing per row,
    so `while read h from path' reads what it looks like.  The path is relative
    to /usr/include for r70's own variants and to the overlay root for ours.
    """
    out = [
        "# Headers to install into /usr/include before compiling anything.",
        "#",
        "# Generated by tools/v10-world.py; check with --check.  r70 keeps these",
        "# only inside a compiler's variant directory and the job is to pick the",
        "# one pcc2 can read -- see INSTALLED_EXTRA in the generator for the",
        "# evidence behind each choice.  `ours' rows come from the overlay,",
        "# v10/src/, and are reconstructions rather than a choice among copies.",
        "#",
        "# fields: header  r70|ours  path",
        "#",
    ]
    for h in sorted(INSTALLED_EXTRA):
        src = INSTALLED_EXTRA[h]
        if src.startswith(OURS_PREFIX):
            out.append("%-12s ours  %s" % (h, src[len(OURS_PREFIX):]))
        else:
            out.append("%-12s r70   %s" % (h, src))
    return "\n".join(out) + "\n"


# Where stage 2 performs its own copies, so the two lists cannot drift.  It is
# the older consumer and it carries the prose reasoning for three of the
# choices, so it is left as it is and CHECKED rather than rewritten -- the
# tc.order lesson, where a component list that appeared twice disagreed for a
# whole run and nothing said so.
STAGE2 = os.path.join(ROOT, "tools", "v10-stage2.exp")
STAGE2_CP = re.compile(r'cp \$(?:INC|N)(?:/ours)?/([A-Za-z_0-9./]+\.h) '
                       r'\$INC/([A-Za-z_0-9./]+\.h)')


GENERATED = [
    ("world.txt", lambda u, p: world_txt(u, p)),
    ("world.cpio", lambda u, p: world_cpio(u)),
    ("world.units", lambda u, p: world_units(u)),
    ("world.incs", lambda u, p: world_incs(u)),
    ("world.gen", lambda u, p: world_gen(u)),
    ("world.link", lambda u, p: world_link(u)),
    ("inc.extra", lambda u, p: inc_extra()),
    ("worldc.sh", lambda u, p: WORLDC),
]


def main():
    args = sys.argv[1:]
    units = inventory()
    pre = prebuilt()

    if "--check" in args or "--write" in args:
        sanity(units)
        # The 14-character rule is a guard here, not a habit: `toolchain.order'
        # was truncated to `toolchain.orde' on a guest disk WITH A SUCCESSFUL
        # EXIT STATUS, which is why mkdep.py's put() refuses long names.  These
        # files are destined for the same disk.
        for name, _fn in GENERATED:
            if len(name) > 14:
                sys.exit("v10-world: generated name %r is over 14 characters, "
                         "which a guest filesystem truncates silently" % name)
        stale = []
        for name, fn in GENERATED:
            path = os.path.join(GEN, name)
            want = fn(units, pre)
            if "--check" in args:
                if read(path) != want:
                    stale.append(name)
                continue
            with open(path, "w") as fh:
                fh.write(want)
        if "--check" in args:
            if stale:
                sys.stderr.write(
                    "v10-world: out of date: %s -- run tools/v10-world.py "
                    "--write\n" % " ".join(stale))
                return 1
            print("v10-world: v10/mk/gen/world.* are current (%d units)"
                  % len(units))
            return 0
        print("v10-world: wrote %s (%d units)"
              % (" ".join(n for n, _ in GENERATED), len(units)))
        return 0

    if "--unit" in args:
        want = args[args.index("--unit") + 1]
        for u in units:
            if u.name == want:
                print("unit      %s (%s)" % (u.name, u.kind))
                print("main()    %s" % ("yes" if u.has_main else "no"))
                print("prebuilt  %s" % ("yes" if u.name in pre else "no"))
                print("overlay   %s" % ("yes" if u.overlay else "no"))
                print("sources   %d" % len(u.paths))
                for p in u.paths:
                    print("          %s" % os.path.relpath(p, SRC))
                print("includes  %d" % len(u.includes))
                dirs = sorted(set(os.path.dirname(p) for p in u.paths))
                # Re-walk the sources so the guard is shown: an include the
                # compiler never reaches must not read as a blocker here
                # either, or the detail view contradicts the summary.
                shown = set()
                for p in u.paths:
                    for b, h, guard in includes_of(read(p)):
                        if (b, h) in shown:
                            continue
                        shown.add((b, h))
                        where = resolve(h, b, dirs, u.root)
                        if where is None:
                            where = ("absent, but behind #if %s" % guard
                                     if guard else "*** MISSING ***")
                        elif guard:
                            where += "  (behind #if %s)" % guard
                        print("          %s%s%s  %s"
                              % (b, h, ">" if b == "<" else '"', where))
                if u.hints:
                    print("ANSI hint %s" % ", ".join(u.hints))
                return 0
        sys.exit("v10-world: no unit named %s" % want)

    if "--units" in args:
        for u in units:
            print("%-16s %-5s main=%-3s pre=%-3s inc=%-3d miss=%d %s"
                  % (u.name, u.kind, "yes" if u.has_main else "no",
                     "yes" if u.name in pre else "no",
                     len(u.includes), len(u.missing),
                     " ".join(u.missing)))
        return 0

    if "--headers" in args:
        hist = {}
        for u in units:
            for h in u.missing:
                hist.setdefault(h, []).append(u.name)
        for h, who in sorted(hist.items(), key=lambda kv: (-len(kv[1]), kv[0])):
            print("%-24s %3d  %s" % (h, len(who), " ".join(sorted(who))))
        return 0

    if "--variants" in args:
        # Every header r70 keeps only inside a compiler's directory, with each
        # copy's verdict.  The point of printing all of them is that the
        # INSTALLED_EXTRA choices are then reviewable against the alternatives
        # instead of asserted -- and it reproduces stage 2's three decisions
        # from a test written for a different phase, which is the closest thing
        # to an independent check available here.
        wanted = {}
        for u in units:
            for h in u.variant:
                wanted.setdefault(h, []).append(u.name)
        print("%-12s %-5s %-8s %s" % ("header", "dir", "verdict", "why / who"))
        for h in sorted(set(list(wanted) + list(INSTALLED_EXTRA))):
            for v in VARIANT_DIRS:
                p = os.path.join(R70, v, h)
                if not os.path.exists(p):
                    continue
                why = installable(read(p))
                chosen = INSTALLED_EXTRA.get(h) == "%s/%s" % (v, h)
                print("%-12s %-5s %-8s %s%s"
                      % (h, v, "PARSES" if why is None else "no",
                         why or "",
                         "   <- INSTALLED" if chosen else ""))
            if h in wanted:
                print("%-12s %-5s %-8s wanted by: %s"
                      % ("", "", "", " ".join(sorted(set(wanted[h])))))
        return 0

    report(units, pre)
    return 0


if __name__ == "__main__":
    sys.exit(main())
