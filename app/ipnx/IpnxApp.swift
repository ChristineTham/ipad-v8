import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "ipnx" — iPad is not Unix, and Intellectual Property is not Unix. The name
/// itself carries no trademark, which is the binding constraint (see
/// docs/licensing.md); both expansions are jokes in the GNU tradition and stay
/// out of the app's name and branding.
/// Boots the bundled V8 disk, shows it on the operator console and the DMD 5620,
/// and keeps the machine alive across app lifecycle via SIMH save/restore.
///
/// The two platforms take deliberately different suspend policies. iOS *must*
/// snapshot on background — the OS freezes or kills the process. macOS must
/// not: nothing reclaims the CPU there, and a machine mid-compile should keep
/// running when the user switches away. The Mac therefore snapshots only on
/// quit (which still buys instant-on) or when explicitly asked.
@main
struct IpnxApp: App {
    @StateObject private var machine = Machine()
    @StateObject private var terminal = Terminal5620()
    @StateObject private var glass = GlassTerminal()
    @StateObject private var settings = Settings()

    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var capture = PointerCapture()
    #else
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            MachineView(machine: machine, terminal: terminal, glass: glass,
                        settings: settings, capture: capture)
                .onAppear {
                    machine.start()
                    appDelegate.machine = machine
                    appDelegate.settings = settings
                    appDelegate.terminal = terminal
                }
        }
        .defaultSize(width: 900, height: 1120)
        .commands {
            CommandMenu("Terminal") {
                // The 5620's mouse is a relative device with free-running
                // counters, so its cursor and the Mac's cannot stay in step
                // once the Mac's hits a screen edge. Grabbing removes the
                // second cursor entirely, which is the only reliable fix.
                Button(capture.captured ? "Release Pointer" : "Grab Pointer") {
                    capture.captured.toggle()
                }
                .keyboardShortcut("g", modifiers: [.command])
            }
            CommandMenu("Machine") {
                Button("Suspend") { Task { await machine.background() } }
                    .keyboardShortcut(".", modifiers: [.command])
                Button("Resume") { machine.foreground() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Restart Terminal") {
                    terminal.restart(dzPort: machine.blitPort,
                                     screen: settings.activeScreen,
                                     nvram: settings.persistNVRAM ? machine.nvramURL : nil,
                                     stats: settings.statsURL(machine))
                }
            }
        }
        // Qualified: our own preferences type is also called Settings, and the
        // scene builder would otherwise resolve to its initialiser.
        SwiftUI.Settings {
            SettingsView(settings: settings, machine: machine, terminal: terminal)
                .frame(width: 520, height: 620)
        }
        #else
        WindowGroup {
            MachineView(machine: machine, terminal: terminal, glass: glass, settings: settings)
                .onAppear { machine.start() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Snapshot inside a UIKit background task; iOS grants a few
                // seconds, the save handshake needs well under one.
                terminal.saveScreen(to: machine.screenURL)
                let token = UIApplication.shared.beginBackgroundTask(withName: "simh-save")
                Task {
                    await machine.background()
                    UIApplication.shared.endBackgroundTask(token)
                }
            case .active:
                machine.foreground()
            default:
                break
            }
        }
        #endif
    }
}

#if os(macOS)
/// Quit is the Mac's only forced suspend point. `applicationShouldTerminate`
/// cannot await, so we defer the reply and let the save handshake finish —
/// otherwise the process dies mid-`save` and the next launch cold-boots.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var machine: Machine?
    weak var settings: Settings?
    weak var terminal: Terminal5620?

    /// Open as large as the desk allows, short of full screen — and shaped so
    /// the emulated CRT fills it exactly.
    ///
    /// The CRT is one of two fixed sizes, so this is simply: make the window
    /// as big as the desk allows at that shape. The terminal is not the whole
    /// window — the title bar and its toolbar come off the top, the bezel off
    /// every edge — so sizing to `visibleFrame` outright would letterbox the
    /// CRT by exactly that much.
    ///
    /// So: take the desk minus the menu bar and Dock (`visibleFrame`), take
    /// the real chrome off that, and give the remainder the CRT's aspect.
    /// Full screen is deliberately not used — it hides the menu bar and moves
    /// the app to its own Space, which is a heavier thing to do to someone on
    /// launch than they asked for.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The window does not exist yet at this point -- SwiftUI creates it
        // during the first update pass -- so this runs on the next turn of
        // the runloop. (didBecomeMainNotification looked tidier and never
        // fired: by the time the delegate is installed, the window is already
        // main.)
        DispatchQueue.main.async { self.shapeWindow(settle: true) }
    }

    private func shapeWindow(settle: Bool) {
        guard let window = NSApp.windows.first(where: {
                  $0.isVisible && $0.styleMask.contains(.titled)
                      && $0.styleMask.contains(.resizable)
              }) else { return }
        DispatchQueue.main.async {
            guard let screen = window.screen ?? NSScreen.main else { return }
            let desk = screen.visibleFrame

            // Real chrome, measured rather than assumed. `contentLayoutRect`
            // is the part of the window neither the title bar nor the toolbar
            // covers, so the difference is both of them together -- which
            // matters now that the controls live in a real NSToolbar whose
            // height is AppKit's business, not ours. (contentRect(forFrameRect:)
            // was wrong here: it answers from the style mask alone and never
            // knows about the toolbar.)
            let chrome = window.frame.height - window.contentLayoutRect.height
            let bezel = Blit5620View.bezel * 2

            let crt = self.settings?.chooseScreen() ?? .stock
            let aspect = CGFloat(crt.width) / CGFloat(crt.height)
            var screenH = desk.height - chrome - bezel
            var screenW = screenH * aspect
            if screenW > desk.width - bezel {         // a wide, short desk
                screenW = desk.width - bezel
                screenH = screenW / aspect
            }
            let target = NSRect(x: desk.midX - (screenW + bezel) / 2,
                                y: desk.maxY - (screenH + bezel + chrome),
                                width: screenW + bezel,
                                height: screenH + bezel + chrome)

            // Stop the frame being restored over the top of ours. AppKit
            // reapplies a remembered frame *after* this point, so setting it
            // here alone looked like it worked -- setFrame reported success --
            // and the window still came up at whatever size it was last time.
            window.isRestorable = false
            window.setFrameAutosaveName("")
            window.setFrame(target, display: true)

            // Lock the shape. The user can still resize — the picture scales —
            // but the window can no longer be dragged into a shape the
            // emulated CRT is not, which is what used to force the terminal to
            // rebuild itself mid-session.
            window.contentAspectRatio = NSSize(width: target.width,
                                               height: target.height - chrome)

            let got = window.frame
            FileHandle.standardError.write(Data("""
                ipnx: desk \(Int(desk.width))x\(Int(desk.height)) \
                chrome \(Int(chrome)) bezel \(Int(bezel)) -> \
                crt \(Int(screenW))x\(Int(screenH)), \
                window wanted \(Int(target.width))x\(Int(target.height)), \
                got \(Int(got.width))x\(Int(got.height))\n
                """.utf8))

            // And measure again a beat later. Not just because "reported
            // success" turned out not to mean "kept it" -- the toolbar may not
            // have been installed on the first pass, and a chrome height
            // measured before it exists is short by the toolbar.
            if settle {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.shapeWindow(settle: false)
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Before anything else: the terminal always power-cycles, so the only
        // way the next launch can look continuous is to keep its screen.
        terminal?.saveScreen(to: machine?.screenURL)
        guard let machine, machine.canSuspend else { return .terminateNow }
        Task { @MainActor in
            await machine.background()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
