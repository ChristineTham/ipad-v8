# The interface: nine ttys, windows by shape, Liquid Glass

**Status: built and verified on macOS, 2026-08-10** (`b08f86f`). Supersedes the
three-face picker (Console / Terminal / 5620) that shipped through A4.

## What was asked for, and what it became

1. **Tabs for all eight lines**, not three faces. V8 runs a getty on `console`
   and `tty00`..`tty07`, so nine sessions are available. ✅
2. **The console is read-only by default**, with a toggle to enable input. ✅
   — a lock in the Mac toolbar, a glass lock on the iPad tab bar.
3. **tty01 is logged in automatically** on first open. ✅ — gated on seeing
   `login:`, never on a timer.
4. **Every session is lazily started** — opening a tab is what dials it. ✅
5. **Multiple windows, not just tabs.** ✅ — `WindowGroup(for: TerminalShape.self)`.
6. **Apple HIG, Liquid Glass.** ✅ — on chrome only.

## Why windows-by-shape is forced, not a style choice

This kernel has `struct sgttyb` and **no `TIOCGWINSZ`** — that arrived in
4.3BSD. Nothing can tell V8 how large a window is, so a terminal's grid is
whatever its termcap entry says and nothing else:

| session | termcap | grid | DZ line |
|---|---|---|---|
| 5620 | `dmd` | 1152×1024 px (127 cols) | 0 |
| console | `vt100` | 80×24 | — (SIMH console) |
| plain | `vt100` | 80×24 | 1..6 |
| wide | `vt100w` | 128×24 | 7 |

Three fixed, unequal shapes. They cannot be reflowed into one another, so tabs
only make sense *within* a shape — which is exactly the requested behaviour,
arrived at from the hardware rather than from taste.

The console falls in the `vt100` window because that is what it *is*: with no
`/etc/ttytype`, `/.profile` runs `case \`tty\` in` and `/dev/console` takes the
`*)` arm. Measured, not assumed — `work/myv8/config.log` records a fresh
console login reporting `TERM=vt100`.

## The load-bearing change: one listen port per DZ line

The old configuration attached **one mux-wide listener** and let
`tmxr_poll_conn` hand each new connection to the next free line. That made the
tty you landed on a function of the order you opened tabs — and since
`/.profile` picks TERM from the device name, connection order decided what
terminal V8 thought you were. A tab labelled `tty03` would have been lying.

Every line now has its own listen port (`Machine.dzPort(_:)` = `portBase+2+n`),
so the mapping is a property of the port dialled. This is supported directly —
*"Each line can have a separate listen port and the mux can have its own as
well"* (`sim_tmxr.c`) — and `tmxr_attach_ex` sets the polling unit on whichever
attach comes first, so the mux-wide attach is gone entirely. `-m` rides the
first attach only, because modem control is a device-wide setting.

Verified from a live session: `Connected to the VAX 11/780 simulator DZ device,
line 1` on the tab labelled `tty01`.

## What was built

- **`Session`** — one per line: the transport, the state, and the terminal
  view. The `.dmd` case drives `Terminal5620`; the console rides `Machine`'s
  own console socket; the rest each own a `ConsoleLink`.
- **`SessionStore`** — app-level registry of all nine, plus which are open.
  App-level rather than window-level so closing a window and reopening it finds
  the sessions as they were rather than freshly logged out.
- **`SessionView`** — the fixed-grid glass terminal, generalised from
  `GlassTerminal`.
- **`SessionWindow`** — tab strip, terminals, chrome. Replaces `MachineView`.
- **`CRTWindow`** (Platform.swift) — window shaping, moved out of the app
  delegate, which could no longer tell which window was the 5620's.

## Traps hit while building it, all of which cost a debugging cycle

- **`Machine.start()` cannot guard on `phase`.** It only *schedules*
  `bringUp()`, so two windows appearing in the same runloop turn both saw
  `.idle` and both spawned a SIMH thread — two VAX-11/780s in one process,
  binding the same ports and attached to the same `v8.disk`. It crashed on the
  spot, which was the lucky outcome. The guard is a synchronous `started` flag.
- **A session must own its `TerminalView`.** Scrollback lives inside that
  object, so letting SwiftUI own it makes switching tabs a silent `clear`.
- **The console session must start before the VAX does**, or the boot
  transcript lands nowhere. `SessionStore.init` starts it.
- **A window holding one terminal is that terminal**, so closing it hangs up
  the line — otherwise the 5620's non-idling WE32100 thread keeps burning most
  of a core for a window nobody can see.
- **Don't stack `.buttonStyle(.glass)` inside an `NSToolbar`.** AppKit already
  draws glass there; a second one reads as a blob.
- **`#if` inside a scene builder must bracket whole statements.** A bare
  `.defaultSize(…)` continuation is not one, so the `WindowGroup` is spelled
  once per platform.

## Facts the build depends on (all established, do not re-derive)

- **`/.profile` picks TERM from the tty** (`work/config.exp`, already applied to
  the golden image): `tty00`→`dmd`, `tty07`→`vt100w`, else `vt100`. There is no
  `/etc/ttytype` and no `/etc/gettytab` on this image.
- **root has no password** — `login: root` goes straight to `#`
  (`work/myv8/config.log`). That is what makes the tty01 auto-login one
  exchange rather than two.
- **Parity**: mask incoming bytes to 7 bits on the DZ lines. V8 puts parity in
  bit 7 and SwiftTerm renders it as Latin-1. Not fixable with `set dz 7b` —
  mux's download on `tty00` is genuinely 8-bit.
- **Cell sizing**: compute it from the font the way SwiftTerm's
  `computeFontDimensions()` does. Measuring it as `frame ÷ grid` while sizing
  the frame as `cell × grid` is a fixed-point iteration with a floor in it and
  it *oscillates* — a visibly flickering terminal. The only feedback allowed is
  the integer column headroom, which latches.
- **Pause hidden renderers.** An `MTKView` that is not on screen keeps its
  display link running: ~62% of a core versus ~22% with `isPaused`.
- **Nothing speaks first.** getty prints `login:` once when it starts and then
  blocks in `getname()`; a shell says nothing unasked. Every new session sends
  a CR to make its line speak, and the 5620's waits for the firmware's idle PC
  window rather than a timer.

## Testing this without fooling yourself

- `open --stdout LOG` **appends** — truncate first or one file accumulates
  across runs and reads as concurrent instances.
- Never drive the app with AppleScript `activate`/`keystroke`: both resolve the
  *bundle* through LaunchServices and can launch a second copy, and two VAXes
  sharing one `v8.disk` is a corruption hazard. Assert
  `pgrep -x ipnx | wc -l` is 1 at every step.
- **Preset state in `defaults` instead of clicking.** `Settings.debugOpenWindow`
  exists for exactly this: `defaults write com.hellotham.ipnx debug.openWindow
  dmd` opens the 5620's window at launch, so the multi-window path can be
  checked with no GUI automation at all. Unset on every real launch.
- Screenshot a specific window rather than the screen — `screencapture -o -x -l
  <id>` captures a window even when it is behind something else, and the window
  IDs come from `CGWindowListCopyWindowInfo` filtered on owner `ipnx`.

## Verified

Evidence in `work/shots-a5/`.

| | |
|---|---|
| Console holds the whole boot transcript | macOS, before anyone looked at the tab |
| `tty01` is line 1 | *"Connected to the VAX 11/780 simulator DZ device, line 1"* |
| Auto-login | `login: root` → motd → `#`, on both platforms |
| `tty02` is line 2 | and stops at `login:` — auto-login is tty01 only |
| Two windows, one VAX | `ipnx` + `ipnx — DMD 5620`, one `cold boot` in the log |
| CRT window shaped to the tube | `crt 877x780` inside a `897x852` window |
| 5620 still works | self-test, 1152×1024, 127 columns, `login:` on the raster |
| iPad | same tab bar, the `+` menu listing tty02..tty06 and the other shapes |

## Still to do

- Closing the 5620 window to reclaim its CPU is implemented but unverified.
- `tty03`..`tty07` are reachable and untested; nothing about them differs from
  `tty02` except the port, and `tty07` its shape.
- The 80×24 grid leaves a lot of black above and below on a portrait iPad.
  That is honest — the grid cannot grow — but the empty field may deserve
  something better than black.
- A container provisioned before `config.exp` was applied keeps its old
  `v8.disk` forever, because provisioning only copies the bundled image when
  there is none. That is deliberate (the disk is the user's), but it means a
  stale simulator still says `v8generi` and shows AT&T's original motd.
  Settings ▸ Reset to pristine V8 is the cure.
