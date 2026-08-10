import Foundation
import SwiftUI
import SwiftTerm

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A plain glass tty on a DZ line — the light alternative to the 5620.
///
/// Sometimes you just want a shell. The 5620 is the point of this app, but it
/// is also its entire CPU cost: the dmd thread runs a WE32100 flat out at
/// ~63% of a core, while patched SIMH idles at 2.7%. A session that never
/// starts it runs the same machine at a twentieth of the power, which on iPad
/// is a battery decision rather than a preference.
///
/// It costs almost nothing to offer, because V8 was already set up for it:
/// `/etc/ttys` runs a getty on `tty00`..`tty07` as well as the console, and
/// SIMH's `tmxr_poll_conn` hands each connection on a listening port to the
/// next free line. So a session is one socket. See docs/machine-config.md.
@MainActor
final class GlassTerminal: ObservableObject {

    /// What a session claims to be. Both are real entries in *this* image's
    /// `/etc/termcap`, and both are pinned to a DZ line whose `/.profile`
    /// exports the matching TERM (config.exp) — because this kernel has
    /// `struct sgttyb` and no `TIOCGWINSZ`, so nothing can tell the guest how
    /// big the window is. The grid is whatever termcap says it is, and the
    /// emulator must agree or full-screen programs paint on the wrong cells.
    enum Kind: String, CaseIterable, Identifiable {
        case vt100          // 80x24, on the mux listener -> tty01..tty06
        case vt100w         // 128x24, on the reserved line 7 -> tty07

        var id: String { rawValue }

        var cols: Int { self == .vt100 ? 80 : 128 }
        var rows: Int { 24 }

        var label: String {
            switch self {
            case .vt100: return "VT100 (80×24)"
            case .vt100w: return "VT100 wide (128×24)"
            }
        }

        var explanation: String {
            switch self {
            case .vt100:
                return "The classic. V8's termcap calls it vt100; vi, more and mail all know it."
            case .vt100w:
                return "termcap's vt100w — the same terminal in 132-column mode, which this image records as 128 columns. One session at a time."
            }
        }
    }

    enum State: Equatable {
        case idle
        case connecting
        case up
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Extra columns/rows the frame must carry beyond the wanted grid.
    ///
    /// On macOS SwiftTerm divides `frame.width - reservedScrollerWidth` by the
    /// cell, so a frame sized to exactly cols x cell can come up one column
    /// short — and one column short corrupts every full-screen program.
    ///
    /// This only ever *grows*, and is capped. That matters more than it
    /// looks: the first version of this measured the cell as `frame / grid`
    /// and sized the frame as `cell x grid`, which is a fixed-point iteration
    /// with a floor in it. It never settled — the grid oscillated between
    /// 111x34 and 112x35 and the terminal visibly flickered. The cell is now
    /// computed from the font instead, so the only feedback left is this
    /// small integer, which can move at most a few times and then stops.
    @Published private(set) var extraCols = 0
    @Published private(set) var extraRows = 0

    private var lastGrid: (Int, Int) = (0, 0)
    /// Extra frame the view needs beyond cols x cell, discovered by
    /// watching what SwiftTerm actually laid out.
    @Published private(set) var slack: CGSize = .zero
    private let link = ConsoleLink()
    /// Bytes from V8, handed to the TerminalView.
    var onBytes: (([UInt8]) -> Void)?

    var isRunning: Bool { state == .up || state == .connecting }

    func start(port: UInt16) {
        guard state == .idle else { return }
        state = .connecting
        Self.note("dialling port \(port)")
        link.onBytes = { [weak self] bytes in
            // Strip the eighth bit. V8 is a 7-bit ASCII machine and its tty
            // driver puts *parity* in bit 7 — getty's partab[] sends the first
            // `login:` with mark parity, and the driver keeps generating it
            // until stty says otherwise. A real VT100 was wired for 7 bits
            // plus parity and discarded it in hardware; SwiftTerm is not, so
            // it renders those bytes as Latin-1 and the screen fills with
            // accented junk.
            //
            // The 5620 never showed this because its firmware masks, and the
            // console never showed it because `set tto 7b` masks in SIMH. The
            // DZ lines are 8-bit and nothing masked them. It cannot be fixed
            // with `set dz 7b` either: that would hit every line, and mux's
            // download protocol on the 5620's line is genuinely 8-bit.
            self?.onBytes?(bytes.map { $0 & 0x7f })
        }
        Task { @MainActor in
            guard await link.connect(port: port) else {
                Self.note("no free line on the DZ (port \(port))")
                state = .failed("no free line on the DZ")
                return
            }
            state = .up
            Self.note("line up")
            // Ask the far end to say something. getty prints its banner and
            // `login:` exactly once, when it starts — long before anyone
            // dialled this line — and then blocks in getname(). Without this
            // a fresh session is a blank screen with a working keyboard,
            // which is the same trap the 5620 fell into after a restore.
            try? await Task.sleep(nanoseconds: 400_000_000)
            link.send([0x0d])
        }
    }

    func stop() {
        link.close()
        state = .idle
    }

    func send(_ bytes: [UInt8]) { link.send(bytes) }

    nonisolated static func note(_ message: String) {
        FileHandle.standardError.write(Data("ipnx glass: \(message)\n".utf8))
    }

    /// What SwiftTerm settled on, reported by its delegate. Used only to
    /// grant headroom, never to size the cell.
    func observed(cols: Int, rows: Int, want: (cols: Int, rows: Int), atFontSize size: CGFloat) {
        if (cols, rows) != lastGrid {
            lastGrid = (cols, rows)
            Self.note("grid \(cols)x\(rows) at \(Int(size)) pt "
                      + "(want \(want.cols)x\(want.rows), headroom \(extraCols)x\(extraRows))")
        }
        if cols < want.cols { extraCols = min(4, extraCols + (want.cols - cols)) }
        if rows < want.rows { extraRows = min(4, extraRows + (want.rows - rows)) }
    }

    // MARK: Geometry

    /// The font a session draws with.
    static func font(_ size: CGFloat) -> PlatformFont {
        // Menlo by name, not the monospaced system font: on macOS SwiftTerm
        // sizes its cell with `font.glyph(withName: "W")`, which wants a font
        // that actually has glyph names.
        PlatformFont(name: "Menlo", size: size)
            ?? PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The cell SwiftTerm will lay out for a font of this size — computed the
    /// same way `AppleTerminalView.computeFontDimensions()` does, rather than
    /// measured back out of a frame it already laid out.
    ///
    /// Replicating another library's internals is a real cost, and it is the
    /// lesser one: the measurement it replaces was circular, and circular was
    /// not "slightly wrong", it was a flickering terminal. If SwiftTerm ever
    /// changes the formula the log line above says so immediately, because the
    /// grid stops matching what was asked for.
    static func cell(fontSize: CGFloat, scale: CGFloat) -> CGSize {
        let f = font(fontSize)
        let ct = f as CTFont
        let height = ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct))
        #if os(macOS)
        let width = f.advancement(forGlyph: f.glyph(withName: "W")).width
        #else
        let width = ("W" as NSString).size(withAttributes: [.font: f]).width
        #endif
        let s = max(scale, 1)
        return CGSize(width: max(1, (width * s).rounded() / s),
                      height: max(1, ceil(height * s) / s))
    }
}

// MARK: - The view

/// The glass tty: a fixed grid, centred, in the same bezel the 5620 wears.
struct GlassTerminalView: View {
    @ObservedObject var session: GlassTerminal
    @ObservedObject var settings: Settings
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let kind = settings.glassKind
            let room = CGSize(width: max(geo.size.width - Blit5620View.bezel * 2, 1),
                              height: max(geo.size.height - Blit5620View.bezel * 2, 1))
            let want = (cols: kind.cols + session.extraCols,
                        rows: kind.rows + session.extraRows)
            let points = fontSize(fitting: room, want: want)
            let cell = GlassTerminal.cell(fontSize: points, scale: displayScale)
            ZStack {
                Color.black
                GlassTerminalHost(session: session, theme: settings.glassTheme,
                                  fontSize: points, want: (kind.cols, kind.rows))
                    .frame(width: cell.width * CGFloat(want.cols),
                           height: cell.height * CGFloat(want.rows))
                    .bezelled()
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .background(Color.black)
    }

    /// The user's choice, or the largest whole point size whose grid fits.
    ///
    /// A search rather than a division: the cell is snapped to the pixel grid,
    /// so it is not quite linear in the point size, and dividing gets the
    /// boundary cases wrong. Forty iterations of arithmetic costs nothing and
    /// is exact.
    private func fontSize(fitting room: CGSize, want: (cols: Int, rows: Int)) -> CGFloat {
        if let chosen = settings.glassFontSize { return chosen }
        var best: CGFloat = 7
        for pt in stride(from: CGFloat(7), through: 48, by: 1) {
            let c = GlassTerminal.cell(fontSize: pt, scale: displayScale)
            guard c.width * CGFloat(want.cols) <= room.width,
                  c.height * CGFloat(want.rows) <= room.height else { break }
            best = pt
        }
        return best
    }
}

/// The moulding, shared with the 5620 so both terminals read as hardware.
private extension View {
    func bezelled() -> some View {
        self
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.05), lineWidth: 1))
            .padding(Blit5620View.bezel)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.07)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
    }
}

private struct GlassTerminalHost: PlatformViewRepresentable {
    let session: GlassTerminal
    let theme: Settings.GlassTheme
    let fontSize: CGFloat
    let want: (cols: Int, rows: Int)

    func makePlatformView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        context.coordinator.view = tv
        apply(to: tv)
        session.onBytes = { [weak tv] bytes in tv?.feed(byteArray: bytes[...]) }
        tv.claimFirstResponder()
        return tv
    }

    func updatePlatformView(_ view: TerminalView, context: Context) {
        context.coordinator.fontSize = fontSize
        context.coordinator.want = want
        apply(to: view)
    }

    private func apply(to tv: TerminalView) {
        tv.font = GlassTerminal.font(fontSize)
        tv.nativeForegroundColor = theme.foreground
        tv.nativeBackgroundColor = theme.background
        tv.caretColor = theme.caret
        #if !os(macOS)
        tv.backgroundColor = theme.background
        #endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, fontSize: fontSize, want: want)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: GlassTerminal
        var fontSize: CGFloat
        var want: (cols: Int, rows: Int)
        weak var view: TerminalView?

        init(session: GlassTerminal, fontSize: CGFloat, want: (cols: Int, rows: Int)) {
            self.session = session
            self.fontSize = fontSize
            self.want = want
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Delete must arrive as ^H. V8's tty driver comes up with erase =
            // ^H (config.exp leaves it there deliberately, because the 5620
            // side maps Delete to 0x08), and SwiftTerm sends 0x7f. One
            // translation here keeps both terminals honest.
            let bytes = data.map { $0 == 0x7f ? 0x08 : $0 }
            Task { @MainActor in self.session.send(bytes) }
        }

        /// SwiftTerm telling us what grid it settled on. Dividing the frame by
        /// it is the only measurement of the cell that cannot go stale.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            let size = fontSize
            let want = self.want
            Task { @MainActor in
                self.session.observed(cols: newCols, rows: newRows,
                                      want: want, atFontSize: size)
            }
        }

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

#if os(macOS)
typealias PlatformFont = NSFont
#else
typealias PlatformFont = UIFont
#endif
