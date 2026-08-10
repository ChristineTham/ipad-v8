#!/usr/bin/env python3
"""
Time a stretch of a V8 console log between two markers.

    tools/netfs-timing.py LOG START-MARKER STOP-MARKER BYTES

Prints "<seconds> <KB/s>", or "?" if both timestamps could not be found.

Separate from the shell driver on purpose. macOS ships bash 3.2, which has no
`mapfile`, and the obvious alternative -- count the `date` lines -- is wrong
anyway: V8 prints its own date at boot, so the Nth date line is not the Nth
measurement. Anchoring on the markers is the only thing that stays correct when
the guest decides to say something extra.

V8's clock has one-second resolution and no shell can reach anything finer, so
the measured stretch has to be long enough that whole seconds are a usable
ruler. Megabytes, not kilobytes.
"""
import re
import sys

STAMP = re.compile(r"^[A-Z][a-z]{2} [A-Z][a-z]{2} +\d+ (\d{2}):(\d{2}):(\d{2})")


def main():
    if len(sys.argv) != 5:
        print("?")
        return 1
    log, start, stop, nbytes = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    try:
        text = open(log, errors="replace").read()
    except OSError:
        print("?")
        return 1

    t0 = t1 = last = None
    for line in text.replace("\r", "").split("\n"):
        m = STAMP.match(line)
        if m:
            secs = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
            last = secs
            if t0 is not None and t1 is None:
                t1 = secs                       # first date after the stop marker
        if start in line and t0 is None:
            t0 = last                           # last date before the start marker
        if stop in line and t0 is not None and t1 is None:
            t1 = None                           # arm: take the next date we see

    if t0 is None or t1 is None:
        print("?")
        return 1

    elapsed = t1 - t0
    if elapsed < 0:
        elapsed += 86400                        # across midnight
    if elapsed == 0:
        elapsed = 1                             # one-second resolution
    kbs = nbytes / elapsed / 1024
    print("%d %.1f" % (elapsed, kbs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
