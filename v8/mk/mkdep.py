#!/usr/bin/env python3
"""
Generate the makefiles Research Unix never had.

    v8/mk/mkdep.py            # regenerate v8/mk/gen/*.mk
    v8/mk/mkdep.py --check    # fail if the committed output is stale

V8's make is V7's make: suffix rules, macros, `include` (yes, really -- see
gram.y's isinclude()), and command-line macro assignment. What it does not have
is any way to discover that foo.o depends on a header three includes deep. It
compares mtimes against an explicit prerequisite list and nothing more.

So the list is written for it, here, on the host, and committed. That is not a
modern imposition on a 1985 system: it is exactly what V8 already does for the
kernel, where config(8) reads conf/files and writes the makefile. This does for
userland what Bell Labs did for the kernel.

WHAT EACH RULE DEPENDS ON

The point of generating rather than hand-writing is that the dependencies which
actually invalidate a target can be stated in full:

    every .o   ->  its .c, every header it reaches transitively,
                   and $(CC) $(CCOM) $(CPP) $(C2) $(AS)
    every bin  ->  its .o files, $(LD), and $(LIBC)
    yacc out   ->  its .y and $(YACC)
    lex out    ->  its .l and $(LEX)

Changing the compiler therefore rebuilds the world, changing yacc rebuilds the
compiler and then the world, and changing libc relinks everything -- which is
the real dependency structure of a self-hosting system, and the reason a plain
loop over directories quietly produces a system built by two different
compilers.

WHAT IS DELIBERATELY NOT GENERATED

An `install` target that writes into `/`. The tape's own makefiles do -- the
worst is ccom's, which is

    install: comp
            cp /lib/ccom comp.sv
            cp comp /lib/ccom

i.e. it overwrites the compiler you are compiling with. Our makefiles install
into $(TOOLDIR) or $(DESTDIR) and nowhere else; see docs/build-from-source.md.
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
V8 = os.path.dirname(HERE)
GEN = os.path.join(HERE, "gen")

INCLUDE = re.compile(rb'^\s*#\s*include\s*([<"])([^">]+)[">]', re.M)

# --------------------------------------------------------------- components
#
# Stage 1: the bootstrap toolchain, in the order the source dictates.  yacc is
# first because make, lex, cpp and -- crucially -- ccom are all yacc grammars;
# see docs/build-from-source.md for the evidence.  This table is explicit
# rather than discovered because the order is the whole point, and fifteen
# entries you can read beats a heuristic you have to trust.
#
#   objs: object -> source, relative to dir.  "*.c" means every .c in dir.
#   gen:  generated source -> (tool, input, extra shell)
#
STAGE1 = [
    # Every object list below is the LINK list from the tape's own makefile,
    # transcribed with the file it came from.  Globbing *.c instead is wrong
    # often enough to matter: lex #includes ldefs.c and once.c rather than
    # compiling them, strip's directory also builds a second program, and cpp
    # links a generated rodata.c that does not exist until yacc has run.
    dict(name="yacc", dir="usr/src/cmd/yacc", objs="*.c", cflags="-DWORD32",
         product="yacc", install="bin/yacc",
         # /usr/lib, not /lib: yacc/files has
         #     # define PARSER "/usr/lib/yaccpar"
         # unconditionally, so a yacc we build reads that absolute path
         # whatever TOOLDIR says.  Installing our copy there keeps the
         # tape's layout; making the build properly hermetic needs
         # PARSER behind an #ifndef, which is a change to our source and
         # a later stage's problem.
         data=[("yaccpar", "usr/lib/yaccpar")],
         note="yacc/Makefile: y?.o, CFLAGS=-O -DWORD32"),

    # -DVERSION8 is not decoration: make/defs uses it to pick <ndir.h> over
    # <sys/dir.h>, and without it make will not compile at all.
    dict(name="make", dir="usr/src/cmd/make",
         objs=["ident.c", "main.c", "doname.c", "dosys.c", "misc.c", "files.c"],
         gen={"gram.c": ("yacc", "gram.y", None)},
         cflags="-DASCARCH -DVERSION8",
         product="make", install="bin/make",
         note="make/Makefile: OBJECTS, CFLAGS=-O -DASCARCH -DVERSION8"),

    # lex links y.tab.o straight from yacc's output, and lmain.c #includes
    # ldefs.c and once.c -- compiling those separately gives duplicate symbols.
    dict(name="lex", dir="usr/src/cmd/lex",
         objs={"lmain.o": "lmain.c", "y.tab.o": "y.tab.c",
               "sub1.o": "sub1.c", "sub2.o": "sub2.c", "header.o": "header.c"},
         gen={"y.tab.c": ("yacc", "parser.y", None)},
         product="lex", install="usr/bin/lex",
         data=[("ncform", "usr/lib/lex/ncform")],
         note="lex/Makefile: lex: lmain.o y.tab.o sub1.o sub2.o header.o"),

    # cpy.c comes from yacc, then :yyfix splits the parser tables out into
    # rodata.c so they can be linked read-only (-R).  Both are generated.
    dict(name="cpp", dir="usr/src/cmd/cpp",
         objs={"cpp.o": "cpp.c", "cpy.o": "cpy.c", "rodata.o": "rodata.c"},
         # :yyfix is a script that lives in cpp's OWN source directory, and
         # the tape's makefile invokes it bare -- which only resolves when you
         # build in-tree with "." on PATH.  Off the share it is "sh: :yyfix:
         # not found".  (pcc1's makefile says ./:yyfix, so the tape is
         # inconsistent with itself here.)  Run it through sh with a full path:
         # sh does not need the executable bit to have survived the wire, and
         # the script itself is cwd-relative in the right way -- it rewrites
         # the y.tab.c yacc just produced in the object directory.
         sidegen={"rodata.c": "cpy.c"},
         gen={"cpy.c": ("yacc", "cpy.y",
                        "sh $(SRC)/usr/src/cmd/cpp/:yyfix "
                        "yyexca yyact yypact yypgo yyr1 yyr2 yychk yydef; "
                        "mv y.tab.c cpy.c")},
         cflags="-Dunix=1 -Dvax=1 -DFLEXNAMES -DMTIME",
         oflags={"rodata.o": "-R"},
         product="cpp", install="lib/cpp",
         note="cpp/Makefile: cpp: cpp.o cpy.o rodata.o"),

    # The C compiler.  OFILES from ccom/vax/makefile is the link list; the
    # longer CFILES there is the lint list, and the VAX build uses Bell Labs'
    # gencode.c rather than pcc's table-driven matcher, which is why cgen.o,
    # match.o, allo.o and table.o are absent and no `sty` is needed.
    dict(name="ccom", dir="usr/src/cmd/ccom/vax",
         objs={
             "cgram.o": "cgram.c",
             "xdefs.o": "../common/xdefs.c",
             "scan.o": "../common/scan.c",
             "pftn.o": "../common/pftn.c",
             "trees.o": "../common/trees.c",
             "optim.o": "../common/optim.c",
             "local.o": "local.c",
             "reader.o": "../common/reader.c",
             "local2.o": "local2.c",
             "debug.o": "debug.c",
             "common1.o": "../common/common1.c",
             "memcpy.o": "memcpy.c",
             "pjw.o": "../common/pjw.c",
             "gencode.o": "gencode.c",
             "genaux.o": "genaux.c",
             "printx.o": "printx.c",
             "lookup.o": "../common/lookup.c",
             "lcatch2.o": "lcatch2.c",
             "catch2.o": "../common/catch2.c",
             # common/, not vax/ -- the tape's makefile says
             #     t2print.o: $M/mfile2.h $M/t2print.c
             # and $M is the common directory.  In-tree this was masked
             # by nothing; out-of-tree it is a hard "Don't know how to
             # make .../vax/t2print.c".
             "t2print.o": "../common/t2print.c",
         },
         # cgram.c is yacc's output with the #line directives commented out --
         # V8's cpp chokes on them in a generated file, hence the tape's sed.
         gen={"cgram.c": ("yacc", "../common/cgram.y",
                          "sed 's_^# line .*_/* & */_' y.tab.c >cgram.c; rm -f y.tab.c")},
         incs=[".", "../common"], cflags="-DVAX -DYYDEBUG",
         # cgram.o wants y.debug present; the tape ships y.debug.sv for it.
         # y.debug.sv ships in the source directory, so an out-of-tree
         # build has to name it: bare "cp y.debug.sv y.debug" looks for
         # it in the object directory and fails.
         pre=["cp $(SRC)/usr/src/cmd/ccom/vax/y.debug.sv y.debug"],
         product="comp", install="lib/ccom"),

    dict(name="c2", dir="usr/src/cmd/c2", objs="*.c", cflags="-DCOPYCODE",
         oflags={"c22.o": "-R"}, ldflags="-z",
         product="c2", install="lib/c2",
         note="c2/Makefile: c20.o c21.o c22.o, c22 with -R, link -z"),

    dict(name="as", dir="usr/src/cmd/as", objs="*.c",
         cflags="-DUNIX -DUNIXDEVEL -DFLEXNAMES",
         product="as", install="bin/as",
         note="as/Makefile: OBJS, CFLAGS=-DUNIX -DUNIXDEVEL -DFLEXNAMES"),

    dict(name="ld", dir="usr/src/cmd", objs=["ld.c"], product="ld", install="bin/ld"),
    dict(name="ar", dir="usr/src/cmd", objs=["ar.c"], product="ar", install="bin/ar"),
    dict(name="ranlib", dir="usr/src/cmd", objs=["ranlib.c"], product="ranlib",
         install="usr/bin/ranlib"),
    dict(name="nm", dir="usr/src/cmd", objs=["nm.c"], product="nm", install="bin/nm"),
    dict(name="size", dir="usr/src/cmd", objs=["size.c"], product="size", install="bin/size"),

    # The directory also builds `stab`; prtsym.o and stab.o belong to that,
    # not to strip, so *.c would link two programs' worth of objects.
    dict(name="strip", dir="usr/src/cmd/strip",
         objs=["strip.c", "rdout.c", "shrink.c", "symwrite.c", "hash.c", "fcopy.c"],
         cflags="-d2", product="strip", install="bin/strip",
         note="strip/Makefile: STRIP=, CFLAGS=-Od2"),

    dict(name="cc", dir="usr/src/cmd", objs=["cc.c"], product="cc", install="bin/cc"),
]


# ------------------------------------------------------------------ scanning


def scan_includes(path, incdirs, seen=None):
    """Transitive #include closure, as filenames make can compare mtimes on.

    Angle-bracket includes are followed too, but only into the tree -- a
    <stdio.h> resolved against v8/usr/include is a real dependency, because
    stage 4 installs our headers and we want that to rebuild the world.
    Unresolvable includes are dropped rather than guessed at.
    """
    if seen is None:
        seen = set()
    if path in seen or not os.path.exists(path):
        return seen
    seen.add(path)
    try:
        data = open(path, "rb").read()
    except OSError:
        return seen
    base = os.path.dirname(path)
    for kind, name in INCLUDE.findall(data):
        name = name.decode("ascii", "replace")
        cands = [os.path.join(base, name)] if kind == b'"' else []
        cands += [os.path.join(d, name) for d in incdirs]
        for c in cands:
            c = os.path.normpath(c)
            if os.path.exists(c):
                scan_includes(c, incdirs, seen)
                break
    return seen


def rel(path, start):
    return os.path.relpath(path, start).replace(os.sep, "/")


# ----------------------------------------------------------------- emission

PREAMBLE = """\
# Generated by v8/mk/mkdep.py -- do not edit; edit the generator.
#
# Run from the component's source directory:
#     make -f $SRC/mk/gen/%(name)s.mk TOOLDIR=... install
#
# Every object below depends on the compiler passes that produced it, so
# replacing $(CCOM) rebuilds all of them; every binary depends on $(LD) and
# $(LIBC). That is the invalidation a self-hosting build needs and V8's make
# cannot work out for itself.

# Source is READ ONLY and lives on the netfs share.  Nothing is ever copied to
# local disk: objects are written into the current directory, which the driver
# makes a per-component directory on the build filesystem.  That is what the
# share is for, and it is why $(SRC) appears on every source path below.
SRC     = /n/src
TOOLDIR = /b/tools
DESTDIR = /b/root

# Stage 0 is the running system; later stages override these to point -B at
# the tools they just built.  Nothing here ever writes outside
# $(TOOLDIR)/$(DESTDIR).
#
# Each of cc, yacc and lex needs TWO macros, and they are not interchangeable.
# $(CC) is what a rule runs -- a command, resolved on PATH, and in later
# stages a whole phrase with -B and -t in it.  $(CCPATH) is the file whose
# timestamp means "the compiler changed", and that is what a prerequisite list
# needs.  Writing "CC = cc" and then using $(CC) as a prerequisite produced
#
#	Make:  Don't know how to make cc.  Stop.
#
# on all fourteen components at once: make went looking for a file named cc in
# the build directory.  The other tools are already absolute paths, so they
# serve as both.
CC       = cc
CCPATH   = /bin/cc
YACC     = yacc
YACCPATH = /usr/bin/yacc
LEX      = lex
LEXPATH  = /usr/bin/lex
CPP  = /lib/cpp
CCOM = /lib/ccom
C2   = /lib/c2
AS   = /bin/as
LD   = /bin/ld
AR   = /bin/ar
LIBC = /lib/libc.a

# Where <angle-bracket> headers really come from.  Stage 1 builds against the
# running system, like any bootstrap; stage 5 onward points this at
# $(DESTDIR)/usr/include so touching our headers rebuilds what includes them.
INCDIR = $(SRC)/usr/include

CFLAGS = -O %(cflags)s
INCS   = %(incs)s -I$(INCDIR)
COMPILE = $(CC) $(CFLAGS) $(INCS) -c
TOOLS  = $(CCPATH) $(CCOM) $(CPP) $(C2) $(AS)

"""


def emit(c):
    d = os.path.join(V8, c["dir"])
    incs = c.get("incs", ["."])
    incdirs = [os.path.normpath(os.path.join(d, i)) for i in incs]
    incdirs.append(os.path.join(V8, "usr/include"))

    # resolve the object -> source map
    objs = c["objs"]
    if objs == "*.c":
        srcs = sorted(f for f in os.listdir(d) if f.endswith(".c"))
        objmap = {f[:-2] + ".o": f for f in srcs}
    elif isinstance(objs, list):
        objmap = {os.path.basename(f)[:-2] + ".o": f for f in objs}
    else:
        objmap = dict(objs)

    gen = c.get("gen", {})
    # Files produced as a SIDE EFFECT of another generated file's rule,
    # mapped to the target that produces them.  cpp's :yyfix splits the
    # parser tables out of y.tab.c into rodata.c while making cpy.c, so
    # rodata.c exists only in the object directory and has no rule and no
    # file on the share.  Without this it is looked for at
    # $(SRC)/usr/src/cmd/cpp/rodata.c and make stops.
    sidegen = c.get("sidegen", {})
    # a generated .c has no file on disk yet; its deps come from the grammar
    for g in gen:
        objmap.setdefault(g[:-2] + ".o", g)

    incdir = os.path.join(V8, "usr/include")

    srcdir = "$(SRC)/" + c["dir"]

    def dep(path):
        """Name a dependency the way make will see it at build time.

        System headers become $(INCDIR)/x.h rather than a relative path, so the
        same makefile is correct in stage 1 (reading the running system's
        /usr/include) and in stage 5 (reading $(DESTDIR)/usr/include) with only
        the macro changed.
        """
        path = os.path.normpath(path)
        if path.startswith(incdir + os.sep):
            return "$(INCDIR)/" + rel(path, incdir)
        return srcdir + "/" + rel(path, d)

    out = [PREAMBLE % dict(name=c["name"], cflags=c.get("cflags", ""),
                           incs=" ".join("-I$(SRC)/" + os.path.normpath(
                               os.path.join(c["dir"], i)) for i in incs))]
    out.append("OBJS = " + " ".join(sorted(objmap)) + "\n")
    out.append("\nall: %s\n" % c["product"])

    # link
    # $(LIBC) is NAMED on the link line, not merely depended on.  cc appends an
    # implicit -lc, which ld resolves from /lib/libc.a -- so a stage that has
    # built its own libc would silently keep linking against the tape's unless
    # the archive is on the command line ahead of it.  ld takes the first
    # definition it finds, so ours wins and the implicit -lc adds nothing.
    # In stage 1 this is /lib/libc.a either way and costs nothing.
    out.append("\n%s: $(OBJS) $(LD) $(LIBC)\n\t$(CC) $(CFLAGS) %s-o %s $(OBJS) $(LIBC)\n"
               % (c["product"], (c["ldflags"] + " ") if c.get("ldflags") else "",
                  c["product"]))

    # generated sources
    for target, (tool, src, extra) in sorted(gen.items()):
        toolmac = "$(YACC)" if tool == "yacc" else "$(LEX)"
        # command vs binary again: the recipe runs $(YACC), the
        # prerequisite must name the file whose mtime says it changed.
        toolpath = "$(YACCPATH)" if tool == "yacc" else "$(LEXPATH)"
        deps = sorted(dep(p) for p in scan_includes(os.path.join(d, src), incdirs))
        # compare against the full path: deps hold "$(SRC)/dir/gram.y" while
        # src is the bare "gram.y", so a bare comparison never matched and the
        # input was listed twice.
        self = "%s/%s" % (srcdir, src)
        out.append("\n%s: %s %s %s\n" % (target, self, toolpath,
                                         " ".join(x for x in deps if x != self)))
        out.append("\t%s %s/%s\n" % (toolmac, srcdir, src))
        if extra:
            out.append("\t%s\n" % extra)
        elif target != "y.tab.c":
            out.append("\tmv y.tab.c %s\n" % target)

    # side-effect files: a rule with prerequisites and no commands, which is
    # exactly what make needs to know "build that, and this will be there".
    for target, producer in sorted(sidegen.items()):
        out.append("\n# written by the %s rule above\n%s: %s\n" % (producer, target, producer))

    # objects, each with its transitive header closure
    oflags = c.get("oflags", {})
    for obj in sorted(objmap):
        src = objmap[obj]
        if src in gen or src in sidegen:     # generated: deps handled above
            deps = [src]
        else:
            deps = [srcdir + "/" + src] + [
                x for x in sorted(dep(y) for y in
                                  scan_includes(os.path.join(d, src), incdirs))
                if x != srcdir + "/" + src]
        extra = (oflags[obj] + " ") if obj in oflags else ""
        # A generated or side-effect source is compiled from the object
        # directory, not from the share.  Getting this right in the
        # prerequisite but not in the recipe just moves the error from
        # make ("Don't know how to make") to cc ("No source file").
        srcref = src if (src in gen or src in sidegen) else srcdir + "/" + src
        out.append("\n%s: %s $(TOOLS)\n\t$(COMPILE) %s%s\n"
                   % (obj, " ".join(deps), extra, srcref))

    # pre-commands (ccom needs y.debug in place before cgram.o)
    if c.get("pre"):
        out.append("\nprepare:\n")
        for cmd in c["pre"]:
            out.append("\t%s\n" % cmd)

    # install -- into TOOLDIR only.  Never /bin, never /lib.
    out.append("\ninstall: %s\n" % c["product"])
    inst = c["install"]
    out.append("\t-mkdir $(TOOLDIR)/%s\n" % os.path.dirname(inst))
    out.append("\tcp %s $(TOOLDIR)/%s\n" % (c["product"], inst))
    for src, dst in c.get("data", []):
        out.append("\t-mkdir $(TOOLDIR)/%s\n" % os.path.dirname(dst))
        out.append("\tcp %s/%s $(TOOLDIR)/%s\n" % (srcdir, src, dst))

    out.append("\nclean:\n\t-rm -f $(OBJS) %s %s\n"
               % (c["product"], " ".join(sorted(gen))))
    return "".join(out)


LIBC_PREAMBLE = """\
# Generated by v8/mk/mkdep.py -- do not edit; edit the generator.
#
#     make -f $SRC/mk/gen/libc.mk TOOLDIR=... install
#
# libc.a, built the way usr/src/libc/Makefile builds it, out of tree and
# installing into $(TOOLDIR)/lib instead of over the libc you are compiling
# against.  See mkdep.py's emit_libc() for why each odd step is here.

SRC     = /n/src
TOOLDIR = /b/tools
DESTDIR = /b/root

CC       = cc
CCPATH   = /bin/cc
CPP  = /lib/cpp
CCOM = /lib/ccom
C2   = /lib/c2
AS   = /bin/as
LD   = /bin/ld
AR   = /bin/ar
RANLIB = /usr/bin/ranlib
LIBC = /lib/libc.a

INCDIR = $(SRC)/usr/include

# -I$(INCDIR) so the library is built against OUR headers, which is the whole
# reason for owning them.  No -I of the source tree: libc's own sources include
# only <angle-bracket> headers.
CFLAGS = -O -I$(INCDIR)
TOOLS  = $(CCPATH) $(CCOM) $(CPP) $(C2) $(AS)

"""


# ------------------------------------------------------------------ libc
#
# libc is not another entry in STAGE1: it is an archive, not a program, and
# almost every step of the tape's recipe is a special case.  Generating it
# separately is honest about that.
#
# usr/src/libc/Makefile builds it as
#
#	cc -c -O crt/*.s gen/*.[cs] math/*.c stdio/*.c sys/*.s
#	rm errlst.o; make errlst.o          # compile to .s, ed it, assemble
#	cp stdio/doprnt.S doprnt.c; cc -E doprnt.c | as -o doprnt.o
#	for i in *.o; do ld -x -r $i; mv a.out $i; done
#	ar cr libc.a `lorder *.o | tsort`
#	ar ma flsbuf.o libc.a exit.o
#	ar m libc.a cleanup.o
#
# Four of those are not derivable and must be carried across verbatim:
#
#   errlst.c is compiled to assembly and then EDITED -- gen/:errfix moves the
#   error-message table from .data to .text so it lands in shared text.
#
#   doprnt.S is assembly that needs the C preprocessor first, which cc will not
#   do for a .s file, so it is renamed to .c to get -E and piped to as.
#
#   `ld -x -r` on every object strips local symbols and re-emits it relocatable.
#   Skipping it does not fail the build; it inflates every binary that links
#   libc and pollutes the symbol table.
#
#   `lorder | tsort` orders the archive members, and the two `ar m` calls fix
#   up what the topological sort cannot know.  V8's ld is SINGLE PASS: it walks
#   an archive once, so a member that needs a symbol defined in an earlier
#   member never resolves.  Order is correctness here, not tidiness.
#
# crt0.o and mcrt0.o are built but are NOT members of libc.a -- they are the
# startup files ld links in front of every program.
#
# What we do not carry across is the tape's `install`, which begins
#	cp $(DESTDIR)/lib/libc.a liboc.a
#	cp libc.a $(DESTDIR)/lib/libc.a
# i.e. it overwrites the libc you are building against.  Ours installs into
# $(TOOLDIR)/lib and nowhere else.
LIBC_DIR = "usr/src/libc"
# gen/errlst.c and stdio/doprnt.S have their own rules below and must not be
# picked up by the ordinary per-file scan.
LIBC_SPECIAL = {"errlst.c", "doprnt.S"}


def emit_libc():
    d = os.path.join(V8, LIBC_DIR)
    srcdir = "$(SRC)/" + LIBC_DIR
    incdir = os.path.join(V8, "usr/include")
    incdirs = [incdir]

    def dep(path):
        path = os.path.normpath(path)
        if path.startswith(incdir + os.sep):
            return "$(INCDIR)/" + rel(path, incdir)
        return srcdir + "/" + rel(path, d)

    # (object, source-relative-path).  Order of directories follows the tape's
    # recipe; within a directory, sorted, so the output is stable.
    members = []
    for sub in ("crt", "gen", "math", "stdio", "sys"):
        p = os.path.join(d, sub)
        if not os.path.isdir(p):
            continue
        for f in sorted(os.listdir(p)):
            if f in LIBC_SPECIAL:
                continue
            if not (f.endswith(".c") or f.endswith(".s")):
                continue
            members.append((f[:-2] + ".o", sub + "/" + f))
    # the two with hand-written rules
    members.append(("errlst.o", "gen/errlst.c"))
    members.append(("doprnt.o", "stdio/doprnt.S"))
    members.sort()

    out = [LIBC_PREAMBLE]
    out.append("OBJS = " + " ".join(o for o, _ in members) + "\n")

    out.append("""
all: libc.a crt0.o mcrt0.o

# The recipe below is the tape's, with the archive ordering intact.  See the
# note in mkdep.py for why each step is here.
libc.a: $(OBJS)
	-for i in *.o ; do $(LD) -x -r $$i; mv a.out $$i; done
	$(AR) cr libc.a `lorder *.o | tsort`
	$(AR) ma flsbuf.o libc.a exit.o
	$(AR) m libc.a cleanup.o
	$(RANLIB) libc.a

# gen/:errfix rewrites the compiled error table from .data to .text.  The
# filename really does start with a colon; it is a V7 convention for a script
# that is not a command you would type.
errlst.o: $(SRC)/usr/src/libc/gen/errlst.c $(TOOLS)
	$(CC) $(CFLAGS) -S $(SRC)/usr/src/libc/gen/errlst.c
	ed - errlst.s < $(SRC)/usr/src/libc/gen/:errfix
	$(AS) -o errlst.o errlst.s
	rm -f errlst.s

# doprnt.S is assembly that needs cpp, and cc will not preprocess a .s.
# Renaming it to .c is how the tape gets -E to look at it.
doprnt.o: $(SRC)/usr/src/libc/stdio/doprnt.S $(TOOLS)
	cp $(SRC)/usr/src/libc/stdio/doprnt.S doprnt.c
	$(CC) -E doprnt.c | $(AS) -o doprnt.o
	rm -f doprnt.c

# Startup files: linked in front of every program, not members of libc.a.
crt0.o: $(SRC)/usr/src/libc/csu/crt0.s $(TOOLS)
	$(CC) $(CFLAGS) -c $(SRC)/usr/src/libc/csu/crt0.s

mcrt0.o: $(SRC)/usr/src/libc/csu/mcrt0.s $(TOOLS)
	$(CC) $(CFLAGS) -c $(SRC)/usr/src/libc/csu/mcrt0.s
""")

    for obj, src in members:
        if obj in ("errlst.o", "doprnt.o"):
            continue
        full = os.path.join(d, src)
        if src.endswith(".c"):
            deps = [srcdir + "/" + src] + [
                x for x in sorted(dep(y) for y in scan_includes(full, incdirs))
                if x != srcdir + "/" + src]
        else:
            # as(1) has no #include we scan; the source alone is the dependency
            deps = [srcdir + "/" + src]
        out.append("\n%s: %s $(TOOLS)\n\t$(CC) $(CFLAGS) -c %s/%s\n"
                   % (obj, " ".join(deps), srcdir, src))

    out.append("""
install: libc.a crt0.o mcrt0.o
	-mkdir $(TOOLDIR)/lib
	cp libc.a $(TOOLDIR)/lib/libc.a
	$(RANLIB) $(TOOLDIR)/lib/libc.a
	cp crt0.o $(TOOLDIR)/lib/crt0.o
	cp mcrt0.o $(TOOLDIR)/lib/mcrt0.o

clean:
	-rm -f $(OBJS) libc.a crt0.o mcrt0.o
""")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the committed makefiles are stale")
    args = ap.parse_args()

    os.makedirs(GEN, exist_ok=True)
    stale = []
    for c in STAGE1:
        text = emit(c)
        path = os.path.join(GEN, c["name"] + ".mk")
        old = open(path).read() if os.path.exists(path) else None
        if args.check:
            if old != text:
                stale.append(c["name"])
        elif old != text:
            open(path, "w").write(text)

    text = emit_libc()
    path = os.path.join(GEN, "libc.mk")
    old = open(path).read() if os.path.exists(path) else None
    if args.check:
        if old != text:
            stale.append("libc")
    elif old != text:
        open(path, "w").write(text)

    # the stage-1 order, as a file the driver reads rather than a second copy
    order = os.path.join(GEN, "stage1.order")
    text = "".join("%s\t%s\t%s\n" % (c["name"], c["dir"], c["install"]) for c in STAGE1)
    if args.check:
        if not os.path.exists(order) or open(order).read() != text:
            stale.append("stage1.order")
    else:
        open(order, "w").write(text)

    if args.check:
        if stale:
            print("stale, re-run v8/mk/mkdep.py: " + " ".join(stale))
            return 1
        print("makefiles are up to date with the source tree")
        return 0
    print("generated %d component makefiles in %s" % (len(STAGE1), rel(GEN, os.getcwd())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
