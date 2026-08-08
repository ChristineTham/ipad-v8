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

## Session artifacts (all under gitignored `work/`)

`simh312/sim/BIN/vax780` · `myv8/rp06v8` (the bootable V8 disk) · `myv8/setup.log` ·
`myv8/boot.log` · `boot-hold.exp` · `dz-login.exp` · `dztalk.py`
