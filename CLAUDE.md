# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A native iPad app that runs Research Unix (V8 first, V10 as the end goal) on an emulated
VAX — open-simh `vax780` — displayed through an emulated DMD 5620 terminal (`dmd_core`),
joined by a virtual serial line inside one iOS process. Full-system emulation is the load-
bearing decision: the Research Unix kernel forks processes inside the emulated machine, so
iOS's no-fork/no-JIT restrictions never apply, and both cores are plain AOT-compiled
interpreters (App Store-legal per UTM SE / iAltair precedent).

**Current state: documentation only — research is complete, no app code exists yet.**
[RESEARCH.md](RESEARCH.md) is the evidence base for every decision; trust it over memory,
and record decision changes in the living docs, not by rewriting the study.

## Commands

There is no build system, test suite, or linter yet. The only executable work so far is the
**Phase A0 desktop spike** — its commands are in [docs/spike-a0.md](docs/spike-a0.md)
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

Planned toolchains, for when code lands (update this section with real commands then):
- App shell: Swift/SwiftUI + Metal (Xcode project, Track A1+)
- VAX core: open-simh as a C static library (CMake → xcframework)
- Terminal core: dmd_core as a Rust `aarch64-apple-ios` staticlib via its C FFI

## Architecture (the big picture)

Two interpreters and a wire, mirroring the real 1985 topology (smart terminal ↔ serial line
↔ headless host):

- **SIMH thread** boots the disk image; its DZ11 line 0 is the wire's host end
  (`set noasync` mandatory).
- **dmd thread** runs the WE32100 terminal; its DUART port A is the wire's other end;
  its 800×1024×1 framebuffer is what the user sees.
- **Serial transport** starts as a localhost telnet loopback (zero-patch, proven shape) and
  must evolve into an unthrottled in-process byte queue — realistic serial pacing makes the
  `mux` download take ~17 minutes, the project's #1 UX risk.
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
  **"UNIX" must not appear in the app name** (Open Group trademark). Binding rules:
  [docs/licensing.md](docs/licensing.md).

## Gotchas (each cost the community real debugging time)

- Naming trap: in Research tapes, `jerq/` = DMD 5620 (WE32100); `blit/` = original 68000
  Blit. The "current" V8/V10 terminal is the 5620.
- dmd_core must run firmware **8;7;3** for Research Unix `mux` (default 8;7;5 fails).
- SIMH newer than 3.9 needs `set noasync` or V8 corrupts RP06 I/O (simh issue #425).
- V8's getty sends the first `login:` with **mark parity** (bit 7 set) — byte-matchers must
  strip the high bit until after login.
- `mux` is not on root's PATH — invoke `/usr/jerq/bin/mux`.
- SIMH `vax780` burns ~97% of a core while V8 idles (no idle detection) — a design
  constraint for the iPad app, and worth killing the simulator when not in use.
- dmd_core's GitHub HEAD embeds only the **8;7;5** ROM, which V8's `32ld` download crashes
  (unimplemented `MOVTRW` + unaligned access in the WE32100 core, ~30 KB in) — this is the
  mechanism behind the documented "use firmware 8;7;3" requirement. Serial pacing lives in
  dmd_core's DUART (wall-clock per-char at programmed baud; fresh NVRAM = 1200 baud), not
  in SIMH. Details: docs/spike-a0-results.md, Session 2.
- V10's `/usr/include` is a 1997 reconstruction of a 1995 tree — expect header/source skew
  during Track B; log every reconciliation as a patch.
- The Alhadis GitHub mirrors are incomplete (v10 mirror omits `630/`) — TUHS tarballs are
  the source of truth.

## Conventions

- Big binaries (disk images, tapes, tarballs) never enter git — rebuild locally per the
  runbook (gitignored: `*.disk`, `*.tap`, `work/`).
- [docs/spike-a0.md](docs/spike-a0.md) contains **VERIFY** markers on steps assembled from
  research but not yet executed — executing them, then correcting the doc and dropping the
  marker, is part of the spike's deliverable.
- Track B keeps pristine upstream sources separate from our patches; every fix is a logged
  patch with a rationale, plus a dated lab-notebook entry (`docs/v10-log/`).
- Cite primary sources (TUHS preferred) for factual claims in docs.
- Project automation: use `/verify-step` to resolve runbook VERIFY markers and `/v10-log`
  for Track B lab-notebook entries. Hooks (`.claude/settings.json` + `tools/*.sh`) enforce
  the no-binaries rule and check markdown links on edit.

## Status / next step

Phase **A0** is largely complete — see [docs/spike-a0-results.md](docs/spike-a0-results.md):
V8 boots under classic SIMH 3.12-5 in `work/`, DZ login and the mux `ESC [ c` handshake are
proven. Remaining: the terminal-emulator leg (**no Homebrew on this machine** — build
`dmd_core` headless with cargo, firmware 8;7;3) and definitive mux timing. After A0, Track A (iOS app) and
Track B (V10 restoration) proceed in parallel; update the checkboxes in
[docs/roadmap.md](docs/roadmap.md) as phases complete.
