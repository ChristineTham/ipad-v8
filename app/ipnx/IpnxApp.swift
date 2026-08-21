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
/// Boots the bundled V8 disk, shows it on the operator console, seven glass
/// ttys and the DMD 5620, and keeps the machine alive across app lifecycle via
/// SIMH save/restore.
///
/// One window group, keyed by terminal shape. That is not a style choice: this
/// kernel has `struct sgttyb` and no `TIOCGWINSZ`, so nothing can tell V8 how
/// large a window is and a terminal's grid is whatever termcap says. The three
/// shapes cannot be reflowed into one another, so each gets its own window and
/// tabs group sessions that are already the same size.
///
/// The two platforms take deliberately different suspend policies. iOS *must*
/// snapshot on background — the OS freezes or kills the process. macOS must
/// not: nothing reclaims the CPU there, and a machine mid-compile should keep
/// running when the user switches away. The Mac therefore snapshots only on
/// quit (which still buys instant-on) or when explicitly asked.
@main
struct IpnxApp: App {
    @StateObject private var machine: Machine
    @StateObject private var dmd: Terminal5620
    @StateObject private var settings: Settings
    @StateObject private var store: SessionStore
    /// N7. Built at launch so a share the user already chose is serving before
    /// the guest is in a position to mount it.
    ///
    /// Two of them, because B0.6 asks for two mounts and they are different
    /// things: `/n/macos` is any folder the user picks, `/n/home` is meant to
    /// be their own. Separate servers on separate ports, so one can be absent
    /// without disturbing the other — which matters on macOS, where each
    /// needs its own security-scoped grant.
    @StateObject private var share = FileShare(role: .macos)
    @StateObject private var homeShare = FileShare(role: .home)

    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var capture = PointerCapture()
    #else
    @Environment(\.scenePhase) private var scenePhase
    #endif

    init() {
        // WHICH EDITION, read from UserDefaults rather than from `Settings',
        // because the machine has to exist before any ObservableObject does --
        // the SessionStore below starts the console session in its initialiser
        // and that must happen before the VAX. `MachineSpec.current' falls back
        // to V8 when the stored choice names media this build does not carry.
        let machine = Machine(spec: .current)
        let dmd = Terminal5620()
        let settings = Settings()
        _machine = StateObject(wrappedValue: machine)
        _dmd = StateObject(wrappedValue: dmd)
        _settings = StateObject(wrappedValue: settings)
        // Built here rather than lazily in a view: the store starts the
        // console session in its initialiser, and that has to happen before
        // the VAX does or the boot transcript lands nowhere.
        _store = StateObject(wrappedValue: SessionStore(machine: machine, dmd: dmd,
                                                        settings: settings))
    }

    var body: some Scene {
        // The WindowGroup is spelled twice rather than once with the platform
        // differences hung off it: `#if` inside a result builder has to bracket
        // whole statements, and a bare `.defaultSize(…)` continuation is not one.
        #if os(macOS)
        WindowGroup(for: TerminalShape.self) { $shape in
            window(shape)
        } defaultValue: {
            .vt100
        }
        .defaultSize(width: 900, height: 700)
        .commands { menus }

        // Qualified: our own preferences type is also called Settings, and the
        // scene builder would otherwise resolve to its initialiser.
        SwiftUI.Settings {
            SettingsView(settings: settings, machine: machine, terminal: dmd, share: share, homeShare: homeShare)
                .frame(width: 520, height: 640)
        }
        #else
        WindowGroup(for: TerminalShape.self) { $shape in
            window(shape)
        } defaultValue: {
            .vt100
        }
        #endif
    }

    @ViewBuilder
    private func window(_ shape: TerminalShape) -> some View {
        #if os(macOS)
        SessionWindow(shape: shape, store: store, machine: machine,
                      settings: settings, dmd: dmd, share: share, homeShare: homeShare, capture: capture)
            .onAppear { launch(shape) }
        #else
        SessionWindow(shape: shape, store: store, machine: machine,
                      settings: settings, dmd: dmd, share: share, homeShare: homeShare)
            .onAppear { launch(shape) }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background:
                    // Snapshot inside a UIKit background task; iOS grants a
                    // few seconds and the save handshake needs well under one.
                    dmd.saveScreen(to: machine.screenURL)
                    store.saveScreens()
                    let token = UIApplication.shared.beginBackgroundTask(withName: "simh-save")
                    Task {
                        await store.unmountShares()
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

    /// Start the VAX once, from whichever window opened first, and give the
    /// default window its second tab.
    private func launch(_ shape: TerminalShape) {
        // Before start(), because start() writes boot.conf and `attach il`
        // is a boot-time decision the guest cannot be told about later.
        machine.networkEnabled = settings.networkEnabled
        // A resume comes back with no shares by design (they are dropped before
        // the snapshot so they can be retaken cleanly); /etc/rc only mounts on a
        // cold boot, so this is what puts them back.
        machine.onRestored = { [store, share, homeShare] in
            Task { await store.mountShares([share, homeShare]) }
        }
        machine.start()
        #if os(macOS)
        appDelegate.machine = machine
        appDelegate.settings = settings
        appDelegate.terminal = dmd
        appDelegate.store = store
        #endif
        if shape == .vt100 { store.openDefaults() }
    }

    #if os(macOS)
    @CommandsBuilder
    private var menus: some Commands {
        WindowCommands()
        CommandMenu("Terminal") {
            // The 5620's mouse is a relative device with free-running
            // counters, so its cursor and the Mac's cannot stay in step once
            // the Mac's hits a screen edge. Grabbing removes the second cursor
            // entirely, which is the only reliable fix.
            Button(capture.captured ? "Release Pointer" : "Grab Pointer") {
                capture.captured.toggle()
            }
            .keyboardShortcut("g", modifiers: [.command])
            Button("Send BREAK") { dmd.sendBreak() }
        }
        CommandMenu("Machine") {
            Button("Suspend") { Task { await machine.background() } }
                .keyboardShortcut(".", modifiers: [.command])
            Button("Resume") { machine.foreground() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Restart Terminal") {
                dmd.restart(dzPort: machine.blitPort,
                            screen: settings.activeScreen,
                            nvram: settings.persistNVRAM ? machine.nvramURL : nil,
                            stats: settings.statsURL(machine))
            }
        }
    }
    #endif
}

#if os(macOS)
/// File ▸ Open Terminal. Its own `Commands` type because `openWindow` is an
/// environment value, and an App struct is not a view — it has no environment
/// to read it from.
struct WindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Menu("Open Terminal") {
                ForEach(TerminalShape.allCases) { shape in
                    Button(shape.label) { openWindow(value: shape) }
                }
            }
        }
    }
}

/// Quit is the Mac's only forced suspend point. `applicationShouldTerminate`
/// cannot await, so we defer the reply and let the save handshake finish —
/// otherwise the process dies mid-`save` and the next launch cold-boots.
///
/// Window shaping used to live here and no longer can: with more than one
/// window, `NSApp.windows.first` is a guess. It is `CRTWindow.shape` now,
/// driven from the 5620's own window (Platform.swift).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var machine: Machine?
    weak var settings: Settings?
    weak var terminal: Terminal5620?
    weak var store: SessionStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Before anything else: the terminal always power-cycles, so the only
        // way the next launch can look continuous is to keep its screen.
        terminal?.saveScreen(to: machine?.screenURL)
        store?.saveScreens()
        guard let machine, machine.canSuspend else { return .terminateNow }
        Task { @MainActor in
            // Before the snapshot, never after: see SessionStore.unmountShares.
            await store?.unmountShares()
            await machine.background()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
