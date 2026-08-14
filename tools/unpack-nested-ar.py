#!/usr/bin/env python3
"""Unpack an ar archive whose member sizes cannot be trusted.

	tools/unpack-nested-ar.py ARCHIVE [--apply]

WHY THIS IS NOT tools/v8-import.py's PARSER.  That one walks the archive by
adding each member's declared size to the offset, which is correct and is what
usr/include/ar.h describes -- a 16-byte name, then date/uid/gid/mode, a
10-byte decimal size, and the two-byte "`\\n" terminator.  It is also how the
last container in the tree defeated it:

    v8/usr/src/cmd/pic/pictest.a/pt.jap

Its first member, `j.a', declares 132 bytes, and the next header does not
start 132 bytes later -- it starts 144 bytes later, with ` rad 60\\n.PE\\n'
(the tail of a pic picture) sitting where the parser expected a header.  So
ar_members() hits a bad terminator, returns None, and the importer files the
whole thing away as an opaque blob.  That is why one source container
survived the rule that there should be none: it was not skipped on purpose,
it simply could not be read.

WHAT THIS DOES INSTEAD.  It finds member boundaries by SCANNING for headers
rather than by trusting sizes: every offset whose 60-byte window has the
"`\\n" terminator, a printable name and a numeric size is a header, and a
member's content is the bytes from the end of its header to the start of the
next one.  That is lossless -- every byte of the archive lands in exactly one
member -- and it does not need the size field to be right, only present.

The declared size is still read, and reported when it disagrees, because a
mismatch is evidence about the artefact and should not be swallowed.
"""

import argparse
import os
import re
import shutil
import sys

MAGIC = b"!<arch>\n"
HDR = 60
FMAG = b"`\n"
NAME_OK = re.compile(rb"^[A-Za-z0-9_.\-+/]+$")


def headers(data):
    """Offsets of every plausible member header, in order."""
    out = []
    for off in range(len(MAGIC), len(data) - HDR + 1):
        h = data[off:off + HDR]
        if h[58:60] != FMAG:
            continue
        name = h[0:16].strip()
        if not name or not NAME_OK.match(name):
            continue
        size = h[48:58].strip()
        if not size.isdigit():
            continue
        # The mode field is octal and always present in a real header; a
        # coincidental "`\n" inside member text almost never has one.
        if not h[40:48].strip().isdigit():
            continue
        out.append(off)
    return out


def members(data):
    """[(name, declared_size, content)] with content taken between headers."""
    offs = headers(data)
    out = []
    for i, off in enumerate(offs):
        h = data[off:off + HDR]
        name = h[0:16].strip().decode("ascii", "replace")
        declared = int(h[48:58].strip())
        start = off + HDR
        end = offs[i + 1] if i + 1 < len(offs) else len(data)
        body = data[start:end]

        # Two different reasons the span between headers can exceed the
        # declared size, and they need opposite treatment.
        #
        # ar pads an odd-sized member to an even boundary, so a member that
        # declares 79 occupies 80. That extra byte is padding and must be
        # dropped or every odd-numbered file grows a spurious tail. 51 of the
        # 54 members here are exactly this case.
        #
        # `j.a' is not: it declares 132 and the next header is 144 bytes
        # later. The twelve bytes are " rad 60\n.PE\n" -- the end of a pic
        # picture -- so the SIZE is wrong, not the span, and truncating to the
        # declared length would cut a drawing in half. Keep the span.
        pad = 0
        if declared % 2 == 1 and len(body) == declared + 1:
            body = body[:declared]
            pad = 1
        out.append((name, declared, body, pad))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("archive")
    ap.add_argument("--apply", action="store_true",
                    help="replace the file with a directory of its members")
    args = ap.parse_args()

    data = open(args.archive, "rb").read()
    if not data.startswith(MAGIC):
        sys.exit("not an ar archive: %s" % args.archive)

    ms = members(data)
    print("%s: %d bytes, %d members" % (args.archive, len(data), len(ms)))
    total = pads = 0
    for name, declared, body, pad in ms:
        pads += pad
        flag = "" if declared == len(body) else "   <- declared %d" % declared
        print("  %-18s %7d bytes%s" % (name, len(body), flag))
        total += len(body)
    accounted = total + HDR * len(ms) + len(MAGIC) + pads
    print("  %d in members + %d headers + %d magic + %d pad = %d of %d"
          % (total, HDR * len(ms), len(MAGIC), pads, accounted, len(data)))
    if accounted != len(data):
        print("  NOTE: does not account for every byte — not unpacking")
        return 1

    if not args.apply:
        print("\n  (dry run; pass --apply to replace it with a directory)")
        return 0

    dest = args.archive
    tmp = dest + ".unpacking"
    os.makedirs(tmp, exist_ok=True)
    for name, _declared, body, _pad in ms:
        # 14-byte filenames are a guest constraint, not a host one, and these
        # names are already short; keep them exactly as the archive has them.
        with open(os.path.join(tmp, name), "wb") as f:
            f.write(body)
    os.remove(dest)
    shutil.move(tmp, dest)
    print("\n  unpacked into %s/ (%d files)" % (dest, len(ms)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
