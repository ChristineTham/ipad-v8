#!/usr/bin/env python3
"""Full scan: is everything that should be on the built disk actually on it?

	tools/config-audit.py [--ref IMG] [--ipnx IMG] [-v]

THE GAP THIS EXISTS TO CLOSE.  retire-check.py asks "is everything the TUHS
image had present?"  It is structurally incapable of noticing that something
of OURS is missing or unconfigured, because there is no reference for our own
additions -- and that is exactly how a golden disk shipped with

  * /etc/whoami reading `v8generic', so the machine did not know its name;
  * /etc/motd still the 1985 trolley-car joke rather than the licensing
    position this project actually runs under;
  * /etc/ttys with `03tty02'..`03tty05' -- leading 0 is DISABLED -- so six of
    the eight ttys the app opens had no getty at all;
  * no uname(1), which is ours and which the build had never been told about.

Every one of those passed retire-check with UNIQUE 0 and boot-newdisk with
thirteen green checks, because presence is not configuration and containment
is not completeness.

WHAT IT COMPARES, and why in two directions.

1. CONFIG, against a reference image that IS configured.  Binaries we build
   ourselves legitimately differ from the tape's (different compiler, 2026 vs
   1985), so those are skipped by looking at the a.out magic rather than by
   keeping a list.  Everything that is NOT an a.out -- shell scripts, /etc
   tables, termcap, the profiles -- should be byte-identical unless we changed
   it deliberately, and each deliberate difference is named in EXPECTED below
   with the reason.  Anything else is a config item that never made it into
   the build.

2. OURS, from the source tree.  Every file under v8/ that MANIFEST does not
   describe came from us rather than off the tape, so it has no business being
   absent.  Compared by inode TYPE as well as path, because a directory named
   /bin/sh satisfies a search for the file /bin/sh -- that is not
   hypothetical either, it is how 424 files became directories and the disk
   still passed its containment check.
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v8fs

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OMAGIC, NMAGIC, ZMAGIC = 0o407, 0o410, 0o413

# Differences that are correct, each with the reason it is correct. Anything
# not named here and not an a.out is a finding, not a footnote.
EXPECTED = {
    "/etc/fstab": "geometry: /usr is partition g on an RP06 and f on an RP07",
    "/etc/mtab": "runtime state — what was mounted on whichever machine",
    "/etc/utmp": "runtime state — who was logged in",
    "/etc/motd": "ours: a greeting and a pointer, not the 1985 joke",
    # The licensing position moved out of motd and into a file of its own, so
    # what greets you at every login is two lines rather than seventeen. The
    # tape has no /etc/copyright at all -- it is ours, and it is where motd
    # now points.
    "/etc/copyright": "ours: the licensing position, moved out of motd",
    "/etc/whoami": "ours: the machine is ipnx-v8",
    "/unix": "stage 7 builds our own kernel",
    # The Wide-screen preset. The configured REFERENCE was made by
    # fix-identity.exp, which predates muxterm.w, so it cannot carry the block
    # that selects it -- ours is the newer file and the difference IS the
    # feature. Checked by reading the disk, not assumed: rp07new's /.profile
    # has the `test -f /etc/dmdwide' arm.
    "/.profile": "ours: adds the MUXTERM arm that picks muxterm.w on a wide screen",
    "/etc/skel/.profile": "ours: the same MUXTERM arm, for every account we create",
    # Runtime state a freshly built disk has not had time to produce. These
    # are written BY running, so a disk that has them is a disk that has been
    # used, and a disk that lacks them is simply new.
    "/usr/adm/lastboot": "written by /etc/rc on every boot",
    "/usr/adm/messages": "the kernel's own log, written while running",
    "/tmp/muxerr": "left in /tmp by a mux session on that machine",
}

def installed_paths(refdirs=frozenset()):
    """Every exact path the build installs — DERIVED, never listed.

    This was a hand-written tuple for about an hour, which is exactly the
    trap the rest of this tree already warns about: a list of "things that
    are ours" is correct on the day it is written and silently wrong
    afterwards. gen/destfiles.txt is scraped from the cp rules of the
    generated makefiles, so a component that starts installing somewhere new
    appears here without anyone remembering to add it.

    Plus the handful builddisk.sh installs by name rather than through a
    makefile — those genuinely have no generated source, and the file that
    installs them is the one place they can be read from.
    """
    dirs = set()
    dp = os.path.join(REPO, "v8", "mk", "gen", "destdirs.txt")
    if os.path.exists(dp):
        for line in open(dp):
            line = line.strip()
            if line and not line.startswith("#"):
                dirs.add("/" + line)

    out = set()
    p = os.path.join(REPO, "v8", "mk", "gen", "destfiles.txt")
    if os.path.exists(p):
        for line in open(p):
            line = line.strip()
            if line and not line.startswith("#"):
                out.add("/" + line)
    # builddisk.sh's explicit installs, read out of the script itself.
    bd = os.path.join(REPO, "v8", "mk", "builddisk.sh")
    if os.path.exists(bd):
        text = open(bd).read()
        for m in re.finditer(r"\$MNT(/[A-Za-z0-9_./+-]+)", text):
            t = m.group(1)
            if not t.endswith("/") and "*" not in t and "$" not in t:
                out.add(t)
    # A path the build makes a DIRECTORY of is not a missing file. Both the
    # generated list and the ones every filesystem has.
    out -= dirs
    # ...and anything the REFERENCE image says is a directory. The $MNT scrape
    # cannot tell `cp x $MNT/usr/jerq/bin' (a directory target) from
    # `cp x $MNT/etc/foo' (a file), and a real V8 system is the only authority
    # on which is which. Derived, so it stays right as the tree changes.
    out -= refdirs
    return out


def is_aout(b):
    if len(b) < 4:
        return False
    m = b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
    return m in (OMAGIC, NMAGIC, ZMAGIC)


def is_archive(b):
    return b[:8] == b"!<arch>\n" or b[:8] == b"<ar>\n\0\0\0"


def walk(img):
    """path -> (fs, inode) across the whole system, /usr included."""
    out = {}
    for part, pfx in v8fs.wholesystem(img):
        fs = v8fs.V8FS(img, part)
        for p, ip in fs.walk("/"):
            out[pfx + p] = (fs, ip)
    return out


def load_manifest_paths():
    """Stored paths MANIFEST describes — i.e. what came off the tape."""
    tape = set()
    p = os.path.join(REPO, "v8", "MANIFEST")
    for line in open(p):
        if line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 6:
            tape.add(f[5])
    return tape


def in_git():
    """Image paths whose content lives in the repo instead of on the disk.

    Without this the audit drowns: the reference image carries the entire
    /usr/src tree as ordinary text, and ours deliberately does not — the
    source is in git and the disk holds binaries. That is 4,400 files of
    "missing" that are nothing of the kind, and they hide the twenty or so
    that matter. Same rule retire-check.py applies, and the same mapping:
    MANIFEST's fifth field is the image path (jerq/ and blit/ live under
    /usr), the sixth is where it is stored under v8/.
    """
    out = set()
    p = os.path.join(REPO, "v8", "MANIFEST")
    for line in open(p):
        if line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) < 6 or f[0] not in ("source", "unpacked"):
            continue
        top = f[4].split("/")[0]
        img = "/usr/" + f[4] if top in ("jerq", "blit") else "/" + f[4]
        if os.path.exists(os.path.join(REPO, "v8", f[5])):
            out.add(img)
    return out


def ours_in_tree():
    """Files under v8/ that did not come off the tape."""
    tape = load_manifest_paths()
    out = []
    v8 = os.path.join(REPO, "v8")
    for root, _dirs, files in os.walk(v8):
        if "/mk" in root.replace(v8, "", 1):
            continue
        for fn in files:
            rel = os.path.relpath(os.path.join(root, fn), v8)
            if rel in ("MANIFEST", "RELEASE", "CASEMAP", "EMPTYDIRS") \
               or rel.endswith(".md") or rel.startswith("mk/"):
                continue
            if rel not in tape:
                out.append(rel)
    return sorted(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default=os.path.join(REPO, "work/myv8/rp06v8.golden"),
                    help="a CONFIGURED reference image")
    ap.add_argument("--ipnx", default=os.path.join(REPO, "work/myv8/rp07new"))
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    ours = walk(args.ipnx)
    ingit = in_git()
    refdirs = frozenset()
    findings = []

    # ---- 1. config, against the configured reference -------------------
    checked = skipped = ngit = 0
    if os.path.exists(args.ref):
        ref = walk(args.ref)
        refdirs = frozenset(p for p, (_f, i) in ref.items() if i.isdir)
        for path in sorted(ref):
            rfs, rip = ref[path]
            if rip.isdir or not rip.isreg:
                continue
            try:
                rdata = rfs.read(rip)
            except Exception:
                continue
            if is_aout(rdata) or is_archive(rdata):
                skipped += 1
                continue          # we rebuild these; difference is expected
            checked += 1
            if path in EXPECTED:
                continue
            if path in ingit:
                ngit += 1
                continue
            got = ours.get(path)
            if got is None:
                findings.append((path, "on the configured reference, NOT on ours"))
                continue
            gfs, gip = got
            if gip.isdir:
                findings.append((path, "ours has it as a DIRECTORY, not a file"))
                continue
            if gfs.read(gip) != rdata:
                findings.append((path, "content differs from the configured reference"))
    else:
        print("note: no reference image at %s — config half skipped\n"
              % os.path.relpath(args.ref, REPO))

    # ---- 2. ours, from the source tree ---------------------------------
    missing_ours = []
    for p in sorted(installed_paths(refdirs)):
        got = ours.get(p)
        if got is None:
            missing_ours.append((p, "the build installs this; it is not on the disk"))
        elif got[1].isdir:
            missing_ours.append((p, "installed, but on the disk as a DIRECTORY"))

    print("config audit")
    print("  reference   %s" % os.path.relpath(args.ref, REPO))
    print("  built       %s" % os.path.relpath(args.ipnx, REPO))
    print("")
    print("  non-binary files compared   %5d" % checked)
    print("  a.out/archives skipped      %5d   (we rebuild these)" % skipped)
    print("  in git, not on the disk     %5d   (MANIFEST source)" % ngit)
    print("  deliberate differences      %5d   (named in EXPECTED)" % len(EXPECTED))
    print("  installed paths checked     %5d   (derived from the build)" % len(installed_paths(refdirs)))
    print("")

    for label, rows in (("CONFIG NOT APPLIED", findings),
                        ("INSTALLED BUT NOT ON THE DISK", missing_ours)):
        if rows:
            print("%s — %d:" % (label, len(rows)))
            for p, why in rows[:40]:
                print("  %-40s %s" % (p, why))
            if len(rows) > 40:
                print("  ... and %d more" % (len(rows) - 40))
            print("")

    if args.verbose:
        print("in the source tree but not on the tape (ours):")
        for p in ours_in_tree():
            print("    %s" % p)
        print("")

    if findings or missing_ours:
        print("FAIL — %d config, %d missing" % (len(findings), len(missing_ours)))
        return 1
    print("OK — every configured file matches and every ipnx addition is present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
