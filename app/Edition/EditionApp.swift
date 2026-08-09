import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "ipnx" — iPad is not Unix. The name itself carries no trademark, which is
/// the binding constraint (see docs/licensing.md); the expansion is a joke in
/// the GNU tradition and stays out of the app's name and branding.
/// Boots the bundled V8 disk, shows it on the operator console and the DMD 5620,
/// and keeps the machine alive across app lifecycle via SIMH save/restore.
///
/// The two platforms take deliberately different suspend policies. iOS *must*
/// snapshot on background — the OS freezes or kills the process. macOS must
/// not: nothing reclaims the CPU there, and a machine mid-compile should keep
/// running when the user switches away. The Mac therefore snapshots only on
/// quit (which still buys instant-on) or when explicitly asked.
@main
struct EditionApp: App {
    @StateObject private var machine = Machine()
    @StateObject private var terminal = Terminal5620()
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
            MachineView(machine: machine, terminal: terminal, settings: settings,
                        capture: capture)
                .onAppear {
                    machine.start()
                    appDelegate.machine = machine
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
                    terminal.restart(dzPort: machine.dzPort,
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
            MachineView(machine: machine, terminal: terminal, settings: settings)
                .onAppear { machine.start() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Snapshot inside a UIKit background task; iOS grants a few
                // seconds, the save handshake needs well under one.
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

    /// Open as large as the desk allows, short of full screen.
    ///
    /// `visibleFrame` is the screen minus the menu bar and the Dock, which is
    /// exactly "as big as possible without going full screen" — and it is the
    /// right default here because the emulated CRT now takes the window's
    /// shape: a bigger window is a bigger 5620, not just a bigger scale
    /// factor. Full screen is deliberately not used; it hides the menu bar
    /// and moves the app to its own Space, which is a heavier thing to do to
    /// someone on launch than they asked for.
    /// Set once the window has been sized, so we do not fight SwiftUI's own
    /// initial sizing (which lands *after* applicationDidFinishLaunching, and
    /// silently undid an earlier attempt made there).
    private var didMaximise = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(maximise(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil)
    }

    @objc private func maximise(_ note: Notification) {
        guard !didMaximise, let window = note.object as? NSWindow,
              window.styleMask.contains(.titled), window.isVisible else { return }
        didMaximise = true
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeMainNotification, object: nil)
        // One more turn of the runloop: becoming main can precede the final
        // layout pass, and setting the frame before that gets overwritten.
        DispatchQueue.main.async {
            guard let screen = window.screen ?? NSScreen.main else { return }
            let target = screen.visibleFrame
            window.setFrame(target, display: true)
            let got = window.frame
            if abs(got.width - target.width) > 1 || abs(got.height - target.height) > 1 {
                // Something constrained us — a content minimum or maximum, or
                // a resizability policy. Worth knowing rather than silently
                // shipping a window that is nearly, but not, the whole desk.
                FileHandle.standardError.write(Data("""
                    ipnx: window wanted \(Int(target.width))x\(Int(target.height)) \
                    at \(Int(target.origin.x)),\(Int(target.origin.y)) but got \
                    \(Int(got.width))x\(Int(got.height)) \
                    at \(Int(got.origin.x)),\(Int(got.origin.y))\n
                    """.utf8))
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
