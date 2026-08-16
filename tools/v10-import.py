#!/usr/bin/env python3
"""
Unpack the TUHS Tenth Edition tarballs into a tree V8 can be shown.

    tools/v10-import.py            # write work/v10/ from the tarballs
    tools/v10-import.py --report   # decide everything, write nothing
    tools/v10-import.py --verify   # prove work/v10/ still matches MANIFEST

WHY THIS IS NOT v8-import.py.  V8's tape became `v8/`, a source tree we own
and commit.  V10 does not, and the difference is deliberate
(docs/v10-restoration.md, "Working conventions"): the pristine tarballs stay
pristine and every change of ours is a logged patch, because the patch series
is the publishable artifact -- the thing someone else can apply to their own
copy from TUHS.  A 243 MB tree with our edits stirred in would be worth far
less to the people who have been waiting for this since 2017.

So the tree lives in `work/` (gitignored) and what git keeps is the RECORD:
v10/CASEMAP, which says how the collisions were resolved, and v10/MANIFEST,
which says what every one of the 24,000 files is.  `--verify` turns "our copy
of V10 is intact and complete" into a checkable claim rather than an assertion.

THREE TARBALLS, ONE ROOT.  v10src becomes src/, v10blit becomes blit/ and
r70include becomes include/ under work/v10/, so one netfsd serves the lot and
the guest mounts one share.  blit is V10's /usr/jerq -- the 5620 software,
sam and samterm included -- and include/ is the /usr/include the source
tarball does not carry.

WHAT THE MANIFEST RECORDS, and why it matters more here than it did for V8.
Every file is classified by its first four bytes:

    text     no NUL in the first 8 KB (git's own heuristic)
    exec     VAX a.out 0410/0413 -- a LINKED EXECUTABLE
    object   VAX a.out 0407 -- a compiled object file
    archive  ar(1)
    binary   anything else

That third column is the point.  docs/v10-restoration.md said until 2026-08-16
that V10 "survives as a source-only snapshot ... no binaries", and RESEARCH.md
said the same.  It is not true: the tree carries 483 linked VAX executables,
including cmd/ccom/vax/comp (the C compiler), cmd/as/as (the assembler) and
cmd/lcc/gen2/vax-v9/rcc, plus a complete src/libc/libc.a.  They RUN on V8 --
tools/v10-probe.sh, 9 of 9 -- but that is a separate experiment; what is
settled here is that they exist, in a form anyone can re-derive.

CASE COLLISIONS.  373 paths in v10src differ from another only by case, and
macOS is case-insensitive, so a plain `tar xjf` silently merges them and drops
files -- quietly, with a zero exit status.  Most are build leftovers (`main.O`
beside `main.o`), but two are not: sys/io/Nttyld.c beside sys/io/nttyld.c, in
the kernel, and libc/stdio/ostdio/doprnt.S beside doprnt.s.  Losing either
would be discovered much later and blamed on something else.

The loser of each group is stored with its uppercase letters percent-escaped
(`Nttyld.c` -> `%4Ettyld.c`) and netfsd's CaseMap serves the true name to the
guest, whose filesystem is case-sensitive and does not care.  The winner is
the name with the fewest capitals, ties broken lexicographically, so `arc`
beats `Arc` beats `ARC` -- a rule rather than a judgement, because the same
answer has to come out on a re-import.
"""

import argparse
import hashlib
import os
import struct
import sys
import tarfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARBALLS = [
    # (subdirectory under the served root, tarball, leading components to drop)
    ("src", os.path.join(REPO, "work", "v10src.tar.bz2"), 0),
    ("blit", os.path.join(REPO, "work", "v10blit.tar.bz2"), 1),
    # V10's /usr/include, which is NOT in the source tarball -- Norman
    # Wilson's r70 reconstruction, taken from a 1997 system and, in his own
    # words, "probably is not precisely concordant" with the 1995 tree.  Only
    # one header was actually needed to get B1 moving (libc.h, which cpp.c
    # includes and V8 has no equivalent of), but the whole set belongs here:
    # it is the reference B2 reconciles against, and guessing from the copies
    # scattered through the tree is how you end up with an older one.  The
    # copy in cmd/mk/export/ is exactly this file minus memmove().
    ("include", os.path.join(REPO, "work", "r70include.tar"), 1),
]
# Where each tarball comes from, for the error message when one is absent.
SOURCES = {
    "v10src.tar.bz2": "Research/Dan_Cross_v10/",
    "v10blit.tar.bz2": "Research/Dan_Cross_v10/",
    "r70include.tar": "Research/Norman_v10/",
}
TREE = os.path.join(REPO, "work", "v10")
RECORD = os.path.join(REPO, "v10")

# VAX a.out, little-endian.  0407 is what the assembler emits and the linker
# eats; 0410 and 0413 have been through ld and can be exec'd.
MAGIC = {0o407: "object", 0o410: "exec", 0o413: "exec"}


def classify(head, blob):
    """What kind of file is this?  See the module docstring."""
    if blob.startswith(b"!<arch>\n"):
        return "archive"
    if len(head) >= 2:
        kind = MAGIC.get(struct.unpack("<H", head[:2])[0])
        if kind:
            return kind
    # Git's heuristic, and deliberately more permissive than a printable-ratio
    # test: V8's import learned that one calls a C file with a few control
    # characters in it binary.
    return "text" if b"\0" not in blob[:8192] else "binary"


# --------------------------------------------------------------- case map


def escape(name):
    """Percent-escape the capitals, which is what makes the name unique on a
    case-insensitive filesystem.  Lowercase and punctuation are left alone so
    the result stays recognisable in a directory listing."""
    return "".join(f"%{ord(c):02X}" if c.isupper() else c for c in name)


def resolve_collisions(paths):
    """Decide the stored spelling of every path.

    Returns (stored_of, casemap) where stored_of maps a true path to its
    on-disk path and casemap is the list of (true parent, stored, true) rows.

    Done breadth-first by depth, and that ordering is load-bearing: escaping a
    directory de-collides everything beneath it, so a child's stored path is
    only knowable once its parent's is.  Written out parents-first for the
    same reason -- CaseMap.swift replays the renames in file order.

    EVERY PREFIX GOES IN, not just the file paths, because a collision can be
    between two DIRECTORIES and be invisible in the file list.  vol2/Preface
    and vol2/preface each hold a preface.ms: at the file level those are two
    different parents and nothing collides, so the first cut of this function
    happily wrote both to one path and lost a file.  Only --verify caught it,
    and only afterwards.
    """
    prefixes = set()
    for p in paths:
        parts = p.split("/")
        for i in range(1, len(parts)):
            prefixes.add("/".join(parts[:i]))

    by_depth = {}
    for p in set(paths) | prefixes:
        by_depth.setdefault(p.count("/"), set()).add(p)

    stored_of = {}          # true path -> stored path
    casemap = []
    for depth in sorted(by_depth):
        # group siblings by (parent, lowercased name)
        groups = {}
        for p in sorted(by_depth[depth]):
            parent, _, name = p.rpartition("/")
            groups.setdefault((parent, name.lower()), []).append(name)

        for (parent, _), names in sorted(groups.items()):
            stored_parent = stored_of.get(parent, parent) if parent else ""
            if len(names) == 1:
                keep = names[0]
                stored_of[f"{parent}/{keep}" if parent else keep] = (
                    f"{stored_parent}/{keep}" if stored_parent else keep)
                continue
            # Fewest capitals wins; ties lexicographically.  A rule, not a
            # judgement, so a re-import lands on the same answer.
            winner = sorted(names, key=lambda n: (sum(c.isupper() for c in n), n))[0]
            for name in sorted(names):
                true = f"{parent}/{name}" if parent else name
                spelling = name if name == winner else escape(name)
                if spelling != name:
                    casemap.append((parent or ".", spelling, name))
                stored_of[true] = f"{stored_parent}/{spelling}" if stored_parent else spelling
    return stored_of, casemap


# ------------------------------------------------------------------ main


def member_paths(tarball, strip):
    """Every regular file in the tarball, as a path with `strip` leading
    components removed.  Directories are implied by their contents; the tape
    carries a few empty ones and losing them costs nothing a build notices."""
    out = []
    with tarfile.open(tarball, "r|*") as tf:
        for m in tf:
            if not m.isfile():
                continue
            parts = m.name.split("/")[strip:]
            if parts and parts[0] in ("", "."):
                parts = parts[1:]
            if parts:
                out.append("/".join(parts))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--report", action="store_true", help="decide, write nothing")
    ap.add_argument("--verify", action="store_true", help="check the tree against MANIFEST")
    args = ap.parse_args()

    for _, tarball, _ in TARBALLS:
        if not os.path.exists(tarball):
            name = os.path.basename(tarball)
            sys.exit(f"v10-import: no {tarball}\n"
                     f"  get it from https://www.tuhs.org/Archive/Distributions/"
                     f"{SOURCES.get(name, '')}")

    if args.verify:
        return verify()

    # Pass one: names only, so the collisions can be resolved before anything
    # is written.  Streaming bz2 twice costs ~25 s and is much simpler than
    # buffering 243 MB to decide the layout.
    print("v10-import: reading names", file=sys.stderr)
    true_paths, order = [], []
    for sub, tarball, strip in TARBALLS:
        names = member_paths(tarball, strip)
        order.append((sub, tarball, strip, names))
        true_paths += [f"{sub}/{n}" for n in names]
    print(f"v10-import: {len(true_paths)} files", file=sys.stderr)

    stored_of, casemap = resolve_collisions(true_paths)
    print(f"v10-import: {len(casemap)} case collisions escaped", file=sys.stderr)

    if args.report:
        for parent, spelling, true in casemap:
            print(f"{parent}\t{spelling}\t{true}")
        return

    # Pass two: extract, hash and classify in one go.
    rows = []
    counts = {}
    for sub, tarball, strip, _ in order:
        print(f"v10-import: unpacking {os.path.basename(tarball)}", file=sys.stderr)
        with tarfile.open(tarball, "r|*") as tf:
            for m in tf:
                if not m.isfile():
                    continue
                parts = m.name.split("/")[strip:]
                if parts and parts[0] in ("", "."):
                    parts = parts[1:]
                if not parts:
                    continue
                true = f"{sub}/" + "/".join(parts)
                stored = stored_of[true]
                blob = tf.extractfile(m).read()
                kind = classify(blob[:4], blob)
                counts[kind] = counts.get(kind, 0) + 1

                dest = os.path.join(TREE, stored)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as fh:
                    fh.write(blob)
                # Keep the execute bit: it is how the tree itself says which
                # of the 435 a.out files someone once ran.
                os.chmod(dest, m.mode & 0o777)
                rows.append((kind, f"{m.mode & 0o777:04o}", str(len(blob)),
                             hashlib.sha256(blob).hexdigest(), true, stored))

    os.makedirs(RECORD, exist_ok=True)
    write_casemap(casemap)
    write_manifest(rows)

    # netfsd reads CASEMAP from the root it serves.  A symlink rather than a
    # copy, so the served map and the committed one cannot drift apart.
    link = os.path.join(TREE, "CASEMAP")
    if os.path.islink(link) or os.path.exists(link):
        os.remove(link)
    os.symlink(os.path.relpath(os.path.join(RECORD, "CASEMAP"), TREE), link)

    print(f"v10-import: wrote {len(rows)} files to {TREE}", file=sys.stderr)
    for kind in sorted(counts, key=lambda k: -counts[k]):
        print(f"  {counts[kind]:6d}  {kind}", file=sys.stderr)


def write_casemap(casemap):
    with open(os.path.join(RECORD, "CASEMAP"), "w") as fh:
        fh.write("""\
# Paths the V10 tarballs distinguish only by case, which macOS and git cannot
# both hold.  The loser of each group is stored percent-escaped; netfsd reads
# this file and serves the true name to the guest, whose filesystem is
# case-sensitive (netfs/Sources/NetFS/CaseMap.swift).
#
# Most of these are build leftovers the CSRC machines left behind -- `main.O`
# beside `main.o` -- but two are real source: sys/io/Nttyld.c beside
# sys/io/nttyld.c, in the kernel, and libc/stdio/ostdio/doprnt.S beside
# doprnt.s.  A plain extraction drops one of each, silently and successfully.
#
# The winner is the name with the fewest capitals, ties broken
# lexicographically.  Written parents-first: escaping a directory de-collides
# everything under it, so a child's stored path is only valid once its
# parent's is known.
#
# Generated by tools/v10-import.py -- do not edit.
# directory<TAB>stored-name<TAB>true-name

""")
        for parent, spelling, true in casemap:
            fh.write(f"{parent}\t{spelling}\t{true}\n")


def write_manifest(rows):
    with open(os.path.join(RECORD, "MANIFEST"), "w") as fh:
        fh.write("""\
# Every file in the TUHS V10 tarballs, and what it is.
# Regenerate with tools/v10-import.py; check with tools/v10-import.py --verify
#
# The tree itself lives in work/v10/ and is not committed: the pristine
# tarballs stay pristine and our changes are a logged patch series, so this
# file is the record that our copy is complete and unaltered.
#
# kind is decided by the first four bytes:
#   text     no NUL in the first 8 KB
#   exec     VAX a.out 0410/0413 -- a linked executable
#   object   VAX a.out 0407
#   archive  ar(1)
#   binary   anything else
#
# The `exec` rows are the reason this column exists.  V10 is described
# everywhere, including in this repository's own docs until 2026-08-16, as a
# source-only snapshot with no binaries.  It is not.
#
# fields: kind<TAB>mode<TAB>size<TAB>sha256<TAB>true-path<TAB>stored-path

""")
        for row in sorted(rows, key=lambda r: r[4]):
            fh.write("\t".join(row) + "\n")


def verify():
    """Re-hash the tree and compare with MANIFEST.  Reports missing, extra and
    altered files separately, because they mean different things: missing is a
    broken extraction, altered is an edit that should have been a patch."""
    path = os.path.join(RECORD, "MANIFEST")
    if not os.path.exists(path):
        sys.exit("v10-import: no v10/MANIFEST -- run tools/v10-import.py first")

    want = {}
    with open(path) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            kind, mode, size, digest, true, stored = line.rstrip("\n").split("\t")
            want[stored] = (int(size), digest, true)

    seen, bad, missing = set(), [], []
    for stored, (size, digest, true) in sorted(want.items()):
        full = os.path.join(TREE, stored)
        if not os.path.exists(full):
            missing.append(true)
            continue
        seen.add(stored)
        blob = open(full, "rb").read()
        if len(blob) != size or hashlib.sha256(blob).hexdigest() != digest:
            bad.append(true)

    extra = []
    for root, _, files in os.walk(TREE):
        for name in files:
            rel = os.path.relpath(os.path.join(root, name), TREE)
            if rel != "CASEMAP" and rel not in want:
                extra.append(rel)

    for label, items in (("MISSING", missing), ("ALTERED", bad), ("EXTRA", extra)):
        for item in items[:20]:
            print(f"{label} {item}")
        if len(items) > 20:
            print(f"{label} ... and {len(items) - 20} more")
    ok = not (missing or bad or extra)
    print(f"v10-import: {len(seen)}/{len(want)} files verified"
          f"{'' if ok else ' -- TREE DOES NOT MATCH MANIFEST'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main() or 0)
