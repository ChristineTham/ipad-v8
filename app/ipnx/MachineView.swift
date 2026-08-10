import SwiftUI
import SwiftTerm

/// Which of the machine's three faces is showing.
///
/// All three stay mounted, so the console transcript and its output binding
/// survive a switch and neither terminal is torn down by looking away.
///
/// They are not three views of one thing: the console is `/dev/console` (boot
/// messages, panics, the only thing alive before multiuser), the terminal is a
/// plain glass tty on a DZ line, and the 5620 is the bitmap terminal this app
/// exists for. All three can be logged in at once — V8 runs a getty on the
/// console and on tty00..tty07 — so switching does not disturb the others.
enum MachineFace: String, CaseIterable, Identifiable {
    case console, glass, blit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .console: return "Console"
        case .glass: return "Terminal"
        case .blit: return "5620"
        }
    }
}

struct MachineView: View {
    @ObservedObject var machine: Machine
    @ObservedObject var terminal: Terminal5620
    @ObservedObject var glass: GlassTerminal
    @ObservedObject var settings: Settings
    #if os(macOS)
    @ObservedObject var capture: PointerCapture
    #endif
    @State private var face: MachineFace = .console
    @State private var autoSwitched = false
    @State private var showSettings = false

    private var showBlit: Bool { face == .blit }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            ConsoleView(machine: machine)
                .padding(.horizontal, 4)
                .opacity(face == .console ? 1 : 0)
                .allowsHitTesting(face == .console)
            GlassTerminalView(session: glass, settings: settings)
                .opacity(face == .glass ? 1 : 0)
                .allowsHitTesting(face == .glass)
            #if os(macOS)
            Blit5620View(terminal: terminal, settings: settings,
                         isActive: showBlit, capture: capture)
                .opacity(showBlit ? 1 : 0)
                .allowsHitTesting(showBlit)
            #else
            Blit5620View(terminal: terminal, settings: settings, isActive: showBlit)
                .opacity(showBlit ? 1 : 0)
                .allowsHitTesting(showBlit)
            #endif
            if let status = statusText {
                HStack(spacing: 10) {
                    if !isFailure { ProgressView().tint(.green) }
                    Text(status)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(isFailure ? Color.red : Color.green)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.75), in: Capsule())
                .overlay(Capsule().strokeBorder(.green.opacity(0.4)))
                .padding(.top, 8)
            }
        }
        #if os(macOS)
        // Real window chrome. Everything the user might reach for lives in the
        // title bar, so nothing floats over the emulated screen and nothing
        // has to wrap: AppKit moves whatever does not fit into the overflow
        // menu, which is exactly the behaviour a hand-rolled strip lacked.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Screen", selection: $face) {
                    ForEach(MachineFace.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            if showBlit {
                ToolbarItem {
                    Text(capture.captured ? "pointer grabbed" : "⌥click B2 · ⌘click B3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("""
                            The 5620 has three mouse buttons. Left, middle and right map \
                            to B1, B2 and B3; on a trackpad, ⌥click gives B2 and ⌘click \
                            gives B3. mux's layer menu is on B3.
                            """)
                }
                ToolbarItem {
                    Button(capture.captured ? "Release Pointer" : "Grab Pointer") {
                        capture.captured.toggle()
                    }
                    .help("""
                        The 5620's mouse is a relative device, so its cursor and the \
                        Mac's drift apart at the screen edge. Grabbing hides the Mac's \
                        entirely (⌘G).
                        """)
                }
                ToolbarItem {
                    Button("BREAK") { terminal.sendBreak() }
                        .help("Send a serial BREAK to the terminal.")
                }
            }
        }
        #else
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                // macOS gets the standard Settings scene on Cmd-, instead.
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)
                .tint(.green)
                Picker("", selection: $face) {
                    ForEach(MachineFace.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            }
            .padding(14)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(settings: settings, machine: machine, terminal: terminal)
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        #endif
        .onReceive(machine.$phase) { phase in
            guard phase == .up else { return }
            if !autoSwitched {
                autoSwitched = true
                face = settings.lastFace           // where they left off
            }
            startFace(face)
        }
        .onChange(of: face) { _, newFace in
            settings.lastFace = newFace
            guard machine.phase == .up else { return }
            startFace(newFace)
        }
        .preferredColorScheme(.dark)
    }

    /// Start whatever the visible face needs, and nothing else.
    ///
    /// The 5620 is deliberately lazy. Its thread is the app's entire CPU cost
    /// — a WE32100 stepped in wall-clock time, ~63% of a core at 2×, against
    /// patched SIMH's 2.7% at an idle prompt — so a session that never opens
    /// it runs the same VAX at a twentieth of the power. That is the whole
    /// point of the light terminal, and it only works if nothing starts the
    /// dmd thread behind the user's back.
    ///
    /// Once started, both terminals stay up: V8 runs a getty per line, so the
    /// sessions are independent and switching back should find things as they
    /// were, not a fresh login.
    private func startFace(_ face: MachineFace) {
        switch face {
        case .console:
            break                                  // always live
        case .glass:
            if glass.state == .idle { glass.start(port: settings.glassPort(machine)) }
        case .blit:
            if terminal.state == .idle {
                terminal.speed.set(settings.speed.multiplier)
                terminal.start(dzPort: machine.blitPort,
                               screen: settings.activeScreen,
                               nvram: settings.persistNVRAM ? machine.nvramURL : nil,
                               stats: settings.statsURL(machine),
                               screenSnapshot: machine.screenURL)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = machine.phase { return true }
        return false
    }

    private var statusText: String? {
        switch machine.phase {
        case .idle, .starting:
            return "Starting VAX-11/780…"
        case .provisioning:
            return "First launch: installing the V8 disk…"
        case .booting:
            return "Booting Research Unix…"
        case .restoring:
            return "Restoring session…"
        case .pausing:
            return "Saving machine state…"
        case .up, .paused:
            return nil
        case .failed(let msg):
            return "Failed: \(msg)"
        }
    }
}

/// AppKit/UIKit bridge for SwiftTerm's TerminalView (an NSView on macOS, a
/// UIView on iOS — the delegate protocol and `feed` are shared).
struct ConsoleView: PlatformViewRepresentable {
    let machine: Machine

    func makePlatformView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = PlatformColor(red: 0.45, green: 1.0, blue: 0.6, alpha: 1.0)
        #if !os(macOS)
        tv.backgroundColor = .black
        #endif
        machine.onOutput = { [weak tv] bytes in
            tv?.feed(byteArray: bytes[...])
        }
        tv.claimFirstResponder()
        return tv
    }

    func updatePlatformView(_ view: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(machine: machine) }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let machine: Machine
        init(machine: Machine) { self.machine = machine }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor in self.machine.sendInput(bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
