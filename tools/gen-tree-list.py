#!/usr/bin/env python3
"""
Write v8/mk/tree.list -- what the guest needs to stage incrementally.

The guest has no rsync, no cmp against a remote, and no reliable clock (its TODR
starts in 1976 until it is set, so mtime comparison is worse than useless -- see
docs/build-from-source.md). What it does have is size, which is cheap on both
sides and changes for essentially every real edit to a source file.

Format, one file per line:

    <size>\t<path>

preceded by a single STAMP line covering the whole tree. The stamp is what turns
"re-run the driver after editing one script" from a 25-minute full copy into a
second: if the guest's stamp matches, nothing has changed and there is nothing
to do.

Not committed -- it is derived from the tree it describes, and it would change
on every source edit, which is exactly the kind of noise git does not need.
"""

import hashlib
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
V8 = os.path.join(REPO, "v8")
OUT = os.path.join(V8, "mk", "tree.list")

# Staged into the guest; mirrors the member list in v8/mk/stage.sh.
ROOTS = ["usr", "mk", "etc", "bin", "jerq", "blit", "proto-dev"]
SKIP = {"tree.list"}          # never describe ourselves


def casemap():
    """stored full path -> true full path, for the 17 escaped names.

    tree.list has to carry both, because the share holds %4Dail and the staged
    tree holds Mail.  Comparing the share's spelling against the guest would
    find nothing there, re-copy the escaped path, and then the rename would move
    it *into* the directory of the same true name -- turning an incremental
    update into quiet corruption.

    Built parents-first, applying earlier mappings to each parent, for the same
    reason the guest renames parents first: once %4Dail is Mail, no path spelled
    the old way is valid.
    """
    maps = []
    path = os.path.join(V8, "CASEMAP")
    if not os.path.exists(path):
        return maps
    for line in open(path):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parent, stored, true = line.split("\t")
        sp = parent
        for s_pre, t_pre in maps:
            if sp == t_pre or sp.startswith(t_pre + "/"):
                sp = s_pre + sp[len(t_pre):]
        maps.append((sp + "/" + stored, parent + "/" + true))
    maps.sort(key=lambda m: -len(m[0]))     # longest prefix wins
    return maps


def true_path(stored, maps):
    for s_pre, t_pre in maps:
        if stored == s_pre or stored.startswith(s_pre + "/"):
            return t_pre + stored[len(s_pre):]
    return stored


def main():
    maps = casemap()
    rows = []
    for root in ROOTS:
        base = os.path.join(V8, root)
        if os.path.isfile(base):
            rows.append((os.path.getsize(base), root))
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            for f in sorted(filenames):
                if f in SKIP:
                    continue
                p = os.path.join(dirpath, f)
                rows.append((os.path.getsize(p), os.path.relpath(p, V8)))
    rows.sort(key=lambda r: r[1])

    body = "".join("%d\t%s\t%s\n" % (sz, path, true_path(path, maps))
                   for sz, path in rows)
    stamp = hashlib.sha256(body.encode()).hexdigest()[:16]

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write("STAMP %s %d\n" % (stamp, len(rows)))
        f.write(body)
    print("v8/mk/tree.list: %d files, stamp %s" % (len(rows), stamp))
    return 0


if __name__ == "__main__":
    sys.exit(main())
