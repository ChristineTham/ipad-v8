import SwiftUI
import SwiftTerm

/// The console screen: a SwiftTerm view wired to the machine's byte stream,
/// with a status capsule while the machine isn't at the login prompt yet.
struct MachineView: View {
    @ObservedObject var machine: Machine

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            ConsoleView(machine: machine)
                .padding(.horizontal, 4)
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

/// UIKit bridge for SwiftTerm's TerminalView.
struct ConsoleView: UIViewRepresentable {
    let machine: Machine

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.backgroundColor = .black
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = UIColor(red: 0.45, green: 1.0, blue: 0.6, alpha: 1.0)
        machine.onOutput = { [weak tv] bytes in
            tv?.feed(byteArray: bytes[...])
        }
        DispatchQueue.main.async { _ = tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

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
