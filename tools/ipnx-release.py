#!/usr/bin/env python3
"""
Generate the version-carrying files from v8/RELEASE.

    tools/ipnx-release.py            # regenerate
    tools/ipnx-release.py --check    # fail if anything has drifted
    tools/ipnx-release.py --bump patch|minor|major

Two files carry the ipnx version into the built system:

    v8/usr/include/ipnx.h          IPNX_VERSION, the integer ports test
    v8/usr/sys/conf/newvers.sh     the string in the kernel's boot banner

FreeBSD keeps its equivalents (sys/param.h and sys/conf/newvers.sh) in step by
hand, and they occasionally disagree.  Generating both from one file is cheaper
than remembering, and --check makes the disagreement impossible to commit.

Policy -- what the numbers mean and what counts as a release: docs/releases.md
"""

import argparse
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASE = os.path.join(REPO, "v8", "RELEASE")
HDR = os.path.join(REPO, "v8", "usr", "include", "ipnx.h")
NEWVERS = os.path.join(REPO, "v8", "usr", "sys", "conf", "newvers.sh")

ORDINAL = {8: "Eighth", 9: "Ninth", 10: "Tenth"}


def read_release():
    v = {}
    for line in open(RELEASE):
        line = line.split("#", 1)[0].strip()
        if "=" in line:
            k, _, val = line.partition("=")
            v[k.strip()] = val.strip()
    for k in ("EDITION", "MAJOR", "MINOR", "PATCH", "BRANCH", "DATE"):
        if k not in v:
            sys.exit("v8/RELEASE is missing %s" % k)
    for k in ("EDITION", "MAJOR", "MINOR", "PATCH"):
        v[k] = int(v[k])
    return v


def version_int(v):
    """edition*1000000 + major*10000 + minor*100 + patch -- monotonic across
    editions, so Edition 10 Release 1.0.0 (10010000) really does exceed every
    Edition 8 release, and a port can compare with >= and mean it."""
    return v["EDITION"] * 1000000 + v["MAJOR"] * 10000 + v["MINOR"] * 100 + v["PATCH"]


def branch_suffix(v):
    """`-CURRENT' between releases, and NOTHING at a tag.

    "Eighth Edition Release 8.0.0-RELEASE" stutters, and a banner is read far
    more often than it is written. FreeBSD gets away with "13.2-RELEASE"
    because it never says the word Release twice; we do, so the suffix goes.
    """
    return "" if v["BRANCH"] == "RELEASE" else "-" + v["BRANCH"]


def rel_string(v):
    """The release as people say it: `1.0', not `1.0.0'.

    PATCH is dropped when zero, so the first release of an edition reads
    "Release 1.0" and a fix release reads "Release 1.0.1". Three components
    with a trailing zero look like a version number nobody chose.
    """
    if v["PATCH"] == 0:
        return "%d.%d" % (v["MAJOR"], v["MINOR"])
    return "%d.%d.%d" % (v["MAJOR"], v["MINOR"], v["PATCH"])


def render_header(v):
    rel  = rel_string(v)
    full = rel + branch_suffix(v)
    ed   = "Edition %d" % v["EDITION"]
    return """\
/*
 * ipnx.h -- which system this is, for anything that needs to care.
 *
 * Generated from v8/RELEASE by tools/ipnx-release.py.  Do not edit; edit
 * RELEASE and regenerate, or --check will catch you.
 *
 * THE NAME OF THIS SYSTEM IS `ipnx Edition 8 Release 1.0'.  Two numbers, and
 * they belong to different people: the EDITION is Bell Labs' and is not ours
 * to increment, the RELEASE counts what this project has made of it.
 *
 * IPNX_RELSTR is the composed string -- release plus branch suffix, with the
 * suffix present only when the branch is not RELEASE.  Use it rather than
 * gluing IPNX_RELEASE and IPNX_BRANCH together at each call site: two
 * commands did that and both printed `1.0-RELEASE'.
 *
 * IPNX_VERSION is the one number to TEST.  It is
 *
 *      edition * 1000000 + major * 10000 + minor * 100 + patch
 *
 * which is monotonic across editions, so a port that wants a base new enough
 * to have some feature writes
 *
 *      #if IPNX_VERSION >= %d
 *
 * and does not have to know how Edition 8 relates to Edition 10.  This is
 * FreeBSD's __FreeBSD_version idea, and it is here rather than in
 * <sys/param.h> because the tape hardlinks usr/include/sys/param.h and
 * usr/sys/h/param.h into one file, git cannot store a hardlink, and anything
 * added to one copy would quietly rot in the other.
 *
 * Ports depend on the base.  The base never depends on a port.
 */

#define IPNX_EDITION    %d
#define IPNX_MAJOR      %d
#define IPNX_MINOR      %d
#define IPNX_PATCH      %d
#define IPNX_VERSION    %d

#define IPNX_BRANCH     "%s"
#define IPNX_RELDATE    "%s"
#define IPNX_RELEASE    "%s"
#define IPNX_RELSTR     "%s"
#define IPNX_SYSNAME    "%s"
#define IPNX_BANNER     "ipnx %s Release %s (%s)"
""" % (version_int(v), v["EDITION"], v["MAJOR"], v["MINOR"], v["PATCH"],
       version_int(v), v["BRANCH"], v["DATE"], rel, full, ed,
       ed, full, v["DATE"])


def render_newvers(v):
    rel = rel_string(v)
    ed = "Edition %d" % v["EDITION"]
    return """\
#!/bin/sh
# Stamp the kernel's boot banner.
#
# Generated from v8/RELEASE by tools/ipnx-release.py.  Do not edit.
#
# What shipped on the tape was one line -- `date` and nothing else -- which is
# why a Research Unix kernel announces itself as "Unix 8th Edition" followed by
# whatever the clock happened to say, and says nothing whatsoever about what is
# actually in it.  A machine should be able to tell you which build it is
# running, so it now does.
#
# The build date is still stamped, because knowing when a -CURRENT tree was
# compiled matters; for a tagged -RELEASE the release date in RELEASE is the
# one that means anything.

REL="%s"
BRANCH="%s"
EDITION="%s"
RELDATE="%s"
SUFFIX="%s"

echo "char version[] = \\"Unix -- ipnx $EDITION Release $REL$SUFFIX ($RELDATE)\\\\nbuilt `date`\\\\n\\";" > vers.c
""" % (rel, v["BRANCH"], ed, v["DATE"], branch_suffix(v))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--bump", choices=("patch", "minor", "major"))
    args = ap.parse_args()

    v = read_release()

    if args.bump:
        # major and minor reset what is below them; that is the whole point of
        # having three numbers rather than a build counter.
        if args.bump == "major":
            v["MAJOR"] += 1; v["MINOR"] = 0; v["PATCH"] = 0
        elif args.bump == "minor":
            v["MINOR"] += 1; v["PATCH"] = 0
        else:
            v["PATCH"] += 1
        text = open(RELEASE).read()
        for k in ("MAJOR", "MINOR", "PATCH"):
            text = re.sub(r"(?m)^%s=.*$" % k, "%s=%d" % (k, v[k]), text)
        open(RELEASE, "w").write(text)
        print("v8/RELEASE -> %s  (remember the CHANGELOG entry)" % rel_string(v))

    outputs = [(HDR, render_header(v)), (NEWVERS, render_newvers(v))]
    stale = []
    for path, text in outputs:
        old = open(path).read() if os.path.exists(path) else None
        if args.check:
            if old != text:
                stale.append(os.path.relpath(path, REPO))
        elif old != text:
            open(path, "w").write(text)
            if path == NEWVERS:
                os.chmod(path, 0o755)

    if args.check:
        if stale:
            print("stale, re-run tools/ipnx-release.py: " + " ".join(stale))
            return 1
        print("ipnx Edition %d Release %s (%s), IPNX_VERSION %d -- files in step"
              % (v["EDITION"], rel_string(v) + branch_suffix(v),
                 v["DATE"], version_int(v)))
        return 0

    print("ipnx Edition %d Release %s (%s)\nIPNX_VERSION %d"
          % (v["EDITION"], rel_string(v) + branch_suffix(v),
             v["DATE"], version_int(v)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
