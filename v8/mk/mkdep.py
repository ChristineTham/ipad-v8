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
         # /usr/lib, not /lib, because that is where the tape puts it and
         # yacc/files still compiles that path in as the DEFAULT.  It is no
         # longer the only answer: y1.c now reads $YACCPAR first (S5), so a
         # staged build points each stage's yacc at its own parser text
         # without changing the binary -- which matters, because a compiled-in
         # path would make stage 1's yacc and stage 3's yacc differ by an
         # embedded string and fail the fixpoint test for no real reason.
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

    # `also` puts a second copy in lib/, which is the directory cc's -B prefix
    # names.  cc executes as and ld; with S5's -t a and -t l they come out of
    # the pass directory alongside ccom, cpp, c2, crt0.o and libc.a, so one
    # prefix seals everything the compiler runs.  bin/ is for people and for
    # makefiles that invoke the assembler directly.  Two copies of a 60 KB
    # program on a scratch filesystem is not a cost worth designing around.
    dict(name="as", dir="usr/src/cmd/as", objs="*.c",
         cflags="-DUNIX -DUNIXDEVEL -DFLEXNAMES",
         product="as", install="bin/as", also=["lib/as"],
         note="as/Makefile: OBJS, CFLAGS=-DUNIX -DUNIXDEVEL -DFLEXNAMES"),

    dict(name="ld", dir="usr/src/cmd", objs=["ld.c"], product="ld",
         install="bin/ld", also=["lib/ld"]),
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


def emit_shell(c):
    """A command that is a shell script: install is the whole build.

    Four of them (bundle, cflow, false, where). They still get a makefile
    rather than a line in the driver, because stage 9 has to be able to
    rebuild the system the same way stage 6 built it, and "the same way"
    means the same rules. A script whose install lives in a driver instead
    would be the one thing chroot could not reproduce.

    The copy is deliberate rather than installing straight off the share: the
    product has to exist in the object directory for `make' to have anything
    to compare mtimes against, exactly like a binary.
    """
    srcdir = "$(SRC)/" + c["dir"]
    src = "%s/%s" % (srcdir, c["script"])
    dest = "$(%s)" % c.get("dest", "DESTDIR")
    out = [PREAMBLE % dict(name=c["name"], cflags="", incs="")]
    # `all' first, like every other generated makefile: the driver runs
    # `make -f x.mk' with no goal, so the first target is the default one.
    out.append("\nall: %s\n" % c["product"])
    out.append("\n%s: %s\n\tcp %s %s\n\tchmod +x %s\n"
               % (c["product"], src, src, c["product"], c["product"]))
    out.append("\ninstall: %s\n" % c["product"])
    out.append("\t-mkdir %s/%s\n" % (dest, os.path.dirname(c["install"])))
    out.append("\tcp %s %s/%s\n" % (c["product"], dest, c["install"]))
    out.append("\nclean:\n\t-rm -f %s\n" % c["product"])
    return "".join(out)


def emit(c):
    d = os.path.join(V8, c["dir"])
    if c.get("script"):
        return emit_shell(c)
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

    # A component that GENERATES A HEADER needs -I. as well, and it is the
    # mirror image of libI77's problem.  cpp searches dirs[0] -- the directory
    # of the file being compiled -- and never the current directory unless the
    # source happens to be in it.  y.tab.h is written by `yacc -d' into the
    # OBJECT directory, while config's main.c is read off the share, so
    #
    #	main.c:14: Can't find include file y.tab.h
    #
    # even though y.tab.h was made correctly a moment earlier.  lex.yy.c
    # compiles fine in the same directory precisely because IT lives there
    # too.  An in-tree build never sees this: source and object are one
    # directory, so dirs[0] covers both.
    incflags = ["-I$(SRC)/" + os.path.normpath(os.path.join(c["dir"], i))
                for i in incs]
    if gen or sidegen:
        incflags.insert(0, "-I.")
    out = [PREAMBLE % dict(name=c["name"], cflags=c.get("cflags", ""),
                           incs=" ".join(incflags))]
    out.append("OBJS = " + " ".join(sorted(objmap)) + "\n")
    out.append("\nall: %s\n" % c["product"])

    # link
    # $(LIBC) is NAMED on the link line, not merely depended on.  cc appends an
    # implicit -lc, which ld resolves from /lib/libc.a -- so a stage that has
    # built its own libc would silently keep linking against the tape's unless
    # the archive is on the command line ahead of it.  ld takes the first
    # definition it finds, so ours wins and the implicit -lc adds nothing.
    # In stage 1 this is /lib/libc.a either way and costs nothing.
    #
    # `libs` names extra archives BY PATH, never with -l.  V8's ld has no -L:
    # getfile() rewrites one template string to try /lib, /usr/lib and
    # /usr/local/lib, so -ll would resolve out of the RUNNING system's
    # /usr/lib in preference to the libl.a stage 5 just built -- silently, and
    # the build would succeed.  config(8) is the first component that needs
    # this and it will not be the last.
    libdeps = "".join(" $(DESTDIR)/" + x for x in c.get("libs", []))
    out.append("\n%s: $(OBJS) $(LD) $(LIBC)%s\n\t$(CC) $(CFLAGS) %s-o %s $(OBJS)%s $(LIBC)\n"
               % (c["product"], libdeps,
                  (c["ldflags"] + " ") if c.get("ldflags") else "",
                  c["product"], libdeps))

    # generated sources
    for target, (tool, src, extra) in sorted(gen.items()):
        # `tool` may carry flags -- "yacc -d", which config(8) needs because
        # its grammar and mkconf.c share y.tab.h and nothing else generates
        # it.  First word picks the macro pair, the rest rides on the command.
        toolname = tool.split()[0]
        toolflags = " ".join(tool.split()[1:])
        # command vs binary again: the recipe runs $(YACC), the
        # prerequisite must name the file whose mtime says it changed.
        # `natural` is the filename the tool writes if you do not tell it
        # otherwise, so a target that differs from it needs the mv -- and
        # lex's is not yacc's, which the old "!= y.tab.c" test got wrong the
        # moment a lex-generated source appeared.
        if toolname == "yacc":
            toolmac, toolpath, natural = "$(YACC)", "$(YACCPATH)", "y.tab.c"
        else:
            toolmac, toolpath, natural = "$(LEX)", "$(LEXPATH)", "lex.yy.c"
        deps = sorted(dep(p) for p in scan_includes(os.path.join(d, src), incdirs))
        # compare against the full path: deps hold "$(SRC)/dir/gram.y" while
        # src is the bare "gram.y", so a bare comparison never matched and the
        # input was listed twice.
        self = "%s/%s" % (srcdir, src)
        out.append("\n%s: %s %s %s\n" % (target, self, toolpath,
                                         " ".join(x for x in deps if x != self)))
        out.append("\t%s%s %s/%s\n"
                   % (toolmac, (" " + toolflags) if toolflags else "",
                      srcdir, src))
        if extra:
            out.append("\t%s\n" % extra)
        elif target != natural:
            out.append("\tmv %s %s\n" % (natural, target))

    # Side-effect files: "build that, and this will be there."
    #
    # The @echo is not decoration.  A command-less target takes doname.c's
    #     else if(keepgoing) printf("Don't know how to make %s\n", ...)
    # branch whenever it is reached while the file still does not exist --
    # and `exists()` returns 0 for a missing name, with ptime sampled on
    # ENTRY, before the producer runs.  rodata.c has got away with it only
    # because cpy.o sorts before rodata.o, so cpy.c (and therefore rodata.c)
    # was always already made by the time make looked.  y.tab.h has no such
    # luck: main.o and mkconf.o both sort before y.tab.o.  Rather than rely
    # on alphabetical order, give every side-effect target a command.
    for target, producer in sorted(sidegen.items()):
        out.append("\n# written by the %s rule above\n%s: %s\n\t@echo %s\n"
                   % (producer, target, producer, target))

    # objects, each with its transitive header closure
    oflags = c.get("oflags", {})
    special = c.get("special", {})
    # A generated HEADER cannot be found by scanning, because it does not
    # exist on the share -- scan_includes silently drops "y.tab.h" and make
    # is then free to compile mkconf.o before yacc has run.  `objdeps` names
    # them, and they go on every object in the component.
    objdeps = c.get("objdeps", [])
    for obj in sorted(objmap):
        src = objmap[obj]
        if src in gen or src in sidegen:     # generated: deps handled above
            deps = [src]
        else:
            deps = [srcdir + "/" + src] + [
                x for x in sorted(dep(y) for y in
                                  scan_includes(os.path.join(d, src), incdirs))
                if x != srcdir + "/" + src]
        deps = deps + [x for x in objdeps if x != src]
        extra = (oflags[obj] + " ") if obj in oflags else ""
        # A generated or side-effect source is compiled from the object
        # directory, not from the share.  Getting this right in the
        # prerequisite but not in the recipe just moves the error from
        # make ("Don't know how to make") to cc ("No source file").
        srcref = src if (src in gen or src in sidegen) else srcdir + "/" + src
        # `special` replaces the recipe for one object.  Several commands need
        # it for the same reason libc needs it for errlst.o: the object is
        # compiled to ASSEMBLY, edited, and then assembled, because something
        # has to move out of .data and into shared text.  sh's ctype.o is the
        # next one (usr/src/cmd/sh/:fix, which is :errfix under another name).
        # %s in a recipe line is the source path, so the entry does not have
        # to repeat it.
        if obj in special:
            out.append("\n%s: %s $(TOOLS)\n" % (obj, " ".join(deps)))
            for line in special[obj]:
                out.append("\t%s\n" % (line.replace("%s", srcref)))
        else:
            out.append("\n%s: %s $(TOOLS)\n\t$(COMPILE) %s%s\n"
                       % (obj, " ".join(deps), extra, srcref))

    # pre-commands (ccom needs y.debug in place before cgram.o)
    if c.get("pre"):
        out.append("\nprepare:\n")
        for cmd in c["pre"]:
            out.append("\t%s\n" % cmd)

    # install -- into TOOLDIR or DESTDIR.  Never /bin, never /lib.
    #
    # Stage 1's tools go to TOOLDIR because they are build machinery: the
    # system being assembled must not contain them just because it needed
    # them.  Stage 6's commands go to DESTDIR because they ARE the system.
    dest = "$(%s)" % c.get("dest", "TOOLDIR")
    out.append("\ninstall: %s\n" % c["product"])
    inst = c["install"]
    out.append("\t-mkdir %s/%s\n" % (dest, os.path.dirname(inst)))
    out.append("\tcp %s %s/%s\n" % (c["product"], dest, inst))
    # a second home for the same binary -- see `also` in the component table
    for dst in c.get("also", []):
        out.append("\t-mkdir %s/%s\n" % (dest, os.path.dirname(dst)))
        out.append("\tcp %s %s/%s\n" % (c["product"], dest, dst))
    for src, dst in c.get("data", []):
        out.append("\t-mkdir %s/%s\n" % (dest, os.path.dirname(dst)))
        out.append("\tcp %s/%s %s/%s\n" % (srcdir, src, dest, dst))

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
    # FOUR basenames appear in two directories each, and all objects share one
    # namespace, so the duplicate has to be resolved -- by us, explicitly.
    #
    #   cerror   crt/cerror.s == sys/cerror.s      byte-identical
    #   mcount   crt/mcount.s == sys/mcount.s      byte-identical
    #   abs      gen/abs.c    vs sys/abs.s         C vs VAX assembly
    #   fabs     math/fabs.c  vs sys/fabs.s        C vs VAX assembly
    #
    # The tape resolves it by overwrite order -- it compiles crt, gen, math,
    # stdio, then sys, all into one directory, so sys/ wins every time.  For
    # cerror and mcount that is a coin toss between identical files.  For abs
    # and fabs it is a real choice and clearly the intended one: sys/abs.s uses
    # mnegl and sys/fabs.s uses movd/mnegd, hand-written VAX instructions that
    # exist precisely to beat the portable C.
    #
    # We must state it, because V8's make resolves a duplicate target the OTHER
    # way -- doname.c keeps the FIRST rule with commands and reports
    # "Too many command lines" for the second -- so generating both rules would
    # have silently linked the C versions of abs and fabs and been an error
    # message rather than a decision.
    #
    # A dict keyed on the object name, filled in the tape's compile order, gets
    # the same answer the tape gets and says why.
    seen = {}
    for sub in ("crt", "gen", "math", "stdio", "sys"):
        p = os.path.join(d, sub)
        if not os.path.isdir(p):
            continue
        for f in sorted(os.listdir(p)):
            if f in LIBC_SPECIAL:
                continue
            if not (f.endswith(".c") or f.endswith(".s")):
                continue
            seen[f[:-2] + ".o"] = sub + "/" + f      # later directory wins
    # the two with hand-written rules
    seen["errlst.o"] = "gen/errlst.c"
    seen["doprnt.o"] = "stdio/doprnt.S"
    members = sorted(seen.items())

    out = [LIBC_PREAMBLE]
    out.append("OBJS = " + " ".join(o for o, _ in members) + "\n")

    out.append("""
all: libc.a crt0.o mcrt0.o

# The recipe below is the tape's, with the archive ordering intact.  See the
# note in mkdep.py for why each step is here.
# Two rules, not one, and the stamp file is the reason.
#
# `ld -x -r` REWRITES every .o in place (mv a.out $$i).  Done inside the
# libc.a recipe, that leaves all 233 prerequisites newer than the target the
# moment the recipe finishes, so libc.a is permanently out of date -- the
# `install` pass rebuilt the whole archive a second time, and an incremental
# build would never converge.
#
# Splitting it out fixes the ordering: `stripped` is written after the objects
# it rewrote, so it is newer than all of them, and libc.a is newer than it.
stripped: $(OBJS)
	-for i in *.o ; do $(LD) -x -r $$i; mv a.out $$i; done
	echo stripped > stripped

libc.a: stripped
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
	-rm -f $(OBJS) libc.a crt0.o mcrt0.o stripped
""")
    return "".join(out)



# ================================================================ stage 4
# Headers.
#
# Nothing is compiled here; the whole stage is 224 copies.  It exists as its
# own stage because everything after it must compile against OUR headers
# rather than the running system's, and that is a property of the -I that
# stages 5, 6 and 7 use, not of anything they do.
#
# Rules per file, not one bulk copy, so that touching a header reinstalls it
# and everything that includes it rebuilds.  That is the dependency rule the
# whole build is organised around, and headers are where it bites hardest --
# one line in <sys/param.h> invalidates the kernel and most of userland.
#
# The prerequisite lists are grouped by directory and split at 50 files.
# V8's make reads a line into INMAX = 5000 bytes (cmd/make/defs) and expands
# a target's prerequisites into tgsbuf[QBUFMAX], also 5000.  All 224 paths on
# one line is about 7,800 characters, which overflows both.  Grouped, the
# largest expansion is under 1,900.

HEADERS_PREAMBLE = """\
# Generated by v8/mk/mkdep.py -- do not edit; edit the generator.
#
#     make -f $SRC/mk/gen/headers.mk DESTDIR=... install
#
# Stage 4: install our headers into $(DESTDIR)/usr/include.  Stages 5, 6 and 7
# compile with INCDIR=$(DESTDIR)/usr/include, so from here on the system is
# built against the headers in this repo and not against the ones on the disk
# it happens to be running.

SRC     = /n/src
DESTDIR = /b/root

"""


def emit_provenance(built):
    """Every command on the shipped image, and where ours comes from.

    This is the answer to "what do we build and what do we copy", generated
    rather than written down, so it cannot drift from the build that produces
    it. builddisk.sh reads it: BUILD entries come from DESTDIR, COPY entries
    are lifted off the golden image, and a name in neither column would be a
    command the disk simply does not have.

    The COPY column is not a defect list. 147 of the image's 381 commands have
    NO SOURCE ANYWHERE IN THE TAPE -- Bell Labs shipped the binaries and kept
    the sources -- and no amount of work on this build will change that. What
    changes it is later tracks: V10 carries an ANSI C compiler (cmd/lcc, with
    a vax back end) which is what cfront and compat actually need, and most of
    /usr/games exists in the BSD sources that Track C/V11 work will bring in.
    Each row says which, so the list shrinks for a stated reason rather than
    by someone noticing.

    `why' is deliberately the same text stage6-skipped.txt carries, so the two
    files agree by construction.
    """
    src = os.path.join(V8, "usr/src/cmd")
    loose = {f[:-2] for f in os.listdir(src) if f.endswith(".c")} | \
            {f[:-3] for f in os.listdir(src) if f.endswith(".sh")}
    dirs = {d for d in os.listdir(src) if os.path.isdir(os.path.join(src, d))}
    why = {}
    for name, reason in SKIPPED:
        why[name.rstrip("/")] = reason

    rows, nbuild, ncopy = [], 0, 0
    for name in sorted(WHERE):
        # Archives and objects are stage 5's business, not commands.
        if name.endswith((".a", ".o")) or name.startswith("lib"):
            continue
        d = sorted(WHERE[name], key=lambda x: (DIRPREF.index(x)
                                               if x in DIRPREF else 99))[0]
        if name in built:
            rows.append((name, d, "build", "-", "-")); nbuild += 1
            continue
        ncopy += 1
        if d == "/usr/games":
            r, fut = "no source in the tape", "V11/BSD"
        elif name in REFUSE:
            r, fut = REFUSE[name], "V10 (cmd/lcc is ANSI)"
        elif name in why:
            r, fut = why[name], "this build"
        elif name in loose or name in dirs:
            r, fut = "has source; not built yet", "this build"
        else:
            r, fut = "no source in the tape", "V10, or V11/BSD"
        rows.append((name, d, "copy", r, fut))

    out = ["# Generated by v8/mk/mkdep.py -- do not edit.\n",
           "#\n",
           "# Every command on the shipped V8 image, and where ours comes\n",
           "# from. builddisk.sh reads this: `build' is taken from DESTDIR,\n",
           "# `copy' is lifted off the golden image.\n",
           "#\n",
           "# A `copy' row is not a defect. Bell Labs shipped binaries whose\n",
           "# sources are not on the tape -- all 34 games among them -- and\n",
           "# this build cannot conjure them. The last column says what can:\n",
           "# V10 has an ANSI C compiler (cmd/lcc) for the two /bin/cc\n",
           "# rejects, and most games exist in the BSD sources V11 work will\n",
           "# bring in.\n",
           "#\n",
           "#\tbuild %d\tcopy %d\tof %d\n" % (nbuild, ncopy, nbuild + ncopy),
           "#\n",
           "#name\tdir\tfrom\twhy\tfixed by\n"]
    out += ["%s\t%s\t%s\t%s\t%s\n" % r for r in rows]
    return "".join(out), nbuild, ncopy


def emit_makedev():
    """Turn v8/proto-dev into a shell script that rebuilds /dev.

    proto-dev is an `ls -lR` of the shipped machine's /dev, so it carries
    every node's type, major, minor and mode -- which is the only place that
    information exists in this repo.  Stage 8 needs it: a filesystem with no
    device nodes will not boot, and mknod's arguments cannot be guessed
    (`hp` is block major 0 and char major 4, and the two switch tables are
    unrelated -- see CLAUDE.md).

    OWNERSHIP IS DELIBERATELY DROPPED.  The listing is a photograph of one
    machine's /dev on one day in 1985, down to who happened to own which
    terminal: dmr, presotto, rob, norman, pjw, reeds, kahrs and fifteen
    others.  Those accounts do not exist on a machine built from this tree,
    so a faithful chown would fail on every one of them -- and would be
    meaningless if it succeeded.  Everything comes out root-owned; the group
    is kept, because the four that appear (bin, man, other, sys) are real
    system groups and some drivers care.  The nodes are data.  The owners
    are history.
    """
    text = open(os.path.join(V8, "proto-dev")).read()
    out = ["""\
#!/bin/sh
# Generated by v8/mk/mkdep.py from v8/proto-dev -- do not edit.
#
#\tsh $SRC/mk/gen/makedev.sh /mnt
#
# Rebuild /dev on a newly made filesystem.  proto-dev is an `ls -lR` of the
# shipped machine's /dev and is the only record in this repo of what major,
# minor and mode each node needs.
#
# Owners are not reproduced: the listing carries the 1127 staff's personal
# ownership of their own terminals, and those accounts do not exist here.
# Groups are, because bin/man/other/sys are real.
#
# /etc/mknod, spelled out 414 times, because there is NO mknod on root's PATH
# -- it lives in /etc, and where.txt says so.  builddisk.sh made the same
# assumption four times and the result was not a clean failure: mkfs given a
# name that is not a special file creates a REGULAR FILE and writes the
# filesystem into it, so four `mknod: not found' messages became `/: file
# system full' about an unrelated filesystem.  Here it would have been 414 of
# them, on the LAST step of stage 8, after the disk was otherwise built.

# Both by absolute path, and they are NOT in the same place: where.txt says
# /etc/mknod and /etc/chgrp, while chmod is /bin/chmod.  Guessing that the
# three commands that set up a device node live together is exactly the kind
# of reasonable assumption this file exists to avoid -- the first stage-8 run
# to reach /dev printed "chgrp: not found" 190 times and produced a complete
# /dev whose every node had the wrong group.
MKNOD=/etc/mknod
CHGRP=/etc/chgrp
DEV=${1-/dev}
mkdir $DEV 2>/dev/null
"""]

    def octal(perm):
        """rwxrwxrwx -> 0644.  Only the nine mode bits; no setuid in /dev."""
        n = 0
        for i, ch in enumerate(perm):
            if ch != "-":
                n |= 1 << (8 - i)
        return "%04o" % n

    cur = ""            # subdirectory within /dev, "" for the top
    ndev = ndir = 0
    for line in text.split("\n"):
        s = line.rstrip()
        if not s or s.startswith("total "):
            continue
        if s.endswith(":"):
            # `ls -lR` announces each subdirectory it descends into
            cur = s[:-1].strip("./") + "/"
            continue
        f = s.split()
        if len(f) < 9 or f[0][0] not in "bcd":
            continue
        name = f[-1]
        mode = octal(f[0][1:10])
        group = f[3]
        if f[0][0] == "d":
            out.append("mkdir $DEV/%s%s\n" % (cur, name))
            out.append("chmod %s $DEV/%s%s\n" % (mode, cur, name))
            ndir += 1
            continue
        # b/c: "19,128" splits as "19," and "128", but a wide minor can also
        # arrive as one field ("19,128"), so handle both rather than trusting
        # the column widths of a 1985 ls.
        blob = " ".join(f[4:6]) if f[4].endswith(",") else f[4]
        try:
            major, minor = [int(x) for x in blob.replace(",", " ").split()[:2]]
        except ValueError:
            continue
        out.append("$MKNOD $DEV/%s%s %s %d %d\n"
                   % (cur, name, f[0][0], major, minor))
        out.append("chmod %s $DEV/%s%s\n" % (mode, cur, name))
        if group != "0":
            out.append("$CHGRP %s $DEV/%s%s\n" % (group, cur, name))
        ndev += 1

    # ---------------------------------------------------------------------
    # THE NODES OUR MACHINE NEEDS AND proto-dev DOES NOT HAVE.
    #
    # proto-dev has no hp or rp entries at all -- it is the /dev of the
    # `research' VAX-11/750, whose disks are RA81s on an MSCP controller
    # (usr/sys/research/conf: `disk ra0 at uda0'), and every block device in
    # it is ra, mt or nmt.  Ours is alice's hardware: RP06/RP07 on a Massbus.
    # A /dev built from proto-dev alone therefore has no root device, and the
    # failure arrives at boot as something far less obvious than "no nodes".
    #
    # These are derived, not guessed.  `hp' is block major 0 and char major 4
    # -- bdevsw and cdevsw are unrelated tables in sys/dev/conf.c and the
    # indices do not match, which has already cost this project two runs.
    # Minor is drive<<3 | partition, so partition a of drive 0 is 0 and
    # partition g of drive 1 is 14.
    out.append("""
# --- RP06/RP07, which proto-dev does not have: see mkdep.py's emit_makedev.
# block major 0, char major 4, minor = drive<<3 | partition.
""")
    for drive in (0, 1):
        for part, letter in enumerate("abcdefgh"):
            minor = (drive << 3) | part
            for pfx, kind, mode in (("rp", "b", "0640"), ("rrp", "c", "0640")):
                node = "%s%d%s" % (pfx, drive, letter)
                out.append("$MKNOD $DEV/%s %s %d %d\n"
                           % (node, kind, 0 if kind == "b" else 4, minor))
                out.append("chmod %s $DEV/%s\n" % (mode, node))
                ndev += 1

    out.append("\necho MAKEDEV-done %d nodes %d directories\n" % (ndev, ndir))
    return "".join(out), ndev, ndir


def emit_headers():
    incroot = os.path.join(V8, "usr/include")
    bydir = {}
    for dirpath, _dirnames, filenames in os.walk(incroot):
        d = rel(dirpath, V8)                      # e.g. usr/include/sys
        for f in sorted(filenames):
            bydir.setdefault(d, []).append(f)

    out = [HEADERS_PREAMBLE]
    groups = []
    dirs = sorted(bydir)

    # every directory that has to exist, parents before children
    out.append("dirs:\n")
    for d in dirs:
        out.append("\t-mkdir $(DESTDIR)/%s\n" % d)
    out.append("\n")

    for d in dirs:
        files = bydir[d]
        # split at 50 -- see the INMAX note above
        for i in range(0, len(files), 50):
            chunk = files[i:i + 50]
            gname = "H_" + d.replace("/", "_").replace("usr_include", "inc") \
                    + ("" if len(files) <= 50 else "_%d" % (i // 50))
            groups.append(gname)
            out.append("%s = %s\n\n" % (
                gname, " \\\n\t".join("$(DESTDIR)/%s/%s" % (d, f) for f in chunk)))

    # One target per group, and `install` depends on those rather than on the
    # macros directly.  Putting $(H_inc_0) $(H_inc_sys_0) ... on the install
    # line would expand to all 224 paths at once -- about 7,800 characters
    # into tgsbuf[QBUFMAX], which is 5000, which is the overflow the grouping
    # exists to avoid.  This way the biggest expansion make ever performs is
    # one group, under 1,800.
    #
    # Each one carries an `@echo` rather than being a bare command-less
    # target.  doname.c reaches
    #
    #	else if(keepgoing) printf("Don't know how to make %s\n", ...)
    #
    # whenever a target has no explicit command, no implicit rule and no
    # .DEFAULT -- and `exists()` returns 0 for a name with no file, so a
    # phony group would take that path on the very first run.  Our own
    # `all: <product>` lines have never tripped it, so something upstream
    # of that branch evidently covers them; a stage that installs 224 files
    # is not the place to find out exactly what.  A command settles it, and
    # doubles as progress output.
    for g in groups:
        out.append("%s: $(%s)\n\t@echo %s\n\n" % (g.lower(), g, g.lower()))

    out.append("install: dirs %s\n\t@echo %d headers installed\n\n"
               % (" ".join(g.lower() for g in groups),
                  sum(len(v) for v in bydir.values())))

    for d in dirs:
        for f in bydir[d]:
            out.append("$(DESTDIR)/%s/%s: $(SRC)/%s/%s\n\tcp $(SRC)/%s/%s $(DESTDIR)/%s/%s\n\n"
                       % (d, f, d, f, d, f, d, f))

    return "".join(out), sum(len(v) for v in bydir.values())


# ================================================================ stage 5
# The libraries.
#
# libc is stage 2 and is not here: it is needed to build the toolchain, so it
# cannot wait for one.  These are everything else, and every one of them is
# an archive built the same way -- compile, ar, ranlib -- with the per-library
# facts taken from the tape's own makefile and recorded in `note`.
#
# NO lorder | tsort HERE, and the reason is worth writing down because the
# opposite is recorded elsewhere in this project.  V8's ld is only single-pass
# for an archive with no usable table of contents.  ld.c's getfile() returns
# 1 (no __.SYMDEF), 2 (current) or 3 (stale, because the archive's mtime is
# newer); case 2 runs `while (ldrand()) continue;` -- repeated passes -- under
# a comment that says "you can get away with backward references when there
# is a table of contents!".  Cases 1 and 3 fall back to one sequential pass
# AND print a warning naming ranlib.  So member order is correctness only
# when the table is missing or stale, and ld says so on stderr when it is.
#
# What this does mean: every rule that COPIES an archive must re-ranlib it at
# the destination, because cp updates the mtime and that alone turns a good
# table of contents into case 3.  libc's install already did this and it was
# not obvious why.
LIB_PREAMBLE = """\
# Generated by v8/mk/mkdep.py -- do not edit; edit the generator.
#
#     make -f $SRC/mk/gen/%(name)s.mk TOOLDIR=... DESTDIR=... install
#
# Stage 5: %(name)s, built with the stage-3 toolchain against the headers
# stage 4 installed.  Source is read-only on the share; objects land in the
# current directory, which the driver makes per-library on the build disk.
#
# From the tape: %(note)s

SRC     = /n/src
TOOLDIR = /b/tools3
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

# Stage 4's headers, not the running system's.  This is the whole reason
# stage 4 is a stage.
INCDIR = $(DESTDIR)/usr/include

CFLAGS = %(cflags)s -I$(INCDIR)
COMPILE = $(CC) $(CFLAGS) -c
TOOLS  = $(CCPATH) $(CCOM) $(CPP) $(C2) $(AS)

"""


def emit_lib(l):
    """One library archive.  See STAGE5 for the shape of `l`."""
    # resolve sources: each entry is a directory relative to V8, and we take
    # its .c and .s files unless an explicit list is given.
    objmap = {}                       # obj -> path relative to V8
    for d in l["dirs"]:
        full = os.path.join(V8, d)
        names = l.get("objs")
        if names is None:
            names = sorted(f for f in os.listdir(full)
                           if f.endswith(".c") or f.endswith(".s"))
        for f in names:
            if not os.path.exists(os.path.join(full, f)):
                continue
            objmap[os.path.splitext(f)[0] + ".o"] = d + "/" + f

    incdir = os.path.join(V8, "usr/include")
    # `incs` names extra include directories, relative to V8.  libin is the
    # first library that needs one: its sources include "../h/config.h",
    # which is outside its own directory, so without this the scan misses it
    # and touching config.h rebuilds nothing.
    incdirs = ([os.path.join(V8, d) for d in l["dirs"]]
               + [os.path.join(V8, i) for i in l.get("incs", [])]
               + [incdir])

    def dep(path):
        path = os.path.normpath(path)
        if path.startswith(incdir + os.sep):
            return "$(INCDIR)/" + rel(path, incdir)
        return "$(SRC)/" + rel(path, V8)

    # -I the library's OWN directories, then any extras, then $(INCDIR) from
    # the preamble.  The own-directory -I is not redundant with cpp searching
    # the source file's directory, and libI77 is the case that proves it:
    #
    #	ecvt.c:12: Can't find include file nan.h
    #
    # nan.h is right there in usr/src/libI77 -- but ecvt.c asks for it as
    # <nan.h>, and cpp searches dirs[0] (the file's own directory) only for
    # the "..." form; <...> starts at dirs[1].  That is exactly why libcurses
    # finds its "curses.h" with no -I at all and libI77 does not find its
    # <nan.h>, and why the tape's libI77 makefile says CFLAGS = -I. -g.
    #
    # Order matters and follows the tape: the library's own directory comes
    # FIRST, so libI77's own stdio.h and values.h shadow the system ones
    # exactly as they do in an in-tree build.
    cflags = l.get("cflags", "-O") + "".join(
        " -I$(SRC)/" + i for i in list(l["dirs"]) + list(l.get("incs", [])))
    # An assembled library has no objects.  Emitting an OBJS list and a
    # per-object rule for one anyway produced a makefile that described work
    # it never does -- dbxxx.o had a rule, nothing depended on it, and `clean`
    # removed a file that never existed.  Harmless, and exactly the kind of
    # thing that later gets read as intent.
    if l.get("assemble"):
        objmap = {}

    out = [LIB_PREAMBLE % dict(name=l["name"], note=l.get("note", "-"),
                               cflags=cflags)]
    if objmap:
        out.append("OBJS = " + " \\\n\t".join(sorted(objmap)) + "\n")
    out.append("\nall: %s\n" % l["product"])

    if l.get("assemble"):
        # libg.a is not an archive at all -- it is one assembled object that
        # happens to be named .a.  `as dbxxx.s -o libg.a`.  ld loads it as a
        # plain file (getfile case 0), which is exactly right.
        src = l["assemble"]
        out.append("\n%s: $(SRC)/%s/%s $(AS)\n\t$(AS) $(SRC)/%s/%s -o %s\n"
                   % (l["product"], l["dirs"][0], src, l["dirs"][0], src,
                      l["product"]))
    else:
        out.append("\n%s: $(OBJS) $(AR)\n\t-rm -f %s\n\t$(AR) cr %s $(OBJS)\n\t$(RANLIB) %s\n"
                   % (l["product"], l["product"], l["product"], l["product"]))

    for obj in sorted(objmap):
        src = objmap[obj]
        deps = [dep(os.path.join(V8, src))] + [
            x for x in sorted(dep(y) for y in
                              scan_includes(os.path.join(V8, src), incdirs))
            if x != dep(os.path.join(V8, src))]
        out.append("\n%s: %s $(TOOLS)\n\t$(COMPILE) $(SRC)/%s\n"
                   % (obj, " ".join(deps), src))

    out.append("\ninstall: %s\n" % l["product"])
    out.append("\t-mkdir $(DESTDIR)/%s\n" % os.path.dirname(l["install"]))
    out.append("\tcp %s $(DESTDIR)/%s\n" % (l["product"], l["install"]))
    if not l.get("assemble"):
        # cp bumps the mtime, which makes __.SYMDEF stale -- ld case 3, one
        # sequential pass and a warning.  Re-ranlib at the destination.
        out.append("\t$(RANLIB) $(DESTDIR)/%s\n" % l["install"])
    for extra in l.get("link", []):
        out.append("\t-rm -f $(DESTDIR)/%s\n" % extra)
        out.append("\tln $(DESTDIR)/%s $(DESTDIR)/%s\n" % (l["install"], extra))

    out.append("\nclean:\n\t-rm -f %s%s\n"
               % ("$(OBJS) " if objmap else "", l["product"]))
    return "".join(out)


STAGE5 = [
    dict(name="libcurses", dirs=["usr/src/lib/libcurses"],
         objs=["box.c", "clear.c", "initscr.c", "endwin.c", "mvprintw.c",
               "mvscanw.c", "mvwin.c", "newwin.c", "overlay.c", "overwrite.c",
               "printw.c", "scanw.c", "refresh.c", "touchwin.c", "erase.c",
               "clrtobot.c", "clrtoeol.c", "cr_put.c", "cr_tty.c", "longname.c",
               "delwin.c", "insertln.c", "deleteln.c", "scroll.c", "getstr.c",
               "getch.c", "addstr.c", "addch.c", "move.c", "curses.c",
               "unctrl.c", "standout.c", "tstp.c", "insch.c", "delch.c"],
         cflags="-O", product="libcurses.a", install="usr/lib/libcurses.a",
         note="lib/libcurses/makefile: OBJS (35), CFLAGS=-O; builds it as "
              "`crlib` and installs that as libcurses.a -- we skip the rename"),

    # Not an archive: one assembled object named .a.  See emit_lib().
    dict(name="libg", dirs=["usr/src/lib/libg"], assemble="dbxxx.s",
         product="libg.a", install="usr/lib/libg.a",
         note="lib/libg/makefile: as dbxxx.s -o libg.a"),

    dict(name="libjobs", dirs=["usr/src/lib/libjobs"],
         objs=["getwd.c", "killpg.s", "setpgrp.s", "signal.s", "sigset.c",
               "wait3.s"],
         cflags="-O", product="libjobs.a", install="usr/lib/libjobs.a",
         note="lib/libjobs/makefile: OBJS -- two .c and four .s"),

    dict(name="libl", dirs=["usr/src/lib/libl"],
         objs=["allprint.c", "main.c", "reject.c", "yyless.c", "yywrap.c"],
         cflags="-O", product="libl.a", install="usr/lib/libl.a",
         note="lib/libl/makefile: ar rvc libl.a allprint main reject yyless "
              "yywrap -- the tape compiles yywrap separately, which changes "
              "nothing since ar is given the order explicitly"),

    dict(name="libmp", dirs=["usr/src/lib/libmp"],
         objs=["pow.c", "gcd.c", "msqrt.c", "mdiv.c", "mout.c", "mult.c",
               "madd.c", "util.c", "halloc.c", "primetab.c"],
         cflags="", product="libmp.a", install="usr/lib/libmp.a",
         note="lib/libmp/makefile: OBJS (10) -- prbits.c is present in the "
              "directory and deliberately NOT a member"),

    dict(name="libtermlib", dirs=["usr/src/lib/libtermlib"],
         objs=["termcap.c", "tgoto.c", "tputs.c"],
         cflags="-O -DCM_N -DCM_GT -DCM_B -DCM_D",
         product="libtermcap.a", install="usr/lib/libtermcap.a",
         link=["usr/lib/libtermlib.a"],
         note="lib/libtermlib/makefile: builds termcap.a from three of its "
              "six .c (tc1/tc2/tc3 are tests), installs as libtermcap.a and "
              "hard-links libtermlib.a to it -- so -ltermlib and -ltermcap "
              "are one file"),

    # No makefile on the tape at all; every .c is a member.
    dict(name="libcbt", dirs=["usr/src/lib/libcbt"],
         cflags="-O", product="libcbt.a", install="usr/lib/libcbt.a",
         note="no makefile on the tape -- all six .c"),

    dict(name="libdbm", dirs=["usr/src/libdbm"], objs=["dbm.c"],
         cflags="-O", product="libdbm.a", install="usr/lib/libdbm.a",
         note="libdbm/Makefile: libdbm.a: dbm.o"),

    # libF77/main.c defines main() and that is CORRECT, so do not "fix" it.
    # It is headed "STARTUP PROCEDURE FOR UNIX FORTRAN PROGRAMS": the Fortran
    # runtime supplies main(), sets up the signal handlers and then calls the
    # compiled program.  It is the one library here that is supposed to
    # contain an entry point.
    dict(name="libF77", dirs=["usr/src/libF77"],
         cflags="-O", product="libF77.a", install="usr/lib/libF77.a",
         note="libF77/Makefile: ar r libF77.a $? -- no object macro, so all "
              "of its .c, main.c included"),

    dict(name="libI77", dirs=["usr/src/libI77"],
         objs=["Version.c", "backspace.c", "dfe.c", "due.c", "iio.c",
               "inquire.c", "rewind.c", "rsfe.c", "rdfmt.c", "sue.c", "uio.c",
               "wsfe.c", "sfe.c", "fmt.c", "nio.c", "lio.c", "lread.c",
               "open.c", "close.c", "util.c", "endfile.c", "wrtfmt.c",
               "err.c", "fmtlib.c", "ecvt.c", "ltostr.c"],
         cflags="-O", product="libI77.a", install="usr/lib/libI77.a",
         note="libI77/makefile: OBJ (26)"),

    # The Internet library.  It is the reason nmount(8) can be built from
    # source at all: nmount calls in_address() and tcp_sock(), and until this
    # was looked at properly the assumption was that /usr/lib/libin.a had no
    # source and the whole netfs mount path depended on a 1985 binary.  It
    # does have source -- filed under cmd/, not lib/, which is why it reads
    # as missing.
    dict(name="libin", dirs=["usr/src/cmd/inet/libin"],
         objs=["tcp_lib.c", "udp_lib.c", "in_service.c", "in_address.c",
               "in_host.c", "in_subrs.c", "in_ntoa.c", "in_ntoh.s"],
         incs=["usr/src/cmd/inet/h"],
         cflags="-O", product="libin.a", install="usr/lib/libin.a",
         note="cmd/inet/libin/makefile: OBJS (8), CFLAGS=-g -I ../h -- -O "
              "here instead of -g, matching every other library"),

    # incs reaches ../cmd, and the tape could not have built this in-tree
    # either.  tdkdial.c says #include "dkdial.h", dkdial.h is in
    # usr/src/dk/cmd, and dk/libc/makefile has CFLAGS = -O with no -I of any
    # kind -- so even `cd dk/libc; make' fails, because "..." searches the
    # including file's directory and dkdial.h is not in it.  Same family as
    # cpp's :yyfix, where the tape contradicts itself between two makefiles.
    dict(name="libdk", dirs=["usr/src/dk/libc"],
         objs=["tdkdial.c", "tdkexec.c", "tdklogin.c", "tdkmgr.c",
               "dkproto.c", "dkctlchan.c", "pwsearch.c"],
         incs=["usr/src/dk/cmd"],
         cflags="-O", product="libdk.a", install="usr/lib/libdk.a",
         note="dk/libc/makefile: LIB (7), CFLAGS=-O -- and dkdial.h is in "
              "../cmd, which that -O cannot reach"),
]

# The plot libraries all have the same shape: the sources arrived as an ar
# archive (plot.c.a, tek.c.a, ...) which our importer unpacked into a
# directory of the same name, so what the tape does with
#	cp plot.c.a/* . ; cc -cO *.c ; ar rc libplot.a *.o
# we do by compiling that directory in place off the share.
for _n, _d in [("libplot", "libplot/plot.c.a"), ("lib2621", "lib2621/hp.c.a"),
               ("lib4014", "lib4014/tek.c.a"), ("lib5620", "lib5620/blit.c.a"),
               ("libblit", "libblit/blit.c.a"), ("libpen", "libpen/pen.c.a"),
               ("libtr", "libtr/tr.c.a")]:
    # No `incs' here, and that was worth checking rather than assuming.  The
    # sources say #include "tek.h", and tek.h also sits in the PARENT
    # directory beside the archive -- which looked like it would need the
    # parent on the include path, the way libI77 and libdk do.  It does not:
    # the archive carries its own copy, byte-identical to the parent's, so
    # cpp finds it in dirs[0] like any other local include.  All seven built
    # first time.
    STAGE5.append(dict(
        name=_n, dirs=["usr/src/libplot/" + _d], cflags="-O",
        product=_n + ".a", install="usr/lib/" + _n + ".a",
        note="libplot/%s/makefile: cp %s/* . ; cc -cO *.c ; ar rc %s.a *.o "
             "-- the archive contains its own header, so out of tree needs "
             "no -I" % (_d.split("/")[0], _d.split("/")[1], _n)))


# ================================================================ stage 6
# The commands.
#
# 113 directories with a makefile, 7 without, 164 loose .c, 2 loose .y and 6
# .sh -- and the makefiles are not a family.  awk's opens by saying it is
# wrong; sed links with `cc -o sed -n *.o`; troff builds two programs from
# overlapping object sets under different CFLAGS.  Six of the 113 state an
# object macro, one link line and nothing exotic.  So this stage is a LIST,
# built up in dependency order, not a loop over a directory.
#
# It starts with the commands the later stages need, because those are the
# ones whose absence blocks something:
#
#	config		stage 7 cannot run without it, and it is the only
#			tool in the build that needs BOTH yacc and lex
#
# ONE RULE APPLIES TO EVERY ENTRY HERE: never -l, always the path.  V8's ld
# has no -L (see "Stage isolation" in docs/build-from-source.md), so -ll on
# the link line searches /lib, /usr/lib and /usr/local/lib -- the RUNNING
# system's libraries -- and finds the tape's libl.a in preference to the one
# stage 5 just built.  It does that silently and the build succeeds.  `libs`
# below names archives by path for exactly this reason.

STAGE6 = [
    dict(name="config", dir="usr/src/cmd/config",
         objs={"y.tab.o": "y.tab.c", "lex.yy.o": "lex.yy.c",
               "main.o": "main.c", "mkioconf.o": "mkioconf.c",
               "mkmakefile.o": "mkmakefile.c", "mkubglue.o": "mkubglue.c",
               "mkheaders.o": "mkheaders.c", "mkconf.o": "mkconf.c"},
         # -d because mkconf.c and the grammar share y.tab.h.  The tape's
         # makefile says `yacc -d config.y` and nothing else generates it.
         gen={"y.tab.c": ("yacc -d", "config.y", None),
              "lex.yy.c": ("lex", "config.l", None)},
         # -d writes y.tab.h beside y.tab.c, and SIX of config's eight sources
         # include it -- including config.l, so even the lex output needs it.
         # It exists only in the object directory, so nothing can find it by
         # scanning the share.
         sidegen={"y.tab.h": "y.tab.c"},
         objdeps=["y.tab.h"],
         libs=["usr/lib/libl.a"],
         # DESTDIR, not TOOLDIR: stage 6's commands ARE the system being
         # assembled, where stage 1's tools were only the machinery that
         # built it.
         dest="DESTDIR",
         product="config", install="etc/config",
         note="cmd/config/makefile: OBJS (8), LDFLAGS=-ll, installs to "
              "$(DESTDIR)/etc -- we name libl.a by path instead of -ll"),

    # OURS, not the tape's.  It is the command that mounts a host directory
    # over TCP using the netfs client that has been compiled into every V8
    # kernel since 1985 and has had nothing to talk to since Datakit was
    # switched off (phase N6; docs/n-track-notes.md).  It lives in
    # usr/src/cmd like any other command and is distinguishable from the
    # tape's files by not being in v8/MANIFEST.
    # The shell.  Nothing boots without it -- init execs /etc/rc, and /etc/rc
    # is a shell script -- so it is the first entry here that exists because
    # of stage 8 rather than because of stage 7.
    #
    # ctype.o is `special' for the same reason libc's errlst.o is: it is
    # compiled to ASSEMBLY, edited to move its table out of .data and into
    # shared text, and then assembled.  The tape does it through
    # usr/src/cmd/sh/:fix, which is :errfix under another name and reads $CC,
    # $CFLAGS and $AS out of the environment.  We inline the three steps
    # instead of invoking :fix, because :fix passes its argument to both cc
    # and as -- and out of tree those need different paths: the source is on
    # the read-only share, the .s and .o are in the object directory.
    #
    # CFLAGS is the tape's -gd2 verbatim even though the preamble puts -O in
    # front of it.  cc.c does `if (gflag) { warning; oflag = 0; }', so -O -gd2
    # and -gd2 produce the same code and differ only by a warning -- which
    # keeps a byte comparison against the shipped /bin/sh available.
    dict(name="sh", dir="usr/src/cmd/sh",
         objs=["setbrk.c", "blok.c", "stak.c", "cmd.c", "fault.c", "main.c",
               "word.c", "string.c", "name.c", "args.c", "xec.c", "service.c",
               "error.c", "io.c", "print.c", "macro.c", "expand.c", "ctype.c",
               "msg.c", "defs.c", "pathserv.c", "func.c", "spname.c"],
         special={"ctype.o": [
             "$(CC) $(CFLAGS) $(INCS) -S %s",
             "sed '/^[ 	]*\\.data/s/data/text/' ctype.s > ctype.t",
             "mv ctype.t ctype.s",
             "$(AS) -o ctype.o ctype.s",
             "rm -f ctype.s"]},
         cflags="-gd2", dest="DESTDIR",
         product="sh", install="bin/sh",
         note="cmd/sh/makefile: OFILES (23), CFLAGS=-gd2, ctype.o via ./:fix, "
              "installs to /bin/sh after moving the old one to /bin/osh"),

    # ---------------------------------------------------------- the boot path
    #
    # Everything below is here because a disk without it does not come up, and
    # every install path is MEASURED rather than inferred:
    #
    #	/etc/init	sys/main.c's own comment -- "loop at loc 13 (0xd) in
    #			user mode -- /etc/init cannot be executed"
    #	/etc/fsck	named by /etc/rc, with its exit status switched on
    #	/etc/mount	/etc/rc: `/etc/mount -a'
    #	/etc/update	/etc/rc
    #	/etc/login	cmd/login/makefile: `cp login /etc' -- NOT /bin,
    #			which is what guessing would have given
    #
    # getty has no makefile and is not named by rc, but init execs it per
    # /etc/ttys and every other thing init runs lives in /etc.
    #
    # Still missing and deliberately not guessed: date, rm, cat, ls, echo,
    # chmod and sync are called by bare name from /etc/rc, so rc says they are
    # on PATH and does not say which of /bin and /usr/bin holds them.  That is
    # what tools/harvest-paths.sh is for -- /usr is a separate filesystem, so
    # the difference decides whether the system can repair itself.
    dict(name="init", dir="usr/src/cmd", objs=["init.c"], dest="DESTDIR",
         product="init", install="etc/init",
         note="loose init.c; sys/main.c execs /etc/init"),
    dict(name="getty", dir="usr/src/cmd", objs=["getty.c"], dest="DESTDIR",
         product="getty", install="etc/getty",
         note="loose getty.c; init execs it per /etc/ttys"),
    dict(name="login", dir="usr/src/cmd/login", objs=["login.c"],
         dest="DESTDIR", product="login", install="etc/login",
         note="cmd/login/makefile: cp login /etc -- /etc, not /bin"),
    dict(name="fsck", dir="usr/src/cmd", objs=["fsck.c"], dest="DESTDIR",
         product="fsck", install="etc/fsck",
         note="loose fsck.c; /etc/rc runs /etc/fsck -p and switches on $?"),
    dict(name="mount", dir="usr/src/cmd", objs=["mount.c"], dest="DESTDIR",
         product="mount", install="etc/mount",
         note="loose mount.c; /etc/rc runs /etc/mount -a"),
    dict(name="umount", dir="usr/src/cmd", objs=["umount.c"], dest="DESTDIR",
         product="umount", install="etc/umount",
         note="loose umount.c; the pair of /etc/mount"),
    dict(name="mkfs", dir="usr/src/cmd", objs=["mkfs.c"], dest="DESTDIR",
         product="mkfs", install="etc/mkfs",
         note="loose mkfs.c; /etc, with fsck and mount"),
    dict(name="update", dir="usr/src/cmd", objs=["update.c"], dest="DESTDIR",
         product="update", install="etc/update",
         note="loose update.c; /etc/rc runs /etc/update"),

    dict(name="nmount", dir="usr/src/cmd", objs=["nmount.c"],
         libs=["usr/lib/libin.a"], dest="DESTDIR",
         product="nmount", install="etc/nmount",
         note="ipnx, phase N6: needs in_address() and tcp_sock() from libin, "
              "which stage 5 now builds from cmd/inet/libin"),

    # Also ours. V8 has chroot(2) -- syscall 61 -- and no chroot(1): no such
    # command on the golden image, no source in usr/src, no manual page. The
    # system call has never had a command in front of it.
    #
    # Stage 9 is what wants it, and cc(1) is why it has to be a real chroot
    # rather than a -B: `-B' is a RUNTIME option, so the cc installed into
    # DESTDIR still carries /lib/ccom as its compiled-in pass directory. Run
    # from outside, that quietly means the BUILDING system's passes; run under
    # chroot, DESTDIR/lib/ccom is /lib/ccom and the same binary cannot cheat.
    dict(name="chroot", dir="usr/src/cmd", objs=["chroot.c"], dest="DESTDIR",
         product="chroot", install="etc/chroot",
         note="ipnx: V8 has chroot(2) and ships no chroot(1); stage 9 needs one"),

    # ------------------------------------------------ the yacc/lex commands
    #
    # Hand-written because they are not a family and cannot be derived. Every
    # one runs yacc or lex differently: expr compiles y.tab.c straight to a
    # binary, m4 renames it, eqn/pic/grap/hoc each COPY y.tab.h to a private
    # name their sources include, ratfor's grammar is called r.g. The pattern
    # config(8) established -- gen for the generated source, sidegen for the
    # header that exists only in the object directory, objdeps so every object
    # waits for it, and -I. because cpp searches the source's directory and
    # never the current one -- is what they all share, and nothing else is.
    #
    # The `extra' third element of a gen entry is the tape's own header copy.
    # Those makefiles all spell it `-cmp -s y.tab.h X || cp y.tab.h X', which
    # exists to avoid touching X when the grammar changes but its tokens do
    # not. Out of tree the object directory is fresh every run, so there is
    # nothing to preserve and the plain cp is the same thing without the
    # dependency on cmp.

    dict(name="expr", dir="usr/src/cmd/expr",
         objs={"y.tab.o": "y.tab.c"},
         gen={"y.tab.c": ("yacc", "expr.y", None)},
         # The tape says `cc -I/usr/src/cmd/bs' -- an absolute path into a
         # live machine. ../bs is the same directory reached hermetically.
         incs=[".", "../bs"],
         dest="DESTDIR", product="expr", install="usr/bin/expr",
         note="cmd/expr/makefile: yacc expr.y, then cc y.tab.c -o expr"),

    dict(name="hoc", dir="usr/src/cmd/hoc",
         objs={"code.o": "code.c", "init.o": "init.c",
               "math.o": "math.c", "symbol.o": "symbol.c"},
         gen={"y.tab.c": ("yacc -d", "hoc.y", None)},
         sidegen={"y.tab.h": "y.tab.c"}, objdeps=["y.tab.h"],
         dest="DESTDIR", product="hoc", install="usr/bin/hoc",
         note="cmd/hoc/makefile: OBJS(5), YFLAGS=-d, -lm (which is libc here). "
              "code.c includes y.tab.h directly, so no header copy is needed -- "
              "the makefile's x.tab.h is dependency bookkeeping, not a source"),

    dict(name="eqn", dir="usr/src/cmd/eqn",
         objs={"main.o": "main.c", "diacrit.o": "diacrit.c",
               "eqnbox.o": "eqnbox.c", "font.o": "font.c", "fromto.o": "fromto.c",
               "funny.o": "funny.c", "glob.o": "glob.c", "integral.o": "integral.c",
               "input.o": "input.c", "lex.o": "lex.c", "lookup.o": "lookup.c",
               "mark.o": "mark.c", "matrix.o": "matrix.c", "move.o": "move.c",
               "over.o": "over.c", "paren.o": "paren.c", "pile.o": "pile.c",
               "shift.o": "shift.c", "size.o": "size.c", "sqrt.o": "sqrt.c",
               "text.o": "text.c"},
         gen={"y.tab.c": ("yacc -d", "eqn.y", "cp y.tab.h e.def")},
         sidegen={"y.tab.h": "y.tab.c", "e.def": "y.tab.c"},
         objdeps=["e.def"],
         dest="DESTDIR", product="eqn", install="usr/bin/eqn",
         note="cmd/eqn/makefile: FILES(22), YFLAGS=-d, e.def is a copy of "
              "y.tab.h and twenty of the sources include it by that name"),

    dict(name="m4", dir="usr/src/cmd/m4",
         objs={"m4.o": "m4.c", "m4ext.o": "m4ext.c",
               "m4macs.o": "m4macs.c"},
         gen={"y.tab.c": ("yacc", "m4y.y", None)},
         dest="DESTDIR", product="m4", install="usr/bin/m4",
         note="cmd/m4/makefile: a.out from four objects, installed as "
              "/usr/bin/m4 -- the product name is in the install rule, not "
              "in the link"),

    dict(name="pp", dir="usr/src/cmd/pp",
         objs={"pp.o": "pp.c"},
         gen={"lex.yy.c": ("lex", "scan.l", None)},
         libs=["usr/lib/libl.a"],
         dest="DESTDIR", product="pp", install="usr/bin/pp",
         note="cmd/pp/makefile: pp.o scan.o -ll; scan.o is the lex output and "
              "its makefile never says `lex', which is why the derivation "
              "linked it without a scanner"),

    dict(name="pic", dir="usr/src/cmd/pic",
         objs={"main.o": "main.c",
               "print.o": "print.c", "misc.o": "misc.c", "symtab.o": "symtab.c",
               "blockgen.o": "blockgen.c", "boxgen.o": "boxgen.c",
               "circgen.o": "circgen.c", "arcgen.o": "arcgen.c",
               "linegen.o": "linegen.c", "movegen.o": "movegen.c",
               "textgen.o": "textgen.c", "input.o": "input.c", "for.o": "for.c",
               "pltroff.o": "pltroff.c"},
         gen={"y.tab.c": ("yacc -d", "picy.y", "cp y.tab.h pic.ydef"),
              "lex.yy.c": ("lex", "picl.l", None)},
         sidegen={"y.tab.h": "y.tab.c", "pic.ydef": "y.tab.c"},
         objdeps=["pic.ydef"],
         dest="DESTDIR", product="pic", install="usr/bin/pic",
         note="cmd/pic/makefile: OFILES(16), YFLAGS=-d, pic.ydef is its copy "
              "of y.tab.h"),

    dict(name="grap", dir="usr/src/cmd/grap",
         objs={"main.o": "main.c",
               "input.o": "input.c", "print.o": "print.c", "frame.o": "frame.c",
               "for.o": "for.c", "coord.o": "coord.c", "ticks.o": "ticks.c",
               "plot.o": "plot.c", "label.o": "label.c", "misc.o": "misc.c"},
         gen={"y.tab.c": ("yacc -d", "grap.y", "cp y.tab.h prevy.tab.h"),
              "lex.yy.c": ("lex", "grapl.l", None)},
         sidegen={"y.tab.h": "y.tab.c", "prevy.tab.h": "y.tab.c"},
         objdeps=["prevy.tab.h"],
         dest="DESTDIR", product="grap", install="usr/bin/grap",
         note="cmd/grap/makefile: grap.o grapl.o + OFILES(10), prevy.tab.h is "
              "its copy of y.tab.h"),

    dict(name="ratfor", dir="usr/src/cmd/ratfor",
         objs={"y.tab.o": "y.tab.c", "r0.o": "r0.c", "r1.o": "r1.c",
               "r2.o": "r2.c", "rio.o": "rio.c", "rlook.o": "rlook.c",
               "rlex.o": "rlex.c"},
         # r.g, not r.y. The tape does not insist on suffixes and the
         # derivation's grammar test had to learn that from this directory.
         gen={"y.tab.c": ("yacc -d", "r.g", None)},
         sidegen={"y.tab.h": "y.tab.c"}, objdeps=["y.tab.h"],
         dest="DESTDIR", product="ratfor", install="usr/bin/ratfor",
         note="cmd/ratfor/makefile: a.out from seven objects; grammar is r.g"),

    # -------------------------------------- one directory, several programs
    #
    # The derivation refuses these because a directory with more than one
    # main() is more than one program and it has no way to know which objects
    # belong to which. The makefile does, so each product becomes its own
    # component here -- same directory, different objects, different install
    # path. Component names are the PRODUCTS, which is also why they do not
    # collide: at and atrun are two entries, not one entry with two outputs.
    #
    # Install directories are measured, and two of them are not where anyone
    # would put them: atrun is /usr/lib, not /etc beside cron, and diffh is
    # /usr/lib, not /bin beside diff.

    dict(name="at", dir="usr/src/cmd/at", objs=["at.c"], dest="DESTDIR",
         product="at", install="usr/bin/at",
         note="cmd/at/makefile: `all: at atrun', two independent programs"),
    dict(name="atrun", dir="usr/src/cmd/at", objs=["atrun.c"], dest="DESTDIR",
         product="atrun", install="usr/lib/atrun",
         note="cmd/at/makefile: the other half of at; /usr/lib measured"),

    dict(name="pack", dir="usr/src/cmd/pack", objs=["pack.c"], dest="DESTDIR",
         product="pack", install="usr/bin/pack",
         note="cmd/pack/makefile: `all: pack unpack'"),
    dict(name="unpack", dir="usr/src/cmd/pack", objs=["unpack.c"],
         dest="DESTDIR", product="unpack", install="usr/bin/unpack",
         # The tape hard-links /usr/bin/pcat to unpack. A second cp is the
         # same program under both names, which is what the link achieves and
         # all that matters here -- V8's ln(1) would need the target to exist
         # in DESTDIR first, and `also' already does copies.
         also=["usr/bin/pcat"],
         note="cmd/pack/makefile: unpack, plus pcat which the tape hard-links "
              "to it"),

    dict(name="diff", dir="usr/src/cmd/diff",
         objs=["diff.c", "diffdir.c", "diffreg.c"],
         # The tape bakes the paths of the programs diff execs into the
         # binary with -D. They are the paths on the system it will RUN on,
         # not on the one building it, so they stay absolute.
         cflags="-DDIFF='\"/bin/diff\"' -DDIFFH='\"/usr/lib/diffh\"' "
                "-DPR='\"/bin/pr\"' -d2",
         dest="DESTDIR", product="diff", install="bin/diff",
         note="cmd/diff/makefile: OBJS(3) and a second program diffh"),
    dict(name="diffh", dir="usr/src/cmd/diff", objs=["diffh.c"],
         dest="DESTDIR", product="diffh", install="usr/lib/diffh",
         note="cmd/diff/makefile: diffh, and /usr/lib is measured -- not /bin "
              "beside diff, which is where guessing would have put it"),

    dict(name="rarct", dir="usr/src/cmd/rarepl", objs=["rarct.c"],
         dest="DESTDIR", product="rarct", install="etc/rarct",
         note="cmd/rarepl/makefile: `cp rarct rarepl /etc'"),
    dict(name="rarepl", dir="usr/src/cmd/rarepl", objs=["rarepl.c"],
         dest="DESTDIR", product="rarepl", install="etc/rarepl",
         note="cmd/rarepl/makefile: the other half of rarct"),

    dict(name="calendar1", dir="usr/src/cmd/calendar", objs=["calendar1.c"],
         dest="DESTDIR", product="calendar1", install="usr/lib/calendar1",
         note="cmd/calendar/makefile: three programs, all /usr/lib"),
    dict(name="calendar2", dir="usr/src/cmd/calendar", objs=["calendar2.c"],
         dest="DESTDIR", product="calendar2", install="usr/lib/calendar2",
         note="cmd/calendar/makefile: three programs, all /usr/lib"),
    dict(name="calendar4", dir="usr/src/cmd/calendar", objs=["calendar4.c"],
         dest="DESTDIR", product="calendar4", install="usr/lib/calendar4",
         note="cmd/calendar/makefile: three programs, all /usr/lib"),
]

# ------------------------------------------------- the rest of usr/src/cmd
#
# Everything above is hand-written because something about it is NOT the
# common case: config needs yacc, lex and a header that exists only in the
# object directory; sh compiles one object to assembly and edits it; and the
# boot path had to be right before stage 8 could exist at all.
#
# The common case is one source file, one binary, one directory to put it in,
# and 173 of those sit LOOSE in usr/src/cmd with no makefile of any kind.
# Those are derived below rather than typed. Not to save typing: 130 hand-
# copied near-identical dicts invite exactly one kind of bug -- a duplicated
# line not fully edited -- and they would bury the single fact that actually
# varies between them, which is where the binary goes.
#
# And that fact is not in the source at all. /usr is a separate filesystem, so
# /bin has to be self-sufficient for a single-user boot, and nothing in a
# loose .c says which of /bin and /usr/bin it belongs to. where.txt answers it
# by MEASUREMENT -- tools/harvest-paths.sh walks the shipped image -- which is
# also why a name the image does not have is skipped rather than guessed: the
# 37 of those are drivers for hardware we do not emulate (rp07dump, bad144,
# hp), terminal support for terminals we do not have (2621, 300, 4014, 450),
# and a handful the image simply never installed.


def load_where():
    """name -> [directories it was found in] on the shipped image.

    Written by tools/harvest-paths.sh. Absent is not an error: the file is a
    measurement of a machine, so a checkout that has never booted one still
    generates -- it just generates the hand-written entries only, and says so.
    """
    path = os.path.join(HERE, "where.txt")
    if not os.path.exists(path):
        return {}
    w = {}
    for line in open(path):
        if line.startswith("#") or not line.strip():
            continue
        name, d = line.rstrip("\n").split("\t")
        w.setdefault(name, []).append(d)
    return w


WHERE = load_where()

# Which directory wins when a name was found in more than one. Root first,
# because the question this whole file exists to answer is what a system needs
# in order to repair itself with /usr unmounted.
DIRPREF = ["/bin", "/etc", "/lib", "/usr/bin", "/usr/games", "/usr/lib"]

# Headers that mean "this needs a library the derivation does not know about".
# The scan found exactly two hits across all 165 loose sources -- fstat.c
# (math.h, and not on the image anyway) and nmount.c (ours, hand-written
# above) -- so every derived command below links against libc alone. That is
# a fact about this tree, not an assumption, and this table is what keeps it
# true if the tree changes.
NEEDSLIB = {
    "curses.h": "libcurses.a + libtermlib.a",
    "math.h": "libm.a",
    "dbm.h": "libdbm.a",
    "sys/inet/in.h": "libin.a",
}


def derive_loose():
    """Entries for every loose file in usr/src/cmd the image says is a command.

    Returns (entries, skipped) where skipped is a list of (name, reason) --
    kept and written out, because a build that silently covers less than it
    appears to is worse than one that covers less and says so.
    """
    d = os.path.join(V8, "usr/src/cmd")
    # STAGE1 as well as STAGE6, and this is not a tidiness point. Six of the
    # toolchain's sources are loose .c in usr/src/cmd -- ld.c ar.c ranlib.c
    # nm.c size.c cc.c -- so the first version of this derived them a second
    # time and, because every generated file is named <component>.mk,
    # OVERWROTE stage 1's. The build would still have run: they are
    # single-file programs and the derived rule compiles them correctly.
    # What it drops is the part that is not in the source -- ld and as install
    # to bin/ AND lib/, which is the whole of what `cc -B$(TOOLDIR)/lib/'
    # resolves against, so stage 3 would have silently gone back to linking
    # with the running system's loader. Caught by --check on the second run,
    # which is the only reason it is a comment and not a week.
    hand = {c["name"] for c in STAGE6} | {c["name"] for c in STAGE1}
    entries, skipped = [], []

    for f in sorted(os.listdir(d)):
        stem, dot, ext = f.rpartition(".")
        if not dot or ext not in ("c", "y", "sh") or not stem:
            continue
        if os.path.isdir(os.path.join(d, f)):
            continue
        if stem in hand:
            continue                    # hand-written above; that one wins
        dirs = WHERE.get(stem)
        if not dirs:
            skipped.append((stem, "no binary of that name on the image"))
            continue

        # A source that reaches for a library we cannot name is skipped
        # rather than emitted with a link line that would fail late.
        body = open(os.path.join(d, f), "rb").read()
        need = [lib for h, lib in sorted(NEEDSLIB.items())
                if re.search(rb'#\s*include\s*[<"]%s[">]'
                             % re.escape(h.encode()), body)]
        if need:
            skipped.append((stem, "needs " + ", ".join(need)))
            continue

        best = sorted(dirs, key=lambda x: (DIRPREF.index(x)
                                           if x in DIRPREF else 99))[0]
        if len(dirs) > 1:
            # Two names in the whole tree, and neither is a plain second copy
            # of a binary: /usr/lib/units is the units TABLE, and procmount is
            # in both /etc and /usr/bin. Install to the preferred one and say
            # so, rather than `also'-ing a data file out of existence.
            skipped.append((stem, "also in %s -- installed only to %s"
                            % (", ".join(x for x in dirs if x != best), best)))
        install = best.lstrip("/") + "/" + stem

        if ext == "sh":
            entries.append(dict(name=stem, dir="usr/src/cmd", script=f,
                                dest="DESTDIR", product=stem, install=install,
                                note="loose %s; /%s measured on the image" % (f, install)))
        elif ext == "y":
            entries.append(dict(name=stem, dir="usr/src/cmd",
                                objs={"y.tab.o": "y.tab.c"},
                                gen={"y.tab.c": ("yacc", f, None)},
                                dest="DESTDIR", product=stem, install=install,
                                note="loose %s; /%s measured on the image" % (f, install)))
        else:
            entries.append(dict(name=stem, dir="usr/src/cmd", objs=[f],
                                dest="DESTDIR", product=stem, install=install,
                                note="loose %s; /%s measured on the image" % (f, install)))
    return entries, skipped


# --------------------------------------------- the makefile directories
#
# 113 of them, and the reason stage 6 is a list rather than a loop is that they
# are not a family: awk's makefile opens by saying it is wrong, sed links with
# `cc -o sed -n *.o', troff builds two programs out of overlapping object sets.
# So this does NOT try to run them, or to translate them wholesale. It reads
# each one for the two facts we cannot get anywhere else -- which objects, and
# which extra libraries -- and takes everything else from the tree and from
# where.txt, exactly as the loose files do.
#
# It is deliberately narrow, and refuses in four cases rather than guessing:
#
#   * the directory name is not a binary on the image (21 of them). The product
#     is then something else -- learn/ links `a.out', dump/ is not installed at
#     all -- and picking it out of `-o' arguments is guessing.
#   * the makefile runs yacc or lex (21). Those need gen/sidegen rules and an
#     -I., which config(8) already demonstrates; they are worth doing properly
#     rather than pattern-matching.
#   * it names a library with no source in this tree: ether, chaos, y, ln.
#   * it wants more than one product.
#
# What is left is 67 directories that really are "these objects, one binary,
# one place to put it", which is the same shape emit() already handles.

# -l<name> -> the archive stage 5 installs, BY PATH. Never -l: V8's ld has no
# -L, so -ll finds the running system's /usr/lib/libl.a in preference to ours,
# silently.  An empty string means "already in libc, link nothing":
#   m   -- V8 has no libm source at all. usr/src/libc/Makefile does
#          `cc -c -O math/*.c' straight into libc.a and our libc.mk compiles
#          the same 17 files, so -lm is a no-op here. /usr/lib/libm.a exists on
#          the shipped image and is not built from this tree.
#   c   -- emit() appends $(LIBC) to every link line already.
LIBMAP = {
    "m": "", "c": "",
    "l": "usr/lib/libl.a",       "cbt": "usr/lib/libcbt.a",
    "dk": "usr/lib/libdk.a",     "jobs": "usr/lib/libjobs.a",
    "termcap": "usr/lib/libtermcap.a", "termlib": "usr/lib/libtermcap.a",
    "curses": "usr/lib/libcurses.a",   "plot": "usr/lib/libplot.a",
    "F77": "usr/lib/libF77.a",   "I77": "usr/lib/libI77.a",
    "in": "usr/lib/libin.a",     "mp": "usr/lib/libmp.a",
    "dbm": "usr/lib/libdbm.a",   "g": "usr/lib/libg.a",
    "2621": "usr/lib/lib2621.a", "4014": "usr/lib/lib4014.a",
    "5620": "usr/lib/lib5620.a", "blit": "usr/lib/libblit.a",
    "tr": "usr/lib/libtr.a",     "pen": "usr/lib/libpen.a",
}

# A `-l' that is not a library at all. Every one of these was found by reading
# the hit rather than trusting the regex: -l84/-l90/-l57 are pr(1) page lengths
# in `print' targets, -lS is a lint flag, -ls is `ls -ls', -ln is the ln
# command in a rule, and -lunet/-lbtl are commented out in uucp/makefile.
NOTALIB = re.compile(r'pr\s+-l|lprint|can\s+-f|lint|\bls\s+-l|^\s*#')

# Two the 1985 compiler cannot build, quoted with its own words so nobody
# re-derives them.  Neither is a defect in the derivation and neither is worth
# patching around: they are facts about the tape.
REFUSE = {
    "cfront": "C++ translator; /bin/cc rejects it -- "
              "munch.c:18: `saw NAME ... cannot recover from earlier errors'",
    "compat": "System V compatibility traps; "
              "unixtraps.c:328: `non-constant case expression'",
}


def has_main(path):
    """Does this source define main() UNCONDITIONALLY?

    The `#ifdef' part is the whole point. ps/getfs.c and ps/getuname.c both
    open a main() inside `#ifdef TEST' -- a standalone test harness for a file
    that is otherwise linked into ps -- and ps/makefile lists getfs.o and
    getuname.o in OBJ alongside ps.o. A plain search for main() therefore
    counts three programs in a directory that builds one, and refuses ps for
    a conflict that cannot happen: TEST is never defined.

    Counting only at conditional depth 0 is conservative in the safe
    direction. A main() genuinely hidden behind an #ifdef the build does
    define would be missed here and would fail at the link, where it is
    obvious; the opposite mistake refuses a command that builds.
    """
    depth = 0
    for line in open(path, "rb").read().splitlines():
        s = line.lstrip()
        if s.startswith(b"#"):
            d = s[1:].lstrip()
            if d.startswith((b"if", b"ifdef", b"ifndef")):
                depth += 1
            elif d.startswith(b"endif"):
                depth = max(0, depth - 1)
            continue
        if depth == 0 and re.match(rb'\s*(?:int\s+)?main\s*\(', line):
            return True
    return False


def derive_dirs(taken):
    """Entries for usr/src/cmd/<dir>/makefile that fit the common shape.

    `taken' is what derive_loose() already produced. A name can be both -- and
    cflow is the case that proves the loose file should win: cmd/cflow.sh IS
    the command, a shell script, while cmd/cflow/ builds the four helpers it
    calls (dag, lpfx, nmf, flip) into /usr/lib. The directory is a
    multi-product entry that happens to share the command's name, so deriving
    it would install the wrong file as /usr/bin/cflow. Caught by put()'s
    duplicate check rather than by foresight.
    """
    d0 = os.path.join(V8, "usr/src/cmd")
    hand = ({c["name"] for c in STAGE6} | {c["name"] for c in STAGE1}
            | set(taken))
    entries, skipped = [], []

    for name in sorted(os.listdir(d0)):
        p = os.path.join(d0, name)
        if not os.path.isdir(p) or not os.path.exists(os.path.join(p, "makefile")):
            continue
        if name in hand:
            skipped.append((name + "/", "a loose file or a hand-written entry "
                                        "already provides this command"))
            continue
        dirs = WHERE.get(name)
        if not dirs:
            skipped.append((name + "/", "directory name is not a binary on the image"))
            continue

        mk = open(os.path.join(p, "makefile"), errors="replace").read()
        if name in REFUSE:
            skipped.append((name + "/", REFUSE[name]))
            continue
        # The DIRECTORY, not just the makefile. pp/ carries scan.l and its
        # makefile never says `lex', so the makefile test passed, the link
        # went ahead without a scanner, and ld reported the symptom rather
        # than the cause: `Undefined: _yylex, _yyinput'.
        # `.g' as well as `.y' and `.l': ratfor's grammar is r.g, and its
        # makefile says `yacc -d r.g'. The tape does not insist on suffixes.
        grammars = [f for f in os.listdir(p) if f.endswith((".y", ".l", ".g"))]
        # A RECIPE that runs yacc or lex, not the word anywhere in the file.
        # csh's makefile contains "lex" only inside sh.lex.o, an object name in
        # a macro continuation, and the loose test skipped the C shell over it.
        # Same shape as the -l84 hits: matching a word is not matching a use.
        invokes = re.search(r'^\t.*[; \t(]?\b(yacc|lex)\b\s', mk, re.M)
        if grammars or invokes:
            skipped.append((name + "/", "yacc/lex (%s) -- needs gen rules, like config"
                            % (" ".join(sorted(grammars))
                               or "invoked by its makefile")))
            continue
        # An archive built inside the component, which stage 5 knows nothing
        # about. map/ links libmap.a out of map/libmap, and without it ld
        # names the missing routines (_Xguyou, _Xtetra) rather than the
        # missing library.
        ours = set(LIBMAP.values())
        local = [a for a in re.findall(r'(\b\w+\.a)\b', mk)
                 if not any(o.endswith(a) for o in ours if o)]
        if local:
            skipped.append((name + "/", "links %s, built inside the component"
                            % " ".join(sorted(set(local)))))
            continue

        # Extra libraries, in the order the makefile names them: without a
        # valid __.SYMDEF, ld makes ONE sequential pass, and stage 5 does not
        # ranlib into DESTDIR.
        libs, unknown = [], []
        for line in mk.splitlines():
            if NOTALIB.search(line):
                continue
            for l in re.findall(r'-l([A-Za-z_][\w]*)', line):
                if l not in LIBMAP:
                    unknown.append(l)
                elif LIBMAP[l] and LIBMAP[l] not in libs:
                    libs.append(LIBMAP[l])
        if unknown:
            skipped.append((name, "needs -l%s, which has no source in this tree"
                            % ", -l".join(sorted(set(unknown)))))
            continue

        # Objects: every .o the makefile names that has a .c beside it. If it
        # names none, the whole directory. Taking the makefile's list matters
        # -- several directories carry sources for a second program, or a
        # `lint' stub, that the product does not link.
        # `[\w.]' and not `\w': trace/ has trace.expr.c, so the object is
        # trace.expr.o, and a pattern that stops at the dot captured `expr',
        # which is not a source here -- so the object was dropped, the link
        # went ahead without it, and ld named the two routines it could not
        # find (_evalcond, _evalexpr) rather than the file. Matching against
        # the directory's actual sources is what makes the looser pattern
        # safe.
        cs = {f[:-2] for f in os.listdir(p) if f.endswith(".c")}
        objs = sorted(o for o in set(re.findall(r'([\w.]+)\.o\b', mk))
                      if o in cs)
        if not objs:
            objs = sorted(cs)
        if not objs:
            skipped.append((name + "/", "no .c files"))
            continue

        # ONE main() OR IT IS NOT ONE PROGRAM. This is the check that catches
        # what "the directory name is a binary" does not: asd/ holds mkpkg,
        # seal and unseal; at/ holds at and atrun; calendar/ holds three. Each
        # source is a whole program, and linking the set gives
        #
        #	_main: atrun.o: multiply defined
        #
        # which is ld naming the second definition rather than the mistake.
        # Splitting them needs to know which objects belong to which product,
        # and the makefile is the only thing that knows -- so refuse here and
        # do those by hand.
        # A makefile that redefines .c.o is not compiling normally, and the
        # difference is not cosmetic. csh's rule pipes every source through
        # xstr to share string literals --
        #
        #	.c.o:
        #		${CC} -E ${CFLAGS} $*.c | ${XSTR} -c -
        #		${CC} -c ${CFLAGS} x.c
        #		mv x.o $*.o
        #
        # -- and strings.o, which the link needs, is PRODUCED by that process
        # rather than compiled from a source. Deriving the objects gives a
        # link that is missing a file no source in the directory could make.
        # ...but only when the recipe is more than one command. tsort also
        # redefines .c.o, and its whole recipe is `$C -c $G $*.c' -- a plain
        # compilation with different flags, which is not a reason to refuse
        # anything. Refusing it too dropped a command that had already been
        # observed to build. One line is normal; three lines and a pipe is
        # xstr.
        m = re.search(r'^\.c\.o\s*:[^\n]*\n((?:\t[^\n]*\n)+)', mk, re.M)
        if m and len([l for l in m.group(1).splitlines() if l.strip()]) > 1:
            skipped.append((name + "/", "redefines .c.o as a multi-step recipe "
                            "(xstr string sharing) -- objects are not plain "
                            "compilations"))
            continue

        # A source that is not C. csh/doprnt.c is VAX ASSEMBLY carrying cpp
        # directives, exactly like libc's errlst.o and sh's ctype.o, and the
        # makefile assembles it with `cc -E doprnt.c > doprnt.s; as'. Compiled
        # as C it dies on line 3 with
        #
        #	illegal character: 043 (octal)
        #
        # which is `#' -- an assembler comment that cpp passes straight
        # through. A `#' line that is not a cpp directive is the signature.
        CPPDIR = re.compile(rb'^\s*#\s*(include|define|undef|if|ifdef|ifndef'
                            rb'|else|elif|endif|line|pragma|\d|$)')
        notc = []
        for o in objs:
            for line in open(os.path.join(p, o + ".c"), "rb").read().splitlines():
                if line.lstrip().startswith(b"#") and not CPPDIR.match(line):
                    notc.append(o + ".c")
                    break
        if notc:
            skipped.append((name + "/", "%s is not C (assembly with cpp "
                            "directives); needs cc -E piped to as"
                            % " ".join(sorted(set(notc)))))
            continue

        # A header the tape references and does not ship. sdb/makefile lists
        # old.o, old.c says #include "bio.h", and bio.h exists nowhere in the
        # tree -- so sdb cannot be built from this source at all, and the
        # build says so as `Can't find include file bio.h' two dozen objects
        # in. Checking on the host costs nothing and names the file.
        missing = []
        inc = os.path.join(V8, "usr/include")
        for o in objs:
            body = open(os.path.join(p, o + ".c"), "rb").read()
            for h in re.findall(rb'^\s*#\s*include\s*"([^"]+)"', body, re.M):
                h = h.decode()
                if not (os.path.exists(os.path.join(p, h))
                        or os.path.exists(os.path.join(inc, h))):
                    missing.append("%s (from %s.c)" % (h, o))
        if missing:
            skipped.append((name + "/", "includes a header the tape does not "
                                        "ship: " + ", ".join(sorted(set(missing)))))
            continue

        mains = [o for o in objs if has_main(os.path.join(p, o + ".c"))]
        if len(mains) > 1:
            skipped.append((name + "/", "%d programs in one directory (%s) -- "
                            "needs the makefile's own object split"
                            % (len(mains), " ".join(sorted(mains)))))
            continue

        best = sorted(dirs, key=lambda x: (DIRPREF.index(x)
                                           if x in DIRPREF else 99))[0]
        if len(dirs) > 1:
            skipped.append((name, "also in %s -- installed only to %s"
                            % (", ".join(x for x in dirs if x != best), best)))
        entries.append(dict(name=name, dir="usr/src/cmd/" + name,
                            objs=[o + ".c" for o in objs],
                            libs=libs, dest="DESTDIR", product=name,
                            install=best.lstrip("/") + "/" + name,
                            note="cmd/%s/makefile: %d objects%s; /%s measured"
                                 % (name, len(objs),
                                    (", " + " ".join(libs)) if libs else "",
                                    best.lstrip("/") + "/" + name)))
    return entries, skipped


DERIVED, SKIPPED = derive_loose()
DIRENTRIES, DIRSKIPPED = derive_dirs({e["name"] for e in DERIVED})
DERIVED = DERIVED + DIRENTRIES
SKIPPED = SKIPPED + DIRSKIPPED
STAGE6 = STAGE6 + DERIVED

# ---------------------------------------------------------------- notes on
# what is NOT here yet, so the gap is on the record rather than implied:
#
#   the 113 makefile directories, minus the four already done (config, login,
#     sh and -- via stage 1 -- the toolchain's own). Each has to be read once,
#     because they are not a family: awk's makefile says outright that it is
#     wrong, sed links with `cc -o sed -n *.o', and troff builds two programs
#     out of overlapping object sets.
#   the 7 directories with no makefile: Admin ccom cref inet lfactor pcc1 upas
#     -- ccom and pcc1 are compilers we already build from elsewhere
#   whatever gen/stage6-skipped.txt lists after the last run


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the committed makefiles are stale")
    args = ap.parse_args()

    os.makedirs(GEN, exist_ok=True)
    stale = []

    written = set()

    def put(name, text):
        """Write gen/<name>, or record it as stale under --check.

        Every generated file goes through here.  It used to be four copies of
        the same read-compare-write, which is how stage5.order would have
        ended up being the one nobody remembered to check.

        The duplicate check is here because generated names are derived from
        component names, and two components CAN collide: six of stage 1's
        tools are also loose sources in usr/src/cmd, so stage 6's derivation
        wrote ld.mk over stage 1's. Nothing failed -- the second file was a
        valid makefile for the same program -- which is exactly why this is
        an assertion and not a warning.
        """
        if name in written:
            raise SystemExit("mkdep: two components both generate %s -- one "
                             "would silently overwrite the other" % name)
        written.add(name)
        path = os.path.join(GEN, name)
        old = open(path).read() if os.path.exists(path) else None
        if args.check:
            if old != text:
                stale.append(name)
        elif old != text:
            open(path, "w").write(text)

    def order(name, entries):
        put(name, "".join("%s\t%s\t%s\n" % e for e in entries))

    for c in STAGE1:
        put(c["name"] + ".mk", emit(c))
    put("libc.mk", emit_libc())
    order("stage1.order", [(c["name"], c["dir"], c["install"]) for c in STAGE1])

    # stage 4 -- one makefile, no order file: there is only one thing to do
    hdrtext, nhdr = emit_headers()
    put("headers.mk", hdrtext)

    # stage 8 -- /dev.  Not a makefile: a shell script, because every line is
    # a mknod and there is nothing to make up to date.
    devtext, ndev, _ = emit_makedev()
    put("makedev.sh", devtext)

    # What we build and what we copy, as a file the build reads rather than
    # a paragraph someone has to keep true.
    installed = set()
    for c in STAGE1 + STAGE6:
        installed.add(c["install"].rsplit("/", 1)[-1])
        for a in c.get("also", []):
            installed.add(a.rsplit("/", 1)[-1])
    provtext, nbuild, ncopy = emit_provenance(installed)
    put("provenance.txt", provtext)

    # stage 5 -- the libraries
    for l in STAGE5:
        put(l["name"] + ".mk", emit_lib(l))
    order("stage5.order", [(l["name"], l["dirs"][0], l["install"]) for l in STAGE5])

    # stage 6 -- the commands, same emitter as stage 1: they are the same
    # shape (objects, one product, one install path) and the only reason
    # stage 1 is separate is that it has to be built before there is anything
    # to build it with.
    for c in STAGE6:
        put(c["name"] + ".mk", emit(c))
    order("stage6.order", [(c["name"], c["dir"], c["install"]) for c in STAGE6])

    # What the derivation deliberately did NOT cover, and why. Generated
    # rather than commented, so it cannot drift from the code that produced
    # it -- and so `stage 6 built 145 commands' is never mistaken for `stage 6
    # built the tree'. Not read by anything; read by people.
    put("stage6-skipped.txt",
        "# Loose files in usr/src/cmd that derive_loose() did not emit.\n"
        "# Regenerated by v8/mk/mkdep.py; see load_where() for the oracle.\n#\n"
        + "".join("%-12s %s\n" % s for s in SKIPPED))

    if args.check:
        if stale:
            print("stale, re-run v8/mk/mkdep.py: " + " ".join(stale))
            return 1
        print("makefiles are up to date with the source tree")
        return 0
    print("generated %d toolchain + libc + %d headers + %d libraries + %d commands"
          " + %d device nodes in %s"
          % (len(STAGE1), nhdr, len(STAGE5), len(STAGE6), ndev,
             rel(GEN, os.getcwd())))
    print("  commands: %d hand-written, %d derived from the tree + where.txt,"
          " %d skipped (gen/stage6-skipped.txt)"
          % (len(STAGE6) - len(DERIVED), len(DERIVED), len(SKIPPED)))
    if not WHERE:
        print("  NO v8/mk/where.txt -- run tools/harvest-paths.sh; without it"
              " stage 6 is the hand-written entries only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
