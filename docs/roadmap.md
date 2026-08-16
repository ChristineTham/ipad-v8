# Roadmap

*Tracks A and B share one spike: Track A ships a real product on proven ground; Track B is the
research moonshot that lands into the same app shell. C and D are later and declared here so
the README's scope has somewhere to point. Update checkboxes and the status line as work
completes.*

**Current phase: Track B, running the V8 bootstrap again for the Tenth
Edition.** V8 is closed out — Track A through A5, Track S built the disk the
app ships, and B0/B0.5/B0.6 are done.

**The goal is a V10 kernel with the V10 toolchain running on it.** Not a
complete userland: a machine that can compile itself. Everything else follows
from that, and nothing can be trusted before it — a V10 command built on a V8
host is validated against the wrong kernel, and `tools/v10-syscalls.py`
already shows two boot-path programs that provably cannot run there.

So Track B is V8's nine stages in V8's order, with **6 and 7 swapped**: the
kernel before the bulk of the commands. Stage 1 is further from done than B1
made it look — four of the seven passes were *taken* prebuilt off the tarball
rather than built — and stages 2 and 3, libc and the toolchain fixpoint, have
not been started at all. Still unexercised from Track A:
`mux`/`jim` under the Mac's real pointer, which needs a human at a mouse; the
App Store steps need the Apple account. A0
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
- [x] `jim` needs no widening at all — `mux.h` makes `display` a *pointer*
      (`(*Jdisplayp)`) that the layer system fills in at runtime, so every
      program running in a layer follows a resized screen for free. `3nm`
      confirms jim exports `Jdisplayp` and no `display`. **The premise of this
      item was wrong**; only `muxterm` carries a real Bitmap, because it *is*
      the layer system
- [x] `muxterm` widened as a mechanism — `tools/widen-jerq.exp` patches the
      20-byte Bitmap at file offset 50512 (stride 25→36, `corner.x` 800→1152)
      into `muxterm.w`, selected by `/usr/jerq/bin/wmux` through `$MUXTERM`.
      Stock binaries deliberately untouched
- [x] **Driven**: `tools/drive-widemux.sh` boots the image on the desktop SIMH
      and runs `tools/dmdbridge` against a resized 5620 with `wmux`. Rightmost
      lit pixel **x=1151 of 1152** (220,167 lit) against **x=648** for stock
      muxterm, which turned out not to be narrow but *invisible* — it draws
      into the framebuffer's old address. Evidence in
      `work/shots-a4-wide-evidence/`; the image is now the golden one

### A5 — the interface, and the name *(2026-08-10; [ui-redesign.md](ui-redesign.md))*
- [x] Rename the app from **Edition** to **ipnx** — project, both targets, both
      schemes, the source folder and the `@main` struct. The product was always
      `ipnx.app`; only the scaffolding lagged
- [x] Raise the deployment targets to iOS 26 / macOS 26, so the glass is
      unconditional and there is one visual design to test rather than two
- [x] **One listen port per DZ line**, replacing the single mux-wide listener —
      *without this a tab labelled `tty03` is a guess, because `tmxr_poll_conn`
      assigns by connection order and `/.profile` picks TERM from the tty*
- [x] Nine sessions — console + `tty00`..`tty07` — each lazily started, each
      keeping its scrollback, replacing the three-face picker
- [x] Windows grouped by terminal shape (vt100 / vt100w / dmd), tabs within a
      shape *(forced by the missing `TIOCGWINSZ`, not chosen)*
- [x] Console read-only behind a lock; `tty01` logs itself in as root, gated on
      seeing `login:` rather than on a timer
- [x] Liquid Glass on the chrome only — nothing composites over the emulated
      raster
- [x] App icon restyled as a stylised licence plate: `ipnx` over LIVE FREE OR
      DIE, after the plate Armando Stettner gave away at USENIX
- [x] Verified on both platforms — evidence in `work/shots-a5/`: the console
      holds the whole boot transcript, `tty01` reports **line 1** and logs in,
      `tty02` reports **line 2** and stops at `login:`, two windows run one VAX,
      and the iPad shows the same tab bar and `+` menu
- [x] Verify closing the 5620's window reclaims its CPU — measured on the Mac
      app, one instance, driven through the app's own File ▸ Open Terminal menu:
      **16% → 112% → 15% → 112%** (baseline, 5620 open, window closed, reopened).
      The dmd thread is genuinely gone, not idling — the WE32100 does not idle at
      all, so a stopped one is the only cheap one. `close(line)` → `dmd.stop()` →
      `stopFlag.set()` → the runloop's `while !stop.isSet` exits, and reopening
      power-cycles it cleanly (`5620 powered on` twice in the log)

## Track B — the V10 restoration *(desktop SIMH until it boots; see [v10-restoration.md](v10-restoration.md))*

**Where this stands (2026-08-16).** The infrastructure is finished, **a Tenth
Edition toolchain runs on the Eighth Edition machine**, and **fifteen of the
seventeen programs the first boot depends on already compile**. What remains
is the rest of a userland, a kernel, and a boot block — the last of which
nobody has ever made.

### The facts every phase below depends on

Established 2026-08-16 by auditing the tarball by file type, which nobody had
done in the nine years it has been public
([v10-log/2026-08-16.md](v10-log/2026-08-16.md)):

| | |
|---|---|
| Files | **25,682** — `v10src` + `v10blit` + `r70include`, in `work/v10/{src,blit,include}` |
| Linked VAX executables | **483**, including `ccom`, `as`, `make`, `sh`, `sed`, `ls`, `ps` |
| Objects / archives | 1,525 `0407` objects, 150 `ar` archives — including a complete 262-member `libc.a` |
| Do they run on V8? | **Yes.** 9/9, `tools/v10-probe.sh` |
| Syscall slots shared | **112 of 128** identical, `tools/v10-syscalls.py`. Six are V10-only; two of those have a boot-path caller |
| Build files | Mixed and irrelevant: 205 `mkfile`, 153 `Makefile`, 209 `makefile` — and **no world build, and none at all for the boot path** |
| Boot media | **None.** That has not changed, and it is the whole of B3 |

Three consequences that reshape everything after B1:

- **There is no cross-build.** V10's own compiler, assembler and libc run on
  the V8 kernel unmodified, because 111 of 129 syscall slots hold the same call
  at the same index. Only `cpp`, `c2` and `ld` had no binary.
- **The prebuilt binaries are an ORACLE, not a shortcut.** 46 of roughly 283
  command source units have a linked binary — a scatter of 1995 build
  leftovers, since these are developers' working directories. And the scatter
  is telling: `sh`, `sed`, `ls`, `make`, `cpio`, `ps`, `cron` are present;
  `init`, `getty`, `login`, `mount`, `mkfs`, `fsck`, `cat`, `cp`, `rm`,
  `echo`, `date` are **not**, because those get *installed* rather than left
  where they were compiled. So the boot path has to be built regardless — and
  every command that does have a 1995 binary becomes a check on the one we
  build.
- **The machine we already emulate is the right target.** `lsys/io` carries
  `hp.c` (Massbus RP), `dz.c` (DZ11) and **`ni1010a.c`** — an Interlan driver,
  for the card N2 modelled for SIMH. The 780 family is `star`
  (`md/machstar.c`, `consstar.c`, `nexstar.c`, `ubastar.c`, `ml/trapstar.s`),
  and `astro/alice.m` is a real CSRC VAX-11/780 configuration (`ms780`,
  `dw780`, `mba`).

### B0 — reaching the guest *(complete; B0 · B0.5 · B0.6)*

Everything needed to get source into a running V8 and a machine worth building
on. All of it done, all of it recorded elsewhere; this is the index.

| | | |
|---|---|---|
| **B0** | ✅ 2026-08-09 | Host↔guest transfer, `lost+found` repaired, TUHS tarballs fetched — [media-exchange.md](media-exchange.md) |
| **B0.5** | ✅ 2026-08-10 | The N track, N0–N7: RP07 disk, an Interlan NI1010 modelled for SIMH, V8 on the Internet, and **a macOS folder mounted read/write inside V8** over Weinberger's netfs — [networking-plan.md](networking-plan.md), [n-track-notes.md](n-track-notes.md), [netfs-protocol.md](netfs-protocol.md) |
| **B0.6** | ✅ 2026-08-15 | A machine to live in, C1–C4: identity, an account named after the host user, network up from `/etc/rc`, host shares at `/n/macos` and `/n/home` — [machine-config.md](machine-config.md) |

**The courier disk is retired.** B0 proved host↔guest transfer through a
raw-only disk on `rp1` because there was no other way in — tape panics V8's
Massbus adapter — and then sized the tree at 243 MB against a `/usr` of 88 MB
and concluded that ingest had to be selective. netfs deleted the problem
rather than easing it: **the tree is served, not copied**, so nothing lands on
guest disk, no subset has to be chosen, and B1 mounted all 25,682 files at
`/n/v10`. `tools/tapeio.py` and [media-exchange.md](media-exchange.md) remain
for the one case netfs cannot serve — moving a *disk image*.

### The stages, and why they are V8's

**Track B is the V8 bootstrap run again for a different edition.** Track S
spent months getting that sequence right and the reasons it is in that order
are properties of building a Unix, not of building V8:

| stage | builds | with | into | V10 |
|---|---|---|---|---|
| **0** | — | V8's `/bin/cc`, `/bin/make`, `/lib/libc.a` | — | the running golden |
| **1** | the toolchain: yacc-order, then cpp, ccom, c2, as, ld, ar, ranlib, nm, size, strip, cc | stage 0 | `TOOLDIR` | ◐ partial |
| **2** | **libc** | stage 1 | `TOOLDIR/lib` | ☐ |
| **3** | the whole toolchain **again** | stage 1 + stage 2 libc | `TOOLDIR3` | ☐ |
| **4** | the headers | — | `DESTDIR/usr/include` | ☐ |
| **5** | the libraries | stage 3 | `DESTDIR/usr/lib` | ☐ |
| **7** | **the kernel, via `config`** | stage 3 | `DESTDIR/unix` | ☐ |
| **6** | the commands | stage 3 | `DESTDIR/{bin,usr/bin,etc}` | ☐ 17 built |
| **8** | a bootable disk | `mkfs` + `DESTDIR` + boot block + `proto-dev` | a new image | ☐ |
| **9** | the whole system again, from inside itself | `chroot DESTDIR` | the completeness proof | ☐ |

**libc before the second toolchain** is the rule Track S learned the hard way
and it transfers unchanged: every stage-1 binary links against whatever libc
existed when stage 1 ran, so rebuilding the toolchain before libc produces a
set that has to be built a third time anyway.

**6 and 7 are deliberately swapped for V10, and that is the one departure.**
In V8 the commands come first because they and the kernel are the same
edition — a command built in stage 6 runs on the stage-0 kernel, so stage 6 is
testable the moment it finishes. **That is not true here.** A V10 command
built on a V8 host runs on a *V8* kernel until stage 7 replaces it, and
`tools/v10-syscalls.py` already shows this is not hypothetical: 112 of 128
syscall slots agree, six are V10-only, and `mount` and `umount` call two of
them (`fmount` at 26, `funmount` at 50, both `nosys` in V8). Those two are
merely the ones a static scan can see. Building ~283 commands and validating
them against the wrong kernel would be measuring the wrong thing, so the
kernel comes first and the commands are checked against the system they are
actually for.

`config(8)` is the exception that gets pulled forward: stage 7 runs it, it
runs on the *host*, and V10 ships it as `cmd/config/{config.h,config.l,config.y,main.c}`
with **no prebuilt binary**. It is a stage-6 item that stage 7 cannot start
without.

### Where each stage actually stands

- [x] **Stage 1 — the toolchain.** ✅ 2026-08-16, `tools/v10-stage1.sh`,
      **42/43** — `yacc cpp ccom as c2 ld cc` all built from V10 source by
      V10's own compiler, on V10, plus `halt`, `sleep`, `ar` and `cmp`. The
      one failure is `tail`, and it is a finding rather than a defect: it is
      the only file in the whole `src/` tree that includes `<libc/libc.h>`,
      which is ANSI-prototyped and which `ccom` (pcc2, K&R) cannot parse.
      **No binary on that machine was compiled by the Eighth Edition any
      more.** History below, because it explains what the stage was for.
      B1 (2026-08-16) assembled a working set and
      that is *not* the same as having done stage 1. Four passes were **taken
      prebuilt off the tarball** — `ccom`, `as`, `libc.a`, `crt0.o` — and only
      `cpp`, `c2` and `ld` were built from source. V8's stage 1 builds every
      pass from source with stage 0, and that is what this has to become.
      **The prebuilt binaries are the ORACLE, exactly as the 46 prebuilt
      commands are** — B1 proved they run (`tools/v10-probe.sh`, 9/9), which
      makes them the ideal thing to check a from-source build against, and a
      poor thing to substitute for one. Evidence and harness:
      [v10-log/2026-08-16.md](v10-log/2026-08-16.md), `tools/v10-toolchain.sh`.
      **The machinery now exists and runs on V10** — `tools/v10-stage1.sh`,
      which builds `yacc cpp ccom as c2 ld cc` from `v10/mk/gen/tc.order`
      plus `halt`, `sleep`, `ar`, `cmp` and `tail`, none of which the golden
      had. Note what is *not* contaminated: `ccom`, `as` and `libc.a` are Bell
      Labs' own 1995 binaries, so the only V8-built artefacts on the golden
      are `cpp`, `c2` and `ld`, and rebuilding those three is the whole of
      "stop mixing the editions"

**B3.0 — getting source onto the machine** ✅ 2026-08-16. There is no netfs
on V10 and there are two independent reasons, either sufficient: `seki.m`
configures `netafs 0` and `netbfs 0` (the types are compiled in with zero
mount slots), and SIMH's `vax750` has no Interlan model at all. seki's config
*does* carry the card, so the simulator half is ours to fix later.
`tools/v10-srcdisk.sh` builds a second RA81 — 558 files, 4.7 MB, the
toolchain sources plus `libc`, our overlay and our generated makefiles —
mounted on unit 1 at `/n/v10`. The full tree is 306 MB and 22,254 non-binary
files, which fits in no partition here.
- [ ] **Stage 2 — libc from source.** Not started; everything so far links the
      1995 `libc.a`. This is the strongest check available anywhere in Track B
      and the reason to want it is not ceremony: `src/libc/libc.a` is 262
      members with a valid `__.SYMDEF` that already links and runs, so a
      from-source rebuild can be compared **member by member** rather than
      merely observed to compile. Track S's `cmpstage.sh` is the precedent
- [ ] **Stage 3 — the toolchain again, against our libc.** Not started. B1's
      "V10's compiler rebuilt V10's linker byte-identically" is one component
      of this and reads like the whole of it; it is not. The stage is the
      fixpoint — the first set in which every pass came from our source and
      links our libc — and until it passes, nothing later can be blamed on
      the source rather than on the toolchain
- [ ] **Stage 4 — the headers.** Currently a `cpio -pd` of the r70 tree onto
      the guest, done inside the harnesses. That is a staging hack, not the
      stage: V8's is 224 per-file rules so that touching a header reinstalls
      it and rebuilds everything that includes it. Two reconciliations are
      already known and both are defects in the 1995 source rather than in
      the 1997 headers — see the B2.0 notes below
- [ ] **Stage 5 — the libraries**
- [ ] **Stage 7 — the kernel.** The headline moment, and nobody has ever
      compiled one. Detail below
- [ ] **Stage 6 — the commands.** 17 built and installed
      (`tools/v10-make.sh`, 30/30) — the boot path, as a proof of the
      mechanism rather than as the stage. ~266 to go, and they get checked
      against a V10 kernel
- [ ] **Stage 8 — a bootable disk**
- [ ] **Stage 9 — the system rebuilds itself under its own kernel.** For V8
      this re-proved a known-good system; for V10 it is the first time a V10
      kernel would ever host its own build

### What is already done, and what it cost to learn

The infrastructure below is finished and edition-independent. It is *not* a
stage — it is what the stages run on.

| | | |
|---|---|---|
| **B0** | ✅ 2026-08-09 | Host↔guest transfer, `lost+found` repaired, TUHS tarballs fetched — [media-exchange.md](media-exchange.md) |
| **B0.5** | ✅ 2026-08-10 | The N track, N0–N7: RP07 disk, an Interlan NI1010 modelled for SIMH, V8 on the Internet, and **a macOS folder mounted read/write inside V8** over Weinberger's netfs — [networking-plan.md](networking-plan.md), [n-track-notes.md](n-track-notes.md), [netfs-protocol.md](netfs-protocol.md) |
| **B0.6** | ✅ 2026-08-15 | A machine to live in: identity, an account named after the host user, network up from `/etc/rc`, host shares at `/n/macos` and `/n/home` — [machine-config.md](machine-config.md) |
| **import** | ✅ 2026-08-16 | `tools/v10-import.py` — 25,682 files, classified by magic number, 196 case collisions escaped, `--verify` in ~15 s. `v10/MANIFEST` and `v10/CASEMAP` committed; the tree is not |
| **serve** | ✅ 2026-08-16 | The whole 243 MB tree at `/n/v10`, read in place. The courier disk and the subset it forced are both out of the picture |
| **build metadata** | ✅ 2026-08-16 | `mk/mkgen.py` is the generator engine, shared with V8 and proved byte-identical by `v8/mk/mkdep.py --check`; `v10/mk/mkdep.py`, `tools/v10-where.py`, `tools/v10-overlay.py` |

**The facts every stage rests on**, established by auditing the tarball by
file type — which nobody had done in the nine years it has been public:

| | |
|---|---|
| Files | **25,682** — `v10src` + `v10blit` + `r70include` |
| Linked VAX executables | **483**, including `ccom`, `as`, `make`, `sh`, `sed`, `ls`, `ps` |
| Objects / archives | 1,525 `0407` objects, 150 `ar` archives — including a 262-member `libc.a` |
| Do they run on V8? | **Yes.** 9/9, `tools/v10-probe.sh` |
| Syscall slots shared | **112 of 128**, `tools/v10-syscalls.py`. Six V10-only; two have a boot-path caller |
| Build files | Mixed and irrelevant: 205 `mkfile`, 153 `Makefile`, 209 `makefile` — and **no world build, and none at all for the boot path** |
| **Prebuilt kernels** | **SIX.** `seki.u`, `dutoit.u`, `atomic.u`, `u0`, `u1`, `t1` — all 0410 NMAGIC, banners `Unix 10e` 1990/1993. Linked Tenth Edition kernels, public for nine years |
| Boot media | **None** — no bootable *disk*. That is stage 8, and it is a different thing from having no kernel |

Three consequences that shape everything:

- **The prebuilt binaries are an ORACLE, not a shortcut** — and this applies
  to the *toolchain* as much as to the 46 prebuilt commands. 46 of roughly
  283 command source units have a 1995 binary, and the split is telling:
  `sh`, `sed`, `ls`, `make`, `cpio`, `ps`, `cron` are present; `init`,
  `getty`, `login`, `mount`, `mkfs`, `fsck`, `cat`, `cp`, `rm`, `echo`,
  `date` are **not**, because those get *installed* rather than left where
  they were compiled.
- **The machine we already emulate is the right target.** `lsys/io` carries
  `hp.c` (Massbus RP), `dz.c` (DZ11) and **`ni1010a.c`** — an Interlan
  driver, for the card N2 modelled for SIMH. The 780 family is `star`
  (`md/machstar.c`, `consstar.c`, `nexstar.c`, `ubastar.c`,
  `ml/trapstar.s`), and `astro/alice.m` is a real CSRC VAX-11/780 config.
- **`-B` crosses the edition boundary.** S5's extended `-t02palc`, built so
  V8's own build could not reach into the running system, is what points a
  `cc` at a *V10* toolchain: `cc -B/usr/v10/lib/ -t02palc` uses nothing of
  V8's but the driver.

### K — boot a kernel that already exists, before compiling one

**Six linked Tenth Edition kernels are in the tarball** and this plan did not
know. They are 0410 NMAGIC where userland is 0413, so an audit that
classified by "is it executable" put them in the same bucket as `ls`;
`seki.u`'s entry point is `0x80000ad8`, VAX S0 system space, and its banner
reads `Unix 10e Mar 15 04:03 1990`.

This does not replace stage 7 — `alice.m` is the real VAX-11/780 config and
has **no** `.u`, so a kernel for the machine we emulate still has to be
built. What it replaces is stage 7's position as the gate. **A running V10
kernel turns stages 1–3 from a build with no oracle into a build with a
system to check against**, which is the same argument that keeps the 46
prebuilt commands.

`seki` is the target: a VAX-11/750 (`dw750`) with MSCP `ra` disks through a
`uda50`, a `dz11`, and — at the same CSR our V8 config uses — **`ni1010a`**,
the Interlan card N2 already modelled for SIMH.

- [ ] **K1 A `vax750` simulator.** open-simh builds one and its device list
      includes `pdp11_rq.c`, the UDA50/MSCP controller `seki` wants. Desktop
      first; the app is a later question
- [ ] **K2 A V10 root filesystem.** V8 cannot write one: `sys/ino.h` and
      `sys/dir.h` are byte-identical and `struct filsys` matches field for
      field, but `NICFREE` is 178 against V8's 50, which alone changes the
      superblock. `BSIZE` is `BITFS(dev) ? 4096 : 1024` where
      `BITFS(dev) = ((dev) & 64)` — **bit 6 of the device number picks the
      variant**, which is also why `fsck.c` opens `#define BITFS(x) (1)`.
      The way through is Track S's: **V10's `mkfs` takes a prototype file**
      (`mkfs filsys proto/size [m n]`), so one command builds a populated
      filesystem, run *inside V8* against a raw device where V8's kernel
      never has to understand the format. `mkfs` is one of the seventeen
      already built
- [ ] **K3 `/unix` and a boot block.** `lsys/boot/README`: *"The scheme is
      stolen from the VAX-11/750 (comet) hardware."* The ROM reads 512 bytes
      off the device and jumps to it; the boot block then reads `/unix`
      directly, with no intermediate `/boot`. So `/unix` must be at the front
      of the filesystem and **no more than singly indirect**, and block 0
      carries the boot block from `lsys/boot/bb`
- [ ] **K4 `boot rq0`.** Kernel reaches single-user is the moment
- [ ] **K5 A userspace that compiles.** The point of the exercise, and the
      stated goal: `sh`, the toolchain, and enough of `/etc` to log in. Then
      stages 1–9 run *on V10*, which is what they were always supposed to do

### Stage 7 in detail — the kernel

- [ ] **Choose the kernel tree, and say why.** `sys/` and `lsys/` are two
      snapshots of the same kernel: 522 files in common of which **131
      differ**, and different machine-configuration sets (`sys/astro` has 10,
      `lsys` has 17 including `crab`, `pipe`, `west`). Settle it *before*
      compiling, not halfway through. One constraint already removed:
      `lsys/os/sysent.c` and `sys/os/sysent.c` are **byte-identical**, so the
      choice does not change the system-call interface
- [ ] **`mkconf`, not `config`.** V10's kernel configurator is `mkconf`
      and it is **prebuilt** — `lsys/lib/mkconf` and `lsys/mkconf/mkconf`,
      37,932 bytes. (`cmd/config/` exists as source only and is *not* what
      builds a V10 kernel; naming it as the stage-7 blocker was wrong.)
- [ ] **The machine description.** Ours joins `astro/alice.m` — declaring the
      machine we actually emulate — exactly as `usr/sys/ipnx/conf` did for V8
      rather than adopting `alice` or `research` wholesale
- [ ] **The kernel compiles and links.** The three drivers are present:
      `hp.c`, `dz.c`, `ni1010a.c`. **`ni1010a.c` is the same card as V8's
      `ill.c`** — compared 2026-08-16: identical three-register layout
      (`il_csr`/`il_bar`/`il_bcr`) and an identical command set. But V10
      *drives* it differently and our SIMH model was written against V8
      alone: V8's `ilcdone()` spins on `IL_CDONE` where V10's `ilincmd()`
      sets `IL_CIE` and sleeps, and V10 queues up to `MAXRBUFS` = 16 receive
      buffers where our ring was 8. Both hardened 2026-08-16
      (`libsimh/patches/pdp11_il.c`); neither has been exercised by a V10
      kernel, because there has never been one
- [ ] **A conformance test for the device model** — a harness that drives
      `pdp11_il.c` the way *V10* does rather than the way V8 happens to
- [ ] **The boot block**, per `lsys/boot/README`: 512 bytes, kernel at the
      start of the filesystem, no more than singly indirect. Read it in full
      first — it is the constraint that shapes the image layout
- [ ] **First boot attempt.** `vax780` first, for continuity; fallbacks are
      `microvax2` (`mflow`, KA630) and `vax8200` (`bvax`, KA820), both of
      which V10 supports and SIMH emulates. **Kernel reaches single-user** is
      the headline
- [ ] **Announce on TUHS** — this answers a question that list asked in 2017,
      and the people who ran these machines still read it

### What B2.0 measured, and the two source defects it found

`tools/v10-bootpath.sh` (35/46) built the seventeen boot-path programs twice,
against V8's headers and against r70's: **15 built against r70**, 10 against
V8's, and all five safe to execute then ran. That is why stage 4 points `-I`
at V10's own tree. The two failures are one line each, and **both are defects
in the 1995 source rather than in the 1997 headers**:

- `fsck.c` is a file caught mid-port — `<ansi.h>`, `<posix.h>` and
  `<sys/stat.h>` are all commented out, it includes a `<stat.h>` that exists
  nowhere, it carries ANSI prototypes the 1985 compiler rejects, and it calls
  POSIX `S_ISBLK()` macros V10's `sys/stat.h` does not define. Three separate
  consequences of one abandoned port, each hidden behind the one before
- `mv.c` uses `ROOTINO` and includes nothing that defines it

r70 was suspected first and cleared: the tarball ships 1995 copies of these
headers in `sys/` and `lsys/`, and `src/sys/sys/types.h` is **byte-identical**
to r70's. **"Skew or source?" is a `cmp`, not a judgement** — ask it before
writing down an inference. Our corrections live in `v10/src`, generated by
`tools/v10-overlay.py` from hashed upstream files so the tarball stays
pristine and `v10/MANIFEST` still proves it; `v10/src/PATCHES.md` carries the
diffs and the reasoning.

### B4 — the V10 experience

- [ ] Multi-user: `init`, gettys, `login`
- [ ] `mux` against dmd_core (firmware 8;7;3 — the protocol is unchanged from V8)
- [ ] **`sam` and `samterm`** — the reason `v10blit` matters, and something V8
      never had
- [ ] A reproducible `v10.disk` build script, in the shape of Track S's stages

### B5 — merge into the app

**Two machines, two goldens, and the user picks.** V10 is built *independently*
of V8 and ships *beside* it — it does not replace it, and V8's golden is not a
staging area for V10's. Concretely:

- Two committed images, each with its own identity stamp and its own
  `Embed … media` build phase, so `tools/app-check.sh` proves both chains
- Two working copies: `~/Library/Application Support/ipnx/v8` and
  `…/ipnx/v10`. The app has been shaped for this since 2026-08-16 — the
  support directory is *app first, edition inside*, for exactly this reason
  (`Machine.support`)
- The consequence for Track B is a constraint, not a feature: **nothing in
  B2–B4 may modify the V8 golden.** V8 is the build host and the shipped
  Eighth Edition, and those are the same disk. Anything V10 needs on the guest
  goes in a scratch filesystem or a share, never into `rp07new`

- [ ] "Edition 10" as a second machine beside V8, chosen at launch
- [ ] A second golden, built and committed on its own terms
- [ ] Embed the winning SIMH simulator if it is not `vax780`

## Track S — the world build *(started 2026-08-10, [build-from-source.md](build-from-source.md))*

> **A note on the letter C.** Three different things in this repo have been
> called C, and it has already caused confusion. "Track C" below is
> **ipnx-ports**. B0.6's **C1–C4** are *image and machine configuration*. The
> task list's **C1–C6** are *this* section — building the system from our own
> source. Prefer **S1, S2, …** for these from here on; the task subjects still
> say C and are not worth renumbering mid-flight.

Building Research Unix from the source in `v8/` rather than shipping a disk
image someone else made. This is what makes `v8/` a *source tree* instead of an
archive, and it is the foundation for Track B — you cannot cross-build V10
inside V8 until you can rebuild V8 itself.

Research Unix never had a world build; the stages, the ordering evidence and
the safety rules are in [build-from-source.md](build-from-source.md).

- [x] **S1** Take ownership of the tape as ipnx source — 7,819 files, `MANIFEST`,
      case collisions escaped, `ar` source archives unpacked *(2026-08-10)*
- [x] **S2** Serve it read-only at `/n/src` over netfs, with the escaped names
      resolved server-side — nothing is copied to guest disk *(2026-08-10)*
- [x] **S3** **Stage 1: the bootstrap toolchain builds from our source.** All
      fourteen of `yacc make lex cpp ccom c2 as ld ar ranlib nm size strip cc`,
      compiled off the share into a separate build filesystem. The compiler
      works and agrees with the 1985 one byte-for-byte on the same input
      *(2026-08-10; `tools/drive-stage1.sh`, `work/myv8/c2-stage1.log`)*
- [x] **S4** Stage 2 (libc) then stage 3 (the toolchain again, against it) —
      `same=14 differ=0`, so the system reproduces itself *(2026-08-10)*
- [x] **S5** `cc -B` extended to `as`, `ld`, `crt0.o` **and `libc.a`** — the
      hermeticity gaps *(2026-08-10)*. `-t02palc` seals everything `cc`
      executes; `-t c` also stops it appending `-lc`, which mattered most
      because V8's `ld` has no `-L` and would have resolved the C library out
      of the running system silently. `yaccpar` moved to a **runtime**
      `$YACCPAR` rather than an `#ifndef`, so stage 1's yacc and stage 3's
      stay byte-identical. Verified with the full seal in place:
      `same=14 differ=0`, and `cmp-sealed-vs-oldcc=0` — our `as` and `ld`
      reproduce the tape's output too. Two bugs fell out: libc was being
      compiled by the *tape's* `cc` (the script conflated "which compiler"
      with "which directory"), and the fixpoint test needed the classic
      stage3-vs-stage3b fallback, now in `v8/mk/fixpoint.sh`
- [x] **S6** Stages 4–7: headers, libraries, then everything. Four separate
      pieces, in a forced order, each blocked on the one before:
  - [x] **4** headers — 224 files into `DESTDIR/usr/include`; nothing after
        this compiles against the running system's *(2026-08-10, first run)*
  - [x] **5** libraries — 19 archives (curses, termcap, F77, I77, mp, l, jobs,
        cbt, dbm, dk, g, **in**, and the seven plot libraries); libc is
        stage 2 *(2026-08-11)*. `curses-ok` proves it together with stage 4:
        a program compiled against our headers, linked against our
        `libcurses` and `libtermcap`, and run
  - [~] **6** commands — **193 built, and the target is not what it looked
        like** *(2026-08-11)*. The shipped image carries **381 commands**;
        we install **205** of them. But of the 176 we do not, **147 have no
        source anywhere in the tape** — including **all 34 games**, whose
        binaries ship in `/usr/games` with nothing behind them. So the
        buildable universe is **234**, and 205 of 234 is **88%**, with
        `/bin` — the partition that has to be self-sufficient when `/usr` is
        unmounted — at **50 of 57**.

        The 29 that remain are listed individually in
        `gen/stage6-skipped.txt`. The largest group needs `xstr`: `csh` and
        `ex` both pipe every object through it to share string literals, and
        `strings.o`, which both links, is *produced* by that pass rather than
        compiled. `awk` needs a `maketab` built and run mid-build to generate
        `proctab.c`. Four link archives built inside their own component
        (`map`, `plot`, `view2d`, `asd`), five include headers the tape never
        shipped, and two — `cfront` and `compat` — the 1985 compiler rejects
        outright.

        Detail below, and the original count of "~277" is superseded: it
        counted source directories, not commands the image actually has.

        Composition: 31 hand-written
        (`config`(8), `sh`, the boot path, `nmount`) plus **121 derived** from
        the tree and `v8/mk/where.txt`, plus **the whole toolchain installed
        into `DESTDIR`** — a system with no compiler cannot rebuild itself,
        which is the whole of stage 9. Every install path **measured**:
        `tools/harvest-paths.sh` walks a booted golden image and writes 434
        entries, because the 165 loose `.c` have no makefile of any kind and
        `/bin` vs `/usr/bin` decides whether the system can repair itself with
        `/usr` unmounted. All seven names it had refused to guess (`date`
        `rm` `cat` `ls` `echo` `chmod` `sync`) are `/bin`. The 113 makefile
        directories are read for the two facts only they know — which objects
        and which extra libraries — and 62 derive cleanly.

        **118 are refused, each with a stated reason** in
        `gen/stage6-skipped.txt`, and every rule was written by a build
        failure rather than foreseen: one `main()` or it is not one program
        (`asd` holds five, `refer` twelve, `view2d` thirteen); the directory
        and not just the makefile (`pp` carries a `scan.l` its makefile never
        names); an archive built inside the component (`map`'s `libmap.a`); a
        header the tape does not ship (`sdb`'s `bio.h`, plus three components
        including headers by **absolute path** into a live machine); a source
        that is not C (`csh`'s `doprnt.c` is VAX assembly with cpp
        directives); and a `.c.o` redefined as a multi-step recipe (`csh`'s
        `xstr` string sharing). Two the 1985 compiler simply cannot build are
        refused by name: `cfront` (C++) and `compat`.

        No new library blocks the rest — `-lm` needs nothing at all, since V8
        compiles `math/*.c` straight into `libc.a` — and of every `-l` in the
        113 makefiles only `ether`, `chaos`, `y` and `ln` name something with
        no source in the tree, blocking three directories
  - [x] **7** the kernel — **a 236,520-byte `unix`, built from our source
        with our toolchain** *(2026-08-11)*. `usr/sys/ipnx/conf` is `alice`'s
        VAX-11/780 plus the Internet pseudo-devices `research` had, and it is
        the machine we actually emulate rather than either of the tape's. The
        only stage that copies source, because `config` resolves its inputs as
        `"../conf/"` by string concatenation
- [x] **S7** Stage 8: a disk built from source, **and a boot from it**
      *(2026-08-11)*. `v8/mk/builddisk.sh` makes both filesystems, fills them
      from `DESTDIR`, writes 414 device nodes from `proto-dev` and installs
      the kernel; `tools/boot-newdisk.sh` boots the image **alone** — nothing
      else attached, so nothing missing can be satisfied from another drive —
      and gets the boot block finding `hp(0,0)unix`, the autoconfig, `login:`,
      a root shell, `/usr` mounted, and a C program **compiled and run** by
      the compiler stage 6 installed. Its own prerequisite was booting the
      build machine on our stage-7 kernel (`tools/install-kernel.sh`), because
      stage 8 needs a third drive and no machine description on the tape
      declares more than two. What it still lacked at that point was most of
      `/usr`: 36 files in `/bin`, 73 in `/usr/bin`, and `/etc/rc` reporting
      `cron` and `rmdir` missing — closed by **S10**, which is where the
      difference between "we built it" and "it is on the disk" turned out to
      live
- [x] **S8** Stage 9: the new system rebuilds itself under `chroot` — the point
      at which `v8/` is demonstrably complete *(2026-08-11)*. **9 of 9 tools**,
      rebuilt from source by the compiler stage 6 installed, inside
      `DESTDIR`, with **no `-B` and no `TOOLDIR`**: `yacc make lex cpp ccom c2
      as ld ar ranlib nm size strip cc` and then libc. `v8/mk/buildstage9.sh`.

      V8 has `chroot(2)` — syscall 61 — and ships **no `chroot(1)`**: no
      command on the image, no source in `usr/src`, no manual page. So
      `v8/usr/src/cmd/chroot.c` is ours, and stage 6 installs it as
      `/etc/chroot`. `cc(1)` is why it has to be a real chroot rather than a
      `-B`: `-B` is a *runtime* option, so the `cc` in `DESTDIR` still carries
      `/lib/ccom` as its compiled-in pass directory and, run from outside,
      would silently use the **building** system's passes and report success
      for a `DESTDIR` containing none of them. Under chroot
      `DESTDIR/lib/ccom` *is* `/lib/ccom`, so a missing pass fails instead of
      being borrowed — which is the whole experiment.

      Three things a chroot needs that nothing lists: `/dev/null` (there is no
      `/dev` in `DESTDIR` at all, so every `> /dev/null` reads as a
      permissions problem), a build directory that is not `/` (`//obj9` is
      rejected by V8's `mkdir` on all fourteen components), and the share
      mounted **inside** the new root before entering it
- [x] **S9** Our guest-side patches move into the tree *(2026-08-11)*: the
      `streamio.c` `istread`/`istwrite` rewrite with `strdata` widened from
      512/256 to **8192/4096**, `nmount.c`, and the `il0` kernel config —
      `usr/sys/ipnx/conf` declares `il0 at uba? csr 0164040` plus the `inet`,
      `uarp`, `tcp` and `udp` pseudo-devices. Every kernel stage 7 builds now
      carries all of it by construction, rather than by a driver patching a
      running machine. `chroot.c` (S8) and `date.c`'s 69/70 window joined them
- [x] **S10** **The golden disk is ours, and the TUHS image retires**
      *(2026-08-11; [golden-disk.md](golden-disk.md))*. The disk stops being
      "what we could build" and becomes a complete system: 206 built, **1406
      carried** off the reference image because the tape shipped them without
      source, and the runtime trees installed beside them.

      The gate is not "does our disk equal theirs" — it does not, and should
      not. It is **containment**: every file on the TUHS image is on ours, or
      in git as a `MANIFEST` `source` row, or named individually as
      deliberately regenerated. `tools/retire-check.py` decides it, and while
      one file is left over it fails.

      Two tools made this cheap enough to do at all. `tools/v8fs.py` reads a
      V8 filesystem out of a SIMH image **from macOS**, so "what is actually
      on that disk?" stopped meaning "boot a VAX and read `find` off a serial
      line". And stage 8's `cp`-per-file loop became one `cpio -p` fed by a
      generated manifest: 22 MB in six seconds, where 400 copies had been the
      slowest thing in the stage.

      `tools/mkcarry.py` generates the three lists and, for the 2264 runtime
      files, **sha256-compares the image's copy against ours** — 2263 match,
      so they come off the mounted disk instead of over netfs, which costs a
      round trip per file and would have taken ninety minutes. The one that
      differs comes from `/n/src`. It is a proof, not a shortcut, and it is
      re-run every time the lists are regenerated.

      Four files were found missing that no boot test could have caught, each
      a different way for a build to lie about itself: `bcd` built into
      `DESTDIR/usr/games` with `usr/games` absent from stage 8's copy list;
      `yacc` and `strip` installed to `TOOLDIR/bin`, reaching the toolchain
      and never `/usr/bin` — where `where.txt`, the image and our own
      `provenance.txt` all say they belong, and where `mkdep.py`'s generated
      makefiles default `YACCPATH` to look; and `wmux`, ours from A4, which no
      `MANIFEST` row describes and no generated list picks up.

      **Done.** The whole pipeline reran from bare source — `STAGE1` through
      `STAGE9-CHROOT`, 193 commands with zero failures, a 236,672-byte kernel,
      and the fixpoint holding at `same=14 differ=0` after the `yacc`/`strip`
      move. `retire-check` reports **UNIQUE 0**; `boot-newdisk` boots the image
      alone and passes all thirteen checks. `image/ipnx-v8-rp07.img.xz` is in
      git at **7.6 MB**, 1.55% of raw.

      And the loop is closed: `carry.txt` regenerated from **our** disk gives
      the same 1405 paths as from the TUHS one, so the reference now defaults
      to ours and the build's only external input is the tapes

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
- [ ] Emscripten web demo — the first browser VAX. *The emulator compiled to WASM; not
      the same thing as the v12 wish below, which is the opposite — no VAX at all*
- [ ] V10-era networking exploration (DEQNA/IP)

## ipnx-v12 — a wish, and deliberately not a track

Research Unix retargeted to **ARM64** and **WASM**: ipnx on real hardware and in a browser
tab, with no emulated 11/780 underneath. There are no phases here and there should not be —
this is weaker than Inferno's "maybe", and everything above it comes first.

Written down only so the direction survives: the kernel's portability boundary is already
explicit (`sys/md/` per machine, `sys/ml/` for the assembler), and the system has crossed
it before — Interdata, VAX, Cray. See the README for the longer note.
