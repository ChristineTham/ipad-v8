import SwiftUI
import UIKit

/// The Blit experience: the 5620 framebuffer with touch-as-mouse, a
/// hidden key-input responder for the 5620 keyboard, and a small toolbar
/// for mouse-button latching (mux's layer menu lives on button 3) and
/// BREAK. Touch is trackpad-style: drags move the cursor by deltas
/// (muxterm integrates counter deltas; absolute warping isn't a thing).
struct Blit5620View: View {
    @ObservedObject var terminal: Terminal5620
    @State private var latchedButton: UInt8 = 0     // 0/1/2 = 5620 buttons 1/2/3

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("DMD 5620")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.8))
                Spacer()
                ForEach(0..<3, id: \.self) { (idx: Int) in
                    Button("B\(idx + 1)") { latchedButton = UInt8(idx) }
                        .buttonStyle(.bordered)
                        .tint(latchedButton == UInt8(idx) ? .green : .gray)
                        .font(.caption)
                }
                Button("BREAK") { terminal.sendBreak() }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black)

            GeometryReader { geo in
                let fitted = fittedRect(in: geo.size)
                ZStack {
                    Color.black
                    FramebufferView(frames: terminal.frames)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .contentShape(Rectangle())
                        .gesture(mouseDrag(fitted: fitted))
                    KeyCaptureRepresentable(terminal: terminal)
                        .frame(width: 0, height: 0)
                }
            }
        }
        .background(Color.black)
    }

    private func fittedRect(in size: CGSize) -> CGSize {
        let aspect: CGFloat = 800.0 / 1024.0
        let byWidth = CGSize(width: size.width, height: size.width / aspect)
        if byWidth.height <= size.height { return byWidth }
        return CGSize(width: size.height * aspect, height: size.height)
    }

    @State private var lastPoint: CGPoint? = nil

    private func mouseDrag(fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let scale = 800.0 / fitted.width
                if let last = lastPoint {
                    let dx = Int16((value.location.x - last.x) * scale)
                    let dy = Int16((value.location.y - last.y) * scale)
                    if dx != 0 || dy != 0 {
                        terminal.mouse(.move(dx, dy))
                        lastPoint = value.location
                    }
                } else {
                    lastPoint = value.location
                    terminal.mouse(.down(latchedButton))
                }
            }
            .onEnded { _ in
                lastPoint = nil
                terminal.mouse(.up(latchedButton))
            }
    }
}

/// Invisible first responder that feeds hardware/soft keyboard input to
/// the 5620 keyboard (plain ASCII; newline becomes CR).
private struct KeyCaptureRepresentable: UIViewRepresentable {
    let terminal: Terminal5620

    func makeUIView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView()
        v.onText = { text in Task { @MainActor in terminal.type(text) } }
        v.onBackspace = { Task { @MainActor in terminal.key(0x08) } }
        DispatchQueue.main.async { _ = v.becomeFirstResponder() }
        return v
    }

    func updateUIView(_ uiView: KeyCaptureView, context: Context) {}
}

final class KeyCaptureView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    // UITextInputTraits (via UIKeyInput): raw ASCII, no smarts.
    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onBackspace?() }
}
