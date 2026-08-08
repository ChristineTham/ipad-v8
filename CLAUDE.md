# CLAUDE.md

Project: a native iPad app running Research Unix (V8 now, V10 as end goal) on an emulated
VAX, displayed through an emulated DMD 5620 terminal. Research is complete; no code exists
yet. [RESEARCH.md](RESEARCH.md) is the evidence base — trust it over memory, and record any
decision changes there or in [docs/](docs/).

## Doc map

- [RESEARCH.md](RESEARCH.md) — frozen feasibility study with sources (don't rewrite; append)
- [docs/architecture.md](docs/architecture.md) — living spec (keep current as code lands)
- [docs/roadmap.md](docs/roadmap.md) — phase status (update checkboxes as phases complete)
- [docs/spike-a0.md](docs/spike-a0.md) — desktop-spike runbook (contains VERIFY markers —
  confirm those steps during the spike and correct the doc)
- [docs/v10-restoration.md](docs/v10-restoration.md) — Track B plan and conventions
- [docs/licensing.md](docs/licensing.md) — licensing constraints (binding on product choices)

## Decisions (settled — don't relitigate without new evidence)

- Full-system emulation, native code. **Not** WASM, **not** iSH-style user-mode.
- VAX core: open-simh `vax780`. Terminal core: `dmd_core` (Rust, C FFI) as DMD 5620.
- End goal is V10, staged through V8. **V9 is skipped** (surviving V9 = Sun-3 port, no VAX
  kernel).
- Free app, self-contained, no ads/IAP — required by the 2017 non-commercial covenant.

## Gotchas (each cost the community real debugging time)

- Naming trap: in Research tapes, `jerq/` = DMD 5620 (WE32100); `blit/` = original 68000
  Blit. The "current" V8/V10 terminal is the 5620.
- dmd_core must run firmware **8;7;3** for Research Unix `mux` (default 8;7;5 fails).
- SIMH newer than 3.9 needs `set noasync` or V8 corrupts RP06 I/O (simh issue #425).
- Realistic DZ11 pacing makes the `mux` terminal download take ~17 min — the app needs an
  unthrottled serial path; measure in A0.
- V10's `/usr/include` is a 1997 reconstruction of a 1995 tree — expect header/source skew
  during Track B; log every reconciliation.
- Don't use "UNIX" in the app name (Open Group trademark; no rights granted).

## Conventions

- Big binaries (disk images, tapes, tarballs) never go in git — build them locally
  (gitignored patterns: `*.disk`, `*.tap`, `work/`).
- Track B keeps pristine upstream sources separate from our patches; every fix is a logged
  patch with a rationale (the patch log is itself a publishable artifact).
- Cite sources for factual claims in docs, TUHS/primary links preferred.

## Current status / next actions

1. **Phase A0** (next): desktop spike per [docs/spike-a0.md](docs/spike-a0.md) — build
   `v8.disk` with myv8, boot under SIMH, connect a 5620/Blit emulator, run `mux`, measure
   serial pacing. Correct the runbook's VERIFY items as you go.
2. Then Track A (iOS app shell) and Track B (V10 bootstrap) proceed in parallel — see
   [docs/roadmap.md](docs/roadmap.md).
