#!/usr/bin/env python3
"""C4: how much of the 1985 image does our from-source build reproduce?

	tools/compare-built.py [--tuhs IMG] [--ipnx IMG] [-v]

For every command `v8/mk/gen/provenance.txt' says we BUILD, compare our
binary against the one Bell Labs shipped, and sort the result into:

  identical	the whole file, byte for byte
  same code	a_text and a_data identical, the rest not -- which in
		practice means the symbol table, and is the expected
		result rather than a near miss
  differs	the code itself differs
  missing	not on one of the two images

"Does the from-source build equal the golden image?" is the wrong question
asked of the whole disk -- see tools/retire-check.py, which asks the one
that actually gates retirement.  Asked of the commands we build, though,
it is a real and sharp question: does our 2026 toolchain, running our
imported source, emit the same VAX code as the 1985 one did?

WHY THE SYMBOL TABLE IS EXPECTED TO DIFFER.  It was measured early in
Track S and written up in docs/build-from-source.md: code generation is
reproducible, the symbol table is not.  ld emits symbols in an order that
depends on hash-bucket traversal, so two links of identical objects agree
on every instruction and disagree on the order of the names.  Comparing
whole files would report that as failure, which is why this splits them.

The a.out layout is usr/include/a.out.h: eight longs of header, then
N_TXTOFF -- 1024 for ZMAGIC, sizeof(struct exec) otherwise -- then a_text
bytes of code and a_data of initialised data.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v8fs

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OMAGIC, NMAGIC, ZMAGIC = 0o407, 0o410, 0o413


def u32(b, o):
    return b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24


def codeof(data):
    """text+data, or None if this is not an a.out we understand."""
    if len(data) < 32:
        return None
    magic = u32(data, 0)
    if magic not in (OMAGIC, NMAGIC, ZMAGIC):
        return None
    text, dat = u32(data, 4), u32(data, 8)
    off = 1024 if magic == ZMAGIC else 32
    if off + text + dat > len(data):
        return None
    return data[off:off + text + dat]


def load(img, parts):
    out = {}
    for part, pfx in parts:
        fs = v8fs.V8FS(img, part)
        for p, ip in fs.walk("/"):
            if ip.isreg:
                out[pfx + p] = (fs, ip)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuhs", default=os.path.join(REPO, "work/myv8/rp06v8.golden"))
    ap.add_argument("--ipnx", default=os.path.join(REPO, "work/myv8/rp07new"))
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    tuhs = load(args.tuhs, v8fs.wholesystem(args.tuhs))
    ours = load(args.ipnx, v8fs.wholesystem(args.ipnx))

    want = []
    for line in open(os.path.join(REPO, "v8/mk/gen/provenance.txt")):
        if line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 3 and f[2] == "build":
            want.append(f[1].rstrip("/") + "/" + f[0])

    ident, samecode, differ, missing, notaout = [], [], [], [], []
    for p in sorted(want):
        a, b = tuhs.get(p), ours.get(p)
        if a is None or b is None:
            missing.append((p, "TUHS" if a is None else "ours"))
            continue
        da = a[0].read(a[1])
        db = b[0].read(b[1])
        if da == db:
            ident.append(p)
            continue
        ca, cb = codeof(da), codeof(db)
        if ca is None or cb is None:
            notaout.append(p)
        elif ca == cb:
            samecode.append(p)
        else:
            differ.append((p, len(ca), len(cb)))

    n = len(want)
    print("commands provenance.txt says we build: %d" % n)
    print("")
    print("  identical (whole file)      %4d   %5.1f%%" % (len(ident), 100.0 * len(ident) / n))
    print("  same code, other symbols    %4d   %5.1f%%" % (len(samecode), 100.0 * len(samecode) / n))
    print("  ---- reproduced             %4d   %5.1f%%"
          % (len(ident) + len(samecode), 100.0 * (len(ident) + len(samecode)) / n))
    print("  code differs                %4d   %5.1f%%" % (len(differ), 100.0 * len(differ) / n))
    print("  not an a.out (scripts)      %4d" % len(notaout))
    print("  missing from an image       %4d" % len(missing))

    if args.verbose:
        if ident:
            print("\nidentical:\n  " + " ".join(os.path.basename(p) for p in ident))
        if differ:
            print("\ncode differs (theirs vs ours, text+data bytes):")
            for p, la, lb in differ[:40]:
                print("  %-28s %7d %7d  %+d" % (p, la, lb, lb - la))
            if len(differ) > 40:
                print("  ... and %d more" % (len(differ) - 40))
        if missing:
            print("\nmissing:")
            for p, where in missing[:30]:
                print("  %-28s not on %s" % (p, where))
    return 0


if __name__ == "__main__":
    sys.exit(main())
