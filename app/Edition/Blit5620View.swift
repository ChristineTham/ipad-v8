import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Blit experience: the 5620 framebuffer plus whatever passes for a
/// mouse and keyboard on this platform.
///
/// The 5620's mouse registers are free-running counters that muxterm
/// integrates, so both platforms feed *deltas* — there is no absolute warp.
/// On iPad that means trackpad-style drags with an on-screen button latch;
/// on the Mac it means the real pointer and real buttons, which is what the
/// hardware always assumed (mux's layer menu lives on button 3).
struct Blit5620View: View {
    @ObservedObject var terminal: Terminal5620
    @State private var latchedButton: UInt8 = 0     // 0/1/2 = 5620 buttons 1/2/3

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                let fitted = fittedRect(in: geo.size)
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                ZStack {
                    Color.black
                    screen(fitted: fitted, center: center)
                }
            }
        }
        .background(Color.black)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text("DMD 5620")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green.opacity(0.8))
            Spacer()
            #if os(macOS)
            Text("L / M / R → B1 / B2 / B3     ⌥click = B2     ⌘click = B3")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.green.opacity(0.5))
            #else
            ForEach(0..<3, id: \.self) { (idx: Int) in
                Button("B\(idx + 1)") { latchedButton = UInt8(idx) }
                    .buttonStyle(.bordered)
                    .tint(latchedButton == UInt8(idx) ? .green : .gray)
                    .font(.caption)
            }
            #endif
            Button("BREAK") { terminal.sendBreak() }
                .buttonStyle(.bordered)
                .tint(.orange)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black)
    }

    @ViewBuilder
    private func screen(fitted: CGSize, center: CGPoint) -> some View {
        #if os(macOS)
        ZStack {
            FramebufferView(frames: terminal.frames)
            // Transparent event surface over the Metal view: AppKit gives us
            // real button and pointer events, including hover.
            MacInputView(terminal: terminal, pixelScale: 800.0 / max(fitted.width, 1))
        }
        .frame(width: fitted.width, height: fitted.height)
        .position(center)
        #else
        FramebufferView(frames: terminal.frames)
            .frame(width: fitted.width, height: fitted.height)
            .position(center)
            .contentShape(Rectangle())
            .gesture(mouseDrag(fitted: fitted))
        KeyCaptureRepresentable(terminal: terminal)
            .frame(width: 0, height: 0)
        #endif
    }

    private func fittedRect(in size: CGSize) -> CGSize {
        let aspect: CGFloat = 800.0 / 1024.0
        let byWidth = CGSize(width: size.width, height: size.width / aspect)
        if byWidth.height <= size.height { return byWidth }
        return CGSize(width: size.height * aspect, height: size.height)
    }

    #if !os(macOS)
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
    #endif
}

// MARK: - macOS: real pointer, real buttons, real keyboard

#if os(macOS)
private struct MacInputView: PlatformViewRepresentable {
    let terminal: Terminal5620
    let pixelScale: CGFloat

    func makePlatformView(context: Context) -> MacBlitInputView {
        let v = MacBlitInputView()
        v.terminal = terminal
        v.pixelScale = pixelScale
        v.claimFirstResponder()
        return v
    }

    func updatePlatformView(_ view: MacBlitInputView, context: Context) {
        view.pixelScale = pixelScale
    }
}

/// Pointer and keyboard capture for the 5620.
///
/// Deltas are computed from successive locations rather than `NSEvent.deltaY`
/// because AppKit's view space has y pointing up while the 5620 wants
/// screen-down positive — doing the flip explicitly here leaves no room for a
/// sign mistake, and the terminal's counter model then negates it once more on
/// the dmd thread (muxterm counts y up the screen).
final class MacBlitInputView: NSView {
    var terminal: Terminal5620?
    var pixelScale: CGFloat = 1

    private var tracking: NSTrackingArea?
    private var lastLocation: NSPoint?
    private var activeButton: UInt8?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Pointer

    private func move(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { lastLocation = p }
        guard let last = lastLocation else { return }
        let dx = Int16(clamping: Int((p.x - last.x) * pixelScale))
        let dy = Int16(clamping: Int((last.y - p.y) * pixelScale))   // AppKit y up -> screen down
        if dx != 0 || dy != 0 { terminal?.mouse(.move(dx, dy)) }
    }

    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }

    /// Re-entering the view must not fire one enormous delta.
    override func mouseExited(with event: NSEvent) { lastLocation = nil }
    override func mouseEntered(with event: NSEvent) { lastLocation = nil }

    override func mouseDown(with event: NSEvent) {
        // Trackpads have no middle button, so modifiers stand in — the same
        // bargain X11's emulate3buttons struck.
        let flags = event.modifierFlags
        let button: UInt8 = flags.contains(.option) ? 1 : flags.contains(.command) ? 2 : 0
        activeButton = button
        lastLocation = convert(event.locationInWindow, from: nil)
        terminal?.mouse(.down(button))
    }

    override func mouseUp(with event: NSEvent) {
        terminal?.mouse(.up(activeButton ?? 0))
        activeButton = nil
    }

    override func rightMouseDown(with event: NSEvent) { terminal?.mouse(.down(2)) }
    override func rightMouseUp(with event: NSEvent) { terminal?.mouse(.up(2)) }
    override func otherMouseDown(with event: NSEvent) { terminal?.mouse(.down(1)) }
    override func otherMouseUp(with event: NSEvent) { terminal?.mouse(.up(1)) }

    // MARK: Keyboard (the 5620 keyboard is 7-bit ASCII)

    override func keyDown(with event: NSEvent) {
        guard let terminal else { return }
        if event.modifierFlags.contains(.control),
           let base = event.charactersIgnoringModifiers?.unicodeScalars.first,
           base.value >= 0x40, base.value < 0x80 {
            terminal.key(UInt8(base.value & 0x1f))          // ^A ... ^_
            return
        }
        for scalar in (event.characters ?? "").unicodeScalars {
            switch scalar.value {
            case 0x7f: terminal.key(0x08)                   // AppKit delete -> BS
            case 0x0a, 0x0d: terminal.key(0x0d)             // newline -> CR
            case 0..<0x80: terminal.key(UInt8(scalar.value))
            default: break                                  // no Unicode on a 1985 wire
            }
        }
    }

    /// Swallow key-up so AppKit does not beep at unhandled keys.
    override func keyUp(with event: NSEvent) {}
}
#endif

// MARK: - iOS: hidden responder for hardware + soft keyboards

#if !os(macOS)
/// Invisible first responder that feeds hardware/soft keyboard input to
/// the 5620 keyboard (plain ASCII; newline becomes CR).
private struct KeyCaptureRepresentable: UIViewRepresentable {
    let terminal: Terminal5620

    func makeUIView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView()
        v.onText = { text in Task { @MainActor in terminal.type(text) } }
        v.onBackspace = { Task { @MainActor in terminal.key(0x08) } }
        v.claimFirstResponder()
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
#endif
