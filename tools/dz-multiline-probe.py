#!/usr/bin/env python3
"""dz-multiline-probe.py -- how many glass ttys does one DZ port already give?

The app attaches the DZ as a single listener:

    att dz -m Speed=*32,127.0.0.1:PORT

and only the 5620 ever dials it. But `set dz lines=8` configures eight lines,
sim_tmxr's tmxr_poll_conn hands each new connection to the next available one,
and V8's /etc/ttys turns out to enable getty on tty00..tty07 as well as the
console. If all three of those are true together, a second, lighter terminal
session costs one socket and no configuration at all.

"If" is doing a lot of work there, so this measures it:

  * connect twice to the same DZ port and see whether both get a login prompt
  * log in on both and ask each one what tty it is
  * check they coexist -- `who` should list both
  * dump the vt100 termcap entry, because a plain terminal emulator has to
    claim to be something this 1985 machine has heard of, and there is no
    xterm in 1985
  * run vi under TERM=vt100 and confirm it actually drives the screen

    tools/dz-multiline-probe.py

One-shot: hard watchdog, simulator killed on every exit path.
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
DISK = "multi.disk"

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


def login(link, label, timeout=60):
    """Drive one line from carrier to a root shell."""
    link.send("\r")
    if not link.wait("login:", timeout):
        print("  %-8s no login: prompt -- %r" % (label, link.take()[-120:]))
        return False
    link.send("root\r")
    if not link.wait("# ", timeout):
        print("  %-8s never reached a shell -- %r" % (label, link.take()[-160:]))
        return False
    print("  %-8s logged in" % label)
    return True


def ask(link, cmd, timeout=25):
    link.take()
    link.send(cmd + "\r")
    link.wait("# ", timeout)
    out = link.take()
    # Drop the echoed command line and the trailing prompt -- by *position*,
    # not by content. Filtering out every line containing `cmd` silently ate
    # the answer to `tty`, whose output is /dev/tty00.
    lines = [l.strip() for l in out.replace("\r", "").split("\n")]
    if lines and cmd in lines[0]:
        lines = lines[1:]
    return [l for l in lines if l and l != "#" and not l.startswith("# ")]


def main():
    if not os.path.exists(CLI):
        sys.exit("missing %s -- build libsimh first" % CLI)
    os.chdir(RUNDIR)
    if os.path.exists(DISK):
        os.unlink(DISK)
    if subprocess.run(["cp", "-c", GOLDEN, DISK]).returncode != 0:
        subprocess.run(["cp", GOLDEN, DISK], check=True)

    con_p, rem_p, dz_p = free_port(), free_port(), free_port()
    with open("multi.conf", "w") as f:
        f.write(BOOT.format(CON=con_p, REM=rem_p, DZ=dz_p, DISK=DISK))
    log = open("multi.log", "w")
    p = subprocess.Popen([CLI, "multi.conf"], stdout=log,
                         stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)

    def cleanup():
        for sig in (signal.SIGTERM, signal.SIGKILL):
            if p.poll() is not None:
                break
            try:
                p.send_signal(sig)
            except OSError:
                pass
            time.sleep(0.7)
        log.close()
        subprocess.run(["pkill", "-9", "-f", "vax780cli multi"], capture_output=True)

    wd = threading.Timer(600, lambda: (print("WATCHDOG"), cleanup()))
    wd.daemon = True
    wd.start()

    try:
        con = Link(con_p, reply_iac=True)
        if not con.wait("login:", 300):
            print("FAILED: console never reached login:")
            return 3
        print("console up\n")

        print("=== two connections, one DZ port ===")
        a = Link(dz_p, reply_iac=True)
        ok_a = login(a, "first")
        b = Link(dz_p, reply_iac=True)
        ok_b = login(b, "second")
        if not (ok_a and ok_b):
            print("  -> one port does NOT give two sessions")
            return 1

        tty_a = ask(a, "tty")
        tty_b = ask(b, "tty")
        print("  first  is on %s" % tty_a)
        print("  second is on %s" % tty_b)
        print("  distinct ttys: %s" % (tty_a != tty_b))
        print("  who:")
        for line in ask(a, "who"):
            print("      %s" % line)

        print("\n=== what a plain terminal emulator may claim to be ===")
        for line in ask(a, "grep -n 'co#' /etc/termcap | grep -i vt100"):
            print("  %s" % line[:150])
        for line in ask(a, "sed -n '558,565p' /etc/termcap"):
            print("  %s" % line[:150])

        print("\n=== does vi drive a vt100? ===")
        a.take()
        a.send("TERM=vt100; export TERM\r")
        a.wait("# ", 15)
        a.take()
        a.send("vi /tmp/vitest\r")
        a.pump(12)
        got = a.take()
        esc = got.count("\x1b") + got.count("[")
        print("  vi emitted %d bytes, %d escape-ish markers" % (len(got), esc))
        print("  sample: %r" % got[:160])
        a.send("\x1b:q!\r")            # ESC : q ! CR
        a.pump(4)
        print("  back at a shell: %s" % ("# " in a.take()))
        return 0
    finally:
        wd.cancel()
        cleanup()
        left = subprocess.run(["pgrep", "-f", "vax780cli multi"],
                              capture_output=True, text=True).stdout.split()
        print("cleanup done; simulators still running: %d" % len(left))


if __name__ == "__main__":
    sys.exit(main())
