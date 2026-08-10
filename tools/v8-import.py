#!/usr/bin/env python3
"""
Import Research Unix 8th Edition into v8/ as ipnx source.

    tools/v8-import.py            # write v8/ from the TUHS tapes
    tools/v8-import.py --report   # decide everything, write nothing
    tools/v8-import.py --verify   # prove v8/ still reproduces the tapes

This runs once to establish v8/ and thereafter only as `--verify`. After the
first commit the tree is *ours*: later divergence from Bell Labs is what git
log is for, so re-importing over local work would be a mistake, and the tool
refuses to unless --force is given.

Three transformations happen on the way in. Each is recorded in MANIFEST so
that "our copy is complete" stays a checkable claim rather than an assertion.

1. CASE COLLISIONS.  The tape names 16 groups of paths that differ only in
   case -- including two whole directories, usr/src/cmd/{Mail,mail} and
   jerq/src/lib/{C,c}.  macOS is case-insensitive, so a plain extraction
   silently merges those directories and drops 15 files; work/v8src has been
   quietly incomplete since the day it was made.  Git cannot check out both
   names either, so the loser of each group is stored with its uppercase
   letters percent-escaped (Mail -> %4Dail) and restored when the tree is
   staged into the guest, whose filesystem is case-sensitive and does not
   care.  Escaping a directory de-collides everything beneath it, which is
   why this is done per level, top down.

2. SOURCE ARCHIVES.  V7-era practice used ar(1) as a source container:
   usr/src/libplot/lib5620/blit.c.a holds 31 .c files, and the makefile does
   `ar x` before compiling.  An opaque blob defeats the purpose of version
   control, so any archive whose members are all text is unpacked -- the
   archive path becomes a directory holding its members.  The makefiles that
   used to unpack them are edited to match; that edit is ours and is a
   separate commit.

3. MACHINE CODE.  a.out executables, object libraries and binary data are not
   imported.  They are still listed in MANIFEST with size and sha256, so the
   exclusion is auditable and nothing is quietly missing -- if a build product
   turns out to have no source, the manifest is where that shows up.
"""

import argparse
import hashlib
import io
import os
import subprocess
import sys
import tarfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TAPES = [
    ("v8", os.path.join(REPO, "work", "v8.tar")),
    ("v8jerq", os.path.join(REPO, "work", "v8jerq.tar")),
]
DEST = os.path.join(REPO, "v8")

# ---------------------------------------------------------------- classify


def is_text(data):
    """Git's own heuristic: a NUL byte means binary, everything else is text.

    Deliberately more permissive than a printable-ratio test, which called
    usr/src/cmd/spline.c binary over a handful of control characters and
    would have dropped a C file from the import.
    """
    return b"\0" not in data[:8192]


def ar_members(data):
    """Parse a System V / BSD ar archive.  Returns [(name, bytes)] or None.

    Written out rather than shelled to ar(1) because we need member *content*
    to decide source-vs-object, and because 1985 archives use 14-byte names
    with no BSD long-name extension to worry about.
    """
    if not data.startswith(b"!<arch>\n"):
        return None
    out, off = [], 8
    while off + 60 <= len(data):
        hdr = data[off : off + 60]
        if hdr[58:60] != b"`\n":
            return None
        name = hdr[0:16].decode("ascii", "replace").strip().rstrip("/")
        try:
            size = int(hdr[48:58].decode("ascii").strip())
        except ValueError:
            return None
        body = data[off + 60 : off + 60 + size]
        if name:
            out.append((name, body))
        off += 60 + size + (size & 1)
    return out


def classify(path, data):
    """-> (disposition, detail).  Disposition drives everything downstream."""
    if not data:
        return "text", None  # empty files are legitimate source
    members = ar_members(data)
    if members is not None:
        if members and all(is_text(b) for _, b in members):
            return "unpack", members
        return "exclude", "object archive (%d members)" % len(members)
    if not is_text(data):
        return "exclude", "binary"
    return "text", None


# ------------------------------------------------------------ case escape


def escape(name):
    """Percent-escape uppercase letters: Mail -> %4Dail, C -> %43."""
    return "".join("%%%02X" % ord(c) if "A" <= c <= "Z" else c for c in name)


class Node:
    __slots__ = ("name", "children", "entry", "order")

    def __init__(self, name, order):
        self.name = name
        self.children = {}
        self.entry = None
        self.order = order


def build_tree(entries):
    """entries: [(path, order, payload)] -> root Node."""
    root = Node("", -1)
    for path, order, payload in entries:
        node = root
        for part in path.split("/"):
            if part not in node.children:
                node.children[part] = Node(part, order)
            node = node.children[part]
        node.entry = payload
    return root


def flatten(node, true_prefix="", stored_prefix="", out=None, collisions=None):
    """Second pass: emit (true_path, stored_path, payload) with case resolved."""
    if out is None:
        out, collisions = [], []
    groups = {}
    for name, child in node.children.items():
        groups.setdefault(name.lower(), []).append(child)
    for _, members in groups.items():
        if len(members) > 1:
            members.sort(key=lambda c: c.order)
            lower = [c for c in members if not any(x.isupper() for x in c.name)]
            canon = lower[0] if len(lower) == 1 else members[0]
        else:
            canon = members[0]
        for child in members:
            stored_name = child.name if child is canon else escape(child.name)
            tp = (true_prefix + "/" + child.name).lstrip("/")
            sp = (stored_prefix + "/" + stored_name).lstrip("/")
            if child is not canon:
                collisions.append((tp, sp, canon.name))
            if child.entry is not None:
                out.append((tp, sp, child.entry))
            if child.children:
                flatten(child, tp, sp, out, collisions)
    return out, collisions


# ------------------------------------------------------------------- main


def read_tapes():
    """-> [(path, order, (mode, mtime, data, tape))], plus dirs seen."""
    entries, dirs, order = [], set(), 0
    for tape, path in TAPES:
        if not os.path.exists(path):
            sys.exit("missing tape: %s\n(see docs/spike-a0.md for provenance)" % path)
        with tarfile.open(path) as tf:
            for m in tf:
                order += 1
                name = m.name[2:] if m.name.startswith("./") else m.name
                name = name.rstrip("/")
                if not name:
                    continue
                if m.isdir():
                    dirs.add(name)
                elif m.isfile():
                    data = tf.extractfile(m).read()
                    entries.append((name, order, (m.mode, m.mtime, data, tape)))
                elif m.islnk():
                    entries.append((name, order, ("link", m.linkname, None, tape)))
                elif m.issym():
                    entries.append((name, order, ("sym", m.linkname, None, tape)))
    return entries, dirs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true", help="decide, write nothing")
    ap.add_argument("--verify", action="store_true", help="check v8/ against the tapes")
    ap.add_argument("--force", action="store_true",
                    help="overwrite an existing v8/ -- DESTROYS local work, see below")
    ap.add_argument("--meta", action="store_true",
                    help="rewrite only MANIFEST/CASEMAP/EMPTYDIRS, never the source")
    args = ap.parse_args()

    entries, dirs = read_tapes()
    # resolve hardlinks to their target's content before anything else
    by_path = {p: e for p, _, e in entries}
    resolved = []
    for path, order, e in entries:
        if e[0] == "link":
            tgt = by_path.get(e[1])
            if tgt is None or tgt[0] == "link":
                sys.exit("unresolved hard link: %s -> %s" % (path, e[1]))
            e = (tgt[0], tgt[1], tgt[2], e[3])
        resolved.append((path, order, e))

    root = build_tree(resolved)
    flat, collisions = flatten(root)

    # The escape is only worth anything if it actually de-collides.  Check it
    # the way the filesystem will: case-folded.
    seen = {}
    for true_path, stored_path, _ in flat:
        key = stored_path.lower()
        if key in seen:
            sys.exit("escape failed to de-collide: %s and %s both store as %s"
                     % (seen[key], true_path, stored_path))
        seen[key] = true_path

    kept, unpacked, excluded = [], [], []
    for true_path, stored_path, (mode, mtime, data, tape) in flat:
        if mode == "sym":
            excluded.append((true_path, stored_path, 0, "", "symlink -> %s" % mtime))
            continue
        disp, detail = classify(true_path, data)
        sha = hashlib.sha256(data).hexdigest()
        if disp == "text":
            kept.append((true_path, stored_path, mode, mtime, data, sha))
        elif disp == "unpack":
            unpacked.append((true_path, stored_path, mode, mtime, data, sha, detail))
        else:
            excluded.append((true_path, stored_path, len(data), sha, detail))

    n_unpacked_members = sum(len(d[6]) for d in unpacked)
    print("tape files      : %d" % len(flat))
    print("  kept as source: %d  (%.1f MB)" % (len(kept), sum(len(k[4]) for k in kept) / 1e6))
    print("  unpacked ar   : %d archives -> %d member files" % (len(unpacked), n_unpacked_members))
    print("  excluded      : %d  (%.1f MB of machine code and binary data)"
          % (len(excluded), sum(e[2] for e in excluded) / 1e6))
    print("case collisions : %d paths escaped" % len(collisions))

    if args.report:
        print("\n--- case collisions ---")
        for tp, sp, canon in sorted(collisions):
            print("  %-46s stored as  %s   (canonical sibling: %s)" % (tp, sp, canon))
        print("\n--- source archives to unpack ---")
        for u in sorted(unpacked, key=lambda x: -len(x[6])):
            print("  %-52s %3d members" % (u[0], len(u[6])))
        print("\n--- excluded, by directory ---")
        agg = {}
        for tp, _, size, _, why in excluded:
            d = "/".join(tp.split("/")[:2])
            a = agg.setdefault(d, [0, 0])
            a[0] += 1
            a[1] += size
        for d in sorted(agg, key=lambda k: -agg[k][1]):
            print("  %-24s %4d files  %7.2f MB" % (d, agg[d][0], agg[d][1] / 1e6))
        return 0

    if args.verify:
        return verify(kept, unpacked, excluded, collisions)

    if os.path.exists(DEST) and not args.force and not args.meta:
        sys.exit("%s already exists -- it is ours now, not a checkout.\n"
                 "  --verify  check it against the tapes\n"
                 "  --meta    regenerate MANIFEST/CASEMAP/EMPTYDIRS only\n"
                 "  --force   re-import, DESTROYING every edit made since\n"
                 % DEST)

    # --force really does mean it: it once silently reverted nine committed
    # makefile fixes.  Refuse unless git says there is nothing to lose.
    if args.force and os.path.isdir(os.path.join(REPO, ".git")):
        st = subprocess.run(["git", "-C", REPO, "status", "--porcelain", "v8"],
                            capture_output=True, text=True).stdout.strip()
        if st:
            sys.exit("refusing --force: v8/ has uncommitted changes that would be lost:\n"
                     + st + "\ncommit or stash them first.")

    write(kept, unpacked, excluded, collisions, dirs, meta_only=args.meta)
    return 0


def write(kept, unpacked, excluded, collisions, dirs, meta_only=False):
    def put(rel, data, mode):
        p = os.path.join(DEST, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
        os.chmod(p, 0o755 if mode & 0o111 else 0o644)

    if not meta_only:
        for _, sp, mode, _, data, _ in kept:
            put(sp, data, mode)
        for _, sp, mode, _, _, _, members in unpacked:
            for name, body in members:
                put(os.path.join(sp, name), body, 0o644)

    lines = ["# Every file on the TUHS V8 tapes, and what we did with it.",
             "# Regenerate/check with: tools/v8-import.py --verify",
             "# fields: disposition<TAB>mode<TAB>size<TAB>sha256<TAB>tape-path<TAB>stored-path",
             ""]
    for tp, sp, mode, _, data, sha in sorted(kept):
        lines.append("source\t%04o\t%d\t%s\t%s\t%s" % (mode, len(data), sha, tp, sp))
    for tp, sp, mode, _, data, sha, members in sorted(unpacked, key=lambda x: x[0]):
        lines.append("unpacked\t%04o\t%d\t%s\t%s\t%s/" % (mode, len(data), sha, tp, sp))
        for name, body in members:
            lines.append("  member\t0644\t%d\t%s\t%s\t%s"
                         % (len(body), hashlib.sha256(body).hexdigest(), name, sp + "/" + name))
    for tp, _, size, sha, why in sorted(excluded):
        lines.append("excluded\t----\t%d\t%s\t%s\t(%s)" % (size, sha, tp, why))
    with open(os.path.join(DEST, "MANIFEST"), "w") as f:
        f.write("\n".join(lines) + "\n")

    cm = ["# Paths the V8 tape distinguishes only by case, which macOS and git",
          "# cannot both hold.  The loser of each group is stored percent-escaped;",
          "# v8/mk/stage.sh restores the true name in the guest, whose filesystem",
          "# is case-sensitive.  Escaping a directory de-collides everything under it.",
          "#",
          "# Written as (directory, stored name, true name) rather than as two full",
          "# paths, because the renames happen parents-first and a child's stored path",
          "# stops being valid the moment its parent is renamed -- and because V8 has",
          "# no dirname(1) to take the prefix apart with.",
          "#",
          "# directory<TAB>stored-name<TAB>true-name",
          ""]
    for tp, sp, _ in sorted(collisions):
        parent = tp.rsplit("/", 1)[0] if "/" in tp else "."
        cm.append("%s\t%s\t%s" % (parent, sp.rsplit("/", 1)[-1], tp.rsplit("/", 1)[-1]))
    with open(os.path.join(DEST, "CASEMAP"), "w") as f:
        f.write("\n".join(cm) + "\n")

    empty = sorted(d for d in dirs
                   if not any(k[0] == d or k[0].startswith(d + "/") for k in kept))
    with open(os.path.join(DEST, "EMPTYDIRS"), "w") as f:
        f.write("# Directories the tape carries with no surviving source under them.\n"
                "# git cannot store an empty directory; stage.sh recreates these.\n\n")
        f.write("\n".join(empty) + ("\n" if empty else ""))
    print("\nwrote %s (%d source files, %d manifest lines, %d empty dirs)"
          % (DEST, len(kept) + sum(len(u[6]) for u in unpacked), len(lines), len(empty)))


def verify(kept, unpacked, excluded, collisions):
    """Prove the working tree still reproduces every byte the tape carries."""
    bad = 0
    for tp, sp, mode, _, data, sha in kept:
        p = os.path.join(DEST, sp)
        if not os.path.exists(p):
            print("MISSING  %s" % sp)
            bad += 1
            continue
        got = hashlib.sha256(open(p, "rb").read()).hexdigest()
        if got != sha:
            print("CHANGED  %s   (ours, not the tape's -- expected once we start editing)" % sp)
            bad += 1
    for tp, sp, mode, _, _, _, members in unpacked:
        for name, body in members:
            p = os.path.join(DEST, sp, name)
            if not os.path.exists(p):
                print("MISSING  %s/%s" % (sp, name))
                bad += 1
                continue
            got = hashlib.sha256(open(p, "rb").read()).hexdigest()
            if got != hashlib.sha256(body).hexdigest():
                print("CHANGED  %s/%s" % (sp, name))
                bad += 1
    n = len(kept) + sum(len(u[6]) for u in unpacked)
    if bad == 0:
        print("\nOK  %d files identical to the TUHS tapes; %d excluded by policy." % (n, len(excluded)))
    else:
        print("\n%d of %d files differ from the tape." % (bad, n))
        print("That is not automatically wrong -- this tree is ours now. Check git log.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
