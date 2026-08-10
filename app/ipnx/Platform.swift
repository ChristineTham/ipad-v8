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
