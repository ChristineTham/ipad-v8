"""
The makefile generator, minus the edition.

Research Unix never shipped a way to build itself. Track S wrote one for V8
(`v8/mk/mkdep.py`) because V8's `usr/src/cmd` is 168 loose `.c` files under a
directory with no makefile in it. B2.0 measured V10's and found the same shape
eight years later -- 207 loose `.c` files, no makefile, and no world build
anywhere in the tree; the one candidate, `src/makefile`, builds a Datakit
daemon called `fshare`.

So the generator is shared and the KNOWLEDGE is not. What lives here is the
machinery that does not care which edition it is looking at:

    scan_includes   transitive #include closure, as filenames make can stat
    emit            one component -> one makefile
    emit_shell      the same, for a component that is a shell script
    mkdirs_for      V8's mkdir makes one level; every ancestor needs a line
    has_main        does this .c define main() at conditional depth 0
    load_where      name -> where the shipped system put it

What stays in each edition's own `mk/mkdep.py` is its component tables, its
preamble, its install layout and its exceptions -- which is most of the volume
and all of the argument. V8's generator is 2,449 lines and roughly 700 of them
are the STAGE1/STAGE5/STAGE6 tables alone.

WHY A PROFILE OBJECT RATHER THAN A FORK. The two editions differ in the
preamble (V10 compiles with `cc -B/usr/v10/lib/ -t02palc` and reads r70's
headers), in where the tree is rooted, and in nothing else about the SHAPE of
a makefile. A fork would mean every later fix to the dependency scanner had to
be made twice and would silently not be -- and this project already has the
scar: three harnesses each grew a private "log in and run a command" and all
three hung, which is why `tools/v8drive.exp` exists.

THE GUARD. `v8/mk/mkdep.py --check` compares the committed makefiles against
freshly generated ones, so any change here that alters V8's output by a single
byte fails a check that already exists. That is what made this extraction safe
to do at all.
"""

import os
import re

# `#   include <x.h>' -- V10's cpp.c opens with `# include <libc.h>', ordinary
# 1970s style, and a scan anchored on the bare token `#include' misses it. That
# exact mistake declared every header present and cost a whole boot in B1.
INCLUDE = re.compile(rb'^\s*#\s*include\s*([<"])([^">]+)[">]', re.M)


class Edition:
    """Everything the generator has to be told rather than work out.

    root     absolute path to the source tree being read
    incdir   absolute path to the <angle-bracket> header directory
    here     absolute path to this edition's mk/ directory (holds where.txt)
    gen      absolute path to where generated makefiles are written
    preamble the makefile header, taking %(name)s %(cflags)s %(incs)s
    """

    def __init__(self, name, root, incdir, here, gen, preamble):
        self.name = name
        self.root = root
        self.incdir = incdir
        self.here = here
        self.gen = gen
        self.preamble = preamble

    def __repr__(self):
        return "<Edition %s root=%s>" % (self.name, self.root)


# ---------------------------------------------------------------- scanning


def scan_includes(path, incdirs, seen=None):
    """Transitive #include closure, as filenames make can compare mtimes on.

    Angle-bracket includes are followed too, but only into the tree -- a
    <stdio.h> resolved against the edition's own include directory is a real
    dependency, because the build installs our headers and we want that to
    rebuild the world. Unresolvable includes are dropped rather than guessed
    at.
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


def mkdirs_for(dest, path):
    """`-mkdir' lines for every ancestor of PATH, outermost first.

    V8's mkdir makes ONE level.  `mkdir /b/root/usr/inet/bin' fails with
    "cannot access /b/root/usr/inet/." unless the parent already exists -- and
    it fails AFTER the compile and the link have both succeeded, so the
    component reports INSTALL FAILED with a perfectly good binary sitting in
    the object directory.  That reads as a build problem and is not one.
    """
    parts = [p for p in os.path.dirname(path).split("/") if p]
    return ["\t-mkdir %s/%s\n" % (dest, "/".join(parts[:i + 1]))
            for i in range(len(parts))]


def has_main(path):
    """Does this source define main() UNCONDITIONALLY?

    The `#ifdef' part is the whole point. V8's ps/getfs.c and ps/getuname.c
    both open a main() inside `#ifdef TEST' -- a standalone test harness for a
    file that is otherwise linked into ps -- and ps/makefile lists getfs.o and
    getuname.o in OBJ alongside ps.o. A plain search for main() therefore
    counts three programs in a directory that builds one, and refuses ps for a
    conflict that cannot happen: TEST is never defined.

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


def load_where(ed):
    """name -> [directories it was found in] on the shipped image.

    For V8 this is written by tools/harvest-paths.sh from the reference image.
    Absent is not an error: the file is a measurement of a machine, so a
    checkout that has never booted one still generates -- it just generates
    the hand-written entries only, and says so.

    V10 has no shipped image to measure, which is the whole of B3, so its
    oracle has to come from somewhere else; see tools/v10-where.py.

    A third, optional column records HOW an entry was decided.  It is ignored
    here and kept in the same file on purpose: V8's answer came from measuring
    one machine, so every row has the same provenance and none needs stating,
    while V10's is assembled from two sources of unequal authority and a
    reader has to be able to tell them apart without opening a second file
    that could drift out of step with this one.
    """
    path = os.path.join(ed.here, "where.txt")
    if not os.path.exists(path):
        return {}
    w = {}
    for line in open(path):
        if line.startswith("#") or not line.strip():
            continue
        parts = line.rstrip("\n").split("\t")
        w.setdefault(parts[0], []).append(parts[1])
    return w


# ---------------------------------------------------------------- emitting


def emit_shell(ed, c):
    """A component that is a shell script: install is the whole build.

    It still gets a makefile rather than a line in the driver, because a
    self-rebuild has to be able to reproduce the system the same way the
    original build made it, and "the same way" means the same rules. A script
    whose install lives in a driver instead would be the one thing chroot
    could not reproduce.

    The copy is deliberate rather than installing straight off the share: the
    product has to exist in the object directory for `make' to have anything
    to compare mtimes against, exactly like a binary.
    """
    srcdir = "$(SRC)/" + c["dir"]
    src = "%s/%s" % (srcdir, c["script"])
    dest = "$(%s)" % c.get("dest", "DESTDIR")
    out = [ed.preamble % dict(name=c["name"], cflags="", incs="")]
    # `all' first, like every other generated makefile: the driver runs
    # `make -f x.mk' with no goal, so the first target is the default one.
    out.append("\nall: %s\n" % c["product"])
    out.append("\n%s: %s\n\tcp %s %s\n\tchmod +x %s\n"
               % (c["product"], src, src, c["product"], c["product"]))
    out.append("\ninstall: %s\n" % c["product"])
    out.extend(mkdirs_for(dest, c["install"]))
    out.append("\tcp %s %s/%s\n" % (c["product"], dest, c["install"]))
    out.append("\nclean:\n\t-rm -f %s\n" % c["product"])
    return "".join(out)


def emit(ed, c):
    # A component may be read from somewhere other than the pristine tree.
    # Track B keeps upstream sources untouched -- v10/MANIFEST is the record
    # that our copy of the tarball is complete and unaltered, and patching in
    # place would invalidate it -- so our corrected files live in a small
    # overlay served beside it.  `root'/`srcmacro' point one component at
    # that overlay, which puts the provenance IN THE MAKEFILE: a rule reading
    # $(OURS) is visibly ours and a rule reading $(SRC) is visibly Bell Labs'.
    #
    # Whole-component only, for now.  Every patched V10 command so far is a
    # single loose .c; a component needing our copy of one file and the
    # tarball's copy of another would need this per source, and should say so
    # rather than quietly taking the overlay for both.
    root = c.get("root", ed.root)
    srcmac = c.get("srcmacro", "SRC")
    d = os.path.join(root, c["dir"])
    if c.get("script"):
        return emit_shell(ed, c)
    incs = c.get("incs", ["."])
    incdirs = [os.path.normpath(os.path.join(d, i)) for i in incs]
    incdirs.append(ed.incdir)

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
    # mapped to the target that produces them.  V8 cpp's :yyfix splits the
    # parser tables out of y.tab.c into rodata.c while making cpy.c, so
    # rodata.c exists only in the object directory and has no rule and no
    # file on the share.  Without this it is looked for on the share and make
    # stops.
    sidegen = c.get("sidegen", {})
    # a generated .c has no file on disk yet; its deps come from the grammar
    for g in gen:
        objmap.setdefault(g[:-2] + ".o", g)

    incdir = ed.incdir

    srcdir = "$(%s)/" % srcmac + c["dir"]

    def dep(path):
        """Name a dependency the way make will see it at build time.

        System headers become $(INCDIR)/x.h rather than a relative path, so the
        same makefile is correct in an early stage (reading the running
        system's /usr/include) and in a later one (reading
        $(DESTDIR)/usr/include) with only the macro changed.
        """
        path = os.path.normpath(path)
        if path.startswith(incdir + os.sep):
            return "$(INCDIR)/" + rel(path, incdir)
        return srcdir + "/" + rel(path, d)

    # A component that GENERATES A HEADER needs -I. as well.  cpp searches
    # dirs[0] -- the directory of the file being compiled -- and never the
    # current directory unless the source happens to be in it.  y.tab.h is
    # written by `yacc -d' into the OBJECT directory, while the source is read
    # off the share, so
    #
    #	main.c:14: Can't find include file y.tab.h
    #
    # even though y.tab.h was made correctly a moment earlier.  lex.yy.c
    # compiles fine in the same directory precisely because IT lives there
    # too.  An in-tree build never sees this: source and object are one
    # directory, so dirs[0] covers both.
    incflags = ["-I$(%s)/" % srcmac + os.path.normpath(os.path.join(c["dir"], i))
                for i in incs]
    if gen or sidegen:
        incflags.insert(0, "-I.")
    out = [ed.preamble % dict(name=c["name"], cflags=c.get("cflags", ""),
                              incs=" ".join(incflags))]
    out.append("OBJS = " + " ".join(sorted(objmap)) + "\n")
    out.append("\nall: %s\n" % c["product"])

    # link
    # $(LIBC) is NAMED on the link line, not merely depended on.  cc appends an
    # implicit -lc, which ld resolves from /lib/libc.a -- so a stage that has
    # built its own libc would silently keep linking against the tape's unless
    # the archive is on the command line ahead of it.  ld takes the first
    # definition it finds, so ours wins and the implicit -lc adds nothing.
    #
    # `libs` names extra archives BY PATH, never with -l.  V8's ld has no -L:
    # getfile() rewrites one template string to try /lib, /usr/lib and
    # /usr/local/lib, so -ll would resolve out of the RUNNING system's
    # /usr/lib in preference to the libl.a the build just made -- silently,
    # and the build would succeed.
    libdeps = "".join(" $(DESTDIR)/" + x for x in c.get("libs", []))
    out.append("\n%s: $(OBJS) $(LD) $(LIBC)%s\n\t$(CC) $(CFLAGS) %s-o %s $(OBJS)%s $(LIBC)\n"
               % (c["product"], libdeps,
                  (c["ldflags"] + " ") if c.get("ldflags") else "",
                  c["product"], libdeps))

    # generated sources
    for target, (tool, src, extra) in sorted(gen.items()):
        # `tool` may carry flags -- "yacc -d", which V8's config(8) needs
        # because its grammar and mkconf.c share y.tab.h and nothing else
        # generates it.  First word picks the macro pair, the rest rides on
        # the command.
        toolname = tool.split()[0]
        toolflags = " ".join(tool.split()[1:])
        # command vs binary again: the recipe runs $(YACC), the
        # prerequisite must name the file whose mtime says it changed.
        # `natural` is the filename the tool writes if you do not tell it
        # otherwise, so a target that differs from it needs the mv -- and
        # lex's is not yacc's, which a "!= y.tab.c" test gets wrong the
        # moment a lex-generated source appears.
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
    # ENTRY, before the producer runs.  Rather than rely on alphabetical
    # order deciding whether the producer has already run, give every
    # side-effect target a command.
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
        # has to move out of .data and into shared text.
        # %s in a recipe line is the source path, so the entry does not have
        # to repeat it.
        if obj in special:
            out.append("\n%s: %s $(TOOLS)\n" % (obj, " ".join(deps)))
            for line in special[obj]:
                out.append("\t%s\n" % (line.replace("%s", srcref)))
        else:
            out.append("\n%s: %s $(TOOLS)\n\t$(COMPILE) %s%s\n"
                       % (obj, " ".join(deps), extra, srcref))

    # pre-commands (V8's ccom needs y.debug in place before cgram.o)
    if c.get("pre"):
        out.append("\nprepare:\n")
        for cmd in c["pre"]:
            out.append("\t%s\n" % cmd)

    # install -- into TOOLDIR or DESTDIR.  Never /bin, never /lib.
    #
    # Build machinery goes to TOOLDIR because the system being assembled must
    # not contain it just because it needed it.  The commands go to DESTDIR
    # because they ARE the system.
    dest = "$(%s)" % c.get("dest", "TOOLDIR")
    out.append("\ninstall: %s\n" % c["product"])
    inst = c["install"]
    out.extend(mkdirs_for(dest, inst))
    out.append("\tcp %s %s/%s\n" % (c["product"], dest, inst))
    # a second home for the same binary -- see `also` in the component table
    for dst in c.get("also", []):
        out.extend(mkdirs_for(dest, dst))
        out.append("\tcp %s %s/%s\n" % (c["product"], dest, dst))
    for src, dst in c.get("data", []):
        out.extend(mkdirs_for(dest, dst))
        out.append("\tcp %s/%s %s/%s\n" % (srcdir, src, dest, dst))

    out.append("\nclean:\n\t-rm -f $(OBJS) %s %s\n"
               % (c["product"], " ".join(sorted(gen))))
    return "".join(out)
