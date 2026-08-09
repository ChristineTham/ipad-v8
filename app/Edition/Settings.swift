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

    /// What shape of CRT to emulate.
    ///
    /// The real 5620 was a portrait 800x1024 tube, which letterboxes badly on a
    /// landscape window. `.fit` widens the emulated screen to the window's
    /// shape instead of scaling a portrait one into it.
    enum ScreenShape: String, CaseIterable, Identifiable {
        case authentic, fit

        var id: String { rawValue }

        var label: String {
            switch self {
            case .authentic: return "Authentic (800×1024)"
            case .fit: return "Fit the window"
            }
        }

        var explanation: String {
            switch self {
            case .authentic:
                return "The real DMD 5620's portrait tube, exactly."
            case .fit:
                return "Widen the emulated CRT to match the window. Height stays 1024 — the firmware's text grid needs it. mux layers use the extra width; the login prompt before mux does not."
            }
        }
    }

    /// Multiplier on the terminal CPU's 10 MHz clock. This is what makes the
    /// 5620 *draw* faster (mux painting, scrolling, cursor tracking); it does
    /// not speed up the serial wire, which is paced in wall-clock time by the
    /// DUART. Above ~4x the firmware's serial handshakes start to be starved —
    /// A0 found a flat-out CPU breaks them outright — so it is a choice with a
    /// stated risk rather than a free win.
    enum Speed: String, CaseIterable, Identifiable {
        case authentic, fast, faster, turbo

        var id: String { rawValue }

        var multiplier: Double {
            switch self {
            case .authentic: return 1
            case .fast: return 2
            case .faster: return 4
            case .turbo: return 8
            }
        }

        var label: String {
            switch self {
            case .authentic: return "Authentic (10 MHz)"
            case .fast: return "Fast (2×)"
            case .faster: return "Faster (4×)"
            case .turbo: return "Turbo (8×)"
            }
        }
    }

    @Published var phosphor: Phosphor { didSet { store.set(phosphor.rawValue, forKey: Key.phosphor) } }
    @Published var scaling: Scaling { didSet { store.set(scaling.rawValue, forKey: Key.scaling) } }
    @Published var screenShape: ScreenShape { didSet { store.set(screenShape.rawValue, forKey: Key.shape) } }
    @Published var mouseSensitivity: Double { didSet { store.set(mouseSensitivity, forKey: Key.mouse) } }
    @Published var persistNVRAM: Bool { didSet { store.set(persistNVRAM, forKey: Key.nvram) } }
    @Published var speed: Speed { didSet { store.set(speed.rawValue, forKey: Key.speed) } }

    /// Throughput instrumentation for the serial wire. Off by default: it is a
    /// diagnostic that appends to a file in the container forever, which has no
    /// business running in a shipped build. It stays available because finding
    /// the real serial bottleneck needed queue depth, not guesswork, and the
    /// next such question will need it again.
    @Published var logTerminalStats: Bool { didSet { store.set(logTerminalStats, forKey: Key.stats) } }

    private let store: UserDefaults

    private enum Key {
        static let phosphor = "screen.phosphor"
        static let scaling = "screen.scaling"
        static let shape = "screen.shape"
        static let mouse = "input.mouseSensitivity"
        static let nvram = "terminal.persistNVRAM"
        static let speed = "terminal.speed"
        static let stats = "terminal.logStats"
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        phosphor = Phosphor(rawValue: store.string(forKey: Key.phosphor) ?? "") ?? .green
        scaling = Scaling(rawValue: store.string(forKey: Key.scaling) ?? "") ?? .fit
        screenShape = ScreenShape(rawValue: store.string(forKey: Key.shape) ?? "") ?? .fit
        let sensitivity = store.double(forKey: Key.mouse)
        mouseSensitivity = sensitivity == 0 ? 1.0 : sensitivity      // 0 == never set
        persistNVRAM = store.object(forKey: Key.nvram) as? Bool ?? true
        speed = Speed(rawValue: store.string(forKey: Key.speed) ?? "") ?? .fast
        logTerminalStats = store.bool(forKey: Key.stats)          // absent == false
    }

    /// Where the terminal thread should write throughput stats, or nil to keep
    /// it silent. Centralised so no call site can accidentally re-enable it.
    func statsURL(_ machine: Machine) -> URL? {
        logTerminalStats ? machine.termStatsURL : nil
    }

    /// What CRT to ask the terminal for, given the space it has to live in.
    ///
    /// Height is always 1024 and only the width moves. That is not a
    /// simplification, it is the firmware's constraint: `YCMAX` is compiled
    /// into the ROM at 69, so it scrolls at pixel row 969, and a screen
    /// shorter than 983 leaves it blitting rows the CRT does not have —
    /// measured, the text collapses into the upper half. Width has no such
    /// limit; it only has to be a multiple of 32, because a Bitmap's stride is
    /// counted in 32-bit Words. Below 800 the ROM's own 88-column text grid
    /// would be clipped, so that is the floor. See docs/screen-size.md.
    func desiredScreen(fitting available: CGSize) -> FrameStore.Geometry {
        guard screenShape == .fit, available.width > 0, available.height > 0 else {
            return .stock
        }
        let height = 1024
        let wanted = CGFloat(height) * (available.width / available.height)
        let words = (wanted / 32).rounded()
        let width = min(2048, max(800, Int(words) * 32))
        return FrameStore.Geometry(width: width, height: height)
    }

    /// Largest size not exceeding `available` that shows a `screen`-sized
    /// terminal at this scaling policy. In `.integer` mode the result is a
    /// whole number of device pixels per 5620 pixel, which is what removes
    /// the moire.
    func screenSize(fitting available: CGSize,
                    screen: FrameStore.Geometry,
                    displayScale: CGFloat) -> CGSize {
        let aspect = CGFloat(screen.width) / CGFloat(screen.height)
        var fit = CGSize(width: available.width, height: available.width / aspect)
        if fit.height > available.height {
            fit = CGSize(width: available.height * aspect, height: available.height)
        }
        guard scaling == .integer, displayScale > 0 else { return fit }
        let factor = floor(fit.width * displayScale / CGFloat(screen.width))
        // Below 1:1 there is no integral scale that fits, and rounding *up* to
        // one would overflow the window — fall back to filling it.
        guard factor >= 1 else { return fit }
        return CGSize(width: CGFloat(screen.width) * factor / displayScale,
                      height: CGFloat(screen.height) * factor / displayScale)
    }
}
