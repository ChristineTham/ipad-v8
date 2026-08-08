# Phase A0 — desktop spike runbook

*Goal: prove the entire emulation chain on a Mac — **V8 boots under SIMH, a Blit-family
terminal connects, `mux` runs** — and measure the serial-pacing problem, before writing any
iOS code. Everything here has been done by others; our job is to reproduce it and take
numbers.*

*Steps marked **VERIFY** are assembled from research, not yet executed here — confirm them
during the spike and correct this document (that's a spike deliverable).*

## 0. Workspace and prerequisites

All work happens in `work/` (gitignored — disk images and vendor checkouts never enter git).

```bash
mkdir -p work && cd work
```

Homebrew packages — `expect` is required by myv8's install scripts; the rest support the
terminal emulators and glue:

```bash
brew install expect socat sdl2 gtk+3 pkg-config
```

## 1. Build SIMH `vax780`

Two options; the myv8 README warns that distro SIMH builds "don't quite cut it", so build
from source. **VERIFY which option myv8's `run.conf` expects** (SIMH 3.x vs 4.x command
syntax differs slightly).

**Option A — classic SIMH 3.x (what the 2017 recipes used, works without `set noasync`):**

```bash
curl -LO http://simh.trailing-edge.com/sources/simhv312-4.zip
unzip -d simh312 simhv312-4.zip && cd simh312 && make vax780 && cd ..
```

**Option B — open-simh (current, MIT; requires `set noasync` in every config):**

```bash
git clone https://github.com/open-simh/simh open-simh
cd open-simh && make vax780 && cd ..
```

The app will ship open-simh, so even if Option A is used to *build* the image, re-verify
boot under Option B + `set noasync` before calling A0 done.

## 2. Build `v8.disk` with myv8

```bash
git clone https://github.com/timnewsham/myv8
cd myv8
```

Read its README first. The flow (**VERIFY details against the README**): fetch the
prerequisite media it lists — the 4.1BSD tape, the 4.0 BSD boot file, and the TUHS
`v8.tar.bz2` + `v8jerq.tar.bz2` from
[Dan_Cross_v8](https://www.tuhs.org/Archive/Distributions/Research/Dan_Cross_v8/) — then run
its expect scripts in order (`install41BSD` → `installV8` → `fixupV8` → `setup`), producing
`v8.disk`. Budget real time: the scripted 4.1BSD + V8 install drives an emulated console.

## 3. Boot V8 and log in

```bash
./vax780 run.conf
```

(**VERIFY** the exact config filename in myv8.) Expect the V8 boot on the console; log in as
`root`. Confirm the DZ11 is a telnet listener (config lines equivalent to
`set dz lines=8` / `att dz -m 8888`).

Smoke tests on the console: `ps`, `ls /usr/jerq /usr/blit`, `cat /proc/*` (V8 has /proc!),
compile a hello.c with `cc`.

## 4. Connect a terminal and run `mux`

Get a second login on a DZ line first: `telnet 127.0.0.1 8888` from the Mac — you should
see a `login:` from V8. That proves the serial path before any graphics.

**Option A — 68K Blit (fastest visual win; telnet built in):**

```bash
git clone https://github.com/aap/blit && cd blit
# build per its README (SDL2), then:
./blit -t 'tcp!127.0.0.1!8888'          # VERIFY exact flag syntax from README
```

Log in inside the Blit window, then run `/usr/blit/bin/mux` (**VERIFY path**; this is the
68000 route — `mpx`-era software, dusty but proven by timnewsham with screenshots).

**Option B — DMD 5620 (the product path; needs a pty↔tcp bridge since dmd5620 1.3 dropped
telnet):**

```bash
git clone https://github.com/dmdmtg/dmd_gtk && cd dmd_gtk
# build per its README (GTK3); alternatively try the experimental SDL frontend.
socat pty,link="$PWD/dz0",raw,echo=0 tcp:127.0.0.1:8888 &   # VERIFY: telnet IAC bytes may
                                                            # need socat to strip; if garbage
                                                            # appears, attach SIMH's DZ with
                                                            # a raw (non-telnet) mode instead
./dmd5620 -F 8:7:3 -d ./dz0                                  # VERIFY flag names: firmware
                                                            # 8;7;3 selection + tty device
```

Log in inside the 5620 window, then run `mux` (host side lives in `/usr/jerq/bin` —
**VERIFY** whether it's on root's default PATH). `mux` downloads `muxterm` into the terminal
via `32ld`; layers should appear, button 3 opens the menu. Try `jim`.

## 5. Measure (the actual point of the spike)

Record all of this in `docs/spike-a0-results.md`:

1. **Wall-clock time from typing `mux` to a usable layer** — the community reports ~17 min
   under realistic DZ pacing. This number drives the v2 serial-transport design.
2. Effect of SIMH line-speed settings (`set dz speed=...`, per-line SPEED, or simulator
   defaults — enumerate what the chosen SIMH version supports) on that time.
3. Whether Option-B (open-simh + `set noasync`) boots and runs V8 as reliably as 3.x.
4. Rough emulated-CPU speed feel (e.g., time `cc` on hello.c) and host CPU usage at idle —
   the battery question for the iPad app.
5. Every place this runbook was wrong — fix it and drop the VERIFY marker.

## Exit criteria

- `mux` usable end-to-end on the Mac through at least one terminal emulator.
- Serial-pacing fix chosen: SIMH config suffices, or the in-process patch (v2) is required.
- `v8.disk` reproducible from scratch by following this (corrected) runbook.
