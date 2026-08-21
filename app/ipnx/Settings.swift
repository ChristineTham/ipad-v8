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

    /// What shape of CRT to emulate — one of exactly two.
    ///
    /// Not a free size. Both ends of the range are pinned by the firmware:
    /// height must stay at 1024 because `YCMAX` is compiled in and the ROM
    /// scrolls at pixel row 969, and width stops being useful past 1152
    /// because the text grid tops out at 127 columns of 9 px plus margins.
    /// Everything in between is a shape nothing benefits from, so offering it
    /// only bought edge cases. See docs/screen-size.md.
    enum ScreenShape: String, CaseIterable, Identifiable {
        case original, wide

        var id: String { rawValue }

        var geometry: FrameStore.Geometry {
            switch self {
            case .original: return .stock        // 800x1024, the real tube
            case .wide:     return .wide         // 1152x1024, 127 columns
            }
        }

        var label: String {
            switch self {
            case .original: return "Original (800×1024)"
            case .wide: return "Wide (1152×1024)"
            }
        }

        var explanation: String {
            switch self {
            case .original:
                return "The real DMD 5620's portrait tube, exactly: 88 columns. Takes effect next launch."
            case .wide:
                return "As wide as the firmware can be driven: 127 columns, the same 1024 lines. Height cannot change — the ROM's text grid is compiled in. Takes effect next launch."
            }
        }
    }

    /// Colours for the plain glass tty. The first three are the 5620's own
    /// phosphors, so switching between the two terminals does not feel like
    /// switching machines; "Paper" is there because sometimes you are reading,
    /// not pretending.
    enum GlassTheme: String, CaseIterable, Identifiable {
        case green, amber, white, paper

        var id: String { rawValue }

        var label: String {
            switch self {
            case .green: return "Green phosphor"
            case .amber: return "Amber phosphor"
            case .white: return "White"
            case .paper: return "Paper"
            }
        }

        private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> PlatformColor {
            PlatformColor(red: r, green: g, blue: b, alpha: 1)
        }

        var foreground: PlatformColor {
            switch self {
            case .green: return Self.rgb(0.45, 1.00, 0.60)
            case .amber: return Self.rgb(1.00, 0.72, 0.30)
            case .white: return Self.rgb(0.92, 0.95, 1.00)
            case .paper: return Self.rgb(0.10, 0.10, 0.11)
            }
        }

        var background: PlatformColor {
            self == .paper ? Self.rgb(0.94, 0.93, 0.89) : Self.rgb(0, 0, 0)
        }

        var caret: PlatformColor { foreground }

        /// The tint the chrome picks up, so the glass around a terminal
        /// belongs to the terminal it surrounds.
        var accent: Color {
            switch self {
            case .green: return Color(red: 0.45, green: 1.00, blue: 0.60)
            case .amber: return Color(red: 1.00, green: 0.72, blue: 0.30)
            case .white: return Color(red: 0.92, green: 0.95, blue: 1.00)
            case .paper: return Color(red: 0.35, green: 0.42, blue: 0.55)
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

    // The plain glass ttys.
    @Published var glassTheme: GlassTheme { didSet { store.set(glassTheme.rawValue, forKey: Key.glassTheme) } }

    /// Whether `tty01` logs itself in as root when it is first opened.
    ///
    /// On by default, and defensible only because of what this machine is:
    /// root is the sole account until B0.6's first-boot provisioner exists,
    /// it has no password, and the machine is a single-user emulator in the
    /// user's own container with no network service listening. Revisit when
    /// there are real accounts.
    @Published var autoLoginRoot: Bool { didSet { store.set(autoLoginRoot, forKey: Key.autoLogin) } }

    /// Whether the emulated VAX gets its Ethernet card at all.
    ///
    /// ON by default, and deliberately: a machine that cannot reach the host
    /// cannot mount /n/macos, which is half of what makes this usable. The
    /// switch exists because "no network" is a legitimate thing to want from
    /// a 1985 machine -- and because SLiRP is a user-mode stack, turning it
    /// off changes nothing about the host's own networking either way.
    ///
    /// Takes effect at the next cold boot: `attach il` happens in boot.conf,
    /// and detaching a card from a running kernel that has autoconfigured it
    /// is not something V8 has any way to be told about.
    @Published var networkEnabled: Bool { didSet { store.set(networkEnabled, forKey: Key.network) } }

    /// Set a password on the account the first-boot provisioner created.
    ///
    /// Empty means none, which is the default and is the honest choice for a
    /// personal machine emulating a personal machine on a disk its owner
    /// already holds: a prompt with no recovery path is a support burden with
    /// no security value. Offered because some people want their machine to
    /// feel like a machine.
    ///
    /// Stored here only long enough to be typed into passwd(1) on the guest;
    /// V8 hashes it with its own crypt(3) and this is cleared afterwards.
    @Published var accountPassword: String { didSet { store.set(accountPassword, forKey: Key.passwd) } }

    /// Which edition to bring up. Takes effect at the next launch, because a
    /// machine is chosen once — `Machine` is constructed in `IpnxApp.init` and
    /// owns a SIMH thread, a disk and ten listening ports from that moment.
    @Published var edition: String { didSet { store.set(edition, forKey: Key.edition) } }
    /// Font size in points, or nil for "fit the window". Stored as 0 for fit,
    /// which is also what an absent default reads as.
    @Published var glassFontSize: CGFloat? {
        didSet { store.set(Double(glassFontSize ?? 0), forKey: Key.glassFont) }
    }

    private let store: UserDefaults

    private enum Key {
        static let phosphor = "screen.phosphor"
        static let scaling = "screen.scaling"
        static let shape = "screen.shape"
        static let screenW = "screen.activeWidth"
        static let screenH = "screen.activeHeight"
        static let mouse = "input.mouseSensitivity"
        static let nvram = "terminal.persistNVRAM"
        static let speed = "terminal.speed"
        static let stats = "terminal.logStats"
        static let glassTheme = "glass.theme"
        static let glassFont = "glass.fontSize"
        static let autoLogin = "session.autoLoginRoot"
        static let network = "machine.networkEnabled"
        static let passwd = "account.password"
        // Deliberately MachineSpec's own constant rather than a second string:
        // `Machine' is built in IpnxApp.init, before any Settings exists, so it
        // reads this key directly.  Two spellings of one key is a list that
        // appears twice.
        static let edition = MachineSpec.defaultsKey
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        // `MachineSpec.current' is the authority on what actually booted -- it
        // falls back when the stored choice names media this build does not
        // carry -- so the control shows what is running, not what was wished for.
        edition = MachineSpec.current.id
        phosphor = Phosphor(rawValue: store.string(forKey: Key.phosphor) ?? "") ?? .green
        scaling = Scaling(rawValue: store.string(forKey: Key.scaling) ?? "") ?? .fit
        screenShape = ScreenShape(rawValue: store.string(forKey: Key.shape) ?? "") ?? .wide
        let w = store.integer(forKey: Key.screenW), h = store.integer(forKey: Key.screenH)
        if w > 0, h > 0 { activeScreen = FrameStore.Geometry(width: w, height: h) }
        let sensitivity = store.double(forKey: Key.mouse)
        mouseSensitivity = sensitivity == 0 ? 1.0 : sensitivity      // 0 == never set
        persistNVRAM = store.object(forKey: Key.nvram) as? Bool ?? true
        speed = Speed(rawValue: store.string(forKey: Key.speed) ?? "") ?? .fast
        logTerminalStats = store.bool(forKey: Key.stats)          // absent == false
        glassTheme = GlassTheme(rawValue: store.string(forKey: Key.glassTheme) ?? "") ?? .green
        let pts = store.double(forKey: Key.glassFont)
        glassFontSize = pts > 0 ? CGFloat(pts) : nil              // 0 / absent == fit
        autoLoginRoot = store.object(forKey: Key.autoLogin) as? Bool ?? true
        networkEnabled = store.object(forKey: Key.network) as? Bool ?? true
        accountPassword = store.string(forKey: Key.passwd) ?? ""
    }

    /// A second window to open at launch, from `defaults` rather than a click.
    ///
    /// The testing seam docs/ui-redesign.md asks for: driving this app with
    /// AppleScript is forbidden (both `activate` and `keystroke` resolve the
    /// *bundle* through LaunchServices and can start a second copy, and two
    /// VAXes sharing one v8.disk is a filesystem-corruption hazard), so a
    /// check that needs the 5620 window presets it instead:
    ///
    ///     defaults write com.hellotham.ipnx debug.openWindow dmd
    ///
    /// Unset — which is every real launch — this does nothing.
    static var debugOpenWindow: TerminalShape? {
        guard let raw = UserDefaults.standard.string(forKey: "debug.openWindow") else {
            return nil
        }
        return TerminalShape(rawValue: raw)
    }

    /// Where the terminal thread should write throughput stats, or nil to keep
    /// it silent. Centralised so no call site can accidentally re-enable it.
    func statsURL(_ machine: Machine) -> URL? {
        logTerminalStats ? machine.termStatsURL : nil
    }

    /// The CRT this session is running, decided **once** and then left alone.
    ///
    /// It is deliberately not a function of the window's current size. The
    /// terminal used to be reshaped on every layout pass, which meant a live
    /// window drag resized the emulated hardware — and made the geometry
    /// depend on when in the boot sequence the drag happened. Now the window
    /// is locked to the CRT's shape instead, so resizing scales the picture
    /// and never rebuilds the machine.
    @Published private(set) var activeScreen: FrameStore.Geometry = .stock

    /// Settle the CRT for this session. A lookup now, not a calculation:
    /// the window is shaped to the result rather than the other way round.
    @discardableResult
    func chooseScreen() -> FrameStore.Geometry {
        let chosen = screenShape.geometry
        activeScreen = chosen
        store.set(chosen.width, forKey: Key.screenW)
        store.set(chosen.height, forKey: Key.screenH)
        return chosen
    }

    /// The geometry the last session ran at, or nil if there was none.
    ///
    /// A restored session has to come back at the size its saved screen was
    /// captured at, or the pixels would be unpacked at the wrong stride.
    var lastScreen: FrameStore.Geometry? {
        let w = store.integer(forKey: Key.screenW), h = store.integer(forKey: Key.screenH)
        guard w > 0, h > 0 else { return nil }
        return FrameStore.Geometry(width: w, height: h)
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
