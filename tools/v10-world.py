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
INSTALLED_EXTRA = {
    "stdlib.h": "CC/stdlib.h",
    "float.h": "lcc/float.h",
    "stdarg.h": "lcc/stdarg.h",
    "shares.h": "<ours: v10/src/include/shares.h>",
}

# r70 keeps several headers ONLY inside a compiler's variant directory --
# include/lcc/, include/CC/, include/olcc/, include/oCC/, include/libc/ -- and
# never at top level.  A unit wanting one of those is not blocked by a missing
# file: it is asking a SYSTEM-LAYOUT question, exactly the one stdlib.h asked
# and INSTALLED_EXTRA answered.  Reporting those separately from genuinely
# absent headers is the difference between "convert this source" and "decide
# which of the tape's four copies belongs at /usr/include", which are entirely
# different pieces of work.
VARIANT_DIRS = ["lcc", "CC", "olcc", "oCC", "libc"]

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
    """The .c/.h/.s/.y/.l files of one directory, not recursing."""
    out = []
    try:
        for n in sorted(os.listdir(d)):
            if n.endswith((".c", ".h", ".s", ".y", ".l")):
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
        self.overlay = False          # do we already carry a patched copy?

    @property
    def ok(self):
        return not self.missing


def resolve(header, bracket, unit_dirs, unit_root=None):
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
    """Fill in a unit's includes, missing headers, hints and main()."""
    dirs = sorted(set(os.path.dirname(p) for p in unit.paths))
    seen = set()
    for p in unit.paths:
        text = read(p)
        if MAIN.search(text):
            unit.has_main = True
        for pat, label in ANSI_HINTS:
            if pat.search(text) and label not in unit.hints:
                unit.hints.append(label)
        for bracket, header, guard in includes_of(text):
            key = (bracket, header)
            if key in seen:
                continue
            seen.add(key)
            unit.includes.append(key)
            where = resolve(header, bracket, dirs, unit.root)
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
    if not csources(u):
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
        if not srcs:
            continue
        d = "." if u.kind == "file" else os.path.relpath(u.root, CMD)
        rel = [os.path.relpath(os.path.join(SRC, s), os.path.join(CMD, d))
               for s in srcs]
        out.append("%s %s %s" % (u.name, d, " ".join(sorted(rel))))
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
#	sh worldc.sh <srcroot> <objdir> <ccpath> <bprefix>
#
# srcroot  the mounted courier disk, e.g. /n/v10
# objdir   scratch on a WRITABLE filesystem, e.g. /usr/k10obj
# ccpath   the driver, /bin/cc
# bprefix  stage 1's passes, e.g. /usr/s1/lib/
SRC=$1
OBJ=$2
CCP=$3
BP=$4
UD=$SRC/src/cmd
JQ=$SRC/jerq
CF="-O -c"
CC="$CCP -B$BP -t02p"

P=CBUILT
Q=CFAILED
N=CNOSRC
K=CANARY
SP=SPACE

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
$CC $CF $UD/halt.c > can.log 2>&1
if test -s halt.o
then
	echo "$K-ok"
else
	echo "NO$K"
	sed -e 5q can.log
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
	# The four units that need more than the unit dir, common/ and vax/ --
	# adb/comm, f77/alt, mk/export, nupas/attin.  Absent from world.incs is
	# the usual case and adds nothing.
	XI=""
	for x in `sed -e "/^$name /!d" -e "s/^$name //" $SRC/mk/world.incs`
	do
		XI="$XI -I$SD/$x"
	done
	for f in $srcs
	do
		# BOTH TESTS, because either alone has lied here before.  The
		# prebuilt lcc exits 0 while writing an EMPTY object, and V10's
		# ld writes its output file even with symbols undefined -- so a
		# status of 0 is not proof, and a file existing is not proof.
		b=`echo $f | sed -e 's|.*/||' -e 's|\.c$|.o|'`
		rm -f $b
		$CC $CF -I$SD -I$SD/common -I$SD/vax $XI -I$JQ $SD/$f \
			>> u.log 2>&1 || ok=n
		test -s $b || ok=n
	done
	if test $ok = y
	then
		echo "$P $name" >> $OBJ/res.log
		echo "$P $name"
		FAILRUN=""
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


GENERATED = [
    ("world.txt", lambda u, p: world_txt(u, p)),
    ("world.cpio", lambda u, p: world_cpio(u)),
    ("world.units", lambda u, p: world_units(u)),
    ("world.incs", lambda u, p: world_incs(u)),
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

    report(units, pre)
    return 0


if __name__ == "__main__":
    sys.exit(main())
