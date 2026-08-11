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
cd app && xcodebuild -project ipnx.xcodeproj -scheme ipnx -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

```bash
# Build the ipnx Mac app (same sources, second target)
cd app && xcodebuild -project ipnx.xcodeproj -scheme ipnxMac -destination 'platform=macOS,arch=arm64' build
```

```bash
# Desktop round-trip of the full app protocol against the library (boot → suspend/save → restore)
bash work/verify-libcli.sh
```

The **Phase A0 desktop spike** commands are in [docs/spike-a0.md](docs/spike-a0.md)
(build SIMH `vax780`, produce `v8.disk` via timnewsham/myv8, connect a 5620/Blit terminal
emulator, run `mux`), all inside the gitignored `work/` directory.

The A0 workbench ran on a local **SIMH 3.12** build at `work/simh312/`, which was
deleted in the 2026-08-12 cleanup. `work/boot-hold.exp` and `work/dztalk.py` survive
but **must not simply be repointed at `work/opensimh/BIN/vax780`**: that build has
async I/O compiled in and `boot-hold.exp` predates the rule, so it opens without
`set noasynch` and walks into the corruption trap documented below
(`hp06: hard error er1=5<RMR,ILF>` and silent file loss). The current equivalents,
which do set it, are:

```bash
# Boot an image alone and check it end to end (13 assertions, then a clean halt)
IMG=rp07new tools/boot-newdisk.sh
```

```bash
# Content-only verification of the built disk, no VAX required (about a second)
tools/verify-golden.sh
```

**What in `work/` is load-bearing**, since the rest is scratch and was cleaned out:
`rp07new` (the built golden — the RP06 variant `rp06new` holds the *same system* in
a different container and nothing consumes it, so it is not kept; one stage-8 run
rebuilds it, `tools/drive-stages48.sh "" "" 8 8 rp07new rp06`), `rp06build` (stages 1–3 —
`drive-stages48.sh` refuses to start without it and rebuilding costs ~50 min),
`rp07v8.net` (the build machine itself, plus `.net.bak`, its only rollback),
`rp06v8.golden` (the TUHS reference — still the default `--tuhs` for
`retire-check.py`, `compare-built.py` and `verify-golden.sh`), the `*.tap.gz`
archives and `work/v8.tar`/`v8jerq.tar` (what `v8-import.py --verify` reads).
Tools for finished phases still name images that are gone — `drive-widemux.sh`
wants `rp06v8.wide`, `rp07mig.sh` wants `rp06v8.mig`, `n3-ilkernel.sh` wants
`rp07v8.golden`, `idle-probe.py` wants `idle-probe.disk`. Each fails with a plain
"no such file"; their outputs are all committed, so recreate the image only if you
genuinely need to re-run that experiment.

Toolchains:
- App shell (real since A1): Swift/SwiftUI, `app/ipnx.xcodeproj` — hand-authored,
  synchronized-folder format. **Code signing: always the Hello Tham Pty. Ltd. org team —
  `DEVELOPMENT_TEAM = RPL5R637DS` — never the personal team** (set at creation, verified
  2026-08-09). Two targets (`ipnx` iPad, `ipnxMac`) share the one `app/ipnx/`
  folder; platform differences go behind `#if os(macOS)` and the
  `PlatformViewRepresentable` shim in `Platform.swift`, never a forked file.
  Everything was named **Edition** until 2026-08-10 — project, targets, schemes,
  folder, `EditionApp` — and is now `ipnx`/`ipnxMac`/`IpnxApp`. The product was
  always `ipnx.app`; only the scaffolding lagged.
- VAX core (real since A1): open-simh as a C static library — `libsimh/` (CMake →
  xcframework; scp's `main` renamed via `-Dmain` only; no async/network/SDL).
- Terminal core (real since A2): dmd_core as a Rust `aarch64-apple-ios` staticlib via
  its **built-in** C FFI — `libdmd/` (never wrap it in another crate: the unmangled
  exports collide; extend via logged patch, e.g. the A2 BREAK exports). Both
  xcframeworks' Swift modules are declared in `app/ipnx/Modules/module.modulemap` —
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

## The one rule that outranks everything else

**NEVER LEAVE A MACHINE INCONSISTENT. A machine that was not cleanly halted has
a corrupted disk — assume it, do not hope otherwise.**

The only correct way to stop a running guest is a clean halt:

```
cd /; sync; sync        # userland flush
/etc/halt               # RB_HALT: boot() calls update(), waits for the I/O,
                        # then spins at IPL 31 -- SIMH reports "Infinite loop"
```

Wait for that marker, *then* `quit`. Never `pkill` a `vax780`, never kill the
app, never quit an emulator with the guest still running, and never delete a
`state.sav` while keeping the disk it belongs to (snapshot and disk are
consistent only as a **pair** — keep both or discard both).

**`fsck` is not a recovery tool.** It restores metadata *consistency* so the
filesystem will mount; it does not restore *data*. Blocks that were in core and
never written are gone, and several of its repairs destroy data by design —
truncating a file to a provable length, clearing an unreconcilable inode,
dumping a directory into `lost+found` under numeric names. A clean `fsck` pass
is not evidence that anything survived. Real data loss from unhalted Research
Unix machines is well attested; treat every uncleanly-stopped disk as damaged
until a **hash against a known-good artefact** says otherwise. That is proof;
"it booted fine" is not.

If a disk must be recovered, **copy the damaged image first**. `fsck` gets one
attempt at the original and its repairs cannot be undone.

This is why `image/ipnx-v8-rp07.img.xz` is in git: it turns "is this disk
intact?" into a three-second `shasum` instead of a judgement call.

## Gotchas (each cost the community real debugging time)

- Naming trap: in Research tapes, `jerq/` = DMD 5620 (WE32100); `blit/` = original 68000
  Blit. The "current" V8/V10 terminal is the 5620.
- dmd_core must run firmware **8;7;3** for Research Unix `mux` (default 8;7;5 fails).
- SIMH newer than 3.9 needs `set noasync` or V8 corrupts RP06 I/O (simh issue #425).
- V8's getty sends the first `login:` with **mark parity** (bit 7 set) — byte-matchers must
  strip the high bit until after login.
- `mux` is not on root's PATH in a *stock* V8 — invoke `/usr/jerq/bin/mux` (same for
  `jim`). The shipped golden image no longer has this problem: `work/fix-identity.exp`
  gives root a `/.profile` with `/usr/games` and `/usr/jerq/bin` on PATH, `TERM=dmd`
  (V8 ships **no** `/.profile`, `/.login` or `/etc/profile` at all, which is why `vi`
  used to die — `TERM` was simply unset), `kill ^U` and `intr ^C`. Leave `erase` at
  V8's own **^H**: the app maps a Mac/iPad Delete key to 0x08, so ^H is what that key
  sends. The machine's name is `/etc/whoami` and nowhere else — V8 has no
  `hostname(1)`, no `uname(1)`, and `/etc/rc` never sets one.
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
- **5620 screen size: widen freely, never shorten below 983 px.** Boot stock and call
  `dmd_resize_screen()` on the running terminal — it rewrites the one 20-byte `Bitmap`
  (`display`, ROM `0x9ca8`, AT&T's own `bootrom.s`: *"The display bitmap in rom at
  last!"*) — it is `.data` linked into ROM and never copied down, so **there is no RAM
  shadow to chase**. RAM is never reallocated: the emulator always carries 1 MB + a
  512 KB reserve at `0x800000`, which the firmware structurally cannot reach (its
  `maxaddr` table at `0xa37c` has exactly two entries, ceiling `0x00800000`). But the
  text grid is *compile-time* — `XCMAX`/`YCMAX` from `setup.h` fold to 87/69 — so a
  resized screen alone keeps 88 columns; `dmd_set_columns()` rewrites the 24 byte
  immediates (`6F 57`/`6F 58`) that hold it, **ceiling 127** because the operand is a
  sign-extended byte. It scrolls at pixel row 969, so a screen under 983 tall silently
  collapses its text. `mux` layers are exempt: `windowproc.c` recomputes the grid per
  layer from the layer rect — **and so is everything running *in* a layer**.
  `jerq/include/mux.h` defines `display` as `(*Jdisplayp)`, a pointer the layer
  system fills in at runtime, so `jim` and the rest of `/usr/jerq/mbin` follow a
  resized screen for free and have nothing to patch (`3nm` shows jim exports
  `Jdisplayp`, a `*struct-Bitmap`, and no `display` at all). **`muxterm` is the sole
  exception** — it *is* the layer system, owns the screen, and carries a real 20-byte
  Bitmap in `.data` at file offset 50512. `tools/widen-jerq.exp` copies it to
  `muxterm.w` with **`base` 0x700000→0x800000**, stride 25→36 and `corner.x`
  800→1152, and `/usr/jerq/bin/wmux` selects it through `$MUXTERM`, which `mux`
  already honours. **`base` is the field that matters, and it fails silently**: a
  resized screen moves the framebuffer to `0x800000`, so stock muxterm on a wide
  screen downloads all 55,156 bytes, runs, and draws into the vacated `0x700000` —
  presenting as a hang with the ROM's text still on screen. **On a wide screen
  `mux` must be `wmux`**, and never patch the stock binaries: `muxterm.w`
  hardcodes `0x800000` and is wrong at the Original preset. Proven end to end by
  `tools/drive-widemux.sh` — rightmost lit pixel x=1151 of 1152, against x=648 for
  stock. Do **not** chase the fault it throws when `base` is wrong: it is always
  `RAM_BASE + ram_visible()`, which looks like a decode-window bug and is not.
  **Three things will wedge or corrupt the power-on
  self-test, all found the hard way**: it blanks screen memory at a hardcoded
  `0x700000` (so it must run at 800×1024 — resize *after*); it stalls in `t_kbd()`
  under "WAITING FOR KEYBOARD STATUS" with a *still screen*, so wait for the idle PC
  window `0x5354`–`0x5389`, never for a quiet framebuffer; and it sizes RAM by probing,
  so the reserve above 1 MB must stay undecoded (`ram_visible()`) or it indexes past
  `maxaddr` and reads `0x0000000a` as its memory limit. Full evidence and the
  measurements: [docs/screen-size.md](docs/screen-size.md); harness
  `libdmd/test/resize-scope.c`.
- AT&T published the 5620 ROM **source** (GPL, Dave Dykstra, 1994 —
  [dmdmtg/5620rom](https://github.com/dmdmtg/5620rom); its README names `lsys.8;7;3`,
  the firmware we run). It answers firmware questions faster than any experiment:
  `src/xt/layersys/rdpatch/lsys.nm.1.1` is the **symbol table for `lsym.8;7;3`** with
  ROM addresses. Read it, don't link it — the boundary is in
  [docs/licensing.md](docs/licensing.md).
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
- **A mux connection dropped across save/restore is by design; only the segfault was
  ever a bug.** Upstream's answer on #576 (markpizz, 2026-08-11): a device is restorable
  only to the extent its whole state lives in its `REG`s, and TMXR's per-line connection
  state lives in the simulator's *host* memory, which no `REG` describes — the most
  `restore` can do is replay the ATTACH string. So `restore -D -Q` plus manual attach is
  **the correct way to use the mechanism**, not a workaround. The general rule is worth
  more than the case: state held inside the *guest* survives a snapshot (it is just RAM),
  state held inside the *simulator* does not. Hence upstream's escape hatch — reach the
  guest over TCP and let its own stack own the session, which V8 can do (it ships
  `usr/src/cmd/inet/etc/telnetd.c`) — and hence why it is no use here: the far end of our
  DZ is a second emulated CPU in the same process, so we checkpoint **both** machines and
  keep the wire stateless.
- A `state.sav` is only disk-consistent while the machine stays paused — the app deletes
  it the moment the machine runs again; unclean kills cold-boot and V8's autoboot fsck
  self-heals (with a telnet console V8 autoboots straight to `login:`, no single-user
  stop).
- **`restore` must be `restore -D -Q`, with every unit attached by hand.** A plain
  `restore` re-attaches each saved unit in device order to the filename in the snapshot
  — and for a mux that "filename" is the *previous launch's port*, which the terminal
  connection that was live a moment ago still holds in TIME_WAIT (tmxr binds without
  `SO_REUSEADDR`). The bind fails. That alone is survivable; scp.c's loop is not: it is
  gated on `r == SCPE_OK` and never resets `r`, so the **first** failure silently skips
  **every remaining attach** — and the DZ precedes RP0 in device order, so the machine
  comes back **with no disk**. Still true of open-simh at `scp.c:9065` (verified
  2026-08-11); **fixed in `simh/simh`**, which attempts every attach and reports each
  failure as it happens — the one concrete cherry-pick target from that codebase. The console still answers (the kernel is in memory) and
  the shell still echoes `# ` from memory, so it presents as a terminal that has gone
  quiet, which is nothing like the truth: `exec` SIGKILLs (`Killed`), `login` never
  reaches a shell, getty is stuck. Proof either way:
  `tools/restore-attach-probe.py` holds the saved port and prints `RP0 ... not attached`
  vs `attached to v8.disk`. Attach the **disk before** the restore and the **DZ after**
  it — that order matters, because `dz_attach`'s `lp->rcve`/DTR fixup only runs when
  CSR_MSE is already set, i.e. against *restored* registers.
- **A restored session has nothing left to say, so the terminal must ask — and it must
  ask *late*.** getty prints its banner and `login:` exactly once, when it starts, then
  blocks in `getname()`; a logged-in shell prints nothing unasked at all. A cold boot
  therefore gets a prompt for free and a restore never does, so the terminal's own CR
  nudge is the *only* thing that makes a resumed far end speak. Three ways to get that
  wrong, all of which shipped at some point and all of which look identical to the user
  (a picture with a dead keyboard): sending it only when no saved screen was restored;
  skipping it because the screen was already the right size, so the whole
  post-self-test block was conditional on a resize; and keying it to a raw step count —
  20M steps is ~1.0 s at the default 2× clock, but the 5620's self-test does not finish
  until ~1.2 s, so V8 answered into a terminal that was still testing itself. Gate every
  start-of-session action on the firmware reaching its idle PC window, never on a timer
  and never on the resize.
- NWConnection to loopback parks in `.waiting(ECONNREFUSED)` forever when it races the
  listener (no reachability change is coming) — treat `.waiting` as a failed attempt and
  redial fresh.
- **Every DZ line gets its own listen port; never one mux-wide listener.**
  `tmxr_poll_conn` hands a connection on the shared port to the next *free* line, so the
  tty a session lands on would depend on the order tabs were opened — and `/.profile`
  picks TERM from `` `tty` ``, so connection order would decide what terminal V8 thinks
  you are. `att dz Line=N,...` per line makes it a property of the port dialled
  (`Machine.dzPort(_:)`); `sim_tmxr.c` supports this explicitly and `tmxr_attach_ex` sets
  the polling unit on whichever attach comes first, so no mux-wide attach is needed.
  `-m` rides the **first** attach only — modem control is device-wide (`dz_mctl`).
- **`Machine.start()` must guard on its own flag, not on `phase`.** It only *schedules*
  `bringUp()`, so two windows appearing in one runloop turn both saw `.idle` and both
  spawned a SIMH thread — two VAX-11/780s in one process, binding the same ports and
  attached to the same `v8.disk`. It crashed immediately, which was the lucky outcome.
- The app's UI is **nine sessions in windows grouped by terminal shape** — forced by the
  missing `TIOCGWINSZ`, not chosen. A session owns its `TerminalView` (scrollback lives
  there, so SwiftUI owning it makes a tab switch a silent `clear`), the console session
  starts before the VAX so the boot transcript has somewhere to land, and a window holding
  one terminal hangs up its line when closed. Full record, including the traps:
  [docs/ui-redesign.md](docs/ui-redesign.md).
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
- **V8's libc is more ANSI than its reputation; its compiler is not.** Measured with
  `tools/v8-libc-probe.exp` (`nm /lib/libc.a` on a scratch boot): `strchr`, `strrchr`,
  `strpbrk`, `strspn`, `strcspn`, `strtok`, `memcpy`, `memcmp`, `memset`, `qsort` and
  `/usr/include/string.h` are all **present**; `strtol`, `strtod`, `strstr`, `memmove`,
  `atexit`, `vprintf`, `vfprintf` and — counter-intuitively — **`bcopy`/`bzero`** are
  not. So do *not* "port backwards" to `index`/`bcopy`: that is the wrong direction and
  `bcopy` is the one that will not link. The genuine wall is `/bin/cc` (1985), which
  rejects a prototype outright (`expected a NAME in list` / `saw TYPE`); there is no
  `stdlib.h`/`stddef.h`/`unistd.h`, and variadics use `varargs.h`. **V10 differs on both
  counts** — its `libc/gen` adds the missing seven, and its tree ships `cmd/lcc` (ANSI C,
  with a `gen2/vax-v9` back end and an `lccmkfile` in `sys/inet`) plus `cmd/gcc`.
- **Never write a sockets layer for Research Unix — it already has TCP/IP.** V8 carries
  `/usr/include/sys/inet/` (`in.h`, `ip.h`, `tcp.h`, `tcp_user.h`, `udp_user.h`,
  `mbuf.h`, its own `socket.h`, …) and `/usr/lib/libin.a`; V10 has the sources in
  `sys/inet/` — including `tcp_ld.c`/`ip_ld.c`/`udp_ld.c`, i.e. the stack is built as
  **stream line disciplines** — with the userland in `ipc/internet/` (`routed`, `arp`,
  `netstat`, `gettable`/`htable`, `tcpconfig`, `interlan.c`) and `ipc/libin/`. The API is
  `open("/dev/tcpNN")` then a `struct tcpuser` written to the fd — Plan 9's `/net` model,
  predating Plan 9. N3 already drove it end to end.
- **Three things stand between you and a TCP connection out of V8**, none of them
  obvious. `tcpconfig` must push the TCP line discipline onto `/dev/ip6`
  (`./tcpconfig /dev/ip6 &`, exactly as N3 pushed UDP onto `/dev/ip17`) — without it
  `open("/dev/tcp01")` succeeds, the `tcpuser` write succeeds, and the connect blocks
  **forever with no diagnostic**, because there is nothing underneath the device. The
  minor must be **odd**: `tcp_device.c` refuses an even one whose socket is not already
  active (`if((dev&01) == 0 && (so->so_state&SS_ACTIVE) == 0) return(0);`) because even
  minors are the accept side — libin's `tcp_sock()` encodes this as
  `for(n = 01; n < 100; n += 2)` and never says why. And the guest reaches the host at
  **10.0.2.2 = 127.0.0.1**: SLiRP rewrites every address inside its virtual network to
  the host's loopback (`tcp_fconnect`, *"It's an alias"*), so nothing needs forwarding
  and the same mechanism works inside the iOS sandbox.
- **netfs does not run over a byte stream unmodified, and "there is a stream driver"
  is not enough.** `usr/src/netfs/README` says so — *"you'll have to fix things"* — and
  four separate Datakit assumptions live in `istread()` (`sys/streamio.c`), which is
  netfs's *only* caller in the kernel and therefore safe to change: it discards the
  unread remainder of a block, returns short when a queue momentarily empties, waits
  forever for the `M_DELIM` a zero-length Datakit write used to produce (so every EOF
  hangs), and sits behind a stream head only **512 bytes** wide
  (`strdata`; `q->count` is bytes, and `tcpdisrv` only drains
  `while((q->next->flag&QFULL) == 0)`). Each is invisible until the one before it is
  fixed and each presents as the same bare `EIO`. `tools/drive-streamfix.sh` applies
  all of it. Also **`doupdat`'s clock skew is applied backwards upstream**
  (`x->ta += dtime` where dtime is `client - server`), harmless between machines whose
  clocks agree and a century of error against a V8 that thinks it is 1976 — subtract.
- **The NI1010 must CHAIN a received frame across receive buffers**, and getting that
  wrong looks like nothing at all. `ill.c` subtracts each buffer's programmed byte count
  from `ilr_length` and waits for another interrupt while any remains, supplying the next
  buffer from inside `ilrint` (`ILOUTSTANDING` is 1). `allocb()` caps a block at
  `rbsize[3]` = **1024 bytes**, so every frame larger than that needs two buffers — and
  our model delivered one and truncated, leaving the driver waiting for an interrupt that
  never came. Not a dropped packet: the receive path *stops*, and every layer above
  reports a timeout on something it never saw. It survived N2, N3 and most of N6 because
  nothing before netfs ever sent a frame over 1024 bytes. Fixed by `il_rxpump()` in
  `libsimh/patches/pdp11_il.c`. The general form is worth keeping: **a limit you measure
  through an emulator is a property of your emulator until proven otherwise** — this one
  spent a day written up as a netfs reply-size bound.
- **The `/n/src` share is LIVE, so never edit `v8/` while a build is running.**
  netfsd serves the working tree directly and the guest compiles straight off it, so
  an edit to `v8/mk/build1.sh` lands in a run already in flight — that is excellent for
  iteration and lethal for a two-hour build. Editing `build1.sh` mid-run once made
  stage 3 fail on all fourteen components (`Don't know how to make /b/tools/lib/as`),
  because the new script wanted a file that run's stage 1 had not been told to install.
  During a run, `docs/`, `CLAUDE.md` and brand-new files are safe; `v8/**` and the
  `tools/*.sh|*.exp` that bash is still reading are not.
- **A generated list read by 1985 shell must hold exactly one kind of thing.**
  `v8/mk/gen/destdirs.txt` briefly held both the directories stage 8 copies and
  the 458 exact installed paths `mkcarry.py` needs, told apart by a leading tab
  — and `builddisk.sh` reads it as `` for d in `grep -v '^#' destdirs.txt` ``,
  which splits on `IFS`. Tab is in `IFS`, so the marker was gone before the
  shell saw a word and `mkdir` got all 458: `/bin/sh`, `/bin/cc`, `/etc/init`
  and 96 more became empty **directories**, and the copy pass skipped each
  (it is guarded by `test -d $DEST/$d`, false for a file). Carried files were
  untouched, so `/bin` came out with its Bell Labs binaries intact and
  everything we build missing. The disk mounted, `fsck`'d clean, walked
  4,507 files — and stopped dead after autoconfig with the CPU idle, because
  there was no `/etc/init` to exec. Exact paths now live in
  `gen/destfiles.txt`; never merge them back.
  **And the check that should have caught it compared paths, not types**: a
  directory named `/bin/sh` satisfied a search for the file `/bin/sh`, so
  `retire-check.py` said UNIQUE 0 about an unbootable disk. It now compares
  the inode type — same image, 424 failures. *A containment check that ignores
  inode type is not a containment check.*
- **V8's `ld` is single-pass only without a valid `__.SYMDEF`** — archive member order
  is *not* unconditionally correctness. `getfile()` returns 1 (no table of contents),
  2 (current) or 3 (stale, because the archive's mtime is newer). Case 2 runs
  `while (ldrand()) continue;` under the tape's own comment *"you can get away with
  backward references when there is a table of contents!"*; cases 1 and 3 fall back to
  one sequential pass **and warn on stderr naming `ranlib`**. Consequence worth
  remembering: **any rule that copies an archive must re-`ranlib` it at the
  destination**, since `cp` bumps the mtime and that alone demotes a good archive to
  case 3. `lorder | tsort` on libc is defence against that, not a hard requirement.
- **Patching guest sources: replace whole functions, and rehearse on the host.**
  `streamio.c`'s `stread()` and `istread()` share whole lines verbatim, so
  context-anchored `ed` edits landed in the wrong one and the kernel failed to compile
  at a line number nowhere near the target — while a `sed -n '/^istread/,/^}/p'` of the
  result looked perfect, because it only printed the function that was fine. Anchor on
  the one unique line (`/^istread(ip, addr, count)/`), `.,/^}/d`, insert a known-good
  body; that is also idempotent and repairs prior damage. macOS `ed` runs the same
  script against `work/v8src/` in a second, against ten minutes for boot-and-build.
  Two traps in the guest's own tools: a backup called `streamio.c.orig` is **15
  characters** and fails with a bare `cp: cannot create` (14-byte names apply to *your*
  filenames too), and V8's `grep` is 1985's, so `\|` is a literal and a pattern using
  it matches nothing while looking like it asked a question — use `egrep`.
- The golden image shipped **no `lost+found` on either filesystem**, so an autoboot
  `fsck` needing to reconnect an orphaned inode aborted to a single-user shell instead
  of `login:` ("Automatic reboot failed... help!") — reachable in the app whenever a
  hard kill interrupts a compile. Fixed 2026-08-09 via `/etc/mklost+found` on `/` and
  `/usr`; `work/fix-lostfound.exp` reapplies it if the image is ever rebuilt.
  A run that *is* hard-killed still needs `tools/fsck-repair.exp`: the autoboot
  `fsck -p` can't answer its own questions, so it aborts to single-user and the machine
  never reaches `login:`. **In that one case** drop to `sim>` with ^E and quit, which
  avoids syncing the stale in-core root superblock back over `fsck`'s repair.
- **`/etc/halt` is the clean shutdown, and it works.** This file used to say the
  opposite, on the strength of one test with `/etc/reboot **-n**` — and `-n` is
  `RB_NOSYNC`, the single flag that skips the part you wanted. `boot()`
  (`usr/sys/sys/machdep.c:477`) does `update()`, prints `syncing disks... `, sleeps
  five `lbolt` ticks for the I/O to drain, prints `done`, and only *then* looks at
  `RB_HALT`: set, it prints `halting (in tight loop)` and spins at IPL 31; clear, it
  falls through to the console-subsystem reboot request the simulator does not
  implement, which is where *"Reboot request failed"* comes from. So the failure is
  the **reboot** branch and the sync has already happened either way — but
  `/etc/halt` (RB_HALT, `usr/src/cmd/halt.c`) is the one to use, because it stops
  deterministically and SIMH reports the spin as `Infinite loop`, an
  output-anchored marker. The proven sequence is `tools/boot-newdisk.exp`'s, and it
  passes on every run:

	sh "cd /; sync; sync"     ;# flush from userland first
	sendline "/etc/halt"      ;# boot() syncs again, then spins
	must "Infinite loop"      ;# SIMH sees the tight loop at IPL 31
	simh "quit"               ;# disk is clean; no snapshot needed

  **Suspending is not halting, and the app is right to do both differently.**
  `Machine.background()` sends ^E then `save state.sav`: it snapshots a *running*
  machine, and disk+snapshot are consistent only as a **pair**. That is the
  correct behaviour for **quit** and for iOS backgrounding — it is what buys
  instant-on, and the pair is safe as long as both are kept. Do not "fix" quit
  to halt instead. **Halting is user-initiated**: a menu action, or Reset.
  The failure mode to avoid is breaking the pair — deleting the snapshot and
  keeping the disk leaves neither state, and the disk has unflushed buffers.
  Two traps if you ever do wire a halt to a control: `/etc/halt` has to be typed
  at a shell, and the **console is read-only behind a lock with no shell on it**
  — the root login is `tty01`. Sending it to the console types into nothing,
  times out, and leaves the machine stopped with neither a snapshot nor a halt.
- **`hp` is block major 0 and char major 4** — `bdevsw` and `cdevsw` are unrelated
  tables and the indices don't match (`sys/dev/conf.c`). Block major 2 is `up`, a
  Unibus disk our machines don't have, so `mknod /dev/rp1g b 2 14` builds a node into
  `upstrategy` on absent hardware and `mount` dies on a wild pointer (`type 8 ... code
  xae50d144`, `panic: trap`). It cost two runs because `fsck` had just passed on that
  exact filesystem through the **raw** node, which was right — so a verified filesystem
  panicking on mount reads as a mount-table bug. **When raw works and block doesn't,
  suspect the majors first.** Minor is `drive<<3 | partition`, and `mknod` does **not**
  replace an existing node — it prints "File exists" and leaves the old one, so a bad
  node outlives the fix and the next run fails identically with a correct script.
- **RP06 partition `a` is 15,884 *sectors*, not blocks** (`hp6_sizes`, `sys/dev/hp.c`):
  `a` 15884, `b` 33440, `c` 340670 (whole disk), `g` 291280 from cyl 118. `mkfs` lays
  its free list down from the top, so an oversized filesystem fails on its *first*
  write ("write error: 39968") rather than partway. `mkfs n` gives `n/25` i-list blocks
  at 16 inodes each — state the inode count, since V8 fixes it at `mkfs` time and
  exhausting it presents as `mkdir` answering "cannot access .".
- **The guest's year comes from the root superblock, not the TODR.** `clkinit()`
  (`sys/sys/machdep.c`) takes only the position-within-year from the TODR; a superblock
  time under `5*SECYR` trips *"preposterous time in file system"*, whose fallback is the
  hardcoded `6*SECYR + 186*SECDAY` — mid-1976 exactly. So `attach TODR` fixes nothing.
  And `date(1)` can't set the year out of it: Berkeley's 1980 `date.c` does a bare
  `year += 1900` on two digits, so `26` means 1926. `v8/usr/src/cmd/date.c` now carries
  the 69/70 window; set the time with `-u` and UTC digits (`stime(2)` takes GMT), then
  `sync` so the superblock carries the year forward. Safe while running — `cron`'s
  `slp()` resynchronises on any delta over an hour.
- **Driving V8 over the console: markers, never prompts, and never a literal.** The tty
  echoes typed characters as they arrive and they interleave *into* whatever is
  printing, so a marker lands mid-line (`echC3-CASE-clean`) — which defeats a
  `^`-anchored grep exactly as reliably as an unanchored one matches the command's own
  echo. Spell every marker through a shell variable (`echo C3-CLOCK$OK`) so the echo
  carries `C3-CLOCK$OK` and only the result carries `C3-CLOCK-ok`. Keep every line under
  **`CANBSIZ` = 256** (`sys/h/param.h`) or the tty discards it silently, and never wrap a
  command that doesn't return (`/etc/halt`) in the marker helper. Dry-run an expect
  driver under `tclsh` with the interactive verbs stubbed: Tcl only reports a syntax
  error when it *reaches* the command, so a typo in the last block surfaces three hours
  in.
- **The tape's makefiles assume you build in the source directory.** Out-of-tree, off a
  read-only share, three things break and none are visible in-tree: a script invoked
  bare from beside the source (`:yyfix` — and `pcc1/pcc/makefile` writes `./:yyfix` for
  the same script, so the tape contradicts itself); a data file copied by relative name
  (`y.debug.sv`); and a generated file that exists only in the object directory
  (`rodata.c`, written by `:yyfix` as a *side effect* of making `cpy.c`, so it has no
  rule and no file on the share). Also **a command is not a path**: `$(CC)` = `cc` used
  as a *prerequisite* gives `Make: Don't know how to make cc` on every component at
  once, so `cc`/`yacc`/`lex` each need a second `*PATH` macro. Stage-0 tools live at
  `/bin/{cc,as,ld,ar,nm,size,make}`, `/lib/{cpp,ccom,c2,libc.a}`,
  `/usr/bin/{yacc,lex,ranlib}`, `/usr/lib/yaccpar` — there is no `/bin/strip`.
  `cc -B` is a bare `strspl`, so the prefix must name the passes' actual directory
  (`-B$(TOOLDIR)/lib/`), and `as`/`ld`/`crt0.o` have no `-B` equivalent at all.
- **Read a V8 disk from the host — don't boot one to look.** `tools/v8fs.py` walks a
  SIMH RP06/RP07 image directly (`ls`/`cat`/`stat`/`diff`, `IMAGE:PART`); every
  constant is quoted from the tree (`param.h`, `ino.h`, `dir.h`, `subr.c`'s `bmap`,
  `hp.c`'s tables in *sectors* with *cylinder* offsets). The one trap is
  `usr/src/libc/gen/l3tol.c`: on the **vax** a 3-byte disk address is little-endian
  with a zero high byte, and the **pdp11 arm of the same file** packs the identical
  bytes in a different order — pick wrong and the inode addresses look almost
  plausible. This turned "what is actually on that disk?" from a five-minute boot
  into a one-second question, which is what made the retirement audit possible at all.
- **netfs costs a round trip per file, not per byte** — measured at ~30 files/minute
  through the emulated VAX + Interlan + SLiRP. So it is excellent for a build reading
  sources on demand and hopeless for bulk installs: 2264 runtime files over the wire
  is ninety minutes, and the same set via `cpio` off a mounted disk is four seconds.
  Diagnose by counting *files*, never bytes.
- **`cp` per file is what makes stage 8 slow, not I/O.** 400 copies took longer than
  the `mkfs` of a 475 MB filesystem. `cpio -p` reads its path list from stdin, which
  is exactly the shape of a generated manifest — one process for the whole set.
- **A command can be built and still not be on the disk.** Stage 8's copy loop has its
  own directory list, unrelated to `provenance.txt`, and `usr/games` was missing from
  it — so `bcd` was built, reported built, and absent. Symmetrically, `TOOLDIR` serves
  *two* roles (the staging toolchain, and the system being built, since stage 6 aims
  it at `DESTDIR`), so an install path in `stage1.order` is a **system-layout**
  decision: `yacc` and `strip` installed to `bin/` reached the toolchain and never
  `/usr/bin`, where `where.txt`, the reference image and `provenance.txt` all say they
  live — and where `mkdep.py`'s own generated makefiles default `YACCPATH` to look.
  Neither is visible from a boot test; both were found by `tools/retire-check.py`.
- **`mkfs` does not clear data blocks.** A second stage 8 over the same image file
  leaves the previous run's contents in what the new filesystem calls free space:
  invisible to the guest, very visible to a compressor. Recreate the file from
  `/dev/zero` before the run that produces a committed artefact.

## Conventions

- Big binaries (disk images, tapes, tarballs) never enter git — rebuild locally per the
  runbook (gitignored: `*.disk`, `*.tap`, `*.img`, `work/`). **Exactly one exception**,
  named in `.gitignore` and in `tools/hook-block-binaries.sh` rather than left to a gap
  in a pattern list: `image/ipnx-v8-rp07.img.xz`, the disk *we* build, because it is the
  **input to the next build** — stage 8 lifts `v8/mk/gen/carry.txt` off it. With it
  committed the build's only external input is the tapes, which `v8/MANIFEST` already
  accounts for. Written only by `tools/image-pack.py`
  ([docs/golden-disk.md](docs/golden-disk.md)).
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

**A4 — the screen** (2026-08-10, [docs/screen-size.md](docs/screen-size.md)): two fixed
presets (Original 800×1024/88 columns, Wide 1152×1024/127) with the window locked to
the CRT's shape rather than the reverse; the screen *and* the session both survive a
quit (`screen.bin` repainted, plus a CR nudge gated on the firmware's idle PC window —
the fix for what looked like a mute restore); area-average sampling in the fragment
shader so fractional scale no longer shimmers, driven off `MTKView.drawableSize` so
Retina panels are actually used; controls out of the terminal field into a real
`NSToolbar` (Mac) or a chrome bar (iPad), with a plain bezel around the tube.

**A5 — the interface** (2026-08-10, [docs/ui-redesign.md](docs/ui-redesign.md)): the
three-face picker is gone. The app is now the machine as it actually is — an operator
console plus a getty on `tty00`..`tty07`, each openable and independent, in windows
grouped by terminal shape (vt100 / vt100w / dmd) because nothing can be reflowed on a
kernel with no `TIOCGWINSZ`. Every DZ line has its own listen port, so a tab labelled
`tty03` *is* `tty03`. The console is read-only behind a lock, `tty01` logs itself in as
root on seeing `login:`, chrome is Liquid Glass (never over the emulated raster), and the
deployment targets are iOS 26 / macOS 26. The app was renamed from **Edition** to
**ipnx** at the same time — project, targets, schemes, folder, `@main` struct — and the
icon is now a stylised licence plate reading `ipnx` over LIVE FREE OR DIE, after the
plate Armando Stettner handed out at USENIX (`tools/gen-icons.swift`).

**B0.6 — a machine to live in** is planned but not started:
[docs/machine-config.md](docs/machine-config.md). `fix-identity.exp` becomes
`work/config.exp` (build time, universal) plus a first-boot provisioner in the app
(per-installation: an account named after the host user). The host share mounts at
`/n/macos` and `/n/home` and is deliberately **not** the home directory — V8's 14-byte
filenames and case sensitivity rule that out.

**Track B's ingest path is settled** (2026-08-09, phase B0): host↔guest file
transfer is proven end to end — [docs/media-exchange.md](docs/media-exchange.md),
`tools/tapeio.py`, `work/mediatest.sh` — including a VAX binary compiled inside V8 and
carried back out. The golden image's missing `lost+found` was fixed at the same time.

**B0.5 — the N track — is complete** (N0–N7, 2026-08-09/10). Plan in
[docs/networking-plan.md](docs/networking-plan.md), results in
[docs/n-track-notes.md](docs/n-track-notes.md), wire format in
[docs/netfs-protocol.md](docs/netfs-protocol.md).

**A macOS folder is mounted inside Research Unix 8th Edition, read/write.**
`work/myv8/rp07v8.net` boots a 516 MB RP07 with an Interlan NI1010 we modelled
for SIMH, reaches the real Internet through SLiRP's NAT, and mounts a host
directory at `/n/macos` over TCP using Weinberger's netfs — whose client has
been compiled into every V8 kernel since 1985 and has had nothing to talk to
since Datakit was switched off. Proven both directions with checksums: a
13,200-byte file reads out byte-exact, and 65,385 bytes written *by V8* land
byte-identical on APFS (`tools/drive-netfs.sh`, `tools/drive-netfs-rw.sh`).

The server is `netfs/`, a SwiftPM package whose `NetFS` target compiles
unchanged into both app targets — `app/ipnx/FileShare.swift` runs it behind a
folder picker. The guest reaches it at 10.0.2.2, which SLiRP aliases to the
host's loopback, so it needs no forwarding and works inside the iOS sandbox.

**What is not done**: the app still ships the RP06, which has neither the `il0`
kernel nor the netfs stream fix, so nothing in the guest can mount the share
yet. That is C3/B0.6 image work with an App Store size decision attached, not
netfs work.

Next: **submit** — the remaining steps need the Apple account and a final name
decision, all listed in [docs/app-store.md](docs/app-store.md) — and **Track B**,
whose ingest path and source are both now in place — the TUHS tarballs are in `work/`, and B1 needs only 14.87 MB of the 243 MB tree.
Not yet exercised: `mux`/`jim` driven by the Mac's real mouse, "Crisp" scaling
compared visually, and `muxterm`/`jim` widened to match the resized screen (they carry
their own `display` from V8's libj). Update the checkboxes in
[docs/roadmap.md](docs/roadmap.md) as phases complete.

**Driving the Mac app from a script**: `open -n app --stdout LOG` *appends*, so
truncate the log first or one file accumulates every run and looks like concurrent
instances. Never use AppleScript `activate`/`keystroke` against the app — both resolve
the *bundle* through LaunchServices and can launch a second copy, and two VAXes sharing
one `v8.disk` is a filesystem-corruption hazard. Target `tell application id "..."` (or
`System Events` `process`), and assert `pgrep -x ipnx | wc -l` is 1 at every step.
