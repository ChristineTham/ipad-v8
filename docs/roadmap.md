# Roadmap

*Tracks A and B share one spike: Track A ships a real product on proven ground; Track B is the
research moonshot that lands into the same app shell. C and D are later and declared here so
the README's scope has somewhere to point. Update checkboxes and the status line as work
completes.*

**Current phase: Track A complete through A4 (2026-08-10) bar the human submission steps;
Track B under way — B0 and B0.5's N0–N3 are done, so V8 has an Internet connection.** A0
proved the machinery on the desktop ([spike-a0-results.md](spike-a0-results.md));
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

### A4 — a bigger, sharper, continuous screen *(2026-08-10; [screen-size.md](screen-size.md))*
- [x] Resize a running 5620 and widen its text grid to 127 columns — *the
      `display` Bitmap is ROM `.data`; the grid is 24 byte immediates*
- [x] Two fixed presets, Original (800×1024, 88 cols) and Wide (1152×1024, 127),
      with the window locked to the CRT's shape instead of the reverse
- [x] The screen survives a quit: `screen.bin` painted back once the terminal
      has booted
- [x] The *session* survives too — the start-of-session nudge now waits for the
      firmware's idle PC window and always fires *(this is what "restored
      session is mute" actually was)*
- [x] Area-average sampling in the fragment shader, from the drawable's real
      pixel count — no shimmer at fractional scale, bit-identical at integral
- [x] Controls out of the terminal field: a real `NSToolbar` on the Mac, a
      chrome bar on iPad, and a plain bezel around the tube
- [ ] Widen `muxterm` and `jim` to match *(they carry their own `display`)*

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
      *done 2026-08-09: `tools/rp07mig.sh` produces `rp07v8.golden`, which boots on its
      own with `/usr` at **459,905 KB, 408,364 free** (was 141,578/90,035). Root needed
      no filesystem copy — partition `a` is the same 15,884 sectors at cylinder 0 on
      both drive types, so a host byte copy suffices. Notes and gotchas:
      [n-track-notes.md](n-track-notes.md)*
- [x] **N1** SLiRP NAT plumbing — *reduced 2026-08-09: `attach xu nat:` initialises
      10.0.2.0/24 (gateway 10.0.2.2, DNS 10.0.2.3) and passes frames. The 4.3BSD half
      was dropped — no ready-made SIMH image exists at TUHS, and `dev/ill.c` is a
      better conformance test than a second driver would have been*
- [x] **N2** `pdp11_il.c` — *done 2026-08-09: the Interlan NI1010 modelled against
      `sim_ether`, in `libsimh/patches/`. Note the plan named the wrong driver —
      `conf/files` builds `dev/ill.c`, not `dev/il.c`*
- [x] **N3** V8 kernel rebuilt with `il0`; the outside world reached — *done
      2026-08-09: `il0 at uba0 csr 164040 vec 0340 ipl x14`, ARP round-trips to SLiRP,
      and `dnsq` resolves **www.bell-labs.com → 184.24.254.233** over real DNS. The
      one-number bug: V8 is classful, so the interface's network is `10.0.0.0`, not
      SLiRP's `10.0.2.0` — [n-track-notes.md](n-track-notes.md)*
- [ ] **N4** Derive and document the netfs wire format → `docs/netfs-protocol.md`
- [ ] **N5** Host netfs server over TCP, read-only first
- [ ] **N6** Guest client (~50 lines: socket, handshake, `gmount`)
- [ ] **N7** Read/write; then port the server into the app for Files access

### B0.6 — a machine to live in *(planned 2026-08-10, [machine-config.md](machine-config.md))*

Turning the shipped image from a demo that boots to `login:` into a machine with
the user's own account, the host's files, and a network. Stage 1 needs nothing
new; stages 2 and 3 wait on N3-into-the-image and N4–N7 respectively.

- [ ] **C1** `work/config.exp` — fold the three fix-*.exp scripts into one
      idempotent build-time script; add `/etc/skel` and the `/n` mount points
- [ ] **C2** First-boot provisioner in the app: an account named after the host
      user, a real V8 home at `/usr/<user>` *(not* the host share — 14-byte
      filenames and case-folding rule that out)*
- [ ] **C3** Golden image rebuilt on the N3 `il0` kernel; `att il0 nat:` in both
      configs; `/etc/rc` brings the interface up *(blocked on N3 → image)*
- [ ] **C4** `/n/macos` and `/n/home` mounted at boot *(blocked on N5–N7)*

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

## Track C — ipnx-ports *(declared 2026-08-10; nothing built)*

A ports tree in this repository, in the spirit of FreeBSD's: one recipe per package —
upstream distfile, patch series, build and install rules — for bringing contemporary
software back to a 1985 machine. The patch series **is** the artifact; the target has
K&R C with no prototypes, 14-byte filenames, no shared libraries and no POSIX, so a
port is an act of translation and has to be readable as one.

- [ ] **P0** Decide the shape: `ports/<category>/<name>/{Makefile,distinfo,patches/}`,
      what fetches (host side) and what builds (guest side), and how a port crosses
      the ingest path — courier disk today, netfs after N5–N7
- [ ] **P1** `libcompat` — smaller than first assumed, because V8's libc was *measured*
      rather than guessed (`tools/v8-libc-probe.exp`): `strchr`, `memcpy`, `memset` and
      `qsort` are already there, and `bcopy`/`bzero` are the ones missing. What is
      actually needed is a prototype-eliding macro, seven functions (`strtol`, `strtod`,
      `strstr`, `memmove`, `atexit`, `vprintf`, `vfprintf` — several liftable from V10's
      own `libc/gen/`), and `bcopy`/`bzero` wrappers
      ([v11-plan.md](v11-plan.md) *"The real cost"*)
- [ ] **P2** First entries: **V10's own games that V8 lacks** (`adv`, `boggle`,
      `doctor`, `morse`, `pacman`, `rain`, `trek`, `wump`, …). Same copyright estate,
      same compiler, no licence question — so the machinery gets debugged on work
      that cannot fail for interesting reasons
- [ ] **P3** Same trick for the **languages already sitting in the V10 tree**:
      Berkeley Pascal is complete there (`cmd/pascal/{pi,px,pxp,pc0,libpc,eyacc}`),
      Fortran is Feldman's own `f77` with `libF77`/`libI77`, and there are `hoc`,
      `icon`, `sml`, `spitbol`, `snocone`, `matlab`, `bc`/`dc`. None of these is a
      port; they are builds
- [ ] **P4** First true port, from 4.4BSD-Lite provenance: `robots` or `worms`
- [ ] **P5** **Franz Lisp** — the real one. `man/mana/lisp.1` proves `lisp`, `liszt`
      and `lxref` ran on the Research machines, but the source is *not* in the tree,
      and Franz Lisp was VAX-native, so it fits this hardware better than almost
      anything else available. Licence is ambiguous (Berkeley origin, distributed with
      BSD, later commercialised by Franz Inc.) — settle it before starting
- [ ] **P6** `gcc` — V10 carries `cmd/gcc/` (145 files, an early 1.x). An ANSI compiler
      on this machine is the key that unlocks everything written after 1989, so it is
      worth knowing whether it builds long before anything depends on it
- [ ] **P7** Reproducibility: a port builds the same way on a fresh golden image

**Out of reach for now: S.** John Chambers', Rick Becker's and Allan Wilks' statistical
language belongs on these machines more than almost anything — it *was* on them — but
Bell Labs gave StatSci an exclusive licence in 1993 and it passed to Insightful and then
TIBCO in 2008. It is not covered by the 2017 covenant and no free source exists. R is
GPL but is a 1993 reimplementation wanting ANSI C, Fortran and far more memory than a
780 has. Both stay open questions rather than plans; **S would need someone at TIBCO to
say yes**, and that is a letter to write, not a task to schedule.

## Track D — ipnx-v11 *(speculative; behind V10, deliberately)*

The Eleventh Edition that never existed. Scope framing and evidence:
[v11-plan.md](v11-plan.md). Nothing is committed and nothing starts before B4.

The admission rule is one question — **does this change the system's model of itself?**
Sockets, vnodes and a wholesale ANSI libc do, and are refused; programs do not. Track D
is the *editorial* track (what belongs in the edition); Track C is the *mechanism*
(how anything gets built). The games are chosen here and built there.

Reconnaissance (2026-08-10) found that much of this is **restoration, not importation**:
V10's own tree carries `cmd/u9fs/` (an original-9P file server — `Tclone`, `Tclwalk`,
`NAMELEN` 28), `cmd/mk/`, and a netfs explicitly designed to take any protocol library.

- [ ] **D0** Licensing pass *first*: Plan 9 is MIT since March 2021 (Plan 9 Foundation),
      so that half is clean. A v11 image still mixes estates and that must be answered
      before code
- [ ] **D1** Build `cmd/u9fs` as it stands and see what it does — the cheapest possible
      probe of the whole thread
- [ ] **D2** Restore `sam`'s host side. There is **no `cmd/sam/`** in the V10 tarball —
      only the 630 terminal half, the man page and the paper. plan9port's sam is MIT and
      the terminal half is already on the disk, so there is a live target from day one
- [ ] **D3** `rc` — Duff's shell; small, self-contained, the absence felt daily
- [ ] **D4** Later, if at all: `acme` on the 5620 (genuinely interesting), `plumber`

**Deferred to Track B, deliberately.** Whether netfs's successor should be **9P** rather
than a documented netb is a real fork in the road, and N4–N7 will reach it — but it is
not worth resolving now, with V10 unbuilt and the interface unrebuilt. Take the netb
route on the N track, keep 9P in view, and decide when Track B is actually there.

**Inferno: parked as a maybe, depending on licensing.** Its estate runs Lucent → Vita
Nuova with GPLv2 and MIT at different points, and until that is settled per component
there is nothing to plan. Note for whoever picks it up: it splits cleanly — **Styx is
9P**, so protocol interoperability needs no VM at all and folds into D1; **Dis and
Limbo** are a research question and plausibly their own edition rather than part of
this one.

## Post-1.0 (unscheduled)

- [ ] Original 68000 Blit mode (Musashi core; requires ROM permission resolution)
- [ ] Emscripten web demo — the first browser VAX
- [ ] V10-era networking exploration (DEQNA/IP)
