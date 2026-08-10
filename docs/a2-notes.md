# Track A2 implementation notes

*Written 2026-08-09 as A2 landed, the same day as A1. The Blit experience:
dmd_core on iOS, a Metal phosphor screen, and `mux` + `jim` running
end-to-end on the iPad simulator. Protocol background lives in
[spike-a0-results.md](spike-a0-results.md) (the desktop bridge proved every
constant this port reuses) and [a1-notes.md](a1-notes.md) (the SIMH side).*

## What A2 delivers

- **DmdCore.xcframework** (`libdmd/`) — the patched dmd_core as a static
  library for iOS device + simulator, via the crate's **built-in C FFI**
  (a global singleton behind a mutex; do not write a wrapper crate — its
  `#[no_mangle]` exports collide). Two BREAK exports the FFI lacked are
  added by `tools/dmdbridge/patches/dmd_core-a2-ffi-break.diff`, applied
  with the A0 spike patches (firmware 8;7;3 BREAK-as-0x00, 8× DUART
  turbo) on the pinned canonical tree (git.loomcom.com `ee222b68`).
  Smoke test: boot to terminal mode + RS232 echo rendered to VRAM — a
  booted 5620 is a black screen with a cursor (~26 lit bytes), so the
  proof is an echo test, not a lit-pixel threshold.
- **Terminal5620** — the dmd thread, a Swift port of the A0 bridge loop
  with the proven constants: `dmd_step_loop(500)` batches paced to 10 MHz
  wall-clock (2 ms slack), ~1 host→terminal byte per 1000 steps, 100 ms
  keyboard gaps (3-deep firmware FIFO), IAC-filtered DZ socket with BREAK
  translated in both directions (inbound IAC BRK → `dmd_rs232_break`;
  outbound `dmd_rs232_tx_break` → IAC BRK), frame publishes at most every
  ~30 ms when VRAM is dirty.
- **Metal framebuffer** — the packed VRAM uploaded as a 100×1024 R8Uint
  texture; a fragment shader does the bit expansion (MSB-first, row 0 at
  top) with the phosphor tint. No CPU-side expansion.
- **Input** — touch is a trackpad: drags feed **counter deltas** into the
  free-running mouse registers (y counts UP the screen, so screen-down
  subtracts), with B1/B2/B3 latch buttons choosing which button a drag
  holds (mux's menu and sweeps live on B3) and a BREAK key. Keyboard via
  a hidden UIKeyInput first responder (ASCII; newline → CR).
- **Dual screens** — the SwiftTerm operator console and the 5620 stay
  mounted (opacity switch, so the boot transcript survives); the app
  auto-switches to the 5620 when the machine reaches `.up`.

## Measured on the iPad Pro 13-inch (M5) simulator

- Cold launch → 5620 showing the DZ `login:`: ~40 s (V8 autoboot ~25–30 s,
  firmware boot + carrier nudge the rest).
- `/usr/jerq/bin/mux`: muxterm download + handshake ≈ **100 s** at the
  ÷8-turbo DUART pacing — matching the desktop bridge's ~98 s, and the
  reason serial transport v2 (in-process unthrottled queue) is deferred:
  v1 (localhost socket) is already at the pacing floor set by the DUART,
  not the transport.
- `/usr/jerq/bin/jim` in a layer: ~50 s download, editor UI takes over
  the layer (body + status line).
- Full desktop flow verified by driving the real UI: B3 menu → New →
  sweep cursor → B3 sweep → bordered layer with a root shell → `date`
  (Sun Aug 8 03:26 EDT 1976) and `cat /etc/motd` round-trip.

## Gotchas earned here

- **dmd_core ships its own C FFI** (`dmd_init`, singleton, status codes
  0/1/2 = success/error/busy). Extend it via patch when something is
  missing; a parallel wrapper crate duplicates its unmangled symbols.
- **Two xcframeworks cannot both bundle `module.modulemap`** — Xcode
  copies every framework's Headers into one flat `include/` and the build
  fails with "Multiple commands produce". Both modules are declared in
  `app/ipnx/Modules/module.modulemap` instead (SWIFT_INCLUDE_PATHS
  points there; header paths are modulemap-relative).
- The mux **menu needs the cursor mid-screen** before the B3 click: the
  menu pops centered on the cursor, and a cursor parked in a corner gets
  a clipped, unusable menu. The sweep-corner cursor after selecting New
  is the visual confirmation the sweep is armed.
- `jim`, like `mux`, is **not on root's PATH** — `/usr/jerq/bin/jim`.
- Swift concurrency: helpers called from the dmd thread must be
  `nonisolated` when the owning class is `@MainActor` — the compiler
  warning becomes an error the moment the caller is annotated.

## Known limitations (A3 candidates)

- Mouse is relative-only (trackpad model); pointer hover (trackpad /
  Pencil) and absolute-warp UX are future polish.
- jim launches and renders but its selection/typing choreography is
  untested beyond startup.
- The 5620 is not restarted around SIMH save/restore: a cold relaunch
  reboots the terminal (fresh firmware, muxterm gone) while V8's mux
  session survives in the snapshot — the restored session's DZ line needs
  a re-login or mux re-entry. Reconciling terminal state with snapshots
  is an A3 design task (NVRAM persistence belongs to the same pass).
- Non-integer display scaling of the 800×1024 framebuffer produces mild
  moiré on the stipple background (cosmetic; integer-scale letterboxing
  would fix it).
- The A0-noted intermittent keyboard-loss in dmd_core's kb path remains
  unchased upstream; the 100 ms pacing works around it.

## Evidence

`work/shots-a2/`: `a2-mux-layer-shell.png` (layer running `date` +
`cat /etc/motd`), `a2-jim.png` (jim's UI in a layer over the desktop),
`a2-jim-attempt.png` (PATH lesson), `a2-final-toolbar.png` (shipping
build, 5620 login). The screen recording-equivalent sequence lives in the
session log.
