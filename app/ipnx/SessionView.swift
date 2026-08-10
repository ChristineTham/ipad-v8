import SwiftUI
import SwiftTerm

// MARK: - Cell geometry

/// How big SwiftTerm's cell will be for a given font, computed rather than
/// measured.
enum TerminalMetrics {

    /// The font a session draws with.
    ///
    /// Menlo by name, not the monospaced system font: on macOS SwiftTerm sizes
    /// its cell with `font.glyph(withName: "W")`, which needs a font that
    /// actually has glyph names.
    static func font(_ size: CGFloat) -> PlatformFont {
        PlatformFont(name: "Menlo", size: size)
            ?? PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The cell SwiftTerm will lay out for a font of this size — computed the
    /// same way `AppleTerminalView.computeFontDimensions()` does, rather than
    /// measured back out of a frame it has already laid out.
    ///
    /// Replicating another library's internals is a real cost, and it is the
    /// lesser one: the measurement it replaces was circular, and circular was
    /// not "slightly wrong", it was a flickering terminal. If SwiftTerm ever
    /// changes the formula, Session's grid log says so immediately — the grid
    /// stops matching what was asked for.
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

    /// The sizes the picker offers, plus "Fit". Anything finer is a slider
    /// nobody wants: the grid is fixed at 80 or 128 columns either way, so this
    /// only decides how big the picture is.
    static let fontSizes: [CGFloat] = [10, 11, 12, 13, 14, 16, 18, 20, 24]
}

// MARK: - A glass session

/// One glass tty: a fixed grid, centred, in the same bezel the 5620 wears.
struct SessionView: View {
    @ObservedObject var session: Session
    @ObservedObject var settings: Settings
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let room = CGSize(width: max(geo.size.width - Blit5620View.bezel * 2, 1),
                              height: max(geo.size.height - Blit5620View.bezel * 2, 1))
            let want = (cols: session.shape.cols + session.extraCols,
                        rows: session.shape.rows + session.extraRows)
            let points = fontSize(fitting: room, want: want)
            let cell = TerminalMetrics.cell(fontSize: points, scale: displayScale)
            ZStack {
                Color.black
                SessionHost(session: session, theme: settings.glassTheme, fontSize: points)
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
    /// so it is not quite linear in the point size and dividing gets the
    /// boundary cases wrong. Forty iterations of arithmetic costs nothing and
    /// is exact.
    private func fontSize(fitting room: CGSize, want: (cols: Int, rows: Int)) -> CGFloat {
        if let chosen = settings.glassFontSize { return chosen }
        var best: CGFloat = 7
        for pt in stride(from: CGFloat(7), through: 48, by: 1) {
            let c = TerminalMetrics.cell(fontSize: pt, scale: displayScale)
            guard c.width * CGFloat(want.cols) <= room.width,
                  c.height * CGFloat(want.rows) <= room.height else { break }
            best = pt
        }
        return best
    }
}

/// The moulding, shared with the 5620 so every terminal reads as hardware.
extension View {
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

/// AppKit/UIKit bridge for the session's own TerminalView.
///
/// Note what this does *not* do: it never makes a terminal. The view belongs to
/// the Session and outlives every window and tab it is shown in, so a tab the
/// user switched away from still has its scrollback when they come back.
private struct SessionHost: PlatformViewRepresentable {
    let session: Session
    let theme: Settings.GlassTheme
    let fontSize: CGFloat

    func makePlatformView(context: Context) -> TerminalView {
        let tv = session.makeView()
        apply(to: tv)
        tv.claimFirstResponder()
        return tv
    }

    func updatePlatformView(_ view: TerminalView, context: Context) {
        apply(to: view)
    }

    private func apply(to tv: TerminalView) {
        tv.font = TerminalMetrics.font(fontSize)
        tv.nativeForegroundColor = theme.foreground
        tv.nativeBackgroundColor = theme.background
        tv.caretColor = theme.caret
        #if !os(macOS)
        tv.backgroundColor = theme.background
        #endif
    }
}

#if os(macOS)
typealias PlatformFont = NSFont
#else
typealias PlatformFont = UIFont
#endif
