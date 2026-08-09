# Phase A0 — desktop spike runbook

*Goal: prove the entire emulation chain on a Mac — **V8 boots under SIMH, a Blit-family
terminal connects, `mux` runs** — and measure the serial-pacing problem, before writing any
iOS code. Everything here has been done by others; our job is to reproduce it and take
numbers.*

*No **VERIFY** markers remain. The last four were resolved on 2026-08-09: the two `mux`
paths in §4 are confirmed present in the image, and the two third-party 5620 frontends were
superseded by driving `dmd_core`'s C FFI directly, so their flag syntax is moot. Where a step
was never executed, this document now says so rather than leaving a marker that implies it
still might be.*

## 0. Workspace and prerequisites

All work happens in `work/` (gitignored — disk images and vendor checkouts never enter git).

```bash
mkdir -p work && cd work
```

Tooling reality on this machine (verified 2026-08-08): **there is no Homebrew installed.**
What matters:

- `expect` ships with macOS (`/usr/bin/expect`) — myv8 needs nothing else.
- No `telnet` client exists; use [work/dztalk.py](../work/dztalk.py), a minimal Python
  telnet client (handles IAC negotiation and strips the mark-parity bit — see §4).
- SDL2/GTK are unavailable without a package manager, so the GUI terminal emulators are
  deferred. **Rust/`cargo` is installed** — the terminal route is headless `dmd_core`
  (see [spike-a0-results.md](spike-a0-results.md), "Remaining for A0").

## 1. Build SIMH `vax780`

Resolved 2026-08-08: **classic SIMH 3.12-5 works end-to-end with myv8** (full install and
multiuser boot verified on this machine). The zip extracts into a `sim/` subdirectory and
builds with only cosmetic warnings on modern clang:

**Option A — classic SIMH 3.x (verified):**

```bash
curl -sLO http://simh.trailing-edge.com/sources/simhv312-5.zip
mkdir -p simh312 && cd simh312 && unzip -oq ../simhv312-5.zip
cd sim && make vax780     # binary lands in sim/BIN/vax780
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

Read its README first. The flow (resolved 2026-08-08: **all media is bundled in the myv8 repo** — nothing to fetch): fetch the
prerequisite media it lists — the 4.1BSD tape, the 4.0 BSD boot file, and the TUHS
`v8.tar.bz2` + `v8jerq.tar.bz2` from
[Dan_Cross_v8](https://www.tuhs.org/Archive/Distributions/Research/Dan_Cross_v8/) — then run
its expect scripts in order (`install41BSD` → `installV8` → `fixupV8` → `setup`), producing
`v8.disk`. Measured: the entire scripted install takes **~2.5 minutes** on this machine, producing
`rp06v8` — the 174 MB RP06 image (run.conf's name for what the app will bundle as
`v8.disk`).

## 3. Boot V8 and log in

```bash
./vax780 run.conf
```

(Resolved: the file is `run.conf`. Boot lands directly in a single-user root `# ` shell
with no date prompt; `^D` brings up multiuser and the DZ gettys.) Expect the V8 boot on the console; log in as
`root`. Confirm the DZ11 is a telnet listener (config lines equivalent to
`set dz lines=8` / `att dz -m 8888`).

Smoke tests on the console: `ps`, `ls /usr/jerq /usr/blit`, `cat /proc/*` (V8 has /proc!),
compile a hello.c with `cc`.

## 4. Connect a terminal and run `mux`

Get a second login on a DZ line first: `telnet 127.0.0.1 8888` from the Mac — you should
see a `login:` from V8. That proves the serial path before any graphics.

Verified 2026-08-08 (via `work/dztalk.py` — no telnet client exists here): login works, `ps`
/ `/proc` / `cc` all live. Two wire facts: the **first `login:` prompt arrives with the
parity bit set** (mark parity — strip bit 7 until after login), and running
`/usr/jerq/bin/mux` on a dumb connection makes mux emit **`ESC [ c`** (a Device Attributes
query) and wait — the terminal-identification handshake that a 5620 with 8;7;3 firmware
answers. The host side of the protocol is proven.

**Option A — 68K Blit: not taken.** The original 68000 Blit is an explicit non-goal (ROM
permissions unresolved — [licensing.md](licensing.md), [architecture.md](architecture.md)),
so `aap/blit` was never built and its flag syntax was never established. The *path* question
in this option is settled though, and it is worth recording because the naming trap is easy
to fall into: **both** `mux` binaries really do ship in the V8 image —
`/usr/blit/bin/mux` (68000, `mpx`-era, alongside `mpx`/`ismpx`/`jterm`) and
`/usr/jerq/bin/mux` (the 5620, alongside `32ld`/`jim`). Confirmed by listing the extracted
`v8jerq` tape in `work/v8src/{blit,jerq}/bin`. The 5620 is the one this project wants.

**Option B — DMD 5620: superseded before it was needed.** The plan here was a third-party
frontend (`dmd_gtk`, or the SDL one) plus a `socat` pty↔tcp bridge. What actually happened in
session 2 was better: `dmd_core` was driven directly through its **built-in C FFI**
(`tools/dmdbridge/`), which is also what the app does, so there is one terminal
implementation rather than two. `work/dmd_gtk` and `work/dmd_sdl` remain as reference
checkouts only — no frontend flag syntax (`-F 8:7:3 -d …`) or socat IAC behaviour was ever
verified, and none is needed now.

The substantive findings that this option was meant to produce were obtained anyway, and are
in [spike-a0-results.md](spike-a0-results.md): firmware 8;7;3 selection (canonical dmd_core
`reset(1)`), the BREAK-as-0x00 patch, the keyboard FIFO's ~ms drop rate, and the DUART's
need for real-time CPU pacing. `mux` downloading `muxterm` via `32ld`, layers, the button-3
menu and `jim` were all proven on the real thing in A2 ([a2-notes.md](a2-notes.md)).

## 5. Measure (the actual point of the spike)

Record all of this in `docs/spike-a0-results.md`:

1. **Wall-clock time from typing `mux` to a usable layer** — the community reports ~17 min
   under realistic DZ pacing. This number drives the v2 serial-transport design.
   *Partial finding (2026-08-08): classic SIMH 3.12-5 shows no artificial DZ pacing — bulk
   output renders instantly — so the 17-minute issue appears specific to newer SIMH's
   line-speed emulation. Definitive mux timing still needs a real terminal emulator.*
2. Effect of SIMH line-speed settings (`set dz speed=...`, per-line SPEED, or simulator
   defaults — enumerate what the chosen SIMH version supports) on that time.
3. Whether Option-B (open-simh + `set noasync`) boots and runs V8 as reliably as 3.x.
4. Rough emulated-CPU speed feel (e.g., time `cc` on hello.c) and host CPU usage at idle —
   the battery question for the iPad app.
   *Measured 2026-08-08: `vax780` sits at ~97% of one core while V8 idles — idle detection
   or throttling is mandatory for the iPad app.*
5. Every place this runbook was wrong — fix it and drop the VERIFY marker.

## Exit criteria

- `mux` usable end-to-end on the Mac through at least one terminal emulator.
- Serial-pacing fix chosen: SIMH config suffices, or the in-process patch (v2) is required.
- `v8.disk` reproducible from scratch by following this (corrected) runbook.
