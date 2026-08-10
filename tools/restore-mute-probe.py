#!/usr/bin/env python3
"""restore-mute-probe.py -- is a *logged-in* DZ session mute after restore?

tools/dz-prompt-probe.py already proved the getty case: after the dz_attach
`lp->rcve` patch, a restored line answers RETURN with a fresh `login:`. The app
still comes back mute -- but the app's failing case is not a getty prompt, it is
a session that was **logged in to a shell** when the snapshot was taken. That is
a materially different line state: getty owns the tty with its own termio, a
login shell owns it through a different open, and only one of the two was ever
tested.

So this runs the app's exact topology and saves at a `#` prompt:

  cold    boot, log in as root on the DZ line, run a command, snapshot there
  resume  restore that snapshot with a FRESH DZ client (what the app does --
          the 5620 always power-cycles) and try to talk to the shell

and reports, at each step, whether bytes move in each direction independently:

  * host -> terminal   (write to the tty from the console side)
  * terminal -> host   (type at the DZ and watch for an echo)

Distinguishing those two is the whole point. A dead rcve kills only the second;
a modem-control or line-count mismatch kills both; a shell that has exited or a
tty that lost its process group kills neither but produces no echo either.

    tools/restore-mute-probe.py

One-shot: hard watchdog, simulators killed on every exit path.
"""
import os
import signal
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "libsimh/build/macos/vax780cli")
RUNDIR = os.path.join(ROOT, "work/myv8")
GOLDEN = "rp06v8.golden"
DISK = "mutep.disk"
SAV = "mutep.sav"

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

# Byte-for-byte the app's resume.conf (app/ipnx/Machine.swift).
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
        conf = "mutep-%s.conf" % tag
        with open(conf, "w") as f:
            f.write(conf_text.format(CON=self.con_p, REM=self.rem_p, DZ=self.dz_p,
                                     DISK=DISK, SAV=SAV, **fmt))
        self.log = open("mutep-%s.log" % tag, "w")
        self.p = subprocess.Popen([CLI, conf], stdout=self.log,
                                  stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)

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


def show(rem_port, tag):
    """`show dz` and the DZ registers, side by side across the restore."""
    r = Remote(rem_port)
    if not r.suspend():
        print("  [%s] remote console did not reach sim>" % tag)
        return
    for cmd in ("show dz", "examine dz csr", "examine dz tcr", "examine dz msr"):
        ok, out = r.run(cmd)
        body = "\n".join(l for l in out.splitlines()
                         if l.strip() and not l.strip().startswith("sim>")
                         and cmd not in l)[:500]
        print("  [%s] %-16s %s" % (tag, cmd, body.replace("\n", "\n" + " " * 28)))
    r.resume()


def probe_line(dz, label, text="echo PROBE-OK\r"):
    """Type at the DZ and report what comes back."""
    dz.take()
    dz.send(text)
    dz.pump(6)
    got = dz.take()
    shown = got.replace("\r", "\\r").replace("\n", "\\n")
    print("  %-38s %s" % (label, ("%d bytes: %r" % (len(got), shown[:150]))
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
        subprocess.run(["pkill", "-9", "-f", "vax780cli mutep"], capture_output=True)

    wd = threading.Timer(900, lambda: (print("WATCHDOG: killing probe"), cleanup()))
    wd.daemon = True
    wd.start()

    try:
        # ---------------- cold boot, then LOG IN on the DZ ----------------
        print("=== COLD BOOT -> log in on the DZ line -> snapshot at a shell ===")
        s1 = Sim(BOOT, "boot")
        sims.append(s1)
        con = Link(s1.con_p, reply_iac=True)
        dz = Link(s1.dz_p, reply_iac=True)
        t0 = time.time()
        if not con.wait("login:", 300):
            print("FAILED: console never reached login:")
            return 3
        print("  console reached login: at %.0f s" % (time.time() - t0))

        dz.send("\r")
        if not dz.wait("login:", 30):
            print("FAILED: DZ line never offered login:")
            return 3
        dz.send("root\r")
        if not dz.wait("# ", 60):
            print("FAILED: DZ line never reached a root shell")
            print("  saw: %r" % dz.take()[-200:])
            return 3
        print("  DZ line logged in to a root shell")
        probe_line(dz, "before save, typing at DZ:")
        show(s1.rem_p, "cold")

        rem = Remote(s1.rem_p)
        if not rem.suspend():
            print("FAILED: remote console did not reach sim>")
            return 4
        ok, _ = rem.run("save %s" % SAV, timeout=60)
        print("  snapshot saved at the shell: %s"
              % ("ok" if ok and os.path.exists(SAV) else "FAILED"))
        s1.kill()
        time.sleep(2)

        # ---------------- resume with a brand-new terminal ----------------
        print("\n=== RESUME: same shell restored, brand-new terminal ===")
        s2 = Sim(RESUME, "resume")
        sims.append(s2)
        con2 = Link(s2.con_p, reply_iac=True)     # hold it: dropping it stops scp
        dz2 = Link(s2.dz_p, reply_iac=True)
        con2.pump(1.0)

        dz2.take()
        dz2.pump(6)
        spontaneous = dz2.take()
        print("  %-38s %s" % ("after restore, unprompted:",
                              "%d bytes" % len(spontaneous) if spontaneous else "NOTHING"))

        # terminal -> host: does anything we type reach the shell?
        up1 = probe_line(dz2, "after restore, RETURN:", "\r")
        up2 = probe_line(dz2, "after restore, a command:", "echo PROBE-OK\r")
        talks_up = "PROBE-OK" in up2 or "#" in up1

        # host -> terminal, independently: write to the tty from the console.
        print("  -- cross-check: host -> terminal, from the console --")
        con2.take()
        con2.send("\r")
        down = ""
        if con2.wait("login:", 25):
            con2.send("root\r")
            if con2.wait("# ", 40):
                dz2.take()
                con2.send("echo DOWNSTREAM-OK > /dev/tty00\r")
                con2.wait("# ", 20)
                dz2.pump(5)
                down = dz2.take()
                print("  %-38s %s" % ("DZ received from console:",
                                      "%r" % down[:120] if down else "NOTHING"))
                con2.take()
                con2.send("ps -a | grep tty00\r")
                con2.wait("# ", 25)
                print("  processes on tty00: %s"
                      % " | ".join(l.strip() for l in con2.take().splitlines()
                                   if "tty00" in l and "grep" not in l))
        else:
            print("  console did not offer a prompt either")
        show(s2.rem_p, "resume")

        print("\n=== VERDICT ===")
        print("  terminal -> host works after restore : %s" % talks_up)
        print("  host -> terminal works after restore : %s" % ("DOWNSTREAM-OK" in down))
        return 0
    finally:
        wd.cancel()
        cleanup()
        left = subprocess.run(["pgrep", "-f", "vax780cli mutep"],
                              capture_output=True, text=True).stdout.split()
        print("cleanup done; simulators still running: %d" % len(left))


if __name__ == "__main__":
    sys.exit(main())
