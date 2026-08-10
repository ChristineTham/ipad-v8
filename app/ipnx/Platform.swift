import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

/// One representable for both platforms. Conformers implement
/// `makePlatformView`/`updatePlatformView`; the AppKit or UIKit spelling of
/// those requirements is synthesized below, so nothing in this app has to be
/// written twice just because Apple named the methods differently.
#if os(macOS)
protocol PlatformViewRepresentable: NSViewRepresentable {
    associatedtype PlatformViewType: NSView
    func makePlatformView(context: Context) -> PlatformViewType
    func updatePlatformView(_ view: PlatformViewType, context: Context)
}

extension PlatformViewRepresentable where NSViewType == PlatformViewType {
    func makeNSView(context: Context) -> PlatformViewType { makePlatformView(context: context) }
    func updateNSView(_ view: PlatformViewType, context: Context) {
        updatePlatformView(view, context: context)
    }
}
#else
protocol PlatformViewRepresentable: UIViewRepresentable {
    associatedtype PlatformViewType: UIView
    func makePlatformView(context: Context) -> PlatformViewType
    func updatePlatformView(_ view: PlatformViewType, context: Context)
}

extension PlatformViewRepresentable where UIViewType == PlatformViewType {
    func makeUIView(context: Context) -> PlatformViewType { makePlatformView(context: context) }
    func updateUIView(_ view: PlatformViewType, context: Context) {
        updatePlatformView(view, context: context)
    }
}
#endif

#if os(macOS)
/// Hands back the NSWindow hosting this view, once there is one.
///
/// SwiftUI does not expose the window, and the window is genuinely needed: the
/// 5620's window has to be *shaped* to the emulated CRT, and only AppKit can
/// set a content aspect ratio. Doing it from the app delegate instead was
/// wrong once there was more than one window — `NSApp.windows.first` picks
/// whichever it likes, and shaped the glass tty window to a portrait tube.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
    }
}

/// Shape a window so the emulated CRT fills it exactly.
///
/// The CRT is one of two fixed sizes, so this is simply: make the window as
/// big as the desk allows at that shape. The terminal is not the whole window
/// — the title bar and its toolbar come off the top, the bezel off every edge
/// — so sizing to `visibleFrame` outright would letterbox the CRT by exactly
/// that much. Full screen is deliberately not used: it hides the menu bar and
/// moves the app to its own Space, which is a heavier thing to do to someone
/// on launch than they asked for.
enum CRTWindow {
    static func shape(_ window: NSWindow, to crt: FrameStore.Geometry, settle: Bool = true) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let desk = screen.visibleFrame

        // Real chrome, measured rather than assumed. `contentLayoutRect` is
        // the part of the window neither the title bar nor the toolbar covers,
        // so the difference is both of them together — which matters now that
        // the controls live in a real NSToolbar whose height is AppKit's
        // business, not ours. (contentRect(forFrameRect:) was wrong here: it
        // answers from the style mask alone and never knows about the toolbar.)
        let chrome = window.frame.height - window.contentLayoutRect.height
        let bezel = Blit5620View.bezel * 2

        let aspect = CGFloat(crt.width) / CGFloat(crt.height)
        var screenH = desk.height - chrome - bezel
        var screenW = screenH * aspect
        if screenW > desk.width - bezel {              // a wide, short desk
            screenW = desk.width - bezel
            screenH = screenW / aspect
        }
        let target = NSRect(x: desk.midX - (screenW + bezel) / 2,
                            y: desk.maxY - (screenH + bezel + chrome),
                            width: screenW + bezel,
                            height: screenH + bezel + chrome)

        // Stop the frame being restored over the top of ours. AppKit reapplies
        // a remembered frame *after* this point, so setting it here alone
        // looked like it worked — setFrame reported success — and the window
        // still came up at whatever size it was last time.
        window.isRestorable = false
        window.setFrameAutosaveName("")
        window.setFrame(target, display: true)

        // Lock the shape. The user can still resize — the picture scales — but
        // the window can no longer be dragged into a shape the emulated CRT is
        // not, which is what used to force the terminal to rebuild itself
        // mid-session.
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

        // And measure again a beat later. Not just because "reported success"
        // turned out not to mean "kept it" — the toolbar may not have been
        // installed on the first pass, and a chrome height measured before it
        // exists is short by the toolbar.
        if settle {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                shape(window, to: crt, settle: false)
            }
        }
    }
}

extension NSView {
    /// AppKit has no `becomeFirstResponder()` you can call directly — focus is
    /// the window's decision, and the window only exists after the view is in
    /// the hierarchy.
    func claimFirstResponder() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }
}
#else
extension UIView {
    func claimFirstResponder() {
        DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
    }
}
#endif
