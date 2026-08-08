# Roadmap

*Two tracks sharing one spike. Track A ships a real product on proven ground; Track B is the
research moonshot that lands into the same app shell. Update checkboxes and the status line
as work completes.*

**Current phase: A0 — in progress (2026-08-08).** SIMH built, V8 disk produced, multiuser
boot + DZ login + mux handshake proven; remaining: terminal-emulator leg (headless dmd_core
via cargo — no package manager on this machine) and definitive mux timing. See
[spike-a0-results.md](spike-a0-results.md).

## Phase A0 — desktop spike *(shared by both tracks; no iOS code)*

Runbook: [spike-a0.md](spike-a0.md)

- [x] Build SIMH `vax780` on macOS (classic 3.12-5; zip unpacks into `sim/`; warnings only)
- [x] Produce the V8 disk via myv8 (`rp06v8`, ~2.5 min; all media bundled in the repo)
- [x] Boot V8 to multi-user login on the Mac (console `# ` → `^D` → DZ gettys)
- [ ] Connect a terminal emulator and run `mux` — *host handshake proven (`ESC [ c` DA
      query captured); emulator pending: no SDL2/GTK here → drive `dmd_core` headless via cargo*
- [ ] Measure `muxterm` download time — *partial: no artificial DZ pacing under 3.12-5*
- [x] Record findings in `docs/spike-a0-results.md`; runbook corrected (remaining VERIFY:
      aap/blit flags, socat bridge, open-simh re-verification)

*Exit criteria: `mux` usable end-to-end; serial-pacing fix chosen (config vs. patch).*

## Track A — the product (V8 inside)

### A1 — text mode on iPad
- [ ] open-simh built as an arm64 static library (CMake → xcframework)
- [ ] App boots bundled `v8.disk` to `login:` in a SwiftTerm console view
- [ ] Background/foreground survival (SIMH save/restore)

### A2 — the Blit experience
- [ ] dmd_core built for `aarch64-apple-ios` (C FFI staticlib), firmware 8;7;3
- [ ] Metal framebuffer view (800×1024×1, phosphor tint)
- [ ] Serial transport v1 (localhost) → v2 (in-process, unthrottled)
- [ ] Input mapping: touch/Pencil/trackpad → 3-button mouse; hardware + soft keyboard
- [ ] `mux` + `jim` usable end-to-end on iPad

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
