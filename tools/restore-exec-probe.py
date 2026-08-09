#!/usr/bin/env python3
"""restore-exec-probe.py -- why does a restored V8 kill everything it execs?

restore-mute-probe.py established that the DZ line is fine after a restore --
it echoes, and RETURN brings back the shell prompt -- and that the shell then
answers `echo PROBE-OK` with **Killed**. A shell that cannot exec is a session
that dies the moment anything runs, which is indistinguishable from a mute
terminal by the time a user looks at it.

"Killed" is SIGKILL, and in a 4.1BSD-lineage execve SIGKILL is what the kernel
sends when something fails *after* the old address space is already gone --
classically an I/O error faulting the new text in. So this reruns the restore
and prints the raw console transcript, which is where the kernel would say so,
plus whatever the machine can tell us about its own memory and disks.

It reuses the snapshot restore-mute-probe.py left behind (work/myv8/mutep.sav
and mutep.disk) if both are present, so it costs one restore rather than a
whole boot.

    tools/restore-exec-probe.py

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
DISK = "mutep.disk"
SAV = "mutep.sav"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
_ip = import_module("idle-probe")
Link, Remote, free_port = _ip.Link, _ip.Remote, _ip.free_port

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


def main():
    if not os.path.exists(CLI):
        sys.exit("missing %s -- build libsimh first" % CLI)
    os.chdir(RUNDIR)
    for f in (DISK, SAV):
        if not os.path.exists(f):
            sys.exit("missing %s -- run tools/restore-mute-probe.py first" % f)

    con_p, rem_p, dz_p = free_port(), free_port(), free_port()
    with open("execp.conf", "w") as f:
        f.write(RESUME.format(CON=con_p, REM=rem_p, DZ=dz_p, SAV=SAV))
    log = open("execp.log", "w")
    p = subprocess.Popen([CLI, "execp.conf"], stdout=log,
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
        subprocess.run(["pkill", "-9", "-f", "vax780cli execp"], capture_output=True)

    wd = threading.Timer(420, lambda: (print("WATCHDOG: killing probe"), cleanup()))
    wd.daemon = True
    wd.start()

    try:
        con = Link(con_p, reply_iac=True)
        dz = Link(dz_p, reply_iac=True)
        con.pump(3.0)
        print("=== console, first 3 s after cont ===")
        print(con.take() or "(silent)")

        # The DZ still holds the shell the snapshot was taken in.
        print("\n=== the restored shell on the DZ line ===")
        for cmd, wait in (("\r", 5), ("echo one\r", 8), ("echo two\r", 8),
                          ("/bin/echo three\r", 8), ("pwd\r", 8), ("sync\r", 8)):
            dz.take()
            dz.send(cmd)
            dz.pump(wait)
            got = dz.take()
            print("  %-20s -> %r" % (cmd.strip() or "RETURN", got[:160]))

        print("\n=== anything the kernel said on the console meanwhile ===")
        con.pump(2.0)
        print(con.take() or "(silent)")

        # A second, independent tty: does a *fresh* login work, or is exec
        # broken machine-wide?
        print("\n=== a fresh login on the console ===")
        con.take()
        con.send("\r")
        if con.wait("login:", 25):
            print("  reached login:")
            con.send("root\r")
            got = ""
            end = time.time() + 45
            while time.time() < end and "# " not in got:
                con.pump(1.0)
                got += con.take()
            print("  after `root`: %r" % got[:400])
        else:
            print("  console never offered login: -- %r" % con.take()[-300:])

        print("\n=== simulator's own log ===")
        with open("execp.log") as f:
            print(f.read()[-1500:])
        return 0
    finally:
        wd.cancel()
        cleanup()
        left = subprocess.run(["pgrep", "-f", "vax780cli execp"],
                              capture_output=True, text=True).stdout.split()
        print("cleanup done; simulators still running: %d" % len(left))


if __name__ == "__main__":
    sys.exit(main())
