#!/usr/bin/env python3
"""restore-attach-probe.py -- one failed re-attach silently unmounts the disk.

`restore` re-attaches every unit that was attached at save time, in device
order, to the filename recorded in the snapshot. For a mux that filename is a
*port*, and tmxr binds without SO_REUSEADDR -- so the port the previous
incarnation was using is still held in TIME_WAIT by the connection that was
live a moment ago, and the bind fails.

That would be survivable on its own. What is not is scp.c's attach loop:

    for (j = 0; j < attcnt; j++) {
        if ((r == SCPE_OK) && (!dont_detach_attach)) {
            ...
            r = scp_attach_unit (dptr, attunits[j], attnames[j]);

`r` is never reset, so the FIRST failure skips every remaining attach -- and
the DZ precedes RP0 in device order. The machine resumes with no disk. The
console still answers, because the kernel is in memory; everything that
touches the filesystem does not.

This makes that deterministic rather than lucky: it holds the saved DZ port
bound so the re-attach cannot succeed, restores, and asks the machine what it
thinks is attached. Then it does the same with `restore -D` -- which neither
detaches nor re-attaches -- and the disk attached by hand beforehand.

    tools/restore-attach-probe.py

Needs the snapshot restore-mute-probe.py leaves behind (work/myv8/mutep.sav
and mutep.disk). One-shot: hard watchdog, simulator killed on every exit path.
"""
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "libsimh/build/macos/vax780cli")
RUNDIR = os.path.join(ROOT, "work/myv8")
DISK = "mutep.disk"
SAV = "mutep.sav"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
_ip = import_module("idle-probe")
Link, Remote, free_port = _ip.Link, _ip.Remote, _ip.free_port

PLAIN = """\
set remote telnet=127.0.0.1:{REM}
set remote timeout=600
set dz lines=8
restore {SAV}
set cpu idle=4.1BSD
set console telnet=127.0.0.1:{CON}
att dz -m Speed=*32,127.0.0.1:{DZ}
cont
"""

FIXED = """\
set remote telnet=127.0.0.1:{REM}
set remote timeout=600
set dz lines=8
set rp0 rp06
at rp0 {DISK}
restore -D -Q {SAV}
set cpu idle=4.1BSD
set console telnet=127.0.0.1:{CON}
att dz -m Speed=*32,127.0.0.1:{DZ}
cont
"""


def saved_dz_port():
    """The port the snapshot will try to re-attach the DZ to."""
    with open(SAV, "rb") as f:
        blob = f.read()
    hits = re.findall(rb"127\.0\.0\.1:(\d+)", blob)
    return int(hits[0]) if hits else None


def run(tag, conf_text, block_port):
    """Restore once and report what the machine ended up with attached."""
    con_p, rem_p, dz_p = free_port(), free_port(), free_port()
    blocker = None
    if block_port:
        blocker = socket.socket()
        try:
            blocker.bind(("127.0.0.1", block_port))
            blocker.listen(1)
            print("  holding port %d so the re-attach must fail" % block_port)
        except OSError as e:
            print("  could not hold port %d (%s) -- test is not deterministic" % (block_port, e))
            blocker = None

    conf = "attachp-%s.conf" % tag
    with open(conf, "w") as f:
        f.write(conf_text.format(CON=con_p, REM=rem_p, DZ=dz_p, SAV=SAV, DISK=DISK))
    log = open("attachp-%s.log" % tag, "w")
    p = subprocess.Popen([CLI, conf], stdout=log, stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL)
    try:
        con = Link(con_p, reply_iac=True)          # holding it keeps scp alive
        dz = Link(dz_p, reply_iac=True)
        con.pump(2.0)

        r = Remote(rem_p)
        if not r.suspend():
            print("  [%s] remote console did not reach sim>" % tag)
            return
        for cmd in ("show rp0", "show dz"):
            ok, out = r.run(cmd)
            body = " / ".join(l.strip() for l in out.splitlines()
                              if l.strip() and not l.strip().startswith("sim>")
                              and cmd not in l)
            print("  [%s] %-9s %s" % (tag, cmd, body[:200]))
        r.resume()

        dz.take()
        dz.send("\r")
        dz.pump(8)
        got = dz.take()
        print("  [%s] DZ after RETURN: %s"
              % (tag, repr(got[:120]) if got else "NOTHING"))
        return got
    finally:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            if p.poll() is not None:
                break
            try:
                p.send_signal(sig)
            except OSError:
                pass
            time.sleep(0.7)
        log.close()
        if blocker:
            blocker.close()


def main():
    if not os.path.exists(CLI):
        sys.exit("missing %s -- build libsimh first" % CLI)
    os.chdir(RUNDIR)
    for f in (DISK, SAV):
        if not os.path.exists(f):
            sys.exit("missing %s -- run tools/restore-mute-probe.py first" % f)

    wd = threading.Timer(420, lambda: (
        print("WATCHDOG"),
        subprocess.run(["pkill", "-9", "-f", "vax780cli attachp"], capture_output=True)))
    wd.daemon = True
    wd.start()

    port = saved_dz_port()
    print("snapshot wants the DZ back on port %s\n" % port)
    try:
        print("=== plain `restore`, with that port held ===")
        bad = run("plain", PLAIN, port)
        print("\n=== `restore -D` with the disk attached by hand ===")
        good = run("fixed", FIXED, port)

        print("\n=== VERDICT ===")
        print("  plain restore : DZ answers = %s" % bool(bad and bad.strip()))
        print("  restore -D    : DZ answers = %s" % bool(good and good.strip()))
        return 0
    finally:
        wd.cancel()
        subprocess.run(["pkill", "-9", "-f", "vax780cli attachp"], capture_output=True)
        left = subprocess.run(["pgrep", "-f", "vax780cli attachp"],
                              capture_output=True, text=True).stdout.split()
        print("cleanup done; simulators still running: %d" % len(left))


if __name__ == "__main__":
    sys.exit(main())
