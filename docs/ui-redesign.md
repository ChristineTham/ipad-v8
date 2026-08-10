# The interface: many ttys, many windows, Liquid Glass

**Status: plan, nothing built.** The tree at the time of writing is `523f336`,
which has the three-face picker (Console / Terminal / 5620) this supersedes.

## What was asked for

1. **Tabs for all eight lines**, not three faces. V8 runs a getty on `console`
   and `tty00`..`tty07`, so nine sessions are available.
2. **The console is read-only by default**, with a toggle to enable input.
   Console messages are the reason to look at it; typing into it by accident
   is not.
3. **tty01 is logged in automatically** on first open.
4. **Every session is lazily started**, the way the 5620 already is — opening a
   tab is what dials its line.
5. **Multiple windows, not just tabs.** The app opens as an 80×24 window with
   Console and tty01. The 5620 opens its *own* window; so does a vt100w
   (128×24). Tabs group sessions of the same shape; different shapes get
   different windows.
6. **Apple HIG, Liquid Glass.** The current interface is amateurish.

## Why windows-by-shape is forced, not a style choice

This kernel has `struct sgttyb` and **no `TIOCGWINSZ`** — that arrived in
4.3BSD. Nothing can tell V8 how large a window is, so a terminal's grid is
whatever its termcap entry says and nothing else:

| session | termcap | grid | DZ line |
|---|---|---|---|
| 5620 | `dmd` | 1152×1024 px (127 cols) | 0, own listener |
| plain | `vt100` | 80×24 | 1..6, mux listener |
| wide | `vt100w` | 128×24 | 7, own listener |

Three fixed, unequal shapes. They cannot be reflowed into one window, so tabs
only make sense *within* a shape — which is exactly the requested behaviour,
arrived at from the hardware rather than from taste.

## Shape of the build

- **`Session`** — one per line: `line`, `shape`, `port`, lazily started, owning
  its transport. Generalises today's `GlassTerminal` (which is already this for
  one line) and subsumes `Terminal5620` as the `dmd` case.
- **`SessionStore`** — the app-level registry: which lines exist, which are
  running, which window each belongs to. Survives window close/open.
- **Windows** — `WindowGroup(for: Shape.self)` plus `@Environment(\.openWindow)`.
  Default window = `.vt100`; opening the 5620 or a wide tty opens its own.
  Each window carries a `TabView` over the sessions of its shape.
- **Console** — `readOnly` defaults true; the toggle lives in the toolbar as a
  lock, not a modal.
- **Auto-login** — tty01 only, on first start, typing `root` at the `login:`
  prompt. Must be gated on actually seeing the prompt, never on a timer.

### Liquid Glass

Verified to typecheck against the installed **MacOSX26.5** SDK:

```swift
GlassEffectContainer(spacing:) { … }
.glassEffect(.regular.tint(.green).interactive(), in: .rect(cornerRadius:))
.buttonStyle(.glass)
```

The app currently targets **macOS 14.0 / iOS 17.0**, so the deployment targets
must rise to 26. That is the right trade here — there is no install base, and a
half-glass interface looks worse than either whole choice — but it is a real
decision and it belongs in the record.

The emulated screens stay exactly as they are. Glass belongs to the chrome; the
raster inside the bezel is meant to be a faithful 1985 display and nothing
should be composited over it.

## Facts the build depends on (all established, do not re-derive)

- **Ports** (`Machine.swift`): `blitPort` = DZ `Line=0`; `glassPort` = the
  mux-wide listener, which hands out lines 1..6; `wideGlassPort` = `Line=7`.
  `tmxr_poll_conn` skips lines that have their own listener, so assignment does
  not depend on connection order — which matters because every session is lazy.
- **`/.profile` picks TERM from the tty** (`work/config.exp`): `tty00`→`dmd`,
  `tty07`→`vt100w`, else `vt100`. There is no `/etc/ttytype` and no
  `/etc/gettytab` on this image; the profile is the only place it can live.
- **Parity**: mask incoming bytes to 7 bits on the DZ lines. V8 puts parity in
  bit 7 and SwiftTerm renders it as Latin-1. Not fixable with `set dz 7b` —
  mux's download on line 0 is genuinely 8-bit.
- **Cell sizing**: compute it from the font the way SwiftTerm's
  `computeFontDimensions()` does. Measuring it as `frame ÷ grid` while sizing
  the frame as `cell × grid` is a fixed-point iteration with a floor in it and
  it *oscillates* — a visibly flickering terminal. The only feedback allowed is
  the integer column headroom, which latches (at 2: the reserved scroller).
- **Pause hidden renderers.** An `MTKView` that is not on screen keeps its
  display link running: ~62% of a core versus ~22% with `isPaused`.
- **Nothing speaks first.** getty prints `login:` once when it starts and then
  blocks in `getname()`; a shell says nothing unasked. Every new session must
  send a CR to make its line speak, and the 5620's must wait for the firmware's
  idle PC window rather than a timer.

## Testing this without fooling yourself

- `open --stdout LOG` **appends** — truncate first or one file accumulates
  across runs and reads as concurrent instances.
- Never drive the app with AppleScript `activate`/`keystroke`: both resolve the
  *bundle* through LaunchServices and can launch a second copy, and two VAXes
  sharing one `v8.disk` is a corruption hazard. Target
  `tell application id "…"`, and assert `pgrep -x ipnx | wc -l` is 1 at every
  step.
- Preset state in `defaults` (`machine.face`, `glass.kind`, …) instead of
  clicking, so a test needs no GUI automation at all.
