# Architecture

*Living spec. [RESEARCH.md](../RESEARCH.md) holds the evidence and alternatives considered;
this document holds the current design. Update it as code lands.*

## Principles

- **Full-system emulation.** The real Research Unix kernel runs on an emulated VAX. No
  syscall translation, no faked processes — iOS's no-fork/no-exec/no-JIT rules never apply
  because the app is one process running ahead-of-time-compiled interpreters.
- **Edition-agnostic shell.** The app knows about *machines* (a SIMH simulator + a disk
  image + a serial wiring), not editions. V8 and, later, V10 are just images. The `mux`
  protocol is stable across V8–V10, so the terminal side never changes.
- **Authentic wire, cheated speed.** The one place we deviate from history is the serial
  link's pacing — it must run unthrottled or the terminal-program download takes ~17 min.

## Components

| Component | Source | Language / license | Role |
|---|---|---|---|
| VAX emulator | [open-simh](https://github.com/open-simh/simh) `vax780` | C, MIT | Boots the Research Unix disk image; console + DZ11 serial mux; no SDL/network deps needed |
| Terminal emulator | [dmd_core](https://github.com/dmdmtg/dmd_core) | Rust (C FFI), MIT | DMD 5620: WE32100 CPU, DUART, 8 KB NVRAM, 800×1024×1 framebuffer; firmware **8;7;3** embedded |
| Console UI | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (in use since A1) | Swift, MIT | VT100 view on the SIMH console line — boot diagnostics, login, pre-graphics milestone |
| App shell | this repo (to be written) | Swift/SwiftUI + Metal | Framebuffer view, input mapping, machine lifecycle, settings, persistence |

## Process model

One iOS process. Threads (all real since A2):

- **simh thread** — runs the SIMH main loop via `simh_vax780_run()`
  (`libsimh/`; compiled **without** `SIM_ASYNCH_IO`, so the V8-critical
  synchronous mode is a build-time guarantee, not a config line).
- **dmd thread** — steps the WE32100 at ~10 MHz wall-clock (`libdmd/`,
  `Terminal5620.swift`: the A0 bridge's pacing model ported verbatim —
  the DUART is a wall-clock state machine) and exchanges bytes with the
  DZ socket.
- **main thread** — SwiftUI + Metal (the 5620's packed VRAM expanded in a
  fragment shader with the phosphor tint); feeds input events as mouse
  counter deltas and paced keyboard bytes.

Control plane (A1, desktop-proven): the app talks to the embedded SIMH over
two localhost sockets — the **telnet console** (127.0.0.1:42323, a pure V8
byte pipe feeding SwiftTerm) and the **SIMH remote console**
(127.0.0.1:42324), where ^E suspends the simulator into command mode for
`save`/`continue`. The channel dialects differ sharply (WRU handling, IAC
tolerance, prompt behavior) — see the table in [a1-notes.md](a1-notes.md)
before touching this plumbing.

## Serial transport

The DZ11's line 0 connects to the 5620's DUART port A.

- **v1 (zero-patch):** SIMH attaches the DZ as a telnet listener on `127.0.0.1`
  (`set dz lines=8` / `att dz -m 8888`); a shim socket pumps bytes into dmd_core's RX queue
  and drains its TX queue, stripping telnet IAC minimally. This is exactly how the proven
  desktop setups work; localhost sockets inside one app are fine on iOS.
- **v2 (the pacing fix):** still not needed, but for a better reason than A2 gave.
  A2 deferred it believing dmd_core's DUART was the floor. Instrumenting the injector
  (rx rate plus **queue depth**) showed the inbound queue permanently empty at ~950 B/s
  — the bottleneck was upstream: `pdp11_dz.c` declares `tmxr_set_port_speed_control`, so
  SIMH throttles the socket to the 9600 baud V8's tty driver programs. Two 9600 throttles
  were in series. Attaching with `Speed=*32` multiplies the guest's rate without lying to
  it: sustained rx goes 950 -> ~4,300 B/s and the `mux` download ~100 s ->
  **~15 s**. The transport itself was never the
  problem, so an in-process queue would not have helped.

## Display

The 5620 framebuffer is a ~100 KB window of terminal RAM (800×1024 ÷ 8). Render: copy to a
Metal texture (or CGImage) with dirty-region diffing at up to 60 Hz; map 1-bit pixels to a
configurable phosphor tint. The 800×1024 portrait geometry matches an iPad held vertically
almost exactly.

## Input

| iPad input | 5620 event |
|---|---|
| Touch / Pencil tap-drag | Mouse move + **button 1** |
| Trackpad/Magic Mouse pointer | Mouse move (true hover); secondary click → **button 3** (mux layer menu) |
| Two-finger tap (or on-screen modifier bar) | **button 2** / **button 3** |
| Hardware keyboard | DUART port B keyboard bytes |
| On-screen toolbar | Soft-keyboard toggle, button-2/3 modifiers, machine controls |

## Persistence

- **Disk image**: bundled pristine copy; working copy in the app container
  (backup-excluded); Files-app import/export for power users (UTM SE /
  iDOS 3 pattern).
- **5620 NVRAM** (8 KB): file in the app container — terminal settings survive relaunch.
- **Instant-on** (real since A1): on background the machine suspends via the
  remote console and `save state.sav` (zero CPU while paused — the 97 %
  idle burn stops); foreground sends `continue`; a cold relaunch replays
  the snapshot via `restore`. A snapshot is deleted the moment the machine
  runs again — it is only disk-consistent while paused — so unclean kills
  cold-boot and V8's autoboot fsck self-heals.

## Machine matrix

| Machine | SIMH simulator | Image | Status |
|---|---|---|---|
| Edition 8 | `vax780` (RP06, DZ11, `set noasync`) | `v8.disk` built by [myv8](https://github.com/timnewsham/myv8) | Proven on desktop; Track A |
| Edition 10 | `vax780` (`star` kernel) first; fallbacks `microvax2`, `vax8200` | `v10.disk` from Track B | **Unprecedented**; see [v10-restoration.md](v10-restoration.md) |

## Non-goals (for now)

- Networking out of the emulated machine (Datakit is gone; DEQNA/IP is a V10-era stretch).
- The original 68000 Blit mode (ROM permissions unresolved — see [licensing.md](licensing.md)).
- WASM/browser build (post-1.0 demo candidate only).
