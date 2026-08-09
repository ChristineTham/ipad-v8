# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A native iPad app that runs Research Unix (V8 first, V10 as the end goal) on an emulated
VAX — open-simh `vax780` — displayed through an emulated DMD 5620 terminal (`dmd_core`),
joined by a virtual serial line inside one iOS process. Full-system emulation is the load-
bearing decision: the Research Unix kernel forks processes inside the emulated machine, so
iOS's no-fork/no-JIT restrictions never apply, and both cores are plain AOT-compiled
interpreters (App Store-legal per UTM SE / iAltair precedent).

**Current state: Track A complete (A1–A3), on iPad *and* Mac.** `libsimh/` and
`libdmd/` package both emulator cores as xcframeworks (ios, ios-simulator,
macos slices); `app/` is the ipnx app, one source folder built by two targets:
V8 boots to `login:` in ~25–30 s with save/restore instant-on
([docs/a1-notes.md](docs/a1-notes.md)); the DMD 5620 runs as a Metal phosphor
screen — `mux` and `jim` work end-to-end on iPad
([docs/a2-notes.md](docs/a2-notes.md)); A3 added settings, media management,
licences, App Store prep and the macOS app ([docs/a3-notes.md](docs/a3-notes.md),
[docs/app-store.md](docs/app-store.md)). Next: **submission** (needs the Apple
account) and **Track B**. [RESEARCH.md](RESEARCH.md) is the evidence base for every
decision; trust it over memory, and record decision changes in the living docs, not by
rewriting the study.

## Commands

Track A commands (media prerequisites still come from the A0 workbench below —
`work/myv8/rp06v8.golden` + `bootV8` must exist before the app build embeds them):

```bash
# Build SimhVAX.xcframework (clones open-simh into work/ pinned to the verified rev)
libsimh/build-xcframework.sh
```

```bash
# Build DmdCore.xcframework (clones + patches canonical dmd_core, needs rust iOS targets)
libdmd/build-xcframework.sh
```

```bash
# Build the ipnx iPad app for the simulator
cd app && xcodebuild -project Edition.xcodeproj -scheme Edition -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

```bash
# Build the ipnx Mac app (same sources, second target)
cd app && xcodebuild -project Edition.xcodeproj -scheme EditionMac -destination 'platform=macOS,arch=arm64' build
```

```bash
# Desktop round-trip of the full app protocol against the library (boot → suspend/save → restore)
bash work/verify-libcli.sh
```

The **Phase A0 desktop spike** commands are in [docs/spike-a0.md](docs/spike-a0.md)
(build SIMH `vax780`, produce `v8.disk` via timnewsham/myv8, connect a 5620/Blit terminal
emulator, run `mux`), all inside the gitignored `work/` directory.

Proven workbench commands (from the A0 spike; run from repo root):

```bash
# Boot V8 to multiuser and hold (console stays on this terminal)
cd work/myv8 && PATH="$PWD/../simh312/sim/BIN:$PATH" expect ../boot-hold.exp
```

```bash
# Prove a DZ login + exercise the system (separate shell, after boot)
python3 work/dztalk.py
```

Toolchains:
- App shell (real since A1): Swift/SwiftUI, `app/Edition.xcodeproj` — hand-authored,
  synchronized-folder format. **Code signing: always the Hello Tham Pty. Ltd. org team —
  `DEVELOPMENT_TEAM = RPL5R637DS` — never the personal team** (set at creation, verified
  2026-08-09). Two targets (`Edition` iPad, `EditionMac`) share the one `Edition/`
  folder; platform differences go behind `#if os(macOS)` and the
  `PlatformViewRepresentable` shim in `Platform.swift`, never a forked file.
- VAX core (real since A1): open-simh as a C static library — `libsimh/` (CMake →
  xcframework; scp's `main` renamed via `-Dmain` only; no async/network/SDL).
- Terminal core (real since A2): dmd_core as a Rust `aarch64-apple-ios` staticlib via
  its **built-in** C FFI — `libdmd/` (never wrap it in another crate: the unmangled
  exports collide; extend via logged patch, e.g. the A2 BREAK exports). Both
  xcframeworks' Swift modules are declared in `app/Edition/Modules/module.modulemap` —
  two frameworks cannot each bundle a modulemap (flat `include/` collision).

## Architecture (the big picture)

Two interpreters and a wire, mirroring the real 1985 topology (smart terminal ↔ serial line
↔ headless host):

- **SIMH thread** boots the disk image; its DZ11 line 0 is the wire's host end
  (`set noasync` mandatory).
- **dmd thread** runs the WE32100 terminal; its DUART port A is the wire's other end;
  its 800×1024×1 framebuffer is what the user sees.
- **Serial transport** is a localhost telnet loopback (zero-patch, proven shape). An
  in-process byte queue was planned but proved unnecessary: the throttles were the DUART
  divisor and SIMH's guest-speed-controlled DZ, both raised by config/patch, so the
  transport was never the bottleneck. `mux` downloads in ~15 s.
- The shell is **edition-agnostic**: machines = SIMH simulator + disk image + wiring. V10
  arrives later as just another image (Track B builds it *inside* the running V8 — V10 has
  never been booted by anyone; that restoration is half the project).

Full spec: [docs/architecture.md](docs/architecture.md) · Phases:
[docs/roadmap.md](docs/roadmap.md) · V10 plan: [docs/v10-restoration.md](docs/v10-restoration.md)

## Decisions (settled — don't relitigate without new evidence)

- Full-system emulation, native code. **Not** WASM, **not** iSH-style user-mode.
- End goal is V10, staged through V8. **V9 is skipped** (surviving V9 = Sun-3 port, no VAX
  kernel code).
- Free app, self-contained, no ads/IAP — required by the 2017 non-commercial covenant;
  **"UNIX" must not appear in the app name** (Open Group trademark) — the app is
  **ipnx** ("iPad is not Unix"; the name itself carries no mark). Binding rules:
  [docs/licensing.md](docs/licensing.md).

## Gotchas (each cost the community real debugging time)

- Naming trap: in Research tapes, `jerq/` = DMD 5620 (WE32100); `blit/` = original 68000
  Blit. The "current" V8/V10 terminal is the 5620.
- dmd_core must run firmware **8;7;3** for Research Unix `mux` (default 8;7;5 fails).
- SIMH newer than 3.9 needs `set noasync` or V8 corrupts RP06 I/O (simh issue #425).
- V8's getty sends the first `login:` with **mark parity** (bit 7 set) — byte-matchers must
  strip the high bit until after login.
- `mux` is not on root's PATH — invoke `/usr/jerq/bin/mux` (same for `jim`).
- mux's B3 menu pops centered on the cursor: park the cursor mid-screen first or the
  menu clips at the screen edge and the selection is lost. After selecting New, the
  sweep-corner cursor is the confirmation that the B3 sweep is armed.
- **Idling needs `set cpu idle=4.1BSD` *and* three `UNIT_IDLE` flags upstream forgot**
  (`libsimh/patches/apply.sh`). `sim_idle()` sleeps only when the unit at the *head* of
  the event queue has `UNIT_IDLE`, so one periodic unit without it pins a core: the
  telnet-console poll unit (1 s), `clk_unit`/TODR and `tmr_unit`/TMR (10 ms each). Fix
  them together — unblocking one only promotes the next to the head. Stock `vax780`
  burns ~97% of a core at an idle `login:`; patched, the app's SIMH thread sits at
  **2.7%**, with V8's clock still exact (90 guest seconds per 90.1 host seconds). The
  flags survive `save`/`restore` because `UNIT_IDLE` is not in `UNIT_RFLAGS`, but
  `cpu_idle_mask` does *not*, so `resume.conf` must re-issue `set cpu idle=`.
  Diagnose with `tools/idle-probe.py --why`, which histograms `sim_idle()`'s own
  "Can't idle: <unit>" messages; measure the app with `tools/app-cpu.sh`.
- The **dmd (5620) thread does not idle at all** and is now the app's whole CPU cost
  (63.5% at the default 2× = 20 MHz; dmd_core tops out near 28.5 MHz on an M-series
  Mac). `libdmd/test/idle-scope.c` shows a settled terminal spends ~86% of its time in
  a 54-byte PC window (0x5354–0x5389) and `dmd_get_pc()` is exported, so the same trick
  is available from Swift — not done yet.
- dmd_core's GitHub HEAD embeds only the **8;7;5** ROM, which V8's `32ld` download crashes
  (unimplemented `MOVTRW` + unaligned access in the WE32100 core, ~30 KB in) — this is the
  mechanism behind the documented "use firmware 8;7;3" requirement. dmd_core's DUART is
  *one* serial pacer (wall-clock per-char at programmed baud; fresh NVRAM = 1200 baud) —
  A2 wrongly concluded it was the only one; see the DZ-throttle bullet below.
  Details: docs/spike-a0-results.md, Session 2.
- The **canonical** dmd repos are on git.loomcom.com (Gitea; HTML bot-walled, `git clone` +
  API work) — GitHub mirrors are stale. Canonical dmd_core 0.7.1: `reset(1)` = 8;7;3.
  Three emulator gotchas cost this project a day: the 8;7;3 self-test needs BREAK delivered
  as a 0x00 byte (patched); the kb FIFO drops keys typed faster than ~ms (type at 100 ms);
  the DUART needs a ~real-time-paced CPU (~10 MHz), never flat-out. Patches:
  tools/dmdbridge/patches/.
- **The DZ line is throttled to the guest's baud rate.** `pdp11_dz.c` calls
  `tmxr_set_port_speed_control`, so every LPR write by V8's tty driver makes SIMH
  rate-limit the socket to whatever V8 asks for — 9600, measured as ~950 B/s with an
  empty injector backlog. Fix without patching: `att dz -m Speed=*32,127.0.0.1:PORT`.
  tmxr keeps the bps *factor* separately (only reset for real serial ports) so it
  survives reprogramming, and its attach parser deliberately allows a bare factor for
  guest-speed-controlled devices. Measured: sustained rx 950 -> ~4,300 B/s and the mux
  download ~100 s -> **~15 s** (55,473 B on the wire, matching the documented 55,156 B
  payload plus overhead — so the transfer is complete, not truncated). This **corrects
  A2**: pacing was never "in the DUART" alone — there were two 9600 throttles in series
  (DUART at ÷8 = 9600-equivalent, and this), which is why changing only one gave 1.7x.
  Diagnose with queue depth, not throughput: a permanently empty inbound queue means the
  bottleneck is upstream, and no downstream tuning can help.
- The infamous "55K download stall" was **not a stall**: 32ld sends only muxterm's
  text+data (**50,324 B** per its COFF header; entry 0x71e85c), not the 144,603-B file —
  the rest is symbol table. ~55K on the wire = complete download + idle mux desktop.
  Measure protocol progress against *loadable* size, never `ls -l`.
- The 5620 mouse registers (0x400000 y, 0x400002 x) are free-running counters; muxterm
  integrates sample deltas with **y counting up the screen** from a (0,0) cursor. Feed
  deltas, not absolute positions (see the bridge's mouse model).
- V10's `/usr/include` is a 1997 reconstruction of a 1995 tree — expect header/source skew
  during Track B; log every reconciliation as a patch.
- The Alhadis GitHub mirrors are incomplete (v10 mirror omits `630/`) — TUHS tarballs are
  the source of truth.
- SIMH channel semantics differ per path: ^E stops the sim **only** on a local-tty
  console; it's an inert data byte on a telnet console, and a suspend-to-command-mode on
  the remote console; scp's `sim>` lives on stdin, never on the console socket. Read the
  table in [docs/a1-notes.md](docs/a1-notes.md) before touching console/control plumbing.
- The SIMH remote-console dialect (the app's control channel): never reply to telnet IAC
  (the session goes permanently silent), lead every command with a sacrificial space
  (multi-command-mode typeahead loses its first byte), and prove completion with
  output-anchored `echo` markers (`"\nMARKER"`) — the `sim>` prompt prints lazily.
- In-app SIMH listeners must rotate ports per launch: tmxr binds without `SO_REUSEADDR`,
  so a quick relaunch hits the previous incarnation's TIME_WAIT pairs ("bind error 48")
  and scp runs with **no listeners**; a failed console re-attach also leaves the restore
  path one `cont` from a NULL-deref segfault (`_tmxr_activate_delay`) — `save` persists
  `UNIT_TM_POLL` in the unit's dynflags, but never the `uptr->tmxr` pointer that only a
  *successful* `tmxr_attach` sets, and restore reports success either way (filed upstream
  as [open-simh/simh#576](https://github.com/open-simh/simh/issues/576)). Don't "fix" the
  crash with `reset tti` — that zeroes the guest-configured CSR and V8 stops seeing
  console input.
- A `state.sav` is only disk-consistent while the machine stays paused — the app deletes
  it the moment the machine runs again; unclean kills cold-boot and V8's autoboot fsck
  self-heals (with a telnet console V8 autoboots straight to `login:`, no single-user
  stop).
- NWConnection to loopback parks in `.waiting(ECONNREFUSED)` forever when it races the
  listener (no reachability change is coming) — treat `.waiting` as a failed attempt and
  redial fresh.
- `libsimh` compiles without `SIM_ASYNCH_IO`, so `set noasynch` errors ("Command not
  allowed") and is unnecessary — the V8-safe synchronous mode is a build-time guarantee.
  **The desktop `work/opensimh/BIN/vax780` is the opposite**: it *is* built with async
  I/O, so every hand-written config must open with `set noasynch` (verify with
  `show asynch`). Omitting it looks like a hardware fault, not a config error —
  `hp06: hard error er1=5<RMR,ILF>` on both drives and silent file loss — and only
  once two units have overlapping transfers, so light I/O hides it entirely.
- macOS gotchas (A3): our preferences type `Settings` **shadows SwiftUI's `Settings`
  scene** — write `SwiftUI.Settings { … }` or the scene silently resolves to the wrong
  initialiser. Exec'ing the app binary directly gets **no WindowServer connection** (it
  boots V8 and binds sockets but never shows a window) — test with
  `open -n Edition.app --stdout <log>`. The Mac deliberately suspends **only on quit**
  (via `applicationShouldTerminate` + `.terminateLater`, since the save handshake is
  async), never on hide: nothing reclaims the CPU there and a long build should keep
  running.
- Integer ("Crisp") screen scaling must be allowed to fail: forcing a minimum factor of
  1 makes small windows request a screen *larger* than the space available. Below 1:1
  there is no integral scale — fall back to filling.
- **Host↔guest file transfer (Track B): one role per disk unit, 512-byte raw transfers.**
  Full recipe in [docs/media-exchange.md](docs/media-exchange.md). SIMH has no
  host-directory passthrough of any kind, so everything goes through emulated media.
  The **tape route is dead**: V8's `ht` driver does a 16-bit read of a Massbus register
  that `mba_rdreg` rejects (tolerated only in SIMH's VAX-750 build), panicking the
  kernel with `panic: mchk`; classic 3.12-5 has the same guard, and `installV8` only
  avoids it by running under 4.1BSD. Use `rp1` as a **raw-only courier**
  (`/dev/rrp1a` = `c 4 8`) with the work area on `/usr` — mixing raw and buffered I/O
  on one `hp` unit corrupts the filesystem *after* everything appears to work. Raw
  transfers **must be 512 bytes**: 4 KB+ writes fail with `er1=5<RMR,ILF>` after one
  record, and `tar`'s own blocking-20 write path silently drops everything past the
  first 10,240 bytes while still exiting 0. **The 512-byte half of this is now
  suspect**: `er1=5<RMR,ILF>` turned out to be the signature of a missing
  `set noasynch` during N0, and `work/rawwrite.exp` never set it either. Re-test
  before relying on the limit; the `tar` blocking trap is independent and real.
- The golden image shipped **no `lost+found` on either filesystem**, so an autoboot
  `fsck` needing to reconnect an orphaned inode aborted to a single-user shell instead
  of `login:` ("Automatic reboot failed... help!") — reachable in the app whenever a
  hard kill interrupts a compile. Fixed 2026-08-09 via `/etc/mklost+found` on `/` and
  `/usr`; `work/fix-lostfound.exp` reapplies it if the image is ever rebuilt.

## Conventions

- Big binaries (disk images, tapes, tarballs) never enter git — rebuild locally per the
  runbook (gitignored: `*.disk`, `*.tap`, `work/`).
- **VERIFY** marks a documented step assembled from research but not yet executed here.
  Resolving one means executing it and correcting the doc, *or* recording that the step was
  superseded — never silently deleting the marker. None remain open
  ([docs/spike-a0.md](docs/spike-a0.md)'s last four were closed 2026-08-09).
- Track B keeps pristine upstream sources separate from our patches; every fix is a logged
  patch with a rationale, plus a dated lab-notebook entry (`docs/v10-log/`).
- Cite primary sources (TUHS preferred) for factual claims in docs.
- Project automation: use `/verify-step` to resolve runbook VERIFY markers and `/v10-log`
  for Track B lab-notebook entries. Hooks (`.claude/settings.json` + `tools/*.sh`) enforce
  the no-binaries rule and check markdown links on edit.

## Status / next step

**Track A is complete** (A1–A3, all 2026-08-09) — see
[docs/a1-notes.md](docs/a1-notes.md), [docs/a2-notes.md](docs/a2-notes.md) and
[docs/a3-notes.md](docs/a3-notes.md). The app boots V8 to `login:` in ~25–30 s with
save/restore instant-on; the 5620 delivers the full Blit experience on iPad — DZ login,
`mux` download (~100 s at the ÷8 DUART turbo), B3 menu → sweep → layer with a root
shell, `jim` in a layer; A3 added settings (phosphor, "Crisp" scaling — the moiré fix,
pointer speed), 5620 NVRAM persistence, "Restart terminal" (the fix for a restored mux
session with no muxterm), staged disk import/export/reset, a licences screen and App
Store prep — plus a **native Mac app** sharing every line of app code. Evidence:
`work/shots-a1-final/`, `work/shots-a2/`, `work/shots-a3/`.

**Track B's ingest path is settled** (2026-08-09, phase B0): host↔guest file
transfer is proven end to end — [docs/media-exchange.md](docs/media-exchange.md),
`tools/tapeio.py`, `work/mediatest.sh` — including a VAX binary compiled inside V8 and
carried back out. The golden image's missing `lost+found` was fixed at the same time.

**B0.5 (the N track) is under way** — plan in
[docs/networking-plan.md](docs/networking-plan.md), results in
[docs/n-track-notes.md](docs/n-track-notes.md). **N0 is done** (2026-08-09):
`work/myv8/rp07v8.golden` is a 516 MB RP07 that boots on its own with `/usr` at
459,905 KB / 408,364 free, built by `work/rp07mig.sh`. The app still ships the RP06.
The courier moves 8.1 MB a load against a 243 MB V10 tree, so before B1 the plan is a
**516 MB RP07 disk** (SIMH and V8 agree on the geometry exactly; `/usr` on partition
`f` = 475 MB), **real TCP/IP** via a new SIMH model of the Interlan NI1010 that V8
already has a driver for (SIMH offers only DEUNA, which V8 cannot drive) against SIMH's
already-compiled-in **NAT/SLiRP** — sandbox-safe, so it works on iOS too — and then
Weinberger's **netfs over TCP**, whose in-kernel client is already `standard` in every
V8 kernel and whose mount takes any file descriptor.

Next: **submit** — the remaining steps need the Apple account and a final name
decision, all listed in [docs/app-store.md](docs/app-store.md) — and **Track B**,
whose ingest path and source are both now in place — the TUHS tarballs are in `work/`, and B1 needs only 14.87 MB of the 243 MB tree.
Not yet exercised: `mux`/`jim` driven by the Mac's real mouse, and "Crisp" scaling
compared visually. Update the checkboxes in [docs/roadmap.md](docs/roadmap.md)
as phases complete.
