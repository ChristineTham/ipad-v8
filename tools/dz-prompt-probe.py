#!/usr/bin/env python3
"""dz-prompt-probe.py -- does the 5620's line get a `login:` on its own?

V8's getty (usr/src/cmd/getty.c, 4.1 BSD lineage) prints its banner and
"login: " exactly ONCE, when it starts, and then blocks in getname(). It
reprints only when getname() returns empty -- which is what a bare RETURN
does. So whether the terminal shows a prompt or a bare cursor is entirely a
question of whether getty happened to print while this particular terminal was
attached, and nothing will ever repeat it unprompted.

This runs the app's exact SIMH topology twice against the same disk:

  cold    boot from scratch, with a DZ client attached the whole time
  resume  restore the snapshot the cold run saved at the login prompt, with a
          FRESH DZ client -- which is exactly what the app does on relaunch,
          because the terminal is re-created from reset every launch while the
          VAX comes back mid-session

and logs, with timestamps, every byte V8 puts on the DZ line -- first with no
input at all, then after a single carriage return.

    tools/dz-prompt-probe.py

One-shot: hard watchdog, and the simulator is killed on every exit path.
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
GOLDEN = "rp06v8.golden"
DISK = "dzprobe.disk"
SAV = "dzprobe.sav"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
_ip = import_module("idle-probe")
Link, Remote, free_port = _ip.Link, _ip.Remote, _ip.free_port

BOOT = """\
set console telnet=127.0.0.1:{CON}
set remote telnet=127.0.0.1:{REM}
set remote timeout=600
set cpu idle=4.1BSD
set tto 7b
set dz lines=8
att dz -m Speed=*32,127.0.0.1:{DZ}
set rp0 rp06
at rp0 {DISK}
set tu0 te16
load -o bootV8 0
run 2
"""

RESUME = """\
set remote telnet=127.0.0.1:{REM}
set remote timeout=600
set dz lines=8
restore {SAV}
set cpu idle=4.1BSD
set console telnet=127.0.0.1:{CON}
att dz -m Speed=*32,127.0.0.1:{DZ}
cont
"""


class Sim:
    def __init__(self, conf_text, tag, **fmt):
        self.con_p, self.rem_p, self.dz_p = free_port(), free_port(), free_port()
        conf = "dzprobe-%s.conf" % tag
        with open(conf, "w") as f:
            f.write(conf_text.format(CON=self.con_p, REM=self.rem_p, DZ=self.dz_p,
                                     DISK=DISK, SAV=SAV, **fmt))
        self.log = open("dzprobe-%s.log" % tag, "w")
        self.p = subprocess.Popen([CLI, conf], stdout=self.log,
                                  stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        self.conf = conf

    def kill(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            if self.p.poll() is not None:
                break
            try:
                self.p.send_signal(sig)
            except OSError:
                pass
            time.sleep(0.7)
        self.log.close()


def dump_dz(rem_port, tag):
    """`show dz` prints per-line connection and modem state. Comparing the cold
    and restored machines side by side is the whole diagnosis."""
    r = Remote(rem_port)
    if not r.suspend():
        print("  [%s] remote console did not reach sim>" % tag)
        return
    for cmd in ("show dz", "examine dz csr", "examine dz tcr",
                "examine dz lpr", "examine dz rxint", "examine dz txint",
                "examine dz sae", "examine dz mdmctl"):
        ok, out = r.run(cmd)
        body = "\n".join(l for l in out.splitlines()
                         if l.strip() and not l.strip().startswith("sim>")
                         and cmd not in l)[:600]
        print("  [%s] %s ->\n      %s" % (tag, cmd, body.replace("\n", "\n      ")))
    r.resume()


def watch_dz(dz, seconds, label):
    """Report what V8 sent, 7-bit stripped -- getty's first prompt goes out
    with software parity in bit 7 (partab[] in getty.c)."""
    dz.take()
    dz.pump(seconds)
    got = dz.take()
    shown = got.replace("\r", "\\r").replace("\n", "\\n")
    print("  %-34s %s" % (label, ("%d bytes: %r" % (len(got), shown[:120]))
                          if got else "NOTHING"))
    return got


def main():
    if not os.path.exists(CLI):
        sys.exit("missing %s -- build libsimh first" % CLI)
    os.chdir(RUNDIR)
    for f in (DISK, SAV):
        if os.path.exists(f):
            os.unlink(f)
    if subprocess.run(["cp", "-c", GOLDEN, DISK]).returncode != 0:
        subprocess.run(["cp", GOLDEN, DISK], check=True)

    sims = []

    def cleanup():
        for s in sims:
            s.kill()
        subprocess.run(["pkill", "-9", "-f", "vax780cli dzprobe"], capture_output=True)

    wd = threading.Timer(600, lambda: (print("WATCHDOG: killing probe"), cleanup()))
    wd.daemon = True
    wd.start()

    try:
        # ---------------- cold boot ----------------
        print("=== COLD BOOT: DZ client attached before V8 is even up ===")
        s1 = Sim(BOOT, "boot")
        sims.append(s1)
        con = Link(s1.con_p, reply_iac=True)
        dz = Link(s1.dz_p, reply_iac=True)          # the 5620's stand-in
        t0 = time.time()
        if not con.wait("login:", 300):
            print("FAILED: console never reached login:")
            return 3
        print("  console reached login: at %.0f s" % (time.time() - t0))
        got = watch_dz(dz, 12, "DZ line, no input:")
        cold_unprompted = "login:" in got
        dump_dz(s1.rem_p, "cold")
        if not cold_unprompted:
            dz.send("\r")
            watch_dz(dz, 6, "DZ line, after one RETURN:")

        # Snapshot at exactly this state, the way the app does on background.
        rem = Remote(s1.rem_p)
        if not rem.suspend():
            print("FAILED: remote console did not reach sim>")
            return 4
        ok, _ = rem.run("save %s" % SAV, timeout=60)
        print("  snapshot saved: %s" % ("ok" if ok and os.path.exists(SAV) else "FAILED"))
        s1.kill()
        time.sleep(2)

        # ---------------- resume ----------------
        print("\n=== RESUME: same machine restored, brand-new terminal ===")
        s2 = Sim(RESUME, "resume")
        sims.append(s2)
        # Hold this: dropping the console socket stops the simulator dead
        # ("Console Telnet connection lost"), which is not the thing under test.
        con2 = Link(s2.con_p, reply_iac=True)
        dz2 = Link(s2.dz_p, reply_iac=True)
        con2.pump(1.0)
        got2 = watch_dz(dz2, 12, "DZ line, no input:")
        resume_unprompted = "login:" in got2
        dz2.send("\r")
        got3 = watch_dz(dz2, 8, "DZ line, after one RETURN:")
        dz2.send("\r\r\r")
        got4 = watch_dz(dz2, 8, "DZ line, after three more:")
        dump_dz(s2.rem_p, "resume")

        # Is the line dead, or merely quiet? Drive it from the other end: log in
        # on the console and write to /dev/tty00 directly. If those bytes arrive,
        # the DZ is healthy and this is purely getty's one-shot prompt.
        print("  -- cross-checking from the console --")
        con2.take()
        con2.send("\r")
        if not con2.wait("login:", 20):
            print("  console did not offer a prompt either")
        else:
            con2.send("root\r")
            if con2.wait("# ", 30):
                con2.take()
                con2.send("echo DZ-ALIVE > /dev/tty00\r")
                con2.wait("# ", 15)
                got5 = watch_dz(dz2, 6, "DZ line, written from console:")
                con2.take()
                con2.send("ps -a | grep -c getty\r")
                con2.wait("# ", 20)
                print("  getty processes: %s" % con2.take().strip().split("\n")[-2:])
                print("  DZ output path alive after restore = %s"
                      % ("DZ-ALIVE" in got5))

        print("\n=== VERDICT ===")
        print("  cold boot   : prompt arrives unprompted = %s" % cold_unprompted)
        print("  after resume: prompt arrives unprompted = %s" % resume_unprompted)
        print("  after resume: RETURN produces a prompt   = %s"
              % ("login:" in got3 or "login:" in got4))
        return 0
    finally:
        wd.cancel()
        cleanup()
        left = subprocess.run(["pgrep", "-f", "vax780cli dzprobe"],
                              capture_output=True, text=True).stdout.split()
        print("cleanup done; simulators still running: %d" % len(left))


if __name__ == "__main__":
    sys.exit(main())
