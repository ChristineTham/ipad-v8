import SwiftUI
import SwiftTerm

/// The machine's screens: the SwiftTerm operator console and the DMD 5620
/// (Blit) display, switchable — both stay mounted so the console transcript
/// and its output binding survive. Auto-switches to the 5620 once the
/// machine is up (the product experience: login happens on the terminal).
struct MachineView: View {
    @ObservedObject var machine: Machine
    @ObservedObject var terminal: Terminal5620
    @ObservedObject var settings: Settings
    #if os(macOS)
    @ObservedObject var capture: PointerCapture
    #endif
    @State private var showBlit = false
    @State private var autoSwitched = false
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            ConsoleView(machine: machine)
                .padding(.horizontal, 4)
                .opacity(showBlit ? 0 : 1)
                .allowsHitTesting(!showBlit)
            #if os(macOS)
            Blit5620View(terminal: terminal, settings: settings, capture: capture)
                .opacity(showBlit ? 1 : 0)
                .allowsHitTesting(showBlit)
            #else
            Blit5620View(terminal: terminal, settings: settings)
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
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                #if !os(macOS)
                // macOS gets the standard Settings scene on Cmd-, instead.
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)
                .tint(.green)
                #endif
                Button(showBlit ? "Console" : "5620") {
                    showBlit.toggle()
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .font(.system(.caption, design: .monospaced))
            }
            .padding(14)
        }
        #if !os(macOS)
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
            if terminal.state == .idle {
                terminal.speed.set(settings.speed.multiplier)
                terminal.start(dzPort: machine.dzPort,
                               nvram: settings.persistNVRAM ? machine.nvramURL : nil,
                               stats: settings.statsURL(machine))
            }
            if !autoSwitched {
                autoSwitched = true
                showBlit = true
            }
        }
        .preferredColorScheme(.dark)
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
