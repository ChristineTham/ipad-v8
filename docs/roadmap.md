# Roadmap

*Two tracks sharing one spike. Track A ships a real product on proven ground; Track B is the
research moonshot that lands into the same app shell. Update checkboxes and the status line
as work completes.*

**Current phase: A3 — complete (2026-08-09) bar the human submission steps; Track B is
next.** A0 proved the machinery on the desktop ([spike-a0-results.md](spike-a0-results.md));
A1 shipped the text-mode app (open-simh as a library, V8 to `login:` in ~25–30 s,
save/restore instant-on — [a1-notes.md](a1-notes.md)); A2 shipped the Blit experience
(dmd_core on iOS, Metal phosphor screen, touch-as-mouse — `mux` and `jim` run end-to-end
on the iPad simulator — [a2-notes.md](a2-notes.md)); A3 made it shippable and added a
**native macOS app** sharing all its code ([a3-notes.md](a3-notes.md), submission
checklist in [app-store.md](app-store.md)).

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
      1200-baud NVRAM default. **A0/A2 concluded pacing lived in dmd_core's DUART alone;
      A3 corrected that** — SIMH's DZ was throttling to the guest's programmed 9600 in
      series with it, and ÷8 happened to be 9600-equivalent, making the two
      indistinguishable. See [a3-notes.md](a3-notes.md)*
- [x] Record findings in `docs/spike-a0-results.md`; runbook corrected — all VERIFY markers
      resolved 2026-08-09 (aap/blit and the socat bridge were superseded, not executed)

*Exit criteria: `mux` usable end-to-end; serial-pacing fix chosen (config vs. patch).*

## Track A — the product (V8 inside)

### A1 — text mode on iPad *(complete 2026-08-09; see [a1-notes.md](a1-notes.md))*
- [x] open-simh built as an arm64 static library (CMake → xcframework) — *`libsimh/`,
      pinned `a1f57fa`, synchronous I/O compiled in (the V8-safe mode, permanently);
      device + simulator slices, plus a macOS `vax780cli` harness that desktop-proved
      the whole app protocol before any Swift ran*
- [x] App boots bundled `v8.disk` to `login:` in a SwiftTerm console view — *the
      ipnx app (team RPL5R637DS): autoboot with self-healing fsck
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

### A3 — ship v1 *(complete 2026-08-09 except the steps only a person can do; see [a3-notes.md](a3-notes.md))*
- [x] Settings, snapshots, disk import/export via Files — *phosphor + scaling
      (the "Crisp" mode is the moiré fix: exactly 2× on an iPad Pro 13-inch),
      pointer speed, 5620 NVRAM persistence, snapshot visibility + discard,
      staged disk import/reset applied at next launch so nothing is swapped
      under a running VAX*
- [x] Licenses/credits screen (acknowledgements) — *2017 covenant, TUHS and
      Berkeley, open-simh / dmd_core / 5620 firmware / SwiftTerm; the statement
      PDF is linked, and bundling it is on the submission checklist*
- [x] App Store prep — *icon (generated, `tools/gen-icons.swift`), privacy
      manifest, export-compliance boolean, category, v1.0, sandbox + hardened
      runtime; **submission itself needs the Apple account** —
      [app-store.md](app-store.md)*

### A3+ — the Mac *(not originally scoped; complete 2026-08-09)*
- [x] macOS slices for both xcframeworks
- [x] Native macOS app target sharing one source folder — *V8 boots to `login:`
      on the 5620 in a native window; real 3-button mouse (right-click is mux's
      menu); snapshot on quit, never on hide*

## Track B — the V10 restoration *(desktop SIMH until it boots; see [v10-restoration.md](v10-restoration.md))*

### B0 — the ingest path *(done 2026-08-09, before any V10 source exists)*
- [x] Establish how files cross between host and V8 — [media-exchange.md](media-exchange.md).
      Tape is unusable (V8's `ht` panics SIMH's Massbus adapter); the working path is a
      raw-only courier disk on `rp1` with the work area on `/usr`, 512-byte transfers,
      driven by `tools/tapeio.py`. Proven end to end by `work/mediatest.sh`, including a
      VAX binary compiled inside V8 and carried back to the host
- [x] Repair the golden image's missing `lost+found` (autoboot `fsck` could not self-heal)
- [x] Download the TUHS tarballs — `v10src.tar.bz2` (74.9 MB) and `v10blit.tar.bz2`
      (2.6 MB) in `work/`, both `bzip2 -t` clean
- [x] Size the expanded tree: **243.3 MB / 23,977 files**, so the whole tree does *not*
      fit `/usr`'s ~88 MB and selective ingest is mandatory, not merely preferable. The
      B1 set (sys, lsys, libc, ccom, pcc1, as, c2, libcc) is **14.87 MB / 2,127 files** —
      two courier loads. Longest stored path is 51 bytes, so V7 tar's 100-byte name
      field is a non-issue

### B0.5 — infrastructure scope-up *(planned 2026-08-09, [networking-plan.md](networking-plan.md))*

The courier is too small and too manual to build V10 on: 8.1 MB a load against a
243 MB tree. Three changes, the last of which the iPad app needs anyway.

- [x] **N0** RP07 disk (516 MB; `/usr` on partition `f`) + migration + `lost+found` —
      *done 2026-08-09: `work/rp07mig.sh` produces `rp07v8.golden`, which boots on its
      own with `/usr` at **459,905 KB, 408,364 free** (was 141,578/90,035). Root needed
      no filesystem copy — partition `a` is the same 15,884 sectors at cylinder 0 on
      both drive types, so a host byte copy suffices. Notes and gotchas:
      [n-track-notes.md](n-track-notes.md)*
- [ ] **N1** 4.3BSD under SIMH with `XU` + `nat:` reaching the Internet — a control
      experiment proving the NAT plumbing before we build on it
- [ ] **N2** `pdp11_il.c` — model the Interlan NI1010 (3 registers) against `sim_ether`.
      V8 has `il`/`ec` drivers; SIMH has only DEUNA; this closes the gap. Highest risk
- [ ] **N3** Rebuild the V8 kernel with `il0`; ping the outside world
- [ ] **N4** Derive and document the netfs wire format → `docs/netfs-protocol.md`
- [ ] **N5** Host netfs server over TCP, read-only first
- [ ] **N6** Guest client (~50 lines: socket, handshake, `gmount`)
- [ ] **N7** Read/write; then port the server into the app for Files access

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
