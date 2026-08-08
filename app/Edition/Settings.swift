import Foundation
import SwiftUI

/// User preferences, persisted in UserDefaults.
///
/// `@AppStorage` is deliberately not used: inside an ObservableObject it does
/// not publish changes, so the Metal renderer would never learn that the
/// phosphor changed. Explicit `@Published` + `didSet` keeps one source of
/// truth that both SwiftUI and the renderer observe.
@MainActor
final class Settings: ObservableObject {

    enum Phosphor: String, CaseIterable, Identifiable {
        case green, amber, white

        var id: String { rawValue }

        var label: String {
            switch self {
            case .green: return "Green"
            case .amber: return "Amber"
            case .white: return "White"
            }
        }

        /// Colour of a lit pixel, fed to the fragment shader.
        var tint: SIMD3<Float> {
            switch self {
            case .green: return SIMD3(0.45, 1.0, 0.60)   // the 5620's own green
            case .amber: return SIMD3(1.00, 0.72, 0.30)
            case .white: return SIMD3(0.92, 0.95, 1.00)
            }
        }
    }

    enum Scaling: String, CaseIterable, Identifiable {
        case fit, integer

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fit: return "Fill"
            case .integer: return "Crisp"
            }
        }

        var explanation: String {
            switch self {
            case .fit:
                return "Use the whole window. Fractional scaling can shimmer on mux's stipple background."
            case .integer:
                return "Draw each 5620 pixel as a whole number of screen pixels — smaller, but exact."
            }
        }
    }

    @Published var phosphor: Phosphor { didSet { store.set(phosphor.rawValue, forKey: Key.phosphor) } }
    @Published var scaling: Scaling { didSet { store.set(scaling.rawValue, forKey: Key.scaling) } }
    @Published var mouseSensitivity: Double { didSet { store.set(mouseSensitivity, forKey: Key.mouse) } }
    @Published var persistNVRAM: Bool { didSet { store.set(persistNVRAM, forKey: Key.nvram) } }

    private let store: UserDefaults

    private enum Key {
        static let phosphor = "screen.phosphor"
        static let scaling = "screen.scaling"
        static let mouse = "input.mouseSensitivity"
        static let nvram = "terminal.persistNVRAM"
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        phosphor = Phosphor(rawValue: store.string(forKey: Key.phosphor) ?? "") ?? .green
        scaling = Scaling(rawValue: store.string(forKey: Key.scaling) ?? "") ?? .fit
        let sensitivity = store.double(forKey: Key.mouse)
        mouseSensitivity = sensitivity == 0 ? 1.0 : sensitivity      // 0 == never set
        persistNVRAM = store.object(forKey: Key.nvram) as? Bool ?? true
    }

    /// Largest size not exceeding `available` that shows the 800x1024 screen
    /// at this scaling policy. In `.integer` mode the result is a whole number
    /// of device pixels per 5620 pixel, which is what removes the moire.
    func screenSize(fitting available: CGSize, displayScale: CGFloat) -> CGSize {
        let aspect: CGFloat = 800.0 / 1024.0
        var fit = CGSize(width: available.width, height: available.width / aspect)
        if fit.height > available.height {
            fit = CGSize(width: available.height * aspect, height: available.height)
        }
        guard scaling == .integer, displayScale > 0 else { return fit }
        let factor = floor(fit.width * displayScale / 800)
        // Below 1:1 there is no integral scale that fits, and rounding *up* to
        // one would overflow the window — fall back to filling it.
        guard factor >= 1 else { return fit }
        return CGSize(width: 800 * factor / displayScale, height: 1024 * factor / displayScale)
    }
}
