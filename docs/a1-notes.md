# Track A1 implementation notes

*Written 2026-08-09 as A1 landed. This is the record of what was built, what
was proven, and the channel semantics that cost real debugging time.
Runbook-style evidence lives in the gitignored `work/` scripts named below;
their transcripts are quoted where they matter.*

## What A1 delivers

- **open-simh vax780 as a static library** — `libsimh/` builds
  `SimhVAX.xcframework` (iOS device arm64 + simulator arm64) plus a macOS
  CLI harness (`vax780cli`) from the same library. Upstream is pinned to
  `a1f57fa3` (2026-07-03), the exact rev the re-verification below proved.
- **The Edition app** (working title; no "UNIX" per
  [licensing.md](licensing.md)) — SwiftUI + SwiftTerm iPad app that boots
  the bundled `v8.disk` to `login:` on the SIMH console, with
  save-on-background / restore-on-relaunch.
- **The deferred A0 item**: V8 under open-simh with synchronous I/O —
  verified (simh issue #425 regression check).

## The library (`libsimh/`)

- Source list and defines mirror `make -n vax780` from the upstream
  makefile, minus networking (pcap/slirp), SDL video, editline, and — by
  design — `SIM_ASYNCH_IO`: **synchronous I/O is a compile-time guarantee**,
  making V8's required `set noasync` state permanent. Corollary: the config
  must NOT say `set noasynch` — in this build the knob doesn't exist and
  scp answers "Command not allowed".
- The single upstream modification is `-Dmain=simh_main` on `scp.c`; the
  shim (`src/simh_shim.c`) exposes `simh_vax780_run(config)` and
  `simh_vax780_request_stop()` (sets scp's `stop_cpu`, the same thing its
  SIGINT handler does — kept as a spare; the app's control path is the
  remote console below).
- `include/ios_compat.h` is force-included on iOS builds only and maps
  `__IOS_PROHIBITED` calls (`system()`) to inert stubs — no upstream patch.
- `include/module.modulemap` makes the C library importable as `SimhVAX`
  from Swift with no bridging header.
- Build: `libsimh/build-xcframework.sh` (clones/pins open-simh under
  `work/`, three CMake slices, `xcodebuild -create-xcframework`).

## Desktop-first proof (the reason A1 debugging stayed sane)

Everything the app does was first proven with the same library on macOS:

- `work/verify-opensimh.sh` — upstream-binary boot + DZ login + RP06
  integrity (`cp /unix` + `cmp` byte-identical, cc round-trip) with
  `Asynchronous I/O disabled` on the record. The #425 re-verification.
- `work/verify-libcli.sh` + `work/consoletest.py` — the full app topology
  against `vax780cli`: autoboot → console login → suspend/save via the
  remote console → PC-sample freeze proof → continue → alive; then a fresh
  process restores the snapshot and the logged-in shell returns.
- `work/remtest.sh` + `work/remtest.py` — a seconds-per-run protocol lab
  (vax780 running `INCL @#400; BRB`, a counter loop) that isolated every
  remote-console quirk without waiting for a 3-minute V8 boot.

## Channel semantics (hard-won; do not re-learn)

Four ways to talk to the embedded SIMH, four different rule sets:

| Channel | WRU (^E) | sim> prompt | Client IAC replies | Notes |
|---|---|---|---|---|
| Local tty console (desktop runs) | stops the sim | on the tty | n/a | the behavior all the classic lore describes |
| Telnet console (app) | **inert data byte** for the VM | **never** (lives on stdin) | required/harmless | pure V8 byte pipe; V8 **autoboots** here — fsck then multiuser `login:`, no single-user `#` stop |
| Remote console (app) | **suspends** the sim into multi-command mode | printed lazily (only before a read, not after a command) | **forbidden — session goes permanently silent** | `save`/`continue` live here; commands run "between instructions" |
| DZ lines | plain data | never | harmless | mark parity on early getty output (strip bit 7 to match) |

The remote-console dialect in full, all desktop-verified:

- Session starts in single-command mode; sending **^E suspends the
  simulator** (`Simulator paused.`) and enters multi-command mode where
  `SAVE` is in the allowed table. `CONTINUE` resumes; idle timeout
  (default 30 s — the app sets `set remote timeout=600`) or disconnect
  auto-continues.
- In multi-command mode a double `tmxr_getc_ln` in the reader **drops the
  first byte of typeahead** sent while a command executes. Armor: lead
  every command with a sacrificial space (scp trims it when it survives).
- Completion must be proven with an output-anchored echo marker —
  `" echo SAVED\r\n"`, match `"\nSAVED"` — because the prompt is lazy and
  the input echo would false-positive a bare substring match.
- **Never reply to telnet IAC negotiation on this socket** (bisected in
  the lab: variant G reproduces the kill in 30 s). The app's TelnetFilter
  takes `sendRefusals: false` for the control link only.

## The app (`app/`)

- Hand-authored `ipnx.xcodeproj` (Xcode 26 synchronized folders — the
  pbxproj lists no source files), `DEVELOPMENT_TEAM = RPL5R637DS` fixed at
  creation time, `TARGETED_DEVICE_FAMILY = 2`, SwiftTerm via SPM
  (Package.resolved pins the version), `SimhVAX.xcframework` by reference.
  A Run Script phase copies `work/myv8/rp06v8.golden` + `bootV8` into the
  bundle as `v8.disk` (never into git; the build degrades to a warning if
  the media hasn't been built).
- `Machine.swift` — provisioning (bundle → Application Support, backup
  excluded, cwd set so simh paths are container-relocation-safe), the simh
  thread, boot automation (wait for `login:`; autoboot fsck is the
  self-healing path after unclean kills), and the lifecycle:
  - scenePhase `.background` (inside a UIKit background task): ^E on the
    control link → `sim>` → ` save state.sav` → ` echo SAVED` →
    **paused, zero CPU** — the 97 %-of-a-core idle burn documented in A0
    stops while backgrounded.
  - `.active`: ` continue` (+ one retry on missing ack) and a console
    nudge.
  - Cold launch with `state.sav` present: `restore` + `cont` via
    `resume.conf`, then a liveness probe — a failed restore leaves scp
    running garbage **silently**, so "any console output within 10 s"
    is the health signal. A `restore.attempt` marker makes restore
    one-shot: if the attempt dies (crash, kill), the next launch drops the
    snapshot and cold-boots instead of crash-looping.
  - The restore path re-attaches the console and DZ on this launch's
    ports, and those binds must **succeed**. `SAVE` persists each unit's
    `dynflags` — `UNIT_TM_POLL`, the "I am a mux polling unit" tag,
    included — but `uptr->tmxr` is a runtime pointer that only a
    *successful* `tmxr_attach` sets, and no save file can carry it. A
    restore whose re-attach fails therefore brings the unit back tagged
    for polling with a NULL backpointer, and the next `cont` segfaults in
    `_tmxr_activate_delay`; restore reports success either way, so the
    session looks healthy right up to the crash. Filed upstream as
    [open-simh/simh#576](https://github.com/open-simh/simh/issues/576),
    reproduced on a stock `vax780` with no disk image and no OS — *any*
    failed re-attach does it, and the TIME_WAIT collision below is just
    the trigger we happened to hit. Tempting wrong fix: `reset tti`
    re-links the pointers, but zeroes the CSR the guest kernel configured
    — interrupt enable included — and V8 stops noticing console input
    entirely.
  - **Snapshot consumption**: `state.sav` is deleted the moment the
    machine runs again (foreground continue or restore success). A
    snapshot is only consistent with the disk while the machine stays
    paused; restoring a stale one against a moved-on disk would corrupt
    the filesystem. Unclean kills therefore cold-boot and fsck heals —
    authentic 1985 behavior.
- `ConsoleLink.swift` / `TelnetFilter.swift` — the two localhost sockets
  (console with IAC refusals, control without), await-style pattern
  matching, 7-bit-clean matching for mark parity. NWConnection gotcha: on
  loopback, a dial that lands before the listener exists parks in
  `.waiting(ECONNREFUSED)` **forever** (no reachability change is coming) —
  treat `.waiting` as this attempt's failure and redial fresh.
- **Ports rotate per launch** (pid-derived triple: console/control/dz).
  tmxr binds without `SO_REUSEADDR`, so on a quick relaunch the previous
  incarnation's ESTABLISHED pairs sit in TIME_WAIT and every `set console
  telnet`/`set remote telnet` fails with `bind error 48` — scp then runs
  with **no listeners** and the app is talking to nobody: the app was
  colliding with its own ghost (and, during development, with the desktop
  harness's 2323/2324/8888 on the shared Mac↔simulator localhost). The
  resume config also re-attaches the DZ explicitly because the snapshot
  records the previous launch's port.

## Timing (iPad Pro 13-inch (M5) simulator, Debug build)

- First launch: ~1 s provisioning (166 MB APFS copy), then autoboot with
  its self-healing fsck pass reaches `login:` in **~25–30 s** — boot text
  is already streaming at t+8 s. (The old "minutes to boot" intuition came
  from paced consoles; the unthrottled telnet console flies.)
- `save state.sav`: ~1 s; snapshot ≈1.6 MB (8 MB RAM + device state).
- Restore to a live console: seconds (getty answers the first poke) — the
  "instant-on" target from architecture.md holds.

## Screenshots

`work/shots-a1-final/` (gitignored, like all spike artifacts):
`a1-first-launch.png`, `a1-boot-streaming.png` (kernel banner + fsck +
`login:` in green phosphor), `a1-login.png`, `a1-restored-session.png`
(post-terminate relaunch, getty re-prompting — no reboot). Working shots
in `work/shots-a1/`.

## Follow-ups deliberately left open

- Login-typing UX niceties (autologin option, bell, font size) — A2 scope.
- The console shows scp chatter (`Simulator paused.` etc.) while pausing;
  arguably honest, possibly worth suppressing in A2.
- `simh_vax780_request_stop()` is unused by the app today (remote console
  won); keep until A2 decides.
- The iOS Simulator MCP live panel needs `sudo xcode-select -s
  /Applications/Xcode.app/Contents/Developer` on this machine before it
  can attach (headless simctl was used for all verification).
