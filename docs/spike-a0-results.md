# Phase A0 — spike results (session 1, 2026-08-08)

**Bottom line: the V8 appliance works end-to-end on this Mac.** Classic SIMH 3.12-5 built
clean, myv8 produced the RP06 image in ~2.5 minutes, V8 boots to multiuser, and a scripted
DZ-line session logged in, listed `/proc`, compiled and ran C, and started `mux` far enough
to capture its terminal-identification handshake. The only unfinished leg is a real terminal
emulator on the other end of the wire — blocked by a machine constraint (no package
manager), with a clear path forward.

## What was proven

| Step | Result | Evidence |
|---|---|---|
| SIMH build | `simhv312-5.zip` → `make vax780` in the `sim/` subdir; **warnings only** on modern clang | `work/simh312/sim/BIN/vax780` (639 KB) |
| V8 install | `./setup` ran unattended to "Done." | `work/myv8/setup.log`; `rp06v8` + `rp06bsd` (174 MB each), **~2.5 min wall clock** |
| Boot | `vax780 run.conf` → single-user `# ` shell, no prompts; `^D` → multiuser with DZ gettys | `work/myv8/boot.log` |
| DZ login | `login: root` (no password) over telnet :8888 | full Eighth Edition motd ("a trolley car is certain to grow in your stomach…") |
| System alive | `ps`, **`ls /proc`** (populated!), `cc h.c && a.out` → "hello from V8" | `work/dztalk.py` transcript |
| Terminal software | `/usr/jerq/bin` (5620: mux, 32ld, jim, crabs, proof, paint…) and `/usr/blit/bin` (68K: mpx, 68ld…) both installed | ls output in transcript |
| mux handshake | `/usr/jerq/bin/mux` emits **`ESC [ c`** (hex `1b 5b 63`, a Device Attributes query) and waits for the terminal's identification — exactly what a 5620 with 8;7;3 firmware answers | dztalk mux-poke capture |

## Measurements

- **Install**: ~2.5 min for the full 4.1BSD → V8 chain (Apple Silicon).
- **Serial pacing**: no artificial throttling observed under classic 3.12-5 — compiles and
  directory listings render instantly over the DZ. The community's "17-minute muxterm load"
  appears specific to newer SIMH's realistic line-speed emulation. Definitive mux download
  timing still requires a real terminal emulator.
- **Idle CPU**: `vax780` sits at **~97% of one core while V8 is idle**. Idle
  detection/throttling is mandatory for the iPad app (research risk confirmed).

## Environment gotchas discovered (runbook corrected)

1. **No Homebrew on this machine.** The runbook's `brew install …` prerequisites were
   wrong for this host. Stock macOS provides `expect` (all myv8 needs). There is **no
   telnet client**; `work/dztalk.py` (Python, handles IAC negotiation) replaces it.
2. **A shell-pipeline trap**: `brew install … | tail` masked the "command not found" —
   the SDL2 "install" silently did nothing. Check exit codes of the *first* pipe stage.
3. **Mark parity on first contact**: V8's getty sends the initial `login:` prompt with the
   parity bit set (`lo\xe7i\xee:`); byte-matchers must strip bit 7 until after login.
4. **`mux` is not on root's PATH** — invoke `/usr/jerq/bin/mux`.
5. The simh zip unpacks into a `sim/` subdirectory (the makefile lives there).

## Remaining for A0

- **Terminal emulator leg**: SDL2/GTK builds are out (no package manager), but **Rust/cargo
  is installed** — the chosen route is `dmd_core` driven headless: a small cargo binary that
  bridges the DZ socket to the emulated 5620 (firmware 8;7;3), answers the `ESC [ c` probe,
  lets mux download muxterm, and dumps the 800×1024 framebuffer to image files for visual
  proof. No GUI toolkit needed, and it prototypes exactly the embedding the iPad app does.
- Definitive muxterm download timing (needs the above).
- Re-verify the appliance under **open-simh + `set noasync`** (the app will ship open-simh).

## Session 2 (2026-08-08, later): the headless dmd_core bridge

**Built and working**: [tools/dmdbridge](../tools/dmdbridge) — a Rust binary embedding
`dmd_core` (pinned git rev) that connects to SIMH's DZ telnet line, handles IAC, strips
mark parity, auto-logs-in, starts `/usr/jerq/bin/mux`, paces bytes into the DUART, dumps
the 800×1024 framebuffer to PNGs, and drives scripted mouse gestures. The full state
machine (login → shell → mux → download) runs unattended. This is the iPad app's terminal
embedding, prototyped.

**Timing measurements (the spike's core question, now fully answered):**

- SIMH does **no** serial throttling (3.12-5's tmxr has zero speed support). The pacing
  lives in **dmd_core's DUART**, which delays per-character in *wall-clock* time at the
  programmed baud.
- A factory-fresh 5620 (empty NVRAM) runs its host port at the 1984 default of **1200
  baud** → measured **156 B/s** sustained. muxterm is **144,603 bytes** → full download
  ≈ **15.5 minutes**. *That* is the community's "17-minute" number, reproduced from first
  principles — it was never SIMH.
- Turbo experiment (local `delay_rate ÷ 8` patch ≈ 9600-baud equivalent, the real
  hardware's supported speed): sustained **~1,100–1,230 B/s** → full download would be
  ≈ 2 minutes. A ÷64 attempt destabilized the firmware — **app guidance: pace the wire at
  hardware-realistic 9600/19200 equivalent, not unthrottled.**

**The 8;7;3 firmware requirement, mechanically explained** (new finding): dmd_core's
GitHub HEAD embeds only the **8;7;5** ROM. With V8's `32ld` download, that ROM
deterministically executes **`MOVTRW`** (a WE32100 MMU-translation instruction) at
PC=0x496c ~30 KB into the transfer — which dmd_core's CPU doesn't implement → panic.
Patching MOVTRW as identity-translation advances execution *into the downloaded code*
(PC in RAM), which then hits an **unaligned word access** — legal on real WE32100 silicon,
unimplemented in dmd_core. So "use firmware 8;7;3" is not protocol lore: **8;7;3 simply
avoids WE32100 corner-cases that dmd_core never needed for SVR3.** Two viable paths:

1. **Obtain the genuine 8;7;3 ROM image** (Sark's 2022 dump, per the TUHS thread) and
   swap it into `rom_lo.rs`/`rom_hi.rs` — the community-proven configuration. ← preferred
2. Finish dmd_core's WE32100 fidelity (MOVTRW semantics from the manual + unaligned
   access support) and upstream it to Seth Morabito.

**Experiment state** (gitignored): `work/dmd_core` = patched checkout (÷8 turbo,
MOVTRW-identity); `tools/dmdbridge/.cargo/config.toml` redirects the build to it — delete
that file to build pristine. `work/turbo-run.sh` = one-shot run-with-cleanup harness.

## Session 3 (2026-08-08, evening): the 8;7;3 ROM — found, fixed, nearly there

**The ROM hunt succeeded.** The dmdmtg GitHub mirrors are stale (pre-2022); the canonical
repos live on Seth Morabito's Gitea (`git.loomcom.com/seth/{dmd_core,dmd_gtk,dmd_sdl}` —
the HTML is bot-walled but `git clone` and the Gitea API work). Canonical `dmd_core` 0.7.1
(rev `ee222b68`) embeds **both** firmwares — `Dmd::reset(1)` = 8;7;3, `reset(2)` = 8;7;5 —
and the bridge now builds against it ([tools/dmdbridge/Cargo.toml](../tools/dmdbridge/Cargo.toml)).

**Three real emulator bugs found and fixed** (patches:
[tools/dmdbridge/patches/dmd_core-spike-patches.diff](../tools/dmdbridge/patches/dmd_core-spike-patches.diff),
applied to a local checkout via the gitignored `.cargo/config.toml` redirect; all are
upstream-PR candidates):

1. **8;7;3 power-on hang**: the ROM's walking-bit DUART loopback self-test ends each
   sequence with a BREAK — which a real UART receives as a 0x00 data byte plus error flags.
   The core set the flags but never delivered the byte, so the ROM retried the self-test
   forever ("RAM TEST" frozen on screen). Diagnosed by single-stepping with an added
   `ir_debug()`; fixed by delivering the byte. **The 8;7;3 terminal now boots fully** and
   renders the V8 login session (screenshot captured).
2. **Keyboard overrun**: the kb FIFO is 3-deep and wall-clock-paced; typing faster than
   ~a few ms/key silently drops keystrokes mid-word. Bridge now types at 100 ms/key.
3. **CPU pacing**: the DUART is a wall-clock state machine; a flat-out CPU races its
   service deadlines nondeterministically. Bridge now paces the WE32100 to ~10 MHz
   (exactly what Seth's SDL frontend does).

Also confirmed: 8;7;5 hits the `MOVTRW` wall on the canonical core too — **8;7;3 is
mandatory for V8**, now understood three levels deep.

**Where it stands — one wall left**: with 8;7;3 booted and typing fixed, `mux`'s download
runs and stalls **deterministically at 55,138 bytes (38%)**, reproduced twice at the exact
same byte. Prime suspect, with direct evidence: the terminal signals `32ld` block/segment
boundaries by sending a **BREAK to the host**, and `dmd_core`'s `CR_START_BRK` handler
contains literally `TODO: We may want to expose a BREAK condition to the outside world` —
the outgoing break is dropped, so V8 waits forever. **Next session**: surface the outgoing
break (core patch → bridge translates it to telnet `IAC BREAK` toward SIMH; verify classic
SIMH's tmxr delivers inbound breaks to the DZ), then the mux desktop should appear.

The inbound half is already plumbed: `rs232_break()` added to the core, and the bridge
translates telnet `IAC BREAK` (243) into it, in-order.

## Session artifacts (all under gitignored `work/`)

`simh312/sim/BIN/vax780` · `myv8/rp06v8` (the bootable V8 disk) · `myv8/setup.log` ·
`myv8/boot.log` · `boot-hold.exp` · `dz-login.exp` · `dztalk.py` · `turbo-run.sh` ·
`shots*/` (framebuffer PNG series from three bridge runs) · `dmd_core/`, `dmd_gtk/`
(reference checkouts; dmd_core carries the experiment patches)
