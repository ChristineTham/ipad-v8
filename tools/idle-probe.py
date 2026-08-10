#!/usr/bin/env python3
"""idle-probe.py -- why is SIMH burning a core while V8 sits at `login:`?

SIMH will only sleep when the *head* of its event queue belongs to a unit
flagged UNIT_IDLE (sim_timer.c, sim_idle). One stray unit without that flag,
rescheduling itself faster than the clock, pins the host CPU at 100% no matter
how correct `set cpu idle=4.1BSD` is.

`SHOW QUEUE` prints the queue in order and annotates every entry with
"(Idle capable)", so it names the offender directly. This runs the app's exact
SIMH topology under the *library* build (vax780cli -- no SIM_ASYNCH_IO, no
reader thread, same as the iPad/Mac app), boots V8 to the login prompt,
measures the host CPU cost of doing nothing, and then dumps the queue.

    tools/idle-probe.py app            # app-exact config
    tools/idle-probe.py app --window 20
    tools/idle-probe.py --list

Every run is self-contained: hard timeout, watchdog thread, and a cleanup that
kills the simulator whatever happens.
"""
import argparse
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
DISK = "idle-probe.disk"

IAC, DONT, DO, WONT, WILL = 255, 254, 253, 252, 251

# Config variants. Each is the app's boot.conf with one thing changed, so a
# CPU difference between two runs is attributable to exactly one line.
# {CON} {REM} {DZ} are filled with this run's ports.
VARIANTS = {
    # Machine.swift bootConf, verbatim.
    "app": """\
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
""",
    # Three DZ listeners: the mux-wide one plus a dedicated port for line 0
    # (the 5620) and line 7 (the 128-column glass tty). Pinning lines is what
    # makes /.profile's TERM-by-tty mapping deterministic -- but every extra
    # listener is another thing tmxr polls, and one periodic unit without
    # UNIT_IDLE at the head of the event queue pins a core.
    "threedz": """\
set console telnet=127.0.0.1:{CON}
set remote telnet=127.0.0.1:{REM}
set remote timeout=600
set cpu idle=4.1BSD
set tto 7b
set dz lines=8
att dz -m Speed=*32,127.0.0.1:{DZ}
att dz Line=0,Speed=*32,127.0.0.1:{DZ0}
att dz Line=7,Speed=*32,127.0.0.1:{DZ7}
set rp0 rp06
at rp0 {DISK}
set tu0 te16
load -o bootV8 0
run 2
""",
    # No remote console.
    "norem": """\
set console telnet=127.0.0.1:{CON}
set cpu idle=4.1BSD
set tto 7b
set dz lines=8
att dz -m Speed=*32,127.0.0.1:{DZ}
set rp0 rp06
at rp0 {DISK}
set tu0 te16
load -o bootV8 0
run 2
""",
    # No DZ at all (so no 5620 line).
    "nodz": """\
set console telnet=127.0.0.1:{CON}
set remote telnet=127.0.0.1:{REM}
set remote timeout=600
set cpu idle=4.1BSD
set tto 7b
set rp0 rp06
at rp0 {DISK}
set tu0 te16
load -o bootV8 0
run 2
""",
    # DZ attached, but without the speed factor and without modem control.
    "plaindz": """\
set console telnet=127.0.0.1:{CON}
set remote telnet=127.0.0.1:{REM}
set remote timeout=600
set cpu idle=4.1BSD
set tto 7b
set dz lines=8
att dz 127.0.0.1:{DZ}
set rp0 rp06
at rp0 {DISK}
set tu0 te16
load -o bootV8 0
run 2
""",
    # Floor: nothing but the console and the disk.
    "bare": """\
set console telnet=127.0.0.1:{CON}
set cpu idle=4.1BSD
set tto 7b
set rp0 rp06
at rp0 {DISK}
load -o bootV8 0
run 2
""",
}


def free_port():
    """A port nothing is listening on. A closed LISTEN socket leaves no
    TIME_WAIT, so SIMH -- which binds without SO_REUSEADDR -- can take it."""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Link:
    """A localhost telnet socket into SIMH, IAC stripped, high bit stripped.

    reply_iac MUST stay False for the remote console: a client that answers
    IAC silences that session permanently (documented in CLAUDE.md)."""

    def __init__(self, port, reply_iac=False, timeout=25):
        end = time.time() + timeout
        self.k = None
        while time.time() < end:
            try:
                self.k = socket.create_connection(("127.0.0.1", port), timeout=2)
                break
            except OSError:
                time.sleep(0.3)
        if self.k is None:
            raise SystemExit("idle-probe: could not connect to port %d" % port)
        self.k.settimeout(0.2)
        self.reply_iac = reply_iac
        self.buf = ""

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                d = self.k.recv(4096)
            except socket.timeout:
                continue
            if not d:
                return
            self._absorb(d)

    def _absorb(self, d):
        i = 0
        out = []
        while i < len(d):
            b = d[i]
            if b == IAC and i + 1 < len(d):
                c = d[i + 1]
                if c in (DO, DONT, WILL, WONT) and i + 2 < len(d):
                    if self.reply_iac:
                        opt = d[i + 2]
                        self.k.sendall(bytes([IAC, WONT if c == DO else DONT, opt]))
                    i += 3
                    continue
                i += 2
                continue
            out.append(chr(b & 0x7F))
            i += 1
        self.buf += "".join(out)

    def wait(self, pattern, timeout):
        """V8's first login: arrives with mark parity, hence the 7-bit strip."""
        end = time.time() + timeout
        while time.time() < end:
            if pattern in self.buf:
                return True
            try:
                d = self.k.recv(4096)
            except socket.timeout:
                continue
            if not d:
                return False
            self._absorb(d)
        return False

    def send(self, text):
        self.k.sendall(text.encode() if isinstance(text, str) else text)

    def take(self):
        s, self.buf = self.buf, ""
        return s


class Remote:
    """SIMH remote-console dialect: ^E suspends to `sim>`; every command needs
    a sacrificial leading space (command-mode typeahead eats the first byte);
    completion is proven with an output-anchored echo marker because the
    `sim>` prompt prints lazily."""

    def __init__(self, port):
        self.link = Link(port, reply_iac=False)
        self.n = 0

    def suspend(self):
        self.link.send("\x05")
        return self.link.wait("sim>", 10)

    def run(self, cmd, timeout=15):
        self.n += 1
        mark = "PROBE%d" % self.n
        self.link.take()
        self.link.send(" %s\r\n" % cmd)
        self.link.send(" echo %s\r\n" % mark)
        ok = self.link.wait("\n" + mark, timeout)
        out = self.link.take()
        return ok, out.split("\n" + mark)[0]

    def resume(self):
        self.link.send(" continue\r\n")
        self.link.wait("Simulator Running", 8)


def cpu_seconds(pid):
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    m = re.match(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$", out)
    if not m:
        return None
    d, h, mi, s = m.groups()
    return (int(d or 0) * 86400 + int(h or 0) * 3600 + int(mi) * 60 + float(s))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("variant", nargs="?", default="app")
    ap.add_argument("--window", type=float, default=20.0, help="CPU sample seconds")
    ap.add_argument("--settle", type=float, default=8.0, help="seconds after login: before sampling")
    ap.add_argument("--boot-timeout", type=float, default=300.0)
    ap.add_argument("--samples", type=int, default=3, help="CPU windows to take")
    ap.add_argument("--why", action="store_true",
                    help="also capture INT-CLOCK IDLE debug and histogram the refusals")
    ap.add_argument("--clock", type=float, default=0.0, metavar="SECS",
                    help="log in and check V8's own clock against the host's over SECS")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if args.list:
        print("\n".join(sorted(VARIANTS)))
        return 0
    if args.variant not in VARIANTS:
        sys.exit("unknown variant %r (try --list)" % args.variant)
    if not os.path.exists(CLI):
        sys.exit("missing %s -- build libsimh first" % CLI)

    con_p, rem_p, dz_p = free_port(), free_port(), free_port()
    os.chdir(RUNDIR)
    # Never boot the golden image itself. -c is an APFS clone: instant, no space.
    if os.path.exists(DISK):
        os.unlink(DISK)
    if subprocess.run(["cp", "-c", GOLDEN, DISK]).returncode != 0:
        subprocess.run(["cp", GOLDEN, DISK], check=True)

    conf = "idle-probe.conf"
    with open(conf, "w") as f:
        f.write(VARIANTS[args.variant].format(CON=con_p, REM=rem_p, DZ=dz_p,
                                             DZ0=free_port(), DZ7=free_port(),
                                             DISK=DISK))

    log = open("idle-probe-%s.log" % args.variant, "w")
    proc = subprocess.Popen([CLI, conf], stdout=log, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL)

    def cleanup():
        for sig in (signal.SIGTERM, signal.SIGKILL):
            if proc.poll() is not None:
                break
            try:
                proc.send_signal(sig)
            except OSError:
                pass
            time.sleep(0.7)
        subprocess.run(["pkill", "-9", "-f", "vax780cli idle-probe.conf"],
                       capture_output=True)

    hard = args.boot_timeout + args.settle + args.window + 120
    watchdog = threading.Timer(hard, lambda: (print("WATCHDOG: killing probe"), cleanup()))
    watchdog.daemon = True
    watchdog.start()

    try:
        print("== variant %r  console=%d remote=%d dz=%d ==" % (args.variant, con_p, rem_p, dz_p))
        con = Link(con_p, reply_iac=True)
        t0 = time.time()
        if not con.wait("login:", args.boot_timeout):
            print("FAILED: no login: prompt")
            return 3
        print("booted to login: in %.0f s" % (time.time() - t0))

        # A DZ line with no client attached and a console with no keystrokes:
        # this is the app sitting in the user's hand doing nothing.
        con.pump(args.settle)
        pcts = []
        for _ in range(args.samples):
            c0, w0 = cpu_seconds(proc.pid), time.time()
            con.pump(args.window)
            c1, w1 = cpu_seconds(proc.pid), time.time()
            pcts.append(100.0 * (c1 - c0) / (w1 - w0))
        print("IDLE CPU: %s  -> median %.1f%% of a core"
              % ("  ".join("%.1f%%" % p for p in pcts), sorted(pcts)[len(pcts) // 2]))

        if args.clock:
            # The whole point of idling is to stop executing instructions --
            # so the guest must still be told how much time went by. sim_idle
            # credits the skipped interval to the calibrated clock; if that
            # accounting is wrong, an idling V8 runs slow and nothing else
            # shows it. Compare V8's own clock with the host's across a window
            # in which the machine does nothing but idle.
            con.take()
            con.send("root\r")
            if not con.wait("# ", 30):
                print("CLOCK: could not get a root shell")
            else:
                def v8_time():
                    con.take()
                    con.send("date\r")
                    con.wait("# ", 20)
                    m = re.search(r"(\d\d):(\d\d):(\d\d)", con.take())
                    return None if not m else \
                        int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
                g0, h0 = v8_time(), time.time()
                con.pump(args.clock)
                g1, h1 = v8_time(), time.time()
                if g0 is None or g1 is None:
                    print("CLOCK: could not read date(1)")
                else:
                    guest = (g1 - g0) % 86400
                    host = h1 - h0
                    print("CLOCK: guest advanced %d s while the host advanced %.1f s "
                          "(drift %+.1f%%)" % (guest, host, 100.0 * (guest - host) / host))

        if "set remote" in VARIANTS[args.variant]:
            rem = Remote(rem_p)
            if not rem.suspend():
                print("remote console did not reach sim>")
                return 0
            for i in range(2):
                ok, out = rem.run("show queue")
                print("\n--- show queue #%d (ok=%s) ---\n%s" % (i + 1, ok, out.strip()))
                if i == 0:
                    rem.resume()
                    time.sleep(1.5)
                    rem.link.send("\x05")
                    rem.link.wait("sim>", 10)
            if args.why:
                # sim_idle() logs the *name* of whatever is at the head of the
                # event queue every time it declines to sleep. A short window
                # is plenty: at an idle prompt the message repeats millions of
                # times a second, so the histogram is the whole answer.
                dbg = os.path.join(RUNDIR, "idle-why.dbg")
                rem.run("set debug -n %s" % dbg)
                rem.run("set INT-CLOCK debug=IDLE")
                rem.resume()
                time.sleep(0.5)
                rem.link.send("\x05")
                rem.link.wait("sim>", 10)
                rem.run("set nodebug")
                counts, total = {}, 0
                with open(dbg, errors="replace") as f:
                    for line in f:
                        if "Can't idle:" in line:
                            key = line.split("Can't idle:")[1].split(" - ")[0].strip()
                            counts[key] = counts.get(key, 0) + 1
                            total += 1
                print("\n--- why sim_idle() refused (%d refusals in ~0.5 s) ---" % total)
                for k, v in sorted(counts.items(), key=lambda kv: -kv[1]):
                    print("  %8d  %.1f%%  head of queue: %s" % (v, 100.0 * v / max(total, 1), k))
                if total == 0:
                    print("  none -- sim_idle() is sleeping whenever it is asked to")
            rem.resume()
        return 0
    finally:
        watchdog.cancel()
        cleanup()
        log.close()
        left = subprocess.run(["pgrep", "-f", "vax780cli idle-probe.conf"],
                              capture_output=True, text=True).stdout.split()
        print("cleanup done; simulators still running: %d" % len(left))


if __name__ == "__main__":
    sys.exit(main())
