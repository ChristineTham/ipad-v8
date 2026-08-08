# Track A3 implementation notes

*Written 2026-08-09, the same day as A1 and A2. A3 turns the working
emulator into a shippable app, and adds the macOS build that was never on
the roadmap but costs almost nothing once the cores are xcframeworks.
Submission steps that need a person are in [app-store.md](app-store.md).*

## The macOS app

Both build scripts already produced macOS artifacts for their own smoke
tests, so shipping a Mac app was mostly a matter of adding the slices
(`macos-arm64`) and a second target over the same source folder.

**One shim, not two codebases.** `Platform.swift` declares a
`PlatformViewRepresentable` protocol that refines the platform's own and
supplies `make{UI,NS}View` from a single `makePlatformView`. The Metal
framebuffer and the SwiftTerm console are therefore written once;
SwiftTerm's `TerminalView` is an `NSView` on macOS with a shared delegate
protocol, so the console needed no logic change at all.

**Input is where the platforms should differ.** The iPad keeps the
trackpad model — drags move the pointer, an on-screen latch picks which
button they hold. The Mac gets what the hardware always assumed: a real
pointer with real buttons, left/middle/right mapped to 5620 buttons 1/2/3,
so mux's layer menu is simply a right-click. Trackpads without a middle
button get ⌥click (B2) and ⌘click (B3). Deltas come from successive
locations rather than `NSEvent.deltaY`, which keeps the AppKit-y-up to
screen-y-down flip explicit — the terminal thread then negates y once more
for the counter registers, and two implicit flips would have been a bug
waiting to happen.

**Suspend policy is deliberately different.** iOS *must* snapshot on
background or the OS freezes the process. macOS must *not*: nothing
reclaims the CPU there, and a machine part-way through a long build should
keep running when the user switches away. The Mac snapshots on quit —
through `applicationShouldTerminate` returning `.terminateLater`, because
the save handshake is async and a synchronous return would kill the
process mid-`save` — plus explicit **Machine ▸ Suspend / Resume** commands.

Sandboxed, with `network.client` + `network.server`: the two emulators
talk over loopback and nothing leaves the machine.

## What A3 added to both platforms

- **Settings** — an iOS sheet, the standard Settings scene (⌘,) on macOS.
  Phosphor (green/amber/white) reaches the fragment shader; pointer speed
  scales the delta conversion.
- **Scaling policy** — the fix for A2's stipple moiré. *Crisp* rounds the
  screen down to a whole number of device pixels per 5620 pixel. On an iPad
  Pro 13-inch that lands on exactly 800×1024 pt — a clean 2× — so the
  stipple resolves perfectly. *Fill* keeps the old behaviour.
- **NVRAM persistence** — the 5620's 8 KB of settings survive relaunch, as
  the real terminal's battery made them. Written on exit and every ~30 s of
  virtual time, because the app can be killed without warning.
- **Restart terminal** — power-cycles the 5620 *and*, because the DZ line
  carries modem control, drops carrier. That is the cure for the one
  mismatch A2 left open: a restored host-side `mux` session talking to a
  terminal that came back without muxterm loaded. Hanging up makes V8 clean
  up and getty start over. It is a user action, not automatic, because a
  plain shell on that line survives a terminal reboot perfectly well and
  should not be killed for no reason.
- **Media management** — export the working disk, import a replacement,
  reset to pristine. Imports and resets are **staged and applied at the
  next launch**: swapping a disk under a running VAX, or under a snapshot
  that describes the old one, corrupts filesystems. Importing also discards
  the snapshot for the same reason. Panels rather than SwiftUI's
  `fileExporter`, which would read all 174 MB into memory.
- **Saved-session visibility** — size and timestamp of the snapshot, and a
  way to discard it, with the consistency rule stated in the UI rather than
  only in the docs.
- **Licences and credits** — required by [licensing.md](licensing.md), not
  decoration: the 2017 Nokia/Alcatel-Lucent covenant is why the app can
  exist and why it is free.

## Gotchas earned here

- **`Settings` collides with SwiftUI's `Settings` scene.** Our preferences
  type shadows it, and the scene builder silently resolves to the wrong
  thing; `SwiftUI.Settings { … }` disambiguates.
- **A direct exec of the app binary gets no WindowServer connection** — it
  runs, binds its sockets and boots V8, but never shows a window. Launch
  with `open -n` (which still redirects stdout via `--stdout`) when testing.
- **Integer scaling must be allowed to fail.** Forcing a minimum factor of
  1 makes small windows request a screen *larger* than the space available.
  Below 1:1 there is no integral scale, so it falls back to filling. A
  headless check of the arithmetic caught this; the UI would have hidden it
  behind clipping.
- **`INFOPLIST_KEY_<anything>` works**, including keys Xcode has no UI for —
  `ITSAppUsesNonExemptEncryption` lands as a real boolean, which is worth
  verifying in the built plist rather than assuming.

## Verification

**macOS**: V8 autoboots to `login:` on the 5620 in a native window in ~25 s
at ~140 % CPU across the two emulator threads; seeded preferences are
honoured; `nvram.bin` (8192 B) is written; quitting produces `state.sav`
(1.6 MB) through the terminate-later path, so save-on-quit works.

**iPad** (simulator, driven through the real UI): the app still boots to
`login:` after the cross-platform refactor; Settings opens and every
section renders; switching the phosphor to **amber repaints the live
screen**, which is the end-to-end proof that a preference reaches the Metal
fragment shader; the licences screen renders in full; version reads 1.0 (1).

Evidence in `work/shots-a3/`: `mac-boot-t60.png`, `ipad-amber-phosphor.png`,
`ipad-licences.png`.

Not verified yet:

- **`mux` and `jim` on macOS with the real mouse.** Everything but the input
  layer is shared with the iPad, where both work (A2), but the Mac's button
  mapping has never been pointed at mux's B3 menu. Driving the Mac app needs
  event-injection permission this session did not have.
- **Restore-on-relaunch on macOS.** The snapshot is written correctly on
  quit; consuming it on the next launch uses the same code as iOS, which
  passed 3/3 cycles in A1, but the Mac path has not been run.
- **"Crisp" scaling visually.** The arithmetic is checked (including the
  overflow case), but no screenshot yet compares it against the moiré.
