# Roadmap

*Two tracks sharing one spike. Track A ships a real product on proven ground; Track B is the
research moonshot that lands into the same app shell. Update checkboxes and the status line
as work completes.*

**Current phase: A2 — complete (2026-08-09); A3 and Track B are next.** A0 proved the
machinery on the desktop ([spike-a0-results.md](spike-a0-results.md)); A1 shipped the
text-mode app (open-simh as a library, V8 to `login:` in ~25–30 s, save/restore
instant-on — [a1-notes.md](a1-notes.md)); A2 shipped the Blit experience (dmd_core on
iOS, Metal phosphor screen, touch-as-mouse — `mux` and `jim` run end-to-end on the
iPad simulator — [a2-notes.md](a2-notes.md)).

## Phase A0 — desktop spike *(shared by both tracks; no iOS code)*

Runbook: [spike-a0.md](spike-a0.md)

- [x] Build SIMH `vax780` on macOS (classic 3.12-5; zip unpacks into `sim/`; warnings only)
- [x] Produce the V8 disk via myv8 (`rp06v8`, ~2.5 min; all media bundled in the repo)
- [x] Boot V8 to multi-user login on the Mac (console `# ` → `^D` → DZ gettys)
- [x] Connect a terminal emulator and run `mux` — *done (Session 6): the "55K stall" was
      mux idling at its desktop — 32ld sends only text+data (50,324 B), not the 144,603-B
      file. Menu → sweep → layer → shell → `date` + motd all round-trip; screenshots in
      `work/shots-final/`. Full story: spike-a0-results.md Session 6*
- [x] Measure `muxterm` download time — *definitive (Session 6): wire burst 55,156 B
      (50,324 payload + protocol overhead); ~98 s at ÷8 turbo, ~6 min computed at the
      1200-baud NVRAM default; pacing lives in dmd_core's DUART, not SIMH*
- [x] Record findings in `docs/spike-a0-results.md`; runbook corrected (remaining VERIFY:
      aap/blit flags, socat bridge, open-simh re-verification)

*Exit criteria: `mux` usable end-to-end; serial-pacing fix chosen (config vs. patch).*

## Track A — the product (V8 inside)

### A1 — text mode on iPad *(complete 2026-08-09; see [a1-notes.md](a1-notes.md))*
- [x] open-simh built as an arm64 static library (CMake → xcframework) — *`libsimh/`,
      pinned `a1f57fa`, synchronous I/O compiled in (the V8-safe mode, permanently);
      device + simulator slices, plus a macOS `vax780cli` harness that desktop-proved
      the whole app protocol before any Swift ran*
- [x] App boots bundled `v8.disk` to `login:` in a SwiftTerm console view — *the
      Edition app (working title; team RPL5R637DS): autoboot with self-healing fsck
      reaches `login:` in ~25–30 s on the iPad Pro simulator; evidence in
      `work/shots-a1-final/`*
- [x] Background/foreground survival (SIMH save/restore) — *suspend + `save` via the
      SIMH remote console on background (zero CPU while paused), `continue` on
      foreground, `restore` on cold relaunch — 3/3 terminate→relaunch cycles with a
      live console after restore; snapshots are consumed the moment the machine runs
      again, so unclean kills cold-boot and fsck heals*

### A2 — the Blit experience *(complete 2026-08-09; see [a2-notes.md](a2-notes.md))*
- [x] dmd_core built for `aarch64-apple-ios` (C FFI staticlib), firmware 8;7;3 —
      *`libdmd/`: the crate's built-in FFI + a logged patch for the two BREAK exports;
      echo-test smoke proof*
- [x] Metal framebuffer view (800×1024×1, phosphor tint) — *packed VRAM as R8Uint,
      fragment-shader bit expansion, dirty-flag uploads*
- [x] Serial transport v1 (localhost) → v2 (in-process, unthrottled) — *v1 shipped;
      v2 deliberately deferred: the ÷8 DUART turbo already puts the mux download at
      ~100 s measured on iPad — the pacing floor is the DUART, not the transport*
- [x] Input mapping: touch/Pencil/trackpad → 3-button mouse; hardware + soft keyboard —
      *trackpad-style counter deltas + B1/B2/B3 latches + BREAK; UIKeyInput keyboard;
      hover/Pencil polish deferred to A3*
- [x] `mux` + `jim` usable end-to-end on iPad — *login on the 5620 → mux download →
      B3 menu → New → sweep → layer with root shell (`date` + motd round-trip); jim
      downloads and takes over a layer (deep editing choreography untested)*

### A3 — ship v1
- [ ] Settings, snapshots, disk import/export via Files
- [ ] Licenses/credits screen (2017 statement PDF, acknowledgements)
- [ ] App Store submission (free app; name avoids "UNIX")

## Track B — the V10 restoration *(desktop SIMH until it boots; see [v10-restoration.md](v10-restoration.md))*

### B1 — toolchain
- [ ] Import `v10src` + `v10blit` into the running V8
- [ ] Build pcc2, as, ld with V8's cc; compile a V10 hello.c and one mid-size command

### B2 — world
- [ ] V10 libc builds
- [ ] Core userland builds (sh, init, getty, login, fs tools, mux/32ld host side)
- [ ] Patch log of every `/usr/include` (r70) skew reconciliation

### B3 — kernel + first boot
- [ ] `star` (780) kernel builds and links
- [ ] Boot block per `lsys/boot/README` (kernel at fs start, ≤ singly indirect)
- [ ] Filesystem image constructed; **first V10 boot attempt** (fallbacks: `microvax2`, `vax8200`)
- [ ] Progress announced on TUHS

### B4 — the V10 experience
- [ ] Multi-user; `mux` against dmd_core
- [ ] `sam`/`samterm` working
- [ ] Reproducible `v10.disk` build script

### Merge
- [ ] "Edition 10" machine in the app (embed the winning SIMH simulator if not `vax780`)

## Post-1.0 (unscheduled)

- [ ] Original 68000 Blit mode (Musashi core; requires ROM permission resolution)
- [ ] Emscripten web demo — the first browser VAX
- [ ] V10-era networking exploration (DEQNA/IP)
