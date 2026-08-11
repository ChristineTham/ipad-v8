import Foundation
import SwiftUI
import SwiftTerm

// MARK: - The machine's terminals

/// One of the nine terminals this machine has: the operator console, plus a
/// getty on `tty00`..`tty07`.
///
/// A fixed list, because the hardware is fixed: `/etc/ttys` runs a getty on
/// exactly these and the DZ11 has exactly eight lines. Nothing here is a
/// preference, and nothing here can be added to at runtime.
enum Line: Hashable, Identifiable, Codable, Sendable {
    case console
    case tty(Int)

    static let all: [Line] = [.console] + (0...7).map(Line.tty)

    var id: Self { self }

    /// The DZ line, or nil for the console — which is not on the DZ at all but
    /// on the 11/780's own console interface, and reached through SIMH rather
    /// than through a serial line.
    var dz: Int? {
        if case .tty(let n) = self { return n }
        return nil
    }

    /// What V8 calls it. This is not cosmetic: `/.profile` runs
    /// `case \`tty\` in` and picks TERM from this exact string, so the name and
    /// the shape below are two views of one fact.
    var device: String {
        switch self {
        case .console: return "console"
        case .tty(let n): return String(format: "tty%02d", n)
        }
    }

    var title: String {
        switch self {
        case .console: return "Console"
        case .tty(0): return "DMD 5620"
        case .tty(let n): return String(format: "tty%02d", n)
        }
    }

    var symbol: String {
        switch self {
        case .console: return "text.alignleft"
        case .tty(0): return "display"
        default: return "terminal"
        }
    }

    /// The shape V8 believes this line is, decided by `/.profile`'s case arms:
    /// `tty00` → dmd, `tty07` → vt100w, everything else (the console included,
    /// which falls through the `*)` arm — measured, not assumed) → vt100.
    var shape: TerminalShape {
        switch self {
        case .console: return .vt100
        case .tty(0): return .dmd
        case .tty(7): return .vt100w
        case .tty: return .vt100
        }
    }
}

/// A terminal's fixed size — and therefore which window it can live in.
///
/// This kernel has `struct sgttyb` and **no `TIOCGWINSZ`**; that arrived in
/// 4.3BSD and V8 is 4.1BSD-derived. Nothing can tell V8 how large a window is,
/// so a terminal's grid is whatever its termcap entry says and nothing else.
/// Three fixed, unequal shapes that cannot be reflowed into one another — so
/// tabs group *within* a shape, and each shape gets its own window. The
/// windows-by-shape rule is hardware, not taste.
enum TerminalShape: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case vt100      // 80×24   — console + tty01..tty06
    case vt100w     // 128×24  — tty07, one line, reserved
    case dmd        // 1152×1024 bitmap — tty00, the 5620

    var id: String { rawValue }

    /// The lines V8 will hand this shape to.
    var lines: [Line] { Line.all.filter { $0.shape == self } }

    var cols: Int { self == .vt100w ? 128 : 80 }
    var rows: Int { 24 }

    /// True when this shape draws through SwiftTerm rather than through the
    /// 5620's Metal framebuffer.
    var isGlass: Bool { self != .dmd }

    var windowTitle: String {
        switch self {
        case .vt100: return "ipnx"
        case .vt100w: return "ipnx — Wide Terminal"
        case .dmd: return "ipnx — DMD 5620"
        }
    }

    var label: String {
        switch self {
        case .vt100: return "Terminal (80×24)"
        case .vt100w: return "Wide terminal (128×24)"
        case .dmd: return "DMD 5620"
        }
    }

    var symbol: String {
        switch self {
        case .vt100: return "terminal"
        case .vt100w: return "rectangle.split.2x1"
        case .dmd: return "display"
        }
    }
}

// MARK: - One session

/// One terminal session: a line, the transport that reaches it, and the view
/// that draws it.
///
/// Sessions are lazy. Opening a tab is what dials the line — nothing starts
/// behind the user's back, which matters most for `tty00`: the 5620's WE32100
/// thread is the app's entire CPU cost (~63% of a core at 2×, against patched
/// SIMH's 2.7% at an idle prompt), so a user who lives in the glass ttys runs
/// the same VAX at a twentieth of the power.
@MainActor
final class Session: ObservableObject, Identifiable {

    enum State: Equatable {
        case idle
        case connecting
        case up
        case failed(String)
    }

    let line: Line
    nonisolated var id: Line { line }
    var shape: TerminalShape { line.shape }
    var title: String { line.title }

    @Published private(set) var state: State = .idle

    /// Console only, and true by default.
    ///
    /// The console is the one terminal that talks unprompted — boot messages,
    /// panics, `hp0: hard error` — and the one place a stray keystroke lands
    /// somewhere no getty is guarding. Reading it is the reason to have it
    /// open; typing into it by accident is not. The lock is in the toolbar,
    /// not behind a confirmation, because unlocking is ordinary.
    @Published var readOnly: Bool

    /// The SwiftTerm view, for glass sessions.
    ///
    /// Owned here rather than by the SwiftUI representable, and that is
    /// deliberate: a terminal's scrollback lives inside this object, so if
    /// SwiftUI were allowed to own it then switching tabs would silently be a
    /// `clear`. The representable hands this same instance back every time.
    private(set) var view: TerminalView?

    private unowned let machine: Machine
    private let dmd: Terminal5620?
    private let link: ConsoleLink?
    private let settings: Settings
    private var nudged = false
    private var autoLoginDone = false

    init(line: Line, machine: Machine, dmd: Terminal5620?, settings: Settings) {
        self.line = line
        self.machine = machine
        self.dmd = line == .tty(0) ? dmd : nil
        self.settings = settings
        self.readOnly = (line == .console)
        // The console rides the machine's own console socket; every tty gets
        // its own link to its own DZ listener.
        self.link = (line == .console || line == .tty(0)) ? nil : ConsoleLink()
    }

    var isRunning: Bool { state == .up || state == .connecting }

    // MARK: Lifecycle

    /// Dial the line. Idempotent — reopening an already-open tab is a no-op,
    /// which is what keeps a session's scrollback across a window close.
    func start() {
        guard state == .idle else { return }

        switch line {
        case .console:
            // Nothing to dial: Machine already owns this socket and has been
            // draining it since launch. Started at store-init time so the
            // whole boot transcript lands in a terminal that exists.
            machine.onOutput = { [weak self] bytes in self?.receive(bytes) }
            state = .up
            note("attached to the machine console")

        case .tty(0):
            guard let dmd else { return }
            state = .connecting
            dmd.speed.set(settings.speed.multiplier)
            dmd.start(dzPort: machine.dzPort(0),
                      screen: settings.activeScreen,
                      nvram: settings.persistNVRAM ? machine.nvramURL : nil,
                      stats: settings.statsURL(machine),
                      screenSnapshot: machine.screenURL)
            state = .up
            note("5620 powered on")

        case .tty(let n):
            guard let link else { return }
            state = .connecting
            link.onBytes = { [weak self] bytes in
                // Strip the eighth bit. V8 is a 7-bit ASCII machine whose tty
                // driver puts *parity* there — getty's partab[] sends the
                // first `login:` with mark parity and keeps generating it
                // until stty says otherwise. A real VT100 was wired for 7 bits
                // plus parity and dropped it in hardware; SwiftTerm is not, so
                // those bytes render as Latin-1 and the screen fills with
                // accented junk. It cannot be fixed with `set dz 7b` either:
                // that would hit every line, and mux's download protocol on
                // tty00 is genuinely 8-bit.
                self?.receive(bytes.map { $0 & 0x7f })
            }
            let port = machine.dzPort(n)
            Task { @MainActor in
                guard await link.connect(port: port) else {
                    self.state = .failed("could not reach \(self.line.device)")
                    self.note("no answer on port \(port)")
                    return
                }
                self.state = .up
                self.note("\(self.line.device) up on port \(port)")
                await self.wakeFarEnd()
            }
        }
    }

    func stop() {
        switch line {
        case .console:
            break                       // the console is the machine's, not ours
        case .tty(0):
            dmd?.stop()
        case .tty:
            link?.close()
        }
        guard line != .console else { return }
        state = .idle
        nudged = false
    }

    /// Make a far end that is already running say something.
    ///
    /// getty prints its banner and `login:` exactly once, when it starts —
    /// long before this line was dialled — and then blocks in `getname()`; a
    /// logged-in shell prints nothing unasked at all. So a session that has
    /// just connected is looking at a machine with nothing left to say, and
    /// this CR is the only thing that changes that. An empty name makes getty
    /// loop and reprint, which is also what gives the auto-login below a
    /// prompt to answer.
    private func wakeFarEnd() async {
        guard let link, !nudged else { return }
        nudged = true
        try? await Task.sleep(nanoseconds: 400_000_000)
        link.send([0x0d])
        await autoLogin()
    }

    /// `tty01` logs itself in. Gated on actually seeing the prompt, never on a
    /// timer: a restored session comes back with a shell already running and
    /// no `login:` will ever arrive, and typing `root` into a live shell is
    /// not a harmless mistake.
    ///
    /// root has no password on this image (verified in work/myv8/config.log:
    /// `login: root` goes straight to `#`), so the name is the whole exchange.
    private func autoLogin() async {
        guard line == .tty(1), !autoLoginDone, let link else { return }
        guard settings.autoLoginRoot else { return }
        guard await link.waitFor("login:", timeout: 20) else {
            note("no login: prompt — leaving \(line.device) to the user")
            return
        }
        autoLoginDone = true
        note("logging \(line.device) in as root")
        link.send(Array("root\r".utf8))
        await provisionIfNeeded(link)
    }

    /// First boot only: create the account that belongs to whoever is running
    /// this copy. Runs here because this is the one place in the app that has
    /// a *root shell* — the console is read-only behind a lock and has no
    /// shell on it at all, which is worth stating because sending these to
    /// the console instead types them into nothing and silently does nothing.
    ///
    /// Everything is proven by an output-anchored marker rather than by a
    /// prompt: V8's tty echoes typed characters as they arrive and they
    /// interleave *into* whatever is printing, so a `#` prompt matcher
    /// matches the echo of the command being sent. The marker is spelled
    /// through a shell variable so the echo carries `PROV$OK` and only the
    /// result carries `PROV-ok`.
    private func provisionIfNeeded(_ link: ConsoleLink) async {
        guard !machine.isProvisioned else { return }
        let user = Provisioner.v8Name(from: Provisioner.hostUserName)
        let gecos = Provisioner.hostFullName

        guard await link.waitFor("#", timeout: 20) else {
            note("no root shell — account not created; will retry next boot")
            return
        }
        // The marker variable itself, before anything that uses it.
        link.send(Array("OK=-ok\r".utf8))
        try? await Task.sleep(nanoseconds: 400_000_000)
        for cmd in Provisioner.commands(user: user, gecos: gecos) {
            link.send(Array("\(cmd)\r".utf8))
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        link.send(Array("echo PROV$OK\r".utf8))
        if await link.waitFor("PROV-ok", timeout: 15) {
            machine.markProvisioned(user)
            note("account `\(user)' created, home /usr/\(user)")
        } else {
            // Deliberately NOT marked: a half-made account should be retried,
            // and every command above is guarded so a second run is safe.
            note("account creation unconfirmed — will retry next boot")
        }
    }

    // MARK: Bytes

    private func receive(_ bytes: [UInt8]) {
        view?.feed(byteArray: bytes[...])
    }

    /// Keystrokes, from the view.
    func send(_ bytes: [UInt8]) {
        guard !readOnly else { return }
        switch line {
        case .console: machine.sendInput(bytes)
        case .tty(0): break                       // the 5620 has its own path
        case .tty: link?.send(bytes)
        }
    }

    // MARK: The view

    /// The session's terminal view, made once and kept.
    ///
    /// Made eagerly at `start()` for the console so the boot transcript has
    /// somewhere to land before anyone looks at it.
    @discardableResult
    func makeView() -> TerminalView {
        if let view { return view }
        let cell = TerminalMetrics.cell(fontSize: 13, scale: 2)
        let frame = CGRect(x: 0, y: 0,
                           width: cell.width * CGFloat(shape.cols),
                           height: cell.height * CGFloat(shape.rows))
        let tv = TerminalView(frame: frame)
        let bridge = Bridge(session: self)
        tv.terminalDelegate = bridge
        self.bridge = bridge
        view = tv
        return tv
    }

    private var bridge: Bridge?

    /// SwiftTerm's delegate. A separate object because the protocol is not
    /// main-actor-isolated and Session is.
    final class Bridge: NSObject, TerminalViewDelegate {
        private let session: Session
        init(session: Session) { self.session = session }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Delete must arrive as ^H. V8's tty driver comes up with
            // erase = ^H — config.exp leaves it there deliberately, because
            // the 5620 side maps Delete to 0x08 — and SwiftTerm sends 0x7f.
            // One translation here keeps every terminal honest.
            let bytes = data.map { $0 == 0x7f ? 0x08 : $0 }
            Task { @MainActor in self.session.send(bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                self.session.observed(cols: newCols, rows: newRows)
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

    /// Extra columns/rows the frame must carry beyond the wanted grid.
    ///
    /// On macOS SwiftTerm divides `frame.width - reservedScrollerWidth` by the
    /// cell, so a frame sized to exactly cols × cell can come up one column
    /// short — and one column short corrupts every full-screen program.
    ///
    /// This only ever *grows*, and is capped, and that matters more than it
    /// looks. The first version measured the cell as `frame / grid` while
    /// sizing the frame as `cell × grid`, which is a fixed-point iteration
    /// with a floor in it: it never settled, the grid oscillated between
    /// 111×34 and 112×35, and the terminal visibly flickered. The cell is now
    /// computed from the font instead, so the only feedback left is this small
    /// integer, which can move a few times and then stops.
    @Published private(set) var extraCols = 0
    @Published private(set) var extraRows = 0
    private var lastGrid = (0, 0)

    private func observed(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if (cols, rows) != lastGrid {
            lastGrid = (cols, rows)
            note("grid \(cols)×\(rows) (want \(shape.cols)×\(shape.rows))")
        }
        if cols < shape.cols { extraCols = min(4, extraCols + (shape.cols - cols)) }
        if rows < shape.rows { extraRows = min(4, extraRows + (shape.rows - rows)) }
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("ipnx \(line.device): \(message)\n".utf8))
    }
}

// MARK: - The registry

/// Every session the machine can have, and which of them are open.
///
/// App-level rather than window-level, so that closing a window and reopening
/// it finds the sessions as they were rather than freshly logged out. V8 runs
/// a getty per line and those gettys do not care about our windows.
@MainActor
final class SessionStore: ObservableObject {

    let machine: Machine
    let dmd: Terminal5620
    let settings: Settings

    private var sessions: [Line: Session] = [:]

    /// Which lines the user has actually opened. Ordered per shape so tabs do
    /// not reshuffle themselves.
    @Published private(set) var opened: [Line] = []

    init(machine: Machine, dmd: Terminal5620, settings: Settings) {
        self.machine = machine
        self.dmd = dmd
        self.settings = settings
        for line in Line.all {
            sessions[line] = Session(line: line, machine: machine,
                                     dmd: dmd, settings: settings)
        }
        // The console is free — Machine has been draining that socket since
        // launch — so it starts now, before the VAX does, and catches the
        // whole boot transcript whether or not anybody is looking at it.
        let console = sessions[.console]!
        console.makeView()
        console.start()
        opened = [.console]
    }

    subscript(line: Line) -> Session { sessions[line]! }

    /// The sessions a window of this shape shows, in tab order.
    func openLines(of shape: TerminalShape) -> [Line] {
        opened.filter { $0.shape == shape }
    }

    /// Lines of this shape that exist but are not open yet — the "+" menu.
    func availableLines(of shape: TerminalShape) -> [Line] {
        shape.lines.filter { !opened.contains($0) }
    }

    func isOpen(_ line: Line) -> Bool { opened.contains(line) }

    /// Open a line, starting it if the machine is ready. A line opened before
    /// the VAX is up is remembered and dialled by `machineIsUp()`.
    @discardableResult
    func open(_ line: Line) -> Session {
        let session = self[line]
        if !opened.contains(line) {
            opened.append(line)
            opened.sort { a, b in
                (Line.all.firstIndex(of: a) ?? 0) < (Line.all.firstIndex(of: b) ?? 0)
            }
        }
        if machine.phase == .up { session.start() }
        return session
    }

    func close(_ line: Line) {
        guard line != .console else { return }      // the console is never closed
        self[line].stop()
        opened.removeAll { $0 == line }
    }

    /// Dial everything the user has open. Called when the VAX reaches `up`,
    /// because a session cannot connect to a DZ that is not listening yet.
    func machineIsUp() {
        for line in opened { self[line].start() }
    }

    /// The default window's contents on a first run: the console, so a new
    /// user sees the machine boot, and one glass tty to work in.
    func openDefaults() {
        open(.tty(1))
    }
}
