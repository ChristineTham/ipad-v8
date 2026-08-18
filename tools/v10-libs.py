#!/usr/bin/env python3
"""K10.2: what libraries does the Tenth Edition have, and can we build them?

    tools/v10-libs.py               the report
    tools/v10-libs.py --write       regenerate v10/mk/gen/libs.*
    tools/v10-libs.py --check       exit 1 if those files are stale
    tools/v10-libs.py --demand      just the -l demand from the commands

THE SAME SHAPE AS tools/v10-world.py, AND FOR THE SAME REASON.  K10.1 was won by
predicting host-side, for free, which command units could resolve every header,
and then letting one guest run measure what the compiler actually accepted; the
disagreement between the two instruments was the finding.  Libraries get the
same treatment.  What is different is the deliverable: a command only has to
COMPILE for K10.1 to learn something, whereas a library has to become an
ARCHIVE that links, so this survey also has to settle member lists, member
order, install paths and which `-l' name each library answers to.

FOUR THINGS IN THIS TREE WILL PRODUCE A PLAUSIBLE WRONG ANSWER IF ASSUMED
RATHER THAN MEASURED.  Each was met during reconnaissance:

  * NEVER GLOB FOR SOURCES.  libI77 keeps 33 of its 122 .c files at top level
    and the remaining 89 under old/, old1/, notused/ and d/ -- superseded
    generations left in place, exactly as libc carries two generations of
    stdio.  A glob compiles all 122 and reports a library nobody shipped.  The
    member list comes from the build file's own target line, or from the
    prebuilt archive, and this tool says which.

  * `X.c.a' IS A SOURCE BUNDLE, NOT A LIBRARY.  libplot/libplot/plot.c.a holds
    `subr.c' and `whoami.c' -- ar used as a packaging tool, which is what it
    was for before tar was everywhere.  So `.a' does not mean "link library"
    and a survey that counts .a files finds libraries that do not exist.  The
    rule is decided by the first member's suffix, and it is checked rather
    than trusted.

  * A LIBRARY'S ARCHIVE NAME NEED NOT MATCH ITS `-l' NAME.  libtermlib builds
    `termcap.a', installs it as `libtermcap.a', and hard-links `libtermlib.a'
    to that -- so one build answers two flags and matches neither its own
    directory nor its own product.  libl builds `libl.a' and the tape's
    prebuilt beside it is `libln.a'.  The `-l' names therefore come from the
    INSTALL rule's destinations, not from the directory or the archive.

  * NOT EVERY `lib*.a' IS AN ARCHIVE AT ALL.  libdbm's whole recipe is
    `mv dbm.o libdbm.a' and libsdb's is `as dbxxx.s -o libsdb.a': single
    object files wearing a `.a' name.  ld accepts them (it reads the magic
    number, not the suffix) but `ar t' and `ranlib' do not, so a harness that
    treats every library the same way fails on these two and the failure looks
    like a broken build rather than a faithful one.

AND ONE FACT THAT RETIRES THE BIGGEST-LOOKING DEPENDENCY.  `-lm' is the most
requested flag in the entire command tree -- 51 uses -- and libm/makefile says,
in Bell Labs' own words:

	# libm is now a dummy for those who still want to say -lm
	libm.a: dummy.o

with dummy.c being `int ________ = 0;'.  The mathematics moved into libc, where
stage 2 has already built it: asin atan exp floor fmod gamma besjn log pow
pow10 sin sinh sqrt are all in libc/mkfile's own OBJ list.  So 51 of the tree's
loudest demands are answered by an archive containing one integer, and K10.2 is
much smaller than the demand table suggests.
"""

import importlib.util
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "work", "v10", "src")
CMD = os.path.join(SRC, "cmd")
GEN = os.path.join(ROOT, "v10", "mk", "gen")
OURS = os.path.join(ROOT, "v10", "src")

# THE INCLUDE RESOLVER IS v10-world.py's, IMPORTED RATHER THAN COPIED.  A
# component list that appears twice will disagree eventually and the
# disagreement is silent -- that is written up in v10drive.exp, where a stale
# Tcl copy of BUILDTOOLS made stage 1 skip `ed' and report 42/44 with no line
# naming the cause.  The same argument applies to a 90-line header-resolution
# model: two copies would drift, and the drift would show up as a survey that
# disagrees with the machine for reasons that are purely bookkeeping.
def _load_world():
    path = os.path.join(ROOT, "tools", "v10-world.py")
    spec = importlib.util.spec_from_file_location("v10world", path)
    if spec is None or spec.loader is None:
        sys.exit("v10-libs: cannot load tools/v10-world.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


WORLD = _load_world()

# Where libraries live.  libplot is a CONTAINER, not a library: it has no
# top-level source and no top-level build file, and holds nine device-specific
# plot(3) libraries -- Tektronix 4014, HP 2621, Ramtek, the 5620 itself -- each
# with its own makefile.  So its children are the units and it is not.
LIB_GLOBS = [
    ("lib*", SRC),
    ("lib*", os.path.join(SRC, "ipc")),
    ("*", os.path.join(SRC, "libplot")),
    ("libnetb", os.path.join(SRC, "netfs")),
]

# libc is stage 2's and is not re-measured here.  It is named rather than
# skipped silently, because "which libraries does V10 have" should answer 19 and
# not 18, and because its member list is where the reading-from-the-archive rule
# below was established.
DONE = {"libc"}

BUILD_NAMES = ["mkfile", "makefile", "Makefile"]

# A target line and a macro assignment, in both dialects.  mk and make differ in
# how a macro is REFERENCED ($OBJ against $(OBJ)) and agree on how it is
# assigned, which is why one pattern serves both.
MACRO = re.compile(r'^([A-Za-z_][A-Za-z_0-9]*)[ \t]*=[ \t]*(.*)$')
# ANY target, not just one named `*.a'.  libcurses calls its archive `crlib'
# and installs it as libcurses.a -- `crlib: ${OBJS}' with `${AR} rv crlib $?' --
# so a pattern requiring a .a suffix finds no archive target at all, falls back
# to the single-object branch, and would have produced a 1-member libcurses.a
# that ranlib blesses and nothing notices until a link fails.
# A target name may itself be a macro, and in mk it may carry `:&': libcc writes
# `$(ARCHIVE):&\t$(OBJ)' with ARCHIVE=libcc.a.  A character class without `$'
# and `{}' matches no target at all there, so the library fell through to a glob.
TARGET = re.compile(r'^([A-Za-z_0-9./+${}()-]+)[ \t]*:&?[ \t]*(.*)$')
# ar in any spelling a 1995 makefile uses.  Five of these files write `${AR}'.
ARVERB = re.compile(r'^\t[ \t]*-?(ar|\$\{AR\}|\$\(AR\)|\$AR)[ \t]')
ARX = re.compile(r'^\t.*\bar[ \t]+x[ \t]')
# ALL THREE SPELLINGS.  `${OBJS}' is what libcurses writes, and a pattern
# handling only $(OBJS) and $OBJS leaves it unexpanded -- so the archive target
# came out with no member list, the survey fell through to a glob, and the whole
# library was about to be built as one object under the `single' kind.
MACRO_REF = re.compile(r'\$\{([A-Za-z_][A-Za-z_0-9]*)\}'
                       r'|\$\(([A-Za-z_][A-Za-z_0-9]*)\)'
                       r'|\$([A-Za-z_][A-Za-z_0-9]*)')
ARLINE = re.compile(r'^\t[ \t]*ar[ \t]+[a-zA-Z]+[ \t]+([A-Za-z_0-9./+-]+\.a)[ \t]+(.*)$')
CCMACRO = re.compile(r'^CC[ \t]*=[ \t]*(\S+)')
CFMACRO = re.compile(r'^(CFLAGS|LCCARGS)[ \t]*=[ \t]*(.*)$')
# THE TAPE'S OWN -D FLAGS ARE LOAD-BEARING, AND ONE OF THEM DECIDES 146 OF THE
# 500 MEMBERS.  libI77/mkfile passes `-DKR_headers' and libI77/Version.c says why
# in as many words:
#
#	23 July 1992: switch to ANSI prototypes unless KR_headers is #defined
#
# So without it libF77 and libI77 emit ANSI prototypes, which pcc2 cannot parse,
# and 29% of this stage fails for a reason that is entirely our flags rather than
# anything about the Tenth Edition.  That is K10.1's third finding -- "flags are
# generic, not per-unit" -- arriving with a much bigger bill.
#
# Two more matter: libtermlib's `-DCM_N -DCM_GT -DCM_B -DCM_D' are termcap
# capability switches, and libipc and libin both set `INCS=-I. -I../h', a SIBLING
# include directory holding the defs.h and ipc.h they include.  libipc is 30 of
# the command tree's asks, the second highest.
#
# -O and -g are NOT carried: optimisation is this build's decision, not the
# tape's, and every stage here compiles -O.
# `cp X Y', `mv X Y' and `ln X Y' inside an install rule.  ln matters: it is how
# libtermlib gives one archive two names, and dropping it loses a whole -l flag.
INSTALL_CP = re.compile(r'^\t[ \t]*-?(cp|mv|ln)[ \t]+(\S+)[ \t]+(\S+)[ \t]*$')


def read(path):
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def continued(text):
    """Lines with backslash continuations joined, comments kept.

    Both dialects wrap long object lists, and libF77's is eleven macros over
    twenty lines.  Joining first means every later pattern sees whole
    statements.
    """
    out, acc = [], ""
    for line in text.splitlines():
        if line.endswith("\\"):
            acc += line[:-1] + " "
            continue
        out.append(acc + line)
        acc = ""
    if acc:
        out.append(acc)
    return out


def is_object(name):
    """Is this word an object file a member list can legitimately contain?

    Three things reach here that are not:  a literal wildcard, because
    libplot/libplot/makefile writes `ar r libplot.a *.o' and the shell -- not
    make -- expands it, so `*.o' arrived as a member name; a macro nothing
    defined, which survives expand() unchanged and still ends in .o; and an
    ar member whose name is padding rather than a file, which is how
    netfs/libnetb produced the member `__________EBEB_'.  Each of the three
    reads as a member with no source, which looks like a gap in the tape and is
    a gap in the parser.
    """
    if not name.endswith(".o") or len(name) < 3:
        return False
    if any(c in name for c in "*?[]$"):
        return False
    return all(c.isalnum() or c in "_.+-/" for c in name)


# STAMP FILES ARE MEMBERS SPELLED SIDEWAYS.  Two of these libraries never name
# an object in a prerequisite list at all:
#
#	libcbt.a: bt.x seek.x tran.x diskrd.x diskwrt.x bwrite.x bdelete.x lib.x
#	OBJ=balloc.t getbitmap.t inbitmap.t outbitmap.t		(libcc)
#
# The `.x'/`.t' file is a timestamp the recipe touches after compiling and
# archiving that member -- the 1980s way to make an incremental `ar u' build
# work -- so `bt.x' means the member `bt.o'.  Read literally, both libraries
# come out with an empty member list and fall through to a glob, which for
# libcbt (17 of the tree's `-l' asks, the fourth highest) would have meant a
# guessed library.
STAMP = (".x", ".t")

# `$L(bdelete.o)' -- mk's ARCHIVE-MEMBER syntax, where $L is the archive and the
# parenthesised name is a member of it.  libcbt/mkfile is written entirely this
# way, and so is libc's, which is why mkdep.py's libc_from_tape() carries the
# same pattern.  Without it libcbt -- 17 of the command tree's `-l' asks, the
# fourth highest -- falls through to a glob.
MEMBER_PAREN = re.compile(r'\$[A-Za-z_][A-Za-z_0-9]*\(([^)]+)\)')


def as_object(word):
    """A prerequisite word as the member it stands for, or None."""
    if is_object(word):
        return word
    for s in STAMP:
        if word.endswith(s) and len(word) > len(s):
            cand = word[:-len(s)] + ".o"
            if is_object(cand):
                return cand
    return None


def expand(words, macros, depth=0):
    """A word list with $MACRO and $(MACRO) expanded, recursively.

    Bounded at depth 8 rather than tracked, because a macro cycle in a 1995
    makefile is a defect we would want to see as a missing member and not as a
    RecursionError three hundred lines later.
    """
    if depth > 8:
        return []
    out = []
    for w in words:
        m = MEMBER_PAREN.fullmatch(w)
        if m:
            out.append(m.group(1))
            continue
        m = MACRO_REF.fullmatch(w)
        if m:
            name = m.group(1) or m.group(2) or m.group(3)
            if name in macros:
                out.extend(expand(macros[name].split(), macros, depth + 1))
                continue
            out.append(w)
            continue
        out.append(w)
    return out


def parse_build(path):
    """(archive, members, compiler, installs) from one build file.

    `members' is the archive target's own prerequisite list, macro-expanded and
    filtered to .o -- the tape's answer to "what is in this library", in the
    tape's own order.  Where the recipe instead names the objects on an `ar'
    line (libl does: it compiles five files and archives them in one rule with
    no prerequisites at all), that line is used.
    """
    text = read(path)
    if not text:
        return None, [], None, [], None, ""
    lines = continued(text)

    macros, cc, cflags = {}, None, ""
    for line in lines:
        if line.startswith("\t"):
            continue
        m = CCMACRO.match(line)
        if m:
            cc = m.group(1)
        m = CFMACRO.match(line)
        if m and not cflags:
            cflags = m.group(2)
        m = MACRO.match(line)
        if m:
            macros[m.group(1)] = m.group(2)

    # THE INSTALL RULE IS READ FIRST, BECAUSE IT NAMES THE ARCHIVE.  Guessing
    # from the target's suffix fails on libcurses (`crlib') and guessing from
    # the directory fails on libtermlib (`termcap.a'), but every one of these
    # nineteen build files installs by copying one file to /usr/lib/lib*.a, and
    # the source of that copy IS the product by definition.
    installs, inrule = [], False
    for line in lines:
        if not line.startswith("\t"):
            inrule = bool(re.match(r'^install[ \t]*:', line))
            continue
        if not inrule:
            continue
        m = INSTALL_CP.match(line)
        if m:
            installs.append((m.group(1), m.group(2), m.group(3)))
    product = None
    for _verb, s, dest in installs:
        b = os.path.basename(dest)
        if b.startswith("lib") and b.endswith(".a") and not s.startswith("$"):
            product = os.path.basename(s)
            break

    # The archive target: the one the install rule names, else the first target
    # whose name ends `.a', else the first target with an object list.
    archive, members = None, []
    targets = {}
    def unmacro(name):
        """A target name with a single whole-word macro resolved."""
        m = MACRO_REF.fullmatch(name)
        if m:
            key = m.group(1) or m.group(2) or m.group(3)
            return macros.get(key, name).strip()
        return name
    for line in lines:
        m = TARGET.match(line)
        if not m:
            continue
        name, prereq = m.group(1), m.group(2)
        objs = [o for o in (as_object(w)
                            for w in expand(prereq.split(), macros)) if o]
        targets.setdefault(unmacro(name), (objs, prereq))
    for want in (product,):
        if want and want in targets:
            archive, members = want, targets[want][0]
    if archive is None:
        for name, (objs, _p) in targets.items():
            if name.endswith(".a"):
                archive, members = name, objs
                break
    if archive is None:
        for name, (objs, _p) in targets.items():
            if objs:
                archive, members = name, objs
                break

    # A SOURCE BUNDLE AS THE ARCHIVE'S PREREQUISITE IS THE TAPE'S OWN BUILD
    # ROUTE, not a curiosity.  Every libplot makefile reads
    #
    #	lib4014.a: tek.c.a
    #		mkdir xplot
    #		cd xplot;ar x ../tek.c.a
    #		cd xplot;cc -c -O *.c
    #		cd xplot;ar rc ../lib4014.a *.o
    #
    # -- so `ar x' on the .c.a is step one of the documented recipe, and the
    # bundle is the DESIGNATED source form for this family rather than a stray
    # artefact.  That answers the question the bundles first posed: libtr's
    # archive has 30 objects against 6 loose .c files because the other 24 are
    # inside tr.c.a, waiting to be extracted exactly as the makefile says.
    bundle = None
    if archive and archive in targets:
        for w in targets[archive][1].split():
            if w.endswith(".c.a"):
                bundle = w
                break

    # The `ar' line inside a recipe, for the libraries whose target has no
    # prerequisites.  Deliberately second: a prerequisite list is a statement
    # about contents, an ar line is a statement about one invocation, and where
    # both exist the first is the better evidence.
    if not members:
        for line in lines:
            m = ARLINE.match(line)
            if not m:
                continue
            objs = [o for o in (as_object(w)
                                for w in expand(m.group(2).split(), macros))
                    if o]
            if objs:
                archive, members = archive or m.group(1), objs
                break

    # EXPANDED, because the flag that matters is one indirection away.  libipc
    # and libin both write `CFLAGS=-g $INCS' with `INCS=-I. -I../h' on another
    # line -- so reading CFLAGS literally finds no include path at all, and
    # libipc is 30 of the command tree's asks.
    cflags = " ".join(expand(cflags.split(), macros))
    return archive, members, cc, installs, bundle, cflags


def ar_members(path):
    """(members, kind) of an ar archive, or (None, why) if it is not one.

    kind is "objects" or "sources", decided by the first member's suffix and
    not by the file's name -- because libplot/libplot/plot.c.a is an archive of
    two .c files and libdbm.a is not an archive at all.
    """
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None, "unreadable"
    if data[:8] != b"!<arch>\n":
        # Not a failure: libdbm.a is `mv dbm.o libdbm.a' and libsdb.a is
        # `as dbxxx.s -o libsdb.a'.  Both are single objects, which ld accepts.
        if data[:2] in (b"\x08\x01", b"\x0b\x01", b"\x07\x01"):
            return None, "bare object (a.out magic, not an archive)"
        return None, "not an archive"
    out, off = [], 8
    while off + 60 <= len(data):
        h = data[off:off + 60]
        if h[58:60] != b"`\n":
            return None, "corrupt member header at byte %d" % off
        name = h[0:16].decode("ascii", "replace").rstrip()
        try:
            size = int(h[48:58].decode("ascii", "replace").strip())
        except ValueError:
            return None, "unreadable member size at byte %d" % off
        # A member that is neither an object nor a source is ar padding or
        # a long-name slot, not a file -- netfs/libnetb has one reading
        # `__________EBEB_'.  Keeping it makes a library look as though it has
        # a member with no source.
        if name != "__.SYMDEF" and (name.endswith((".o", ".c", ".s"))):
            out.append(name)
        off += 60 + size + (size & 1)
    if not out:
        return None, "empty archive"
    # Classified by CONTENT, and a bundle may lead with a header: hp.c.a's
    # first member is a .c but nothing guarantees that in general.
    kind = "objects" if out[0].endswith(".o") else "sources"
    return out, kind


def ar_extract(path):
    """{member name: bytes} of an ar archive.

    Needed because four of these libraries keep their source ONLY inside a
    `.c.a' bundle -- lib2621, libblit, libram and libplot -- and the tape's own
    recipe extracts it with `ar x' as step one.  Reading the members here lets
    the header prediction cover them without unpacking anything onto disk, so
    the pristine tree stays pristine and `v10/MANIFEST' keeps meaning what it
    says.
    """
    out = {}
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return out
    if data[:8] != b"!<arch>\n":
        return out
    off = 8
    while off + 60 <= len(data):
        h = data[off:off + 60]
        if h[58:60] != b"`\n":
            break
        name = h[0:16].decode("ascii", "replace").rstrip()
        try:
            size = int(h[48:58].decode("ascii", "replace").strip())
        except ValueError:
            break
        out[name] = data[off + 60:off + 60 + size]
        off += 60 + size + (size & 1)
    return out


def demand():
    """Every -l flag the command tree asks for, and how often.

    Measured over cmd/'s own build files.  THE RESULT IS NOT A STATEMENT ABOUT
    V10: thirteen of these name libraries that exist nowhere in the tarball --
    -lbsd, -lport, -lsocket, -lresolv, -lgc, -lether, -lcoexpr, -ltroff -- which
    is the fingerprint of makefiles written for other machines, the same
    evidence as cmd/lcc/include/sparc_sun/ and iolib.h's `#ifdef sgi'.
    CLAUDE.md already records that no makefile on the tape reliably names its
    compiler; a makefile's -l list is no more reliable, and this function's job
    is to show which asks can be answered rather than to answer all of them.
    """
    counts = {}
    for dirpath, _dirs, files in os.walk(CMD):
        for f in files:
            if f not in BUILD_NAMES:
                continue
            for flag in re.findall(r'-l([A-Za-z0-9_]+)',
                                   read(os.path.join(dirpath, f))):
                counts[flag] = counts.get(flag, 0) + 1
    return counts


def overlay_of(rel):
    """Our corrected copy of a source, if we carry one."""
    p = os.path.join(OURS, rel)
    return p if os.path.exists(p) else None


def inventory():
    """One record per library, everything measured rather than typed."""
    seen, libs = set(), []
    for pat, base in LIB_GLOBS:
        if not os.path.isdir(base):
            continue
        import fnmatch
        for entry in sorted(os.listdir(base)):
            if not fnmatch.fnmatch(entry, pat):
                continue
            d = os.path.join(base, entry)
            if not os.path.isdir(d):
                continue
            rel = os.path.relpath(d, SRC)
            if rel in seen:
                continue
            # libplot is a container: no build file and no source of its own.
            if rel == "libplot":
                continue
            seen.add(rel)
            libs.append(survey(rel, d))
    return libs


def survey(rel, d):
    """Everything knowable about one library directory, from the host."""
    u = {
        "name": os.path.basename(rel),
        "rel": rel,
        "dir": d,
        "done": os.path.basename(rel) in DONE,
    }

    build = None
    for n in BUILD_NAMES:
        p = os.path.join(d, n)
        if os.path.exists(p):
            build = p
            break
    u["build"] = os.path.basename(build) if build else None
    (archive, members, cc, installs, bundle,
     cflags) = parse_build(build) if build else (None, [], None, [], None, "")
    u["bundle"] = bundle
    u["cflags"] = cflags
    u["archive"] = archive
    u["cc"] = cc
    u["installs"] = installs

    # HOW THIS LIBRARY IS ASSEMBLED, decided here rather than in the guest.
    # Two of the nineteen are not archives at all: libdbm's entire recipe is
    # `mv dbm.o libdbm.a' and libsdb's is `as dbxxx.s -o libsdb.a'.  ld accepts
    # a bare object under a .a name -- it reads the magic number, not the
    # suffix -- but `ar t' and `ranlib' do not, so a guest script that treats
    # every library alike fails on exactly these two and the failure reads as a
    # broken build rather than a faithful one.  The tell is whether the recipe
    # invokes ar at all.
    text = read(build) if build else ""
    has_ar = any(ARVERB.match(l) for l in text.splitlines())
    has_arx = any(ARX.match(l) for l in text.splitlines())
    if bundle and has_arx:
        u["kind"] = "bundle"
    elif has_ar:
        u["kind"] = "ar"
    else:
        u["kind"] = "single"

    # The prebuilt archives beside the source.  Split by what they CONTAIN, so
    # a source bundle is never mistaken for an oracle.
    oracle, bundles, odd = None, [], []
    for f in sorted(os.listdir(d)):
        if not f.endswith(".a"):
            continue
        p = os.path.join(d, f)
        got, kind = ar_members(p)
        if got is None:
            odd.append((f, kind))
        elif kind == "sources":
            bundles.append((f, got))
        elif oracle is None or f == archive:
            oracle = (f, got)
    u["oracle"] = oracle
    u["bundles"] = bundles
    u["odd"] = odd

    # THE MEMBER LIST, AND WHERE IT CAME FROM -- recorded, because the three
    # sources are not equally good evidence and a reader must be able to tell
    # which one an answer rests on.  The tape's own archive is best (it is what
    # Bell Labs shipped, and it settles ORDER as well as contents, which is the
    # rule stage 2 already follows for libc); the build file's target line is
    # next; a glob is a guess and is labelled one.
    # KIND `bundle': the members are whatever `ar x' puts on the floor, and the
    # tape's recipe says so outright -- `cd xplot;ar x ../tek.c.a' then
    # `cc -c -O *.c' then `ar rc ../lib4014.a *.o'.  So the bundle's own .c list
    # IS the member list, which is how libtr gets its missing 24: the archive
    # has 30 objects, the directory has 6 loose .c files, and tr.c.a holds the
    # rest.  Reading them from the oracle instead would give the right NAMES
    # with no source behind them.
    if u["kind"] == "bundle" and bundle:
        got, kind = ar_members(os.path.join(d, bundle))
        if got and kind == "sources":
            u["members"] = [c[:-2] + ".o" for c in got if c.endswith(".c")]
            u["from"] = "%s (ar x, per the recipe)" % bundle
            # TWO LIBRARIES HAVE BOTH A BUNDLE AND AN ORACLE -- libpen and
            # libtr -- so they have two candidate member ORDERS, and V10's
            # authenticity rule settles which wins: member order comes out of
            # the tape's own archive, the way stage 2 reads libc's rather than
            # recomputing it with `lorder | tsort'.  Measured 2026-08-18, the
            # two agree exactly for both (30 and 21 members, same sequence), so
            # this changes nothing today; it is here because a re-import that
            # made them disagree would otherwise silently take the bundle's,
            # and V8-lineage ld makes ONE sequential pass when __.SYMDEF is
            # absent or stale, so order is not merely cosmetic.
            if oracle:
                if list(oracle[1]) != u["members"]:
                    u["members"] = list(oracle[1])
                    u["from"] = ("%s for source, %s FOR ORDER (they disagree; "
                                 "the tape's archive is the authority)"
                                 % (bundle, oracle[0]))
        else:
            u["members"], u["from"] = [], "bundle %s unreadable" % bundle
    elif oracle:
        u["members"], u["from"] = list(oracle[1]), "archive"
        if members and set(members) != set(oracle[1]):
            u["disagree"] = (sorted(set(oracle[1]) - set(members)),
                             sorted(set(members) - set(oracle[1])))
    elif members:
        u["members"], u["from"] = members, u["build"]
    else:
        # THE FALLBACK, AND IT MUST FILTER TO COMPILABLE SOURCES.
        # WORLD.sources() answers ".c/.h/.s/.y/.l", which is right for a survey
        # of what a directory contains and wrong for a member list: mapping
        # basename -> stem + ".o" turns curses.h and curses.c into one name
        # twice, so libcurses read 39 members against 36 sources and the report
        # printed 363 members resolving headers out of 362 -- a total larger
        # than its own subtotal, which is impossible by construction and is now
        # asserted rather than printed.
        stems = []
        for f in sorted(WORLD.sources(d)):
            if not f.endswith((".c", ".s")):
                continue
            obj = os.path.basename(f)[:-2] + ".o"
            if obj not in stems:
                stems.append(obj)
        u["members"] = stems
        u["from"] = "GLOB (a guess -- no archive and no object list)"

    # Each member's source, and whether it resolves its headers.  A member with
    # no source is a real finding: libtr's archive has 30 objects and its
    # directory has 6 .c files.
    unit_dirs = [d] + WORLD.machine_dirs(d)
    srcs, missing, blocked = {}, [], {}
    inbundle = {}
    if u["kind"] == "bundle" and bundle:
        inbundle = ar_extract(os.path.join(d, bundle))
    for obj in u["members"]:
        stem = obj[:-2]
        for ext in (".c", ".s"):
            cand = os.path.join(d, stem + ext)
            if os.path.exists(cand):
                srcs[obj] = stem + ext
                break
        else:
            # THE BUNDLE COUNTS AS HAVING THE SOURCE, because `ar x' is the
            # recipe's own first step and the guest runs it.  Treating a bundled
            # member as sourceless is what made libtr read as 24 members of tape
            # rot and lib2621/libblit/libram/libplot read as empty directories.
            if stem + ".c" in inbundle:
                srcs[obj] = stem + ".c"
            else:
                missing.append(obj)
                continue
        if not srcs[obj].endswith(".c"):
            continue            # as(1) has no include path worth modelling
        rel_src = os.path.join(rel, srcs[obj])
        over = overlay_of(rel_src)
        disk = os.path.join(d, srcs[obj])
        if over:
            text = read(over)
        elif os.path.exists(disk):
            text = read(disk)
        else:
            text = inbundle.get(srcs[obj], b"").decode("ascii", "replace")
        # (bracket, header, guard) -- BRACKET FIRST, and the third element is
        # the text of the controlling #if or None, not a depth.  Getting this
        # order wrong is why the first run of this tool reported 35 of 362
        # members able to resolve their headers: every call asked the resolver
        # for a header literally named `"', so almost everything "failed".
        # Same family as the fixpoint's "seven differences from zero
        # comparisons", where v10_order's one column was destructured as rows.
        # It ran PESSIMISTIC, which sanity() below now checks for -- the three
        # errors in v10-world.py all ran the flattering way and that is what
        # its own plausibility check was built to catch.
        for bracket, header, guard in WORLD.includes_of(text):
            if guard is not None:
                continue        # inside #if/#ifdef -- not unconditionally needed
            # A HEADER INSIDE THE SAME BUNDLE RESOLVES, because `ar x' puts it
            # in the extraction directory beside the sources and `-I.' finds it.
            # hp.c.a carries hp.h, ramtek.c.a carries ram.h and blit.c.a carries
            # both jcom.h and jplot.h -- 143 of the 145 apparent blocks were
            # these four headers, sitting in the very archive the recipe unpacks.
            if os.path.basename(header) in inbundle:
                continue
            where = WORLD.resolve(header, bracket, unit_dirs, d)
            if where is None:
                blocked.setdefault(obj, []).append(header)
    u["srcs"] = srcs
    u["missing"] = missing
    u["blocked"] = blocked
    u["overlay"] = sorted(o for o in srcs
                          if overlay_of(os.path.join(rel, srcs[o])))

    # Which -l flags this library answers, from the install rule's
    # destinations.  Falling back to the archive name, and then to the
    # directory, each of which is weaker evidence and is why the report shows
    # the install lines verbatim.
    names = set()
    for _verb, _s, dest in installs:
        b = os.path.basename(dest)
        if b.startswith("lib") and b.endswith(".a"):
            names.add(b[3:-2])
    if not names and archive and archive.startswith("lib"):
        names.add(archive[3:-2])
    if not names and u["name"].startswith("lib"):
        names.add(u["name"][3:])
    extra = ALSO_ANSWERS.get(u["name"])
    if extra:
        names.add(extra[3:-2])
    u["lnames"] = sorted(names)
    return u


# A LIBRARY THE TAPE INSTALLS UNDER A SECOND NAME THAT ITS MAKEFILE NEVER
# MENTIONS.  cmd/pret and cmd/struct link `-lln', and libl's makefile builds and
# installs only libl.a -- so those two units could not link and the flag went
# into the report as one the tarball does not provide.  It does provide it:
# src/libl/ carries a PREBUILT libln.a beside the source, and its member list is
#
#	allprint.o  main.o  reject.o  yyless.o  yywrap.o
#
# which is, member for member, exactly what the makefile puts in libl.a.  So
# libln.a is libl.a under a second name, and the question is a system-layout one
# of the same kind as libtermlib answering both -ltermcap and -ltermlib from a
# single build.
#
# THE TAPE'S OWN ARTEFACT SETTLES IT, which is why this is a table and not a
# guess: sanity() below compares the prebuilt archive's members against the
# members the makefile names and refuses to print a measurement if they differ.
# Installing our BUILD under the second name is not the same as installing the
# prebuilt archive -- the prebuilt one stays an oracle and is never copied.
ALSO_ANSWERS = {"libl": "libln.a"}


def sanity(libs):
    """Refuse to report a measurement taken through a scan that read too little.

    v10-world.py was optimistic three times running, always in the flattering
    direction, and every one of those errors would have been caught by a check
    on the scan's own plausibility rather than on its conclusions.  Two here:
    a library with no members at all means the build file was not understood,
    and a tree where most libraries have no member list means the parser is
    broken rather than the tape being odd.
    """
    live = [u for u in libs if not u["done"]]
    if not live:
        sys.exit("v10-libs: no libraries found under %s -- run "
                 "tools/v10-import.py" % SRC)
    empty = [u["rel"] for u in live if not u["members"]]
    if len(empty) > len(live) // 4:
        sys.exit("v10-libs: %d of %d libraries came out with no members (%s) "
                 "-- the build-file parser is not reading this tree, so no "
                 "number here means anything"
                 % (len(empty), len(live), " ".join(empty[:6])))
    # ALSO_ANSWERS is a claim about two archives holding the same thing, so it
    # is checked against both rather than trusted.  A prebuilt archive whose
    # members have drifted from the makefile's list would mean the second name is
    # a DIFFERENT library, and installing our build under it would put the wrong
    # code behind a -l flag -- silently, since ld would find something.
    for name, second in sorted(ALSO_ANSWERS.items()):
        u = next((x for x in live if x["name"] == name), None)
        if u is None:
            sys.exit("v10-libs: ALSO_ANSWERS names %s, which is not a library "
                     "in this tree" % name)
        p = os.path.join(SRC, u["rel"], second)
        got, _why = ar_members(p)
        if not got:
            sys.exit("v10-libs: ALSO_ANSWERS claims %s is %s under another name, "
                     "but %s has no readable members" % (second, name, p))
        want = set(u["members"])
        if set(got) != want:
            sys.exit("v10-libs: %s and %s do not hold the same members -- %s vs "
                     "%s.  The second name would put different code behind a -l "
                     "flag." % (second, u["archive"], sorted(got), sorted(want)))
    guessed = [u for u in live if u["from"].startswith("GLOB")]
    if len(guessed) > len(live) // 2:
        sys.exit("v10-libs: %d of %d member lists are globs -- neither the "
                 "archives nor the build files were read, so the survey is "
                 "measuring its own fallback" % (len(guessed), len(live)))

    # AND THE HEADER MODEL MUST HAVE PRODUCED A PLAUSIBLE READING, which is the
    # check this tool's first run needed and did not have.  It reported 35 of
    # 362 members able to resolve their headers, because includes_of returns
    # (bracket, header, guard) and the caller unpacked (header, bracket, depth);
    # every lookup asked for a header named `"'.  The three faults in
    # v10-world.py all ran optimistic and this one ran pessimistic, so the
    # check has to be two-sided: a survey where almost nothing resolves is as
    # surely broken as one where almost everything does.
    #
    # A quarter is well below any real figure -- libc's own measured rate is
    # 260 of 261 -- and well above the 10% a wholly broken resolver produces.
    # A member list with a repeat is a parser fault, not a tape fact: ar keys
    # members by name, so a library cannot contain the same object twice.
    for u in live:
        if len(set(u["members"])) != len(u["members"]):
            import collections
            dup = [o for o, n in collections.Counter(u["members"]).items()
                   if n > 1]
            sys.exit("v10-libs: %s lists %s more than once (member list from "
                     "%s).  An archive cannot hold one name twice, so this is "
                     "the parser and not the tape."
                     % (u["rel"], " ".join(dup), u["from"]))

    # `single' MEANS ONE MEMBER, and a contradiction here is a parser fault with
    # a very quiet failure mode: libcurses (35 members) and lib4014 (31) were both
    # classified single before ${AR} and ${OBJS} were understood, which would have
    # produced a one-object libcurses.a that ranlib blesses and nothing notices
    # until a link fails much later.
    for u in live:
        if u["kind"] == "single" and len(u["members"]) > 1:
            sys.exit("v10-libs: %s is kind `single' with %d members -- a "
                     "contradiction, so the build-file parser misread it.  A "
                     "one-object archive would be blessed by ranlib and fail "
                     "only at link time."
                     % (u["rel"], len(u["members"])))

    withsrc = sum(len(u["srcs"]) for u in live)
    okay = sum(len(buildable(u)) for u in live)
    # Arithmetic that cannot happen.  A member needs a source to be buildable,
    # so this total can never exceed that one; when it did, it was a duplicate
    # inflating a list count against a dict count.
    if okay > withsrc:
        sys.exit("v10-libs: %d members resolve their headers out of %d that "
                 "have a source at all -- impossible, so the counting is wrong"
                 % (okay, withsrc))
    if withsrc and okay < withsrc // 4:
        sys.exit("v10-libs: only %d of %d members with source resolve their "
                 "headers.  That is too few to be a fact about the tape -- the "
                 "include model is broken, so no number here means anything.  "
                 "Check includes_of()'s tuple order first."
                 % (okay, withsrc))
    return True


# --------------------------------------------------------------- the report ---

def buildable(u):
    """Members that have a source and resolve every header at depth 0."""
    return [o for o in u["members"]
            if o in u["srcs"] and o not in u["blocked"]]


def report(libs, dem):
    print("== K10.2: the Tenth Edition's libraries ==")
    print()
    print("%-14s %-9s %5s %5s %5s %5s  %-8s %s"
          % ("library", "build", "mem", "src", "hdrOK", "-l", "oracle",
             "member list from"))
    print("%-14s %-9s %5s %5s %5s %5s  %-8s %s"
          % ("-" * 14, "-" * 9, "-" * 5, "-" * 5, "-" * 5, "-" * 5, "-" * 8,
             "-" * 24))
    tot = {"mem": 0, "src": 0, "ok": 0}
    for u in libs:
        if u["done"]:
            continue
        ok = buildable(u)
        tot["mem"] += len(u["members"])
        tot["src"] += len(u["srcs"])
        tot["ok"] += len(ok)
        want = sum(dem.get(n, 0) for n in u["lnames"])
        print("%-14s %-9s %5d %5d %5d %5d  %-8s %s"
              % (u["name"], u["build"] or "NONE", len(u["members"]),
                 len(u["srcs"]), len(ok), want,
                 "yes" if u["oracle"] else "-",
                 u["from"]))
    print("%-14s %-9s %5d %5d %5d" % ("TOTAL", "", tot["mem"], tot["src"],
                                      tot["ok"]))

    print()
    print("== what the commands ask for, and whether it can be answered ==")
    known = {}
    for u in libs:
        for n in u["lnames"]:
            known.setdefault(n, u)
    print("   %-10s %5s  %s" % ("flag", "uses", "answered by"))
    for flag, n in sorted(dem.items(), key=lambda kv: -kv[1]):
        if n < 2:
            continue
        u = known.get(flag)
        if u and u["done"]:
            how = "%s -- BUILT ALREADY (stage 2)" % u["rel"]
        elif u:
            how = u["rel"]
        else:
            how = "NOTHING IN THE TREE -- a foreign makefile's flag"
        print("   -l%-9s %5d  %s" % (flag, n, how))

    print()
    print("== the things that are not what they look like ==")
    for u in libs:
        for f, why in u["odd"]:
            print("   %-30s %s" % (os.path.join(u["rel"], f), why))
        for f, got in u["bundles"]:
            print("   %-30s SOURCE BUNDLE (%d .c members, not a library)"
                  % (os.path.join(u["rel"], f), len(got)))
    for u in libs:
        # libc excepted: its mkfile spells members as `$L(name.o)', which
        # mkdep.py's libc_from_tape() parses and this parser deliberately does
        # not -- one component list, one reader.  Reporting a disagreement here
        # would be this tool complaining about a file it is not the authority on.
        if u.get("disagree") and not u["done"]:
            only_a, only_b = u["disagree"]
            print("   %-14s archive and %s disagree: only in the archive %s; "
                  "only in the build file %s"
                  % (u["rel"], u["build"], " ".join(only_a) or "none",
                     " ".join(only_b) or "none"))
    for u in libs:
        if u["cc"] and u["cc"] != "cc":
            print("   %-14s its build file names CC = %s"
                  % (u["rel"], u["cc"]))
    for u in libs:
        if u["missing"] and not u["done"]:
            print("   %-14s %d members have no source: %s"
                  % (u["rel"], len(u["missing"]), " ".join(u["missing"][:8])))

    print()
    print("== headers that block a member (depth 0 only) ==")
    hist = {}
    for u in libs:
        if u["done"]:
            continue
        for _obj, hs in u["blocked"].items():
            for h in hs:
                hist[h] = hist.get(h, 0) + 1
    for h, n in sorted(hist.items(), key=lambda kv: -kv[1])[:20]:
        print("   %4d  %s" % (n, h))
    if not hist:
        print("   none")
    return 0


# ------------------------------------------------------ generated artefacts ---

def libs_txt(libs, dem):
    out = ["# K10.2: one line per library.  Generated by tools/v10-libs.py.",
           "# name dir build archive members withsource headerok demand from"]
    for u in libs:
        if u["done"]:
            continue
        out.append("%s %s %s %s %d %d %d %d %s"
                   % (u["name"], u["rel"], u["build"] or "-",
                      u["archive"] or "-", len(u["members"]), len(u["srcs"]),
                      len(buildable(u)),
                      sum(dem.get(n, 0) for n in u["lnames"]),
                      u["from"].split()[0]))
    return "\n".join(out) + "\n"


def libs_units(libs, dem):
    """The guest's manifest: one line per library, in build order.

    name<SP>dir<SP>archive<SP>kind<SP>installname[ installname...]

    ORDER IS BY DEMAND, HIGHEST FIRST, and that is a deliberate hedge rather
    than tidiness: libm answers 51 of the command tree's `-l' flags with a
    single object, libipc 30 and libcbt 17, so a run that dies two thirds of
    the way through still leaves the libraries that matter most installed.  The
    alternative -- alphabetical -- would spend the first minutes on lib2621.

    Every name a library answers to is listed, because libtermlib answers both
    `-ltermcap' and `-ltermlib' from one build and dropping the second loses
    three of the tree's asks.
    """
    out = ["# name dir archive kind bundle install...  "
           "-- generated by tools/v10-libs.py, ordered by -l demand"]
    # A DIRECTORY WITH NO BUILD FILE AND NO `-l' NAME IS NOT A LIBRARY, and
    # `libplot/oldplot' is the case: no makefile, one loose .c, and seven source
    # bundles (300.c.a, 4014.c.a, jerq.c.a, vt0.c.a ...) -- the superseded
    # generation of plot(3), kept beside the current one exactly as libI77 keeps
    # old/ and old1/.  Nothing asks for `-loldplot'.  Excluded here and named in
    # the report, rather than either built or silently dropped.
    live = [u for u in libs
            if not u["done"] and u["srcs"] and (u["lnames"] or u["archive"])]
    live.sort(key=lambda u: (-sum(dem.get(n, 0) for n in u["lnames"]),
                            u["rel"]))
    for u in live:
        names = ["lib%s.a" % n for n in u["lnames"]] or [u["archive"]]
        out.append("%s %s %s %s %s %s"
                   % (u["name"], u["rel"], u["archive"] or ("%s.a" % u["name"]),
                      u["kind"], u.get("bundle") or "-", " ".join(names)))
    return "\n".join(out) + "\n"


# WHERE WE ADD A FLAG THE TAPE DOES NOT, AND WHY IT IS NOT A DEVIATION.
# libF77/mkfile says `CC = lcc' and passes no -DKR_headers, because lcc is ANSI
# and does not need it.  We cannot use lcc: CLAUDE.md records that the prebuilt
# driver is compiled from bowell.c, whose cpp line passes `-undef', which ph/cpp
# rejects -- so lcc writes an EMPTY object and exits 0.  A loud failure beats a
# silent hole, and LIBC_LCC is empty for exactly this reason.
#
# So libF77 is compiled by cc, and `KR_headers' is THE TAPE'S OWN SWITCH for a
# K&R compiler -- libI77/Version.c: "switch to ANSI prototypes unless KR_headers
# is #defined".  Using it is taking the option the source ships, not patching the
# source.  And it belongs in OUR build description rather than in v10/src/,
# exactly as CLAUDE.md already argues for the `-DV10' that libc/mkfile's cc rule
# omits: "V10 never had these makefiles".
CFLAGS_ADD = {
    "libF77": ["-DKR_headers"],
}


def libs_cf(libs, _dem):
    """Per-library -D flags: `name flag...', one line each.

    -O and -g are dropped: optimisation is this build's decision and every stage
    here compiles -O.  Only the -D flags are the tape's statement about its own
    source.
    """
    out = ["# name -Dflag...  -- the tape's own CFLAGS, less -O/-g"]
    for u in libs:
        if u["done"]:
            continue
        flags = [w for w in u.get("cflags", "").split() if w.startswith("-D")]
        flags += [f for f in CFLAGS_ADD.get(u["name"], []) if f not in flags]
        if flags:
            out.append("%s %s" % (u["name"], " ".join(flags)))
    return "\n".join(out) + "\n"


def libs_inc(libs, _dem):
    """Extra include directories, RELATIVE to the library directory.

    Same shape as world.incs, and for the same reason: the guest builds
    `-I$SD/$x' from it, so a path here is a statement about layout rather than a
    string the guest has to rewrite.  `-I.' is dropped -- the guest always passes
    the source directory -- so in practice this file is libipc and libin's
    `-I../h', a SIBLING directory holding the defs.h and ipc.h they include.
    libipc is 30 of the command tree's asks, the second highest, so missing this
    would have failed the most-wanted real library in the set.
    """
    out = ["# name reldir...  -- extra -I, relative to the library directory"]
    for u in libs:
        if u["done"]:
            continue
        dirs = []
        for w in u.get("cflags", "").split():
            if not w.startswith("-I"):
                continue
            rel = w[2:]
            if rel in (".", "") or rel.startswith("$"):
                continue
            if rel not in dirs:
                dirs.append(rel)
        if dirs:
            out.append("%s %s" % (u["name"], " ".join(dirs)))
    return "\n".join(out) + "\n"


def libs_orcl(libs, _dem):
    """Libraries whose archive Bell Labs shipped, and where it is.

    name<SP>path-relative-to-src<SP>membercount

    THE ORACLE IS THE AUTHENTICITY TEST, and it is the same one stage 2 applies
    to libc: where our bytes differ from the tape's, the tape's bytes are the
    authority.  Nine of these libraries have a prebuilt archive beside their
    source, so nine can be checked member-for-member rather than merely
    "it built".

    Source bundles are excluded by construction -- see ar_members(), which
    classifies by the first member's suffix -- so `plot.c.a' can never be
    mistaken for an oracle and give a comparison against 1980s source text.
    """
    out = ["# name oracle members  -- the tape's own archive, for comparison"]
    for u in libs:
        if u["done"] or not u["oracle"] or not u["srcs"]:
            continue
        out.append("%s %s %d" % (u["name"],
                                 os.path.join(u["rel"], u["oracle"][0]),
                                 len(u["oracle"][1])))
    return "\n".join(out) + "\n"


def libs_objs(libs, _dem):
    """The guest's member table: library, object, source -- in the tape's order.

    ONE LINE PER MEMBER, WITH THE SOURCE NAMED, so the guest never has to guess
    a source from an object name and never has to glob.  That is the whole
    defence against libI77's 89 superseded files.
    """
    out = ["# lib obj src  -- the tape's own member order, per libs.txt"]
    for u in libs:
        if u["done"]:
            continue
        for obj in u["members"]:
            if obj in u["srcs"]:
                out.append("%s %s %s" % (u["name"], obj, u["srcs"][obj]))
    return "\n".join(out) + "\n"


def libs_cpio(libs, _dem):
    """The path list for cpio -p, relative to src/, one per line.

    THE `.a' FILES ARE CARRIED TOO, and for two different reasons that both
    matter -- which is the whole `ar bundles source as well as objects' problem
    in one function:

      * A SOURCE BUNDLE IS SOURCE.  Four libraries keep their only copy inside
        one (lib2621, libblit, libram, libplot) and libtr keeps 24 of its 30
        there, and the tape's own recipe extracts it with `ar x'.  Leaving these
        behind would mean copying a library's makefile and none of its code.
      * AN OBJECT LIBRARY IS THE ORACLE.  Nine of these have the archive Bell
        Labs shipped sitting beside the source, which is the authenticity test
        stage 2 applies to libc: where our bytes differ from the tape's, the
        tape's bytes are the authority.  It cannot be checked against something
        that was left on the host.
    """
    out = []
    for u in libs:
        if u["done"]:
            continue
        # EVERYTHING BUT THE OBJECTS.  A suffix allowlist (.c/.s/.h/.a) looked
        # careful and dropped `libcurses/curses.ext' -- a generated declarations
        # file that 29 of its 35 members include -- so 29 members failed on
        # `Can't find include file curses.ext' and read as a language problem.
        # The tape's directories also hold `:ctfix', `llib-lcurses', `cr_ex.h'
        # and other things no allowlist would have guessed.  Excluding objects
        # is a rule about what we do NOT need; listing what we do need is a
        # guess about a 1995 tree.  Costs 0.6 MB.
        for f in sorted(os.listdir(u["dir"])):
            p2 = os.path.join(u["dir"], f)
            if not os.path.isfile(p2):
                continue
            if f.endswith((".o", ".O")):
                continue
            out.append(os.path.join(u["rel"], f))
        # AND THE SIBLING INCLUDE DIRECTORIES THIS LIBRARY NAMES.  libipc and
        # libin both compile with `-I../h', and `ipc/h' is not a library
        # directory -- so it was in no manifest, the -I pointed at nothing, and
        # 8 members failed on `Can't find include file defs.h'.  A -I is a
        # statement that those files are needed; the manifest has to honour it.
        for rel in u.get("cflags", "").split():
            if not rel.startswith("-I") or rel[2:] in (".", ""):
                continue
            d2 = os.path.normpath(os.path.join(u["dir"], rel[2:]))
            if not os.path.isdir(d2):
                continue
            for f in sorted(os.listdir(d2)):
                p2 = os.path.join(d2, f)
                if os.path.isfile(p2) and not f.endswith((".o", ".O")):
                    out.append(os.path.relpath(p2, SRC))
    return "\n".join(sorted(out)) + "\n"


LIBSC = r'''#!/bin/sh
# K10.2: build every Tenth Edition library from source, on V10.
# GENERATED by tools/v10-libs.py -- do not edit here.
#
#	sh libsc.sh <srcroot> <objdir> <ccpath> <bprefix> <ar> <ranlib> <as>
#
# srcroot  the mounted courier disk, e.g. /n/v10
# objdir   scratch on a WRITABLE filesystem, e.g. /usr/k10lib
# ccpath   the driver, /bin/cc
# bprefix  stage 1's passes, e.g. /usr/s1/lib/
# ar       stage 1's ar -- the GOLDEN HAS NONE, which is why stage 1 builds it
# ranlib   /usr/bin/ranlib, which the golden does have (prebuilt.txt)
SRC=$1
OBJ=$2
CCP=$3
BP=$4
AR=$5
RL=$6
# as(1) is a stage-1 pass and 12 of the 362 members are hand-written VAX
# assembly -- 11 of libnm's 12 and libsdb's only file.  Sending those to cc
# reports a whole library failing on a syntax error in perfectly good assembler.
AS=$7
UD=$SRC/src
CF="-O -c"
CC="$CCP -B$BP -t02p"

# Spelled through variables so the tty's echo of these commands carries `$P'
# and not the token itself.  A literal in the QUESTION counts as an answer --
# that is why stage 2 had to write `echo $S $name' rather than `echo SAME $name'.
P=LBUILT
Q=LFAILED
A=LARCH
Z=LNOARCH
K=LCANARY
SP=LSPACE
M=LMEM

rm -rf $OBJ
mkdir $OBJ
cd $OBJ

# ---------------------------------------------------------------- canary ---
# THREE canaries, because this stage needs three tools and each absence looks
# like a different bug.  A compile failure reads as a language fact about the
# tape; an `ar' that is not there reads as a library that would not archive; a
# missing ranlib reads as a link problem two stages downstream.  All three are
# facts about THIS script's arguments.
#
# EVERY TOP-LEVEL EXIT PRINTS THE END MARKER.  v10_run waits for the program's
# own closing output, so a script that exits silently strands the driver for its
# whole timeout with a simulator at 100% CPU and no console -- which is exactly
# what a failed `dd' probe did to K10.1 for twenty minutes.
$CC $CF $UD/cmd/halt.c > can.log 2>&1
if test -s halt.o
then
	# A MARKER FILE, because `can.log' is EMPTY when the canary succeeds -- a
	# compile that works writes nothing -- so a `test -s can.log' assertion is
	# exactly inverted and failed on the first run while the canary had passed.
	echo ok > can.mark
	echo "$K-cc-ok"
else
	echo "NO$K"
	echo "the compiler did not build cmd/halt.c, which stage 1 builds here"
	sed -e 5q can.log
	echo "LIBSC-done"
	exit 1
fi
rm -f halt.o
if $AR cr can.a can.mark && $RL can.a
then
	echo ok > canar.mark
	echo "$K-ar-ok"
else
	echo "NO$K"
	echo "ar=$AR ranlib=$RL -- one of them is not here"
	echo "LIBSC-done"
	exit 1
fi
rm -f can.a

# ------------------------------------------------------------------ loop ---
# The runaway detector, as a string and `case': 1985 sh has no $(( )) and
# `expr' is no more guaranteed present than `dd' was.  A full filesystem makes
# V10's alloc() SLEEP rather than fail, so nothing errors and no
# count-the-errors probe can work -- but a systemic cause also makes every
# remaining library fail, and ten consecutive failures is not a distribution of
# defects when the host predicts 361 of 362 members can resolve their headers.
FAILRUN=""

sed -e '/^#/d' $SRC/mk/libs.units | while read name dir arch kind bndl inst
do
	SD=$UD/$dir
	LD=$OBJ/$name
	rm -rf $LD
	mkdir $LD
	cd $LD
	# THE FAILURE TALLY IS A FILE, NOT A VARIABLE, AND THAT IS A BUG FIX.
	# This was `nf=""' with `nf="$nf."' in the failing branch, and the first
	# run reported 26 of 26 libraries with every member compiled while
	# TALLYM said 42 members had NOT built -- two numbers from the same
	# `else' branch, contradicting each other.
	#
	# The cause is the shell.  The member loop below is
	# `while read obj src ... done < objs.lst', and the historical Bourne
	# shell FORKS for a compound command carrying an input redirection.  So
	# the `echo >> mem.log' survived (a file) and the `nf=' did not (a
	# variable in a dead child), and every library came out looking perfect.
	#
	# A file is immune to that either way, so this needs no theory about
	# which shell forks when.  Rule worth keeping: in 1970s sh, never carry a
	# tally out of a redirected loop in a variable.
	rm -f m.log nf.cnt
	# WHERE THIS LIBRARY'S SOURCE COMES FROM.  For most, the courier disk.
	# For the libplot family it is inside a `.c.a' SOURCE BUNDLE, and `ar x'
	# is step one of the tape's own recipe:
	#
	#	lib4014.a: tek.c.a
	#		cd xplot;ar x ../tek.c.a
	#		cd xplot;cc -c -O *.c
	#		cd xplot;ar rc ../lib4014.a *.o
	#
	# ar bundles source as well as objects -- it predates tar being
	# everywhere -- so a `.a' here is not a library.  Four of these
	# libraries have their source ONLY in a bundle, and libtr's archive has
	# 30 objects against 6 loose .c files because the other 24 are in
	# tr.c.a.  The headers are in there too (hp.h, ram.h, jcom.h, jplot.h),
	# which is why -I. suffices after extraction.
	# THE TAPE'S OWN FLAGS FOR THIS LIBRARY, and one of them decides 146 of
	# the 500 members.  libI77/mkfile passes `-DKR_headers' and
	# libI77/Version.c says why outright: "23 July 1992: switch to ANSI
	# prototypes unless KR_headers is #defined".  Without it libF77 and
	# libI77 emit ANSI prototypes that pcc2 cannot parse, and 29% of this
	# stage fails on OUR flags rather than on anything about the Tenth
	# Edition -- K10.1's "flags are generic, not per-unit" with a much
	# bigger bill.  libtermlib's four -DCM_* are termcap capability
	# switches.
	XD=""
	for x in `sed -e "/^$name /!d" -e "s/^$name //" $SRC/mk/libs.cf`
	do
		XD="$XD $x"
	done
	# Extra include directories, relative to the library dir -- same shape as
	# world.incs.  In practice this is libipc's and libin's `-I../h', a
	# SIBLING directory holding the defs.h and ipc.h they include; libipc is
	# 30 of the command tree's asks, the second highest.
	XI=""
	for x in `sed -e "/^$name /!d" -e "s/^$name //" $SRC/mk/libs.inc`
	do
		XI="$XI -I$SD/$x"
	done
	FROM=$SD
	if test "$bndl" != "-"
	then
		if $AR x $SD/$bndl
		then
			FROM=$LD
		else
			# BOTH VERDICTS, or the tallies do not add up.  This
			# branch used to print only `$Z' and `continue', so a
			# library that failed here was counted in neither
			# TALLYB nor TALLYF -- and v10-libs.sh compares those
			# against the manifest.  A hole in the accounting reads
			# as a transcript that lost data, which is the one thing
			# the cross-check exists to distinguish.
			echo "$Z $name"
			echo "$Z $name" >> $OBJ/res.log
			echo "$Q $name"
			echo "$Q $name" >> $OBJ/res.log
			echo "could not extract $bndl -- ar x failed"
			continue
		fi
	fi
	# MEMBER ORDER IS THE TAPE'S, read out of its own archive where one
	# exists and out of the build file's target line otherwise -- never from
	# a glob.  It matters twice: V8's ld is single-pass without a valid
	# __.SYMDEF, and libI77 keeps 89 superseded sources under old/, old1/,
	# notused/ and d/ that a glob would compile in place of the 33 real ones.
	#
	# The order this loop reads them in is the order they are archived,
	# because ORDER is written into libs.objs and `ar cr' appends.
	sed -e "/^$name /!d" -e "s/^$name //" $SRC/mk/libs.objs > objs.lst
	while read obj src
	do
		rm -f $obj
		# Our overlay wins where we carry a corrected copy.  Reading
		# only the tape made K10.1 report `mv' as failing on
		# `ROOTINO undefined' -- the exact defect v10/src/cmd/mv.c
		# patches -- and it was worth three commands when fixed.
		S=$FROM/$src
		if test -f $SRC/ours/$dir/$src
		then
			S=$SRC/ours/$dir/$src
		fi
		# .s members go to as(1), which has no include path worth
		# modelling.  libnm is 11 of 12 hand-written VAX assembly and
		# libsdb is one file; a script that sends them to cc reports a
		# whole library failing on a syntax error in perfectly good
		# assembler.
		case "$src" in
		*.s)
			( $AS $S -o $obj 2>&1 ; echo "CCST=$?" ) | sed -e 40q > m1.log
			;;
		*)
			# Output bounded by a PIPE, which is a bug fix and not
			# tidiness: an unbounded `>>' filled a 120 MB filesystem
			# twice in K10.1 when a cpp that could not find an
			# include wrote the same line until the disk was gone.
			# The pipe closes after 40 lines and the compiler gets
			# EPIPE.  The status rides through the pipe as its own
			# line because a pipeline's status is sed's and 1985 sh
			# has no PIPESTATUS.
			( $CC $CF $XD -I$FROM -I$SD $XI $S 2>&1
			  echo "CCST=$?" ) | sed -e 40q > m1.log
			;;
		esac
		st=`sed -e '/^CCST=/!d' -e 's/CCST=//' -e 1q m1.log`
		# BOTH TESTS, because either alone has lied on this tree: the
		# prebuilt lcc exits 0 while writing an EMPTY object, and V10's
		# ld writes its output file even with symbols undefined.
		if test "$st" = 0 -a -s $obj
		then
			:
		else
			echo . >> nf.cnt
			echo "$M-no $name $obj" >> $OBJ/mem.log
			# TO STDOUT AS WELL, bounded, so the transcript carries
			# the diagnosis.  The first run left its only record of
			# 42 failures in a file on a halted machine, which meant
			# the finding could not be read without another boot.
			echo "$M-no $name $obj"
			sed -e 4q m1.log >> m.log
		fi
		rm -f m1.log
	done < objs.lst
	# ------------------------------------------------- the archive ---
	# `single' is not a degenerate case of `ar': libdbm is `mv dbm.o
	# libdbm.a' and libsdb is `as dbxxx.s -o libsdb.a' -- bare objects
	# wearing a .a name, which ld accepts and ar t and ranlib do not.
	built=n
	case "$kind" in
	single)
		# ORDER MATTERS AND THE OBVIOUS ORDER IS WRONG.  sed runs its
		# commands in sequence per line and `q' AUTO-PRINTS before
		# quitting, so `-e 1q -e "s/ .*//"' emits the whole line
		# `dbm.o dbm.c' and the substitution never runs -- then
		# `test -s "dbm.o dbm.c"' fails and libdbm and libsdb both
		# report as unbuildable for no reason at all.  Substitute
		# first, quit second.
		one=`sed -e 's/ .*//' -e 1q objs.lst`
		if test -s "$one"
		then
			cp $one $arch && built=y
		fi
		;;
	*)
		# The member list, in order, as ar's arguments.  Deliberately
		# NOT `ar cr $arch *.o': a glob is alphabetical and the tape's
		# order is not, and V8's ld falls back to a single sequential
		# pass whenever __.SYMDEF is absent or stale.
		rm -f $arch
		if $AR cr $arch `sed -e 's/ .*//' objs.lst` 2>ar.log
		then
			if $RL $arch 2>>ar.log
			then
				built=y
			fi
		fi
		;;
	esac
	# HOW MANY MEMBERS DID THE ARCHIVE ACTUALLY GET?  The strongest check
	# here, and the one that would have caught the first run outright: `ar cr'
	# was handed 42 object names that did not exist and produced an archive
	# anyway, for all 26 libraries, which ranlib then blessed.  An archive of
	# 30 objects out of 33 links until the day something needs the other
	# three, so "an archive appeared" is not the question -- "does it hold
	# every member" is.
	#
	# __.SYMDEF is dropped from the count: ranlib prepends it and `ar t' lists
	# it, so a raw line count is one too many for every archive and zero for
	# the `single' kind that has no table of contents at all.
	want=`sed -n '$=' objs.lst`
	if test -z "$want"; then want=0; fi
	case "$kind" in
	single)
		have=$want ;;
	*)
		$AR t $arch 2>/dev/null | sed -e '/__\.SYMDEF/d' > at.log
		have=`sed -n '$=' at.log`
		if test -z "$have"; then have=0; fi ;;
	esac
	if test "$have" != "$want"
	then
		echo "$M-short $name $have of $want members"
		echo "$M-short $name" >> $OBJ/mem.log
	fi
	if test $built = y -a -s $arch
	then
		echo "$A $name"
		echo "$A $name" >> $OBJ/res.log
	else
		echo "$Z $name"
		echo "$Z $name" >> $OBJ/res.log
		sed -e 3q ar.log 2>/dev/null
	fi
	# ------------------------------------------------ the verdict ---
	# The per-library verdict is "every member compiled", which is a
	# stricter and more useful statement than "an archive appeared" -- an
	# archive of 30 objects out of 33 links until the day something needs
	# the other three.
	if test ! -f nf.cnt
	then
		echo "$P $name"
		echo "$P $name" >> $OBJ/res.log
		FAILRUN=""
	else
		echo "$Q $name"
		echo "$Q $name" >> $OBJ/res.log
		sed -e 3q m.log
		FAILRUN="$FAILRUN."
	fi
	# Install every name this library answers to.  libtermlib answers both
	# -ltermcap and -ltermlib from one build, and dropping the second loses
	# three of the tree's asks.
	if test $built = y
	then
		for i in $inst
		do
			cp $arch /usr/lib/$i
		done
	fi
	cd $OBJ
	rm -rf $LD
	case "$FAILRUN" in
	..........*)
		echo "NO$SP"
		echo "ten consecutive libraries failed -- something systemic"
		exit 1
		;;
	esac
done

# ---------------------------------------------------------------- tallies ---
# THE GUEST COUNTS TOO, so the host has something to disagree with.  Stage 2
# printed a total that contradicted its own assertion four lines above and
# nothing compared them; v10-libs.sh refuses to report when these disagree.
#
# No `wc' on this machine -- `sed -n $=' is the line count.  The labels are
# TALLYB/TALLYF/TALLYA and NOT the tokens: a tally printed as `TALLY-LBUILT 27'
# would be found by an unanchored host-side count of `LBUILT <word>' inside its
# own summary line and inflate the total by one.  Anchoring the host pattern is
# not the fix, because the tty splice is what defeats anchors; a different
# string is.
for t in "$P TALLYB" "$Q TALLYF" "$A TALLYA" "$Z TALLYZ"
do
	set -- $t
	sed -e "/^$1 /!d" $OBJ/res.log > t.log
	n=`sed -n '$=' t.log`
	if test -z "$n"; then n=0; fi
	echo "$2 $n"
done
sed -e "/^$M-no /!d" $OBJ/mem.log > t.log 2>/dev/null
n=`sed -n '$=' t.log`
if test -z "$n"; then n=0; fi
echo "TALLYM $n"
echo "LIBSC-done"
'''


GENERATED = [
    ("libs.txt", libs_txt),
    ("libs.units", libs_units),
    ("libs.objs", libs_objs),
    ("libs.orcl", libs_orcl),
    ("libs.cf", libs_cf),
    ("libs.inc", libs_inc),
    ("libs.cpio", libs_cpio),
    ("libsc.sh", lambda libs, dem: LIBSC),
]


def main():
    args = sys.argv[1:]
    libs = inventory()
    dem = demand()

    if "--demand" in args:
        for flag, n in sorted(dem.items(), key=lambda kv: -kv[1]):
            print("%5d  -l%s" % (n, flag))
        return 0

    if "--check" in args or "--write" in args:
        sanity(libs)
        for name, _fn in GENERATED:
            if len(name) > 14:
                sys.exit("v10-libs: generated name %r is over 14 characters, "
                         "which a guest filesystem truncates SILENTLY and with "
                         "a successful exit status" % name)
        stale = []
        for name, fn in GENERATED:
            path = os.path.join(GEN, name)
            want = fn(libs, dem)
            if "--check" in args:
                if read(path) != want:
                    stale.append(name)
                continue
            with open(path, "w") as fh:
                fh.write(want)
        if "--check" in args:
            if stale:
                sys.stderr.write("v10-libs: out of date: %s -- run "
                                 "tools/v10-libs.py --write\n"
                                 % " ".join(stale))
                return 1
            print("v10-libs: v10/mk/gen/libs.* are current (%d libraries)"
                  % len([u for u in libs if not u["done"]]))
            return 0
        print("v10-libs: wrote %s (%d libraries)"
              % (" ".join(n for n, _ in GENERATED),
                 len([u for u in libs if not u["done"]])))
        return 0

    sanity(libs)
    return report(libs, dem)


if __name__ == "__main__":
    sys.exit(main())
