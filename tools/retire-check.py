#!/usr/bin/env python3
"""Prove that nothing is lost by retiring the TUHS V8 image.

	tools/retire-check.py [--tuhs IMG] [--ipnx IMG] [-v]

Exit 0 only if EVERY file on the TUHS image is accounted for by one of:

  on ours	the ipnx image has that path -- built by stages 4-7, or
		carried by gen/carry.txt
  in git	v8/MANIFEST calls it `source' (or `unpacked') and the stored
		file is present in v8/.  The tape's text lives in the repo,
		so the image is not the only copy.  Content is proven
		separately and once, by `tools/v8-import.py --verify',
		which re-hashes every stored file against MANIFEST.
  by policy	deliberately not reproduced: /dev (makedev.sh builds it),
		the kernel (stage 7 builds it), scratch and one machine's
		runtime state.  Each is named, never a wildcard.

Anything else is a file that exists nowhere but that disk, and while even
one of those remains, deleting it would destroy something.

This is the C4 question asked the right way round.  "Does our build equal
the golden image?" has the answer "no, and it should not" -- we build newer
binaries from the same source and skip the Labs' local state.  The question
that actually gates retirement is the containment one above.
"""

import argparse
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mkcarry
import v8fs

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Reproduced by this build, or state that belongs to whoever ran the machine.
#
# IMPORTED, not restated. This list and mkcarry.py's have to agree exactly --
# one decides what stage 8 puts on the disk and the other decides whether the
# result is complete -- and two copies of a list that must agree is a bug
# waiting for someone to edit one of them. mkcarry.py owns it.
#
# The distinction it draws is per-FILE. Directories under these prefixes are
# a separate question with the opposite answer, and mkcarry.emit_dirs is
# where that is handled: uucp's spool files are one machine's backlog, and
# uucp's spool DIRECTORIES are how uucp is configured.
POLICY = mkcarry.SKIP_PREFIX
# Deliberately NOT importing mkcarry.SKIP_EXACT, which also lists /.profile,
# /etc/skel/.profile and /usr/jerq/bin/wmux. Those are ours and mkcarry skips
# CARRYING them because builddisk.sh installs them from v8/ instead -- so if
# that install ever breaks, this check should say the file is missing rather
# than excuse it. A shared list would have excused it.
POLICY_EXACT = {
    "/unix": "stage 7 builds our own kernel",
    "/etc/utmp": "who was logged in, on their machine",
    "/etc/mtab": "what was mounted, on their machine",
}


def walk(img, parts):
    out = {}
    for part, pfx in parts:
        fs = v8fs.V8FS(img, part)
        for p, ip in fs.walk("/"):
            out[pfx + p] = ip
    return out


def load_manifest():
    """image path -> (disposition, stored path under v8/).

    The stored path is MANIFEST's sixth field, which already carries the
    percent-escaping for the 16 paths the tape distinguishes only by case --
    so this never has to reimplement CASEMAP."""
    m = {}
    for line in open(os.path.join(REPO, "v8", "MANIFEST")):
        if line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) < 6 or f[0] not in ("source", "excluded", "unpacked"):
            continue
        top = f[4].split("/")[0]
        img = "/usr/" + f[4] if top in ("jerq", "blit") else "/" + f[4]
        m[img] = (f[0], f[5])
    return m


def policy(path):
    for pfx, why in POLICY:
        if path.startswith(pfx):
            return why
    return POLICY_EXACT.get(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuhs", default=os.path.join(REPO, "work/myv8/rp06v8.golden"))
    ap.add_argument("--ipnx", default=os.path.join(REPO, "work/myv8/rp07new"))
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    tuhs = walk(args.tuhs, v8fs.wholesystem(args.tuhs))
    # The whole inode, not just the path. This used to be a set() of paths,
    # and a set of paths cannot tell a file from a directory that happens to
    # have the same name -- which is not a hypothetical. A stage-8 bug
    # created /bin/adb, /etc/init and 96 more as empty DIRECTORIES, and this
    # check passed the resulting disk with UNIQUE 0 because every path it
    # looked for was present. The disk could not boot: there was no
    # /etc/init to exec. See mkdep.py's emit_destfiles() for the cause.
    ipnx = walk(args.ipnx, v8fs.wholesystem(args.ipnx))
    man = load_manifest()

    tally = collections.Counter()
    orphan = []
    for path in sorted(tuhs):
        ip = tuhs[path]
        if ip.isdir:
            continue
        # Every path that gets here is a FILE on the tape (dirs skipped
        # above), so ours has to be a file too. A directory of the same name
        # is not the file: it is the shape a failed install leaves behind.
        ours = ipnx.get(path)
        if ours is not None:
            if ours.isdir:
                orphan.append((path, "ours has this as a DIRECTORY, not a file"
                                     " -- a failed install, not a copy"))
            else:
                tally["on ours"] += 1
            continue
        d, stored = man.get(path, (None, None))
        if d in ("source", "unpacked"):
            if os.path.exists(os.path.join(REPO, "v8", stored)):
                tally["in git"] += 1
            else:
                orphan.append((path, "MANIFEST says source, but v8/%s is gone" % stored))
            continue
        why = policy(path)
        if why:
            tally["by policy"] += 1
            continue
        orphan.append((path, "unique to that image (%d bytes)" % ip.size))

    total = sum(tally.values()) + len(orphan)
    print("TUHS image %s" % os.path.relpath(args.tuhs, REPO))
    print("ipnx image %s" % os.path.relpath(args.ipnx, REPO))
    print("")
    for k in ("on ours", "in git", "by policy"):
        print("  %-10s %5d files" % (k, tally[k]))
    print("  %-10s %5d files" % ("UNIQUE", len(orphan)))
    print("  %-10s %5d files" % ("total", total))
    print("")

    if args.verbose:
        for pfx, why in POLICY:
            n = sum(1 for p in tuhs if p.startswith(pfx) and not tuhs[p].isdir)
            if n:
                print("  policy: %-22s %4d files -- %s" % (pfx, n, why))
        for p, why in POLICY_EXACT.items():
            if p in tuhs:
                print("  policy: %-22s %4d file  -- %s" % (p, 1, why))
        print("")

    if orphan:
        print("NOT SAFE TO RETIRE -- %d files exist only on the TUHS image:" % len(orphan))
        for p, why in orphan[:40]:
            print("  %-46s %s" % (p, why))
        if len(orphan) > 40:
            print("  ... and %d more" % (len(orphan) - 40))
        return 1

    print("SAFE TO RETIRE: every file on the TUHS image is on ours, in git,")
    print("or named above as deliberately regenerated.")
    print("Content of the `in git' half is proven by: tools/v8-import.py --verify")
    return 0


if __name__ == "__main__":
    sys.exit(main())
