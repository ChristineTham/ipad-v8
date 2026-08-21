#!/usr/bin/env python3
"""Read a SIMH IL debug trace and say WHERE THE TIME GOES.

	tools/il-gaps.py work/il.trace              the summary
	tools/il-gaps.py work/il.trace --frames     every frame, decoded
	tools/il-gaps.py work/il.trace --top 20     the twenty longest gaps

Task #13 is "netfs costs 9.46 s per request in the guest and 0.84 ms in the
server", with the server, the wire, dropped frames and queue loss all excluded by
measurement.  What is left is a question a packet trace can answer and inference
cannot: BETWEEN WHICH TWO FRAMES does the time actually go?

	host->guest is `il-read'   (il_deliver, pdp11_il.c)
	guest->host is `il-write'  (the transmit path)

So a gap that falls after the last il-read of a reply and before the next
il-write is the guest thinking; a gap between two il-reads is our reply being
held up; and the same (seq, len) seen twice is a retransmission, which is the one
hypothesis no counter can report -- `show il statistics' counts frames, and a
retransmitted frame is a perfectly good frame.

THE TRACE IS GUARDED, NOT TRUSTED.  Both of scp.c's defaults are wrong for this
question and neither is visible from the simulator's behaviour:

  * a bare `set debug <file>' timestamps NOTHING (sim_console.c:2358 forces -T
    only inside `if (sim_deb_switches & SWMASK ('R'))'), and
  * without -F, _sim_debug_write_flush() collapses consecutive identical lines
    into "same as above (N times)" -- so the default instrument DELETES
    retransmissions, which is precisely what it was pointed at.

There is a third elision inside the dump itself: eth_packet_trace_ex() writes
"%04X thru %04X same as above" for a 16-byte group it judges identical to the
one before -- on the strength of `eth_mac_cmp', which compares SIX bytes.  A hex
dump from it is therefore not a faithful record of the frame.  Any of the three
makes this tool refuse rather than interpolate: a frame we cannot reconstruct is
not a frame we may guess at.
"""

import re
import sys

PREFIX = re.compile(
    r"^DBG\((?P<t>\d\d:\d\d:\d\d\.\d\d\d) +\d+\)\+?> +IL +(?P<verb>[A-Z]+): ?(?P<rest>.*)$")
HEAD = re.compile(r"^il-(?P<dir>read|write)\b.*\blen: (?P<len>\d+)")
HEX = re.compile(r"^(?P<off>[0-9A-F]{4})(?P<bytes>(?: [0-9A-F]{2})+)")
# TWO ELISIONS, AND THEY ARE NOT THE SAME FAULT.
#   scp.c's _sim_debug_write_flush() writes "same as above (N times)" and drops
#   WHOLE LINES -- so a retransmitted frame disappears entirely.  Fatal: the
#   analysis it removes is the one being asked for.  Suppressed by -F.
#   eth_packet_trace_ex() writes "%04X thru %04X same as above" INSIDE one
#   frame's hex dump, on a six-byte comparison that elides sixteen bytes.  That
#   spoils one frame -- and since the elision can start at offset 0x30, which is
#   where the TCP window field lives, it can spoil the header too.  Not fatal:
#   quarantine that frame and keep the rest, but SAY SO, because a missing frame
#   is a missed duplicate and that error runs in the flattering direction.
FILTERED = re.compile(r"same as above \(\d+ time")
INTRA = re.compile(r"^[0-9A-F]{4} thru [0-9A-F]{4} same as above")


def hhmmss(s):
    h, m, rest = s.split(":")
    sec, ms = rest.split(".")
    return int(h) * 3600 + int(m) * 60 + int(sec) + int(ms) / 1000.0


class Frame:
    __slots__ = ("t", "dir", "wirelen", "data", "bad", "tcp")

    def __init__(self, t, dr, wirelen):
        self.t, self.dir, self.wirelen = t, dr, wirelen
        self.data = bytearray()
        self.bad = None
        self.tcp = None

    def add(self, off, bs):
        if off != len(self.data):          # a hole means a group was elided
            self.bad = "hex dump not contiguous at 0x%04X" % off
            return
        self.data.extend(bs)

    def decode(self):
        """Ethernet -> IP -> TCP.  Sets .tcp or leaves it None with a reason."""
        d = self.data
        if self.bad:
            return
        if len(d) < 14:
            self.bad = "short frame"
            return
        if int.from_bytes(d[12:14], "big") != 0x0800:
            self.bad = "not IPv4"
            return
        if len(d) < 34:
            self.bad = "truncated IP header"
            return
        ihl = (d[14] & 0x0F) * 4
        if ihl < 20:
            self.bad = "bad IHL"
            return
        iplen = int.from_bytes(d[16:18], "big")
        if d[23] != 6:
            self.bad = "not TCP (proto %d)" % d[23]
            return
        o = 14 + ihl
        if len(d) < o + 20:
            self.bad = "truncated TCP header"
            return
        doff = (d[o + 12] >> 4) * 4
        if doff < 20:
            self.bad = "bad TCP data offset"
            return
        paylen = iplen - ihl - doff
        if paylen < 0:
            self.bad = "negative payload"
            return
        self.tcp = {
            "sport": int.from_bytes(d[o:o + 2], "big"),
            "dport": int.from_bytes(d[o + 2:o + 4], "big"),
            "seq": int.from_bytes(d[o + 4:o + 8], "big"),
            "ack": int.from_bytes(d[o + 8:o + 12], "big"),
            "flags": d[o + 13],
            "win": int.from_bytes(d[o + 14:o + 16], "big"),
            "paylen": paylen,
        }

    def flagstr(self):
        if not self.tcp:
            return "-"
        f = self.tcp["flags"]
        return "".join(n for b, n in ((0x01, "F"), (0x02, "S"), (0x04, "R"),
                                      (0x08, "P"), (0x10, "A"), (0x20, "U"))
                       if f & b) or "."


def parse(path):
    frames, cur = [], None
    seen_prefix = untimed = 0
    elisions = []      # fatal: scp.c dropped whole lines
    intra = []         # quarantine: one frame's dump is not faithful
    for lineno, raw in enumerate(open(path, errors="replace"), 1):
        line = raw.rstrip("\r\n")
        if line.startswith("DBG("):
            seen_prefix += 1
        m = PREFIX.match(line)
        if not m:
            # A DBG line we cannot read the time off is the -t fault; anything
            # else (SIMH's own banners) is not our business.
            if line.startswith("DBG("):
                untimed += 1
            if FILTERED.search(line):
                elisions.append((lineno, line[:90]))
            continue
        t, verb, rest = hhmmss(m["t"]), m["verb"], m["rest"]
        if FILTERED.search(rest):
            elisions.append((lineno, rest[:90]))
            continue
        if INTRA.match(rest):
            intra.append((lineno, rest[:90]))
            if cur:
                cur.bad = "an elided 16-byte group at line %d" % lineno
            continue
        h = HEAD.match(rest)
        if h:
            if cur:
                cur.decode()
                frames.append(cur)
            cur = Frame(t, h["dir"], int(h["len"]))
            continue
        hx = HEX.match(rest)
        if hx and cur is not None:
            cur.add(int(hx["off"], 16),
                    bytes(int(b, 16) for b in hx["bytes"].split()))
    if cur:
        cur.decode()
        frames.append(cur)
    return frames, seen_prefix, untimed, elisions, intra


def unwrap(frames):
    """Midnight rollover: a trace may cross it, and time must not go backwards."""
    add = 0.0
    prev = None
    for f in frames:
        if prev is not None and f.t + add < prev - 1.0:
            add += 86400.0
        f.t += add
        prev = f.t


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path = argv[1]
    want_frames = "--frames" in argv
    top = 12
    if "--top" in argv:
        top = int(argv[argv.index("--top") + 1])

    frames, seen, untimed, elisions, intra = parse(path)

    print("== the instrument, before its readings ==")
    print("   trace                 %s" % path)
    print("   DBG lines             %d" % seen)
    print("   frames                %d" % len(frames))
    if seen and untimed:
        print()
        print("   REFUSING: %d DBG lines carry no hh:mm:ss.mmm timestamp." % untimed)
        print("   `set debug <file>' does not timestamp; it must be `set debug -tf <file>'.")
        return 3
    if elisions:
        print()
        print("   REFUSING: %d line(s) collapsed by scp.c's duplicate filter." % len(elisions))
        for ln, txt in elisions[:5]:
            print("      %d: %s" % (ln, txt))
        print("   That filter deletes WHOLE LINES, so a retransmitted frame --")
        print("   the thing this trace is for -- is gone.  Use `set debug -tf'.")
        return 3
    if not frames:
        print()
        print("   REFUSING: no frames.  Was `set il debug=PKT;DAT' accepted?")
        return 3

    if intra:
        print("   frames QUARANTINED    %d, by eth_packet_trace_ex's own elision" % len(intra))
        print("      it writes \"NNNN thru NNNN same as above\" for a 16-byte group it")
        print("      judges identical on a SIX-byte compare, so the dump is not the")
        print("      frame.  Those frames are dropped, not guessed at -- which means")
        print("      a duplicate among them is MISSED, an error in the flattering")
        print("      direction.  Read the retransmission count as a LOWER BOUND.")
    bad = [f for f in frames if f.tcp is None]
    tcp = [f for f in frames if f.tcp is not None]
    print("   decoded as TCP        %d" % len(tcp))
    if bad:
        from collections import Counter
        for reason, n in Counter(f.bad or "?" for f in bad).most_common():
            print("   not TCP/undecoded     %-30s %d" % (reason, n))
    unwrap(frames)
    span = frames[-1].t - frames[0].t
    print("   span                  %.3f s" % span)
    nr = sum(1 for f in frames if f.dir == "read")
    nw = len(frames) - nr
    print("   il-read  (host->guest) %d" % nr)
    print("   il-write (guest->host) %d" % nw)

    if want_frames:
        print()
        print("== every frame ==")
        t0 = frames[0].t
        for i, f in enumerate(frames):
            gap = 0.0 if i == 0 else f.t - frames[i - 1].t
            t = f.tcp or {}
            print("   %8.3f  +%7.3f  %-9s %-5s seq=%-11u ack=%-11u len=%-5s win=%-6s"
                  % (f.t - t0, gap,
                     "host->gst" if f.dir == "read" else "gst->host",
                     f.flagstr(), t.get("seq", 0), t.get("ack", 0),
                     t.get("paylen", "-"), t.get("win", "-")))

    # ---------------- where the time goes -------------------------------
    gaps = [(frames[i].t - frames[i - 1].t, i) for i in range(1, len(frames))]
    gaps.sort(reverse=True)
    print()
    print("== the %d longest gaps, and WHICH SIDE each one is on ==" % top)
    print("   a gap after the last host->guest frame of a reply and before the")
    print("   next guest->host frame is the GUEST; one between two host->guest")
    print("   frames is OUR REPLY being held up.")
    print()
    tot = sum(g for g, _ in gaps)
    onguest = sum(g for g, i in gaps
                  if frames[i - 1].dir == "read" and frames[i].dir == "write")
    onhost = sum(g for g, i in gaps
                 if frames[i - 1].dir == "read" and frames[i].dir == "read")
    guestself = sum(g for g, i in gaps
                    if frames[i - 1].dir == "write" and frames[i].dir == "write")
    hostwait = sum(g for g, i in gaps
                   if frames[i - 1].dir == "write" and frames[i].dir == "read")
    for g, i in gaps[:top]:
        a, b = frames[i - 1], frames[i]
        print("   %8.3f s   %s -> %s   (seq %u len %s  ->  seq %u len %s, win %s)"
              % (g,
                 "host->gst" if a.dir == "read" else "gst->host",
                 "host->gst" if b.dir == "read" else "gst->host",
                 (a.tcp or {}).get("seq", 0), (a.tcp or {}).get("paylen", "-"),
                 (b.tcp or {}).get("seq", 0), (b.tcp or {}).get("paylen", "-"),
                 (b.tcp or {}).get("win", "-")))
    print()
    print("== the whole span, apportioned by which pair of directions bounds it ==")
    for label, v in (("host->guest then guest->host  (the GUEST thinking)", onguest),
                     ("host->guest then host->guest  (our reply held up)", onhost),
                     ("guest->host then guest->host  (the guest talking)", guestself),
                     ("guest->host then host->guest  (us answering)", hostwait)):
        print("   %-52s %9.3f s  %5.1f%%"
              % (label, v, 100.0 * v / tot if tot else 0.0))

    # ---------------- retransmission ------------------------------------
    print()
    print("== retransmission: the same (direction, seq, length) carrying data twice ==")
    from collections import defaultdict
    key = defaultdict(list)
    for f in tcp:
        if f.tcp["paylen"] > 0:
            key[(f.dir, f.tcp["seq"], f.tcp["paylen"])].append(f.t)
    dups = {k: v for k, v in key.items() if len(v) > 1}
    ndup = sum(len(v) - 1 for v in dups.values())
    print("   data-carrying frames  %d" % sum(1 for f in tcp if f.tcp["paylen"] > 0))
    print("   distinct (seq,len)    %d" % len(key))
    print("   RETRANSMISSIONS       %d" % ndup)
    if dups:
        print()
        for (dr, seq, ln), ts in sorted(dups.items(), key=lambda kv: kv[1][0])[:top]:
            deltas = " ".join("+%.3f" % (b - a) for a, b in zip(ts, ts[1:]))
            print("      %-9s seq=%-11u len=%-5d x%d   %s"
                  % ("host->gst" if dr == "read" else "gst->host", seq, ln, len(ts), deltas))

    # ---------------- zero windows --------------------------------------
    zw = [f for f in tcp if f.dir == "write" and f.tcp["win"] == 0]
    print()
    print("== the guest's advertised receive window ==")
    wins = sorted(f.tcp["win"] for f in tcp if f.dir == "write")
    if wins:
        print("   min %d   median %d   max %d   (zero-window frames: %d)"
              % (wins[0], wins[len(wins) // 2], wins[-1], len(zw)))
        print("   tcp_output.c sets win=0 whenever sbrcvspace < hiwat/4, and")
        print("   tcpdrinit's hiwat is 2048 -- so a 4096-byte reply cannot be")
        print("   sent without at least one window update in the middle.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
