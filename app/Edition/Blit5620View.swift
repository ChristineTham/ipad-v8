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
    @ObservedObject var settings: Settings
    @Environment(\.displayScale) private var displayScale
    @State private var latchedButton: UInt8 = 0     // 0/1/2 = 5620 buttons 1/2/3
    #if os(macOS)
    @ObservedObject var capture: PointerCapture
    #endif

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                // The window decides the shape of the CRT, and the CRT decides
                // the layout — in that order, so a rotation or a window drag
                // reshapes the emulated screen rather than letterboxing a
                // portrait one into a landscape space.
                let crt = settings.desiredScreen(fitting: geo.size)
                let fitted = settings.screenSize(fitting: geo.size, screen: crt,
                                                 displayScale: displayScale)
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                ZStack {
                    Color.black
                    screen(crt: crt, fitted: fitted, center: center)
                }
                // Resizing is idempotent and latched, so firing on every layout
                // pass is free; a live window drag collapses to its last value.
                .onChange(of: crt, initial: true) { _, wanted in
                    terminal.resizeScreen(to: wanted)
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
            Text(capture.captured
                 ? "pointer grabbed — ⌘G or switch away to release"
                 : "L / M / R → B1 / B2 / B3     ⌥click = B2     ⌘click = B3")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.green.opacity(capture.captured ? 0.8 : 0.5))
            Button(capture.captured ? "Release" : "Grab pointer") {
                capture.captured.toggle()
            }
            .buttonStyle(.bordered)
            .tint(capture.captured ? .green : .gray)
            .font(.caption)
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
    private func screen(crt: FrameStore.Geometry, fitted: CGSize, center: CGPoint) -> some View {
        #if os(macOS)
        ZStack {
            FramebufferView(frames: terminal.frames, phosphor: settings.phosphor.tint)
            // Transparent event surface over the Metal view: AppKit gives us
            // real button and pointer events, including hover.
            MacInputView(terminal: terminal, pixelScale: pixelScale(crt: crt, fitted: fitted),
                         capture: capture)
        }
        .frame(width: fitted.width, height: fitted.height)
        .position(center)
        #else
        FramebufferView(frames: terminal.frames, phosphor: settings.phosphor.tint)
            .frame(width: fitted.width, height: fitted.height)
            .position(center)
            .contentShape(Rectangle())
            .gesture(mouseDrag(crt: crt, fitted: fitted))
        KeyCaptureRepresentable(terminal: terminal)
            .frame(width: 0, height: 0)
        #endif
    }

    /// Screen points -> 5620 pixels, with the user's pointer speed folded in.
    private func pixelScale(crt: FrameStore.Geometry, fitted: CGSize) -> CGFloat {
        CGFloat(crt.width) / max(fitted.width, 1) * settings.mouseSensitivity
    }

    #if !os(macOS)
    @State private var lastPoint: CGPoint? = nil

    private func mouseDrag(crt: FrameStore.Geometry, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let scale = pixelScale(crt: crt, fitted: fitted)
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
/// Whether the pointer is grabbed. Shared so the toolbar, the menu command and
/// the view's own safety releases all agree.
@MainActor
final class PointerCapture: ObservableObject {
    @Published var captured = false
}

private struct MacInputView: PlatformViewRepresentable {
    let terminal: Terminal5620
    let pixelScale: CGFloat
    @ObservedObject var capture: PointerCapture

    func makePlatformView(context: Context) -> MacBlitInputView {
        let v = MacBlitInputView()
        v.terminal = terminal
        v.pixelScale = pixelScale
        v.onAutoRelease = { [weak capture] in capture?.captured = false }
        v.claimFirstResponder()
        return v
    }

    func updatePlatformView(_ view: MacBlitInputView, context: Context) {
        view.pixelScale = pixelScale
        view.setCaptured(capture.captured)
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
    // Sub-pixel remainder. A real mouse sends a stream of small moves, and
    // truncating each one independently throws away everything below a whole
    // 5620 pixel — slow movement then rounds to zero every time and the
    // cursor never moves at all.
    private var carryX: CGFloat = 0
    private var carryY: CGFloat = 0

    /// Grab state. While grabbed the system cursor is hidden and frozen, so
    /// `locationInWindow` stops changing and motion must come from the event
    /// deltas instead.
    private(set) var captured = false
    var onAutoRelease: (() -> Void)?
    private var resignObserver: NSObjectProtocol?

    /// Sign that converts `NSEvent.deltaY` into screen-down-positive. Learned
    /// from real events while the cursor is free — where locations are
    /// authoritative — rather than assumed, because AppKit's mouse-move delta
    /// convention is easy to get backwards and impossible to check by reading.
    private static var deltaYSign: CGFloat = 1

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Without this the window swallows mouse-moved events, so the pointer
        // would only work while a button is held.
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)

        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        guard let window else { return }
        // Safety valve: never leave the user with no cursor because they
        // switched away with the pointer grabbed.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.captured else { return }
                self.setCaptured(false)
                self.onAutoRelease?()
            }
        }
    }

    deinit { Self.releasePointer() }

    // MARK: Grab

    func setCaptured(_ on: Bool) {
        guard on != captured else { return }
        captured = on
        carryX = 0; carryY = 0
        lastLocation = nil
        if on {
            // Park the cursor mid-view so releasing later leaves it somewhere
            // sensible, then freeze and hide it.
            if let screenPoint = centreInScreenCoordinates() {
                CGWarpMouseCursorPosition(screenPoint)
            }
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            Self.releasePointer()
        }
    }

    private static func releasePointer() {
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    /// Centre of this view in Quartz global coordinates (y down from the top of
    /// the primary display), which is what CGWarpMouseCursorPosition wants.
    private func centreInScreenCoordinates() -> CGPoint? {
        guard let window, let screen = window.screen else { return nil }
        let inWindow = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        return CGPoint(x: onScreen.x, y: screen.frame.maxY - onScreen.y)
    }

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
        if captured {
            // Frozen cursor: locations no longer change, so the event deltas
            // are the only signal — and there is no screen edge to run into,
            // which is the whole point of grabbing.
            emit(dx: event.deltaX, downwards: event.deltaY * Self.deltaYSign)
            return
        }

        let p = convert(event.locationInWindow, from: nil)
        defer { lastLocation = p }
        guard let last = lastLocation else { return }
        let down = last.y - p.y                      // AppKit y up -> screen down

        // Calibrate the captured-mode delta sign from data we can trust.
        if abs(down) > 1, abs(event.deltaY) > 0.5 {
            Self.deltaYSign = (down / event.deltaY) > 0 ? 1 : -1
        }

        emit(dx: p.x - last.x, downwards: down)
    }

    /// Scale to 5620 pixels and carry the sub-pixel remainder.
    private func emit(dx: CGFloat, downwards dy: CGFloat) {
        carryX += dx * pixelScale
        carryY += dy * pixelScale
        let outX = carryX.rounded(.towardZero)
        let outY = carryY.rounded(.towardZero)
        guard outX != 0 || outY != 0 else { return }  // keep the remainder
        carryX -= outX
        carryY -= outY
        terminal?.mouse(.move(Int16(clamping: Int(outX)), Int16(clamping: Int(outY))))
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
