import Foundation
import Darwin
import DmdCore

/// The DMD 5620 terminal: owns the dmd thread that steps the WE32100 at
/// the A0-proven pacing (~10 MHz wall-clock; the DUART is a wall-clock
/// state machine and a flat-out CPU wedges its serial handshakes), speaks
/// RS232 to SIMH's DZ line 0 over a localhost socket, and publishes
/// framebuffer snapshots for the Metal view.
///
/// dmd_core is a global singleton behind a mutex: one Terminal5620 per
/// process, and every dmd_* call happens on the dmd thread only.
@MainActor
final class Terminal5620: ObservableObject {

    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    let frames = FrameStore()
    /// Multiplier on the WE32100's 10 MHz clock, live-adjustable from Settings.
    let speed = SpeedBox()
    /// The CRT this session runs. Settled once at start; the window is
    /// shaped to it rather than the other way round.
    let screen = ScreenBox()
    private let rxq = EventQueue<UInt16>()      // host -> terminal (256 = BREAK)
    private let kbq = EventQueue<UInt8>()       // keystrokes, FIFO-paced on the thread
    private let mouseq = EventQueue<MouseEvent>()
    private let stopFlag = AtomicFlag()
    private var thread: Thread?

    enum MouseEvent {
        case move(Int16, Int16)                 // screen-pixel deltas (dx right+, dy down+)
        case down(UInt8)                        // button 0..2
        case up(UInt8)
    }

    // MARK: - Lifecycle

    /// Start the 5620 against SIMH's DZ listener. Call once, when the
    /// machine is up (the getty raises carrier on connect).
    ///
    /// `nvram` is the 8 KB NVRAM file: the terminal's own settings (baud,
    /// screen preferences) live there, so restoring it is what makes the
    /// terminal feel like the same physical unit across launches.
    func start(dzPort: UInt16, screen geometry: FrameStore.Geometry = .stock,
               nvram: URL? = nil, stats: URL? = nil, screenSnapshot: URL? = nil) {
        guard state == .idle else { return }
        state = .running
        stopFlag.clear()
        // Geometry is settled here, once, before the machine exists — not
        // renegotiated from the window on every layout pass.
        screen.set(geometry)
        let t = Thread { [rxq, kbq, mouseq, frames, stopFlag, speed, screen] in
            Terminal5620.threadMain(dzPort: dzPort, nvram: nvram, stats: stats,
                                    rxq: rxq, kbq: kbq,
                                    mouseq: mouseq, frames: frames, stop: stopFlag,
                                    speed: speed, screen: screen,
                                    screenSnapshot: screenSnapshot)
            Task { @MainActor in
                // Only report unexpected exits; deliberate stops go .idle.
                NotificationCenter.default.post(name: .terminal5620Exited, object: nil)
            }
        }
        t.name = "dmd-5620"
        t.qualityOfService = .userInteractive
        t.stackSize = 4 << 20
        thread = t
        t.start()
    }

    func stop() {
        stopFlag.set()
        state = .idle
    }

    /// Power-cycle the terminal: fresh firmware, and — because the DZ line
    /// carries modem control — a dropped carrier that makes V8 hang up
    /// whatever was on the line. That is the cure for the one mismatch
    /// save/restore can produce: the host's mux session survives in the
    /// snapshot while the terminal comes back without muxterm loaded, so the
    /// two ends are talking different protocols. Hanging up lets getty start
    /// over.
    func restart(dzPort: UInt16, screen geometry: FrameStore.Geometry = .stock,
                 nvram: URL? = nil, stats: URL? = nil) {
        guard state == .running else {
            start(dzPort: dzPort, screen: geometry, nvram: nvram, stats: stats)
            return
        }
        stopFlag.set()
        Task { @MainActor in
            // The dmd thread tests the flag every 500 steps; this is orders of
            // magnitude longer than it needs, and dmd_core is a process-wide
            // singleton that must not be re-initialised under the old thread.
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.state = .idle
            self.start(dzPort: dzPort, screen: geometry, nvram: nvram, stats: stats)
        }
    }

    // MARK: - Input (called from the UI)

    func type(_ text: String) {
        for b in text.utf8 {
            kbq.push(b == 0x0a ? 0x0d : b)      // newline -> CR
        }
    }

    func key(_ byte: UInt8) { kbq.push(byte) }

    func mouse(_ event: MouseEvent) { mouseq.push(event) }

    /// Host-side BREAK toward the terminal (rarely needed by hand).
    func sendBreak() { rxq.push(256) }

    /// Write the screen out so the next launch can put it back.
    ///
    /// Deliberately taken from the FrameStore on the main actor rather than
    /// from the dmd thread: at quit the thread may be killed before any
    /// `defer` of its own runs, and the store already holds the latest frame
    /// under a lock. Nothing has to be coordinated.
    func saveScreen(to url: URL?) {
        guard let url else { return }
        let data = frames.snapshot()
        guard !data.isEmpty else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - The dmd thread

    nonisolated private static func threadMain(dzPort: UInt16, nvram: URL?, stats: URL?,
                                               rxq: EventQueue<UInt16>,
                                               kbq: EventQueue<UInt8>, mouseq: EventQueue<MouseEvent>,
                                               frames: FrameStore, stop: AtomicFlag,
                                               speed: SpeedBox, screen: ScreenBox,
                                               screenSnapshot: URL?) {
        // Power on at the authentic 800x1024, and stay there until the
        // self-test has finished.
        //
        // The self-test cannot run anywhere else. It draws each stage's name
        // through the `display` Bitmap with F_XOR, but it clears and scribbles
        // on screen memory at a *hardcoded* 0x700000 -- seven times in
        // selftest.c, including the RAM tests. Move the framebuffer and the
        // text still lands on the visible screen while every clear misses it,
        // so the stage names accumulate on top of one another and the power-on
        // screen is unreadable mush. Resizing mid-self-test is the same bug
        // arriving early.
        //
        // So: authentic power-on, then resize once it has gone quiet.
        // (docs/screen-size.md)
        var appliedScreen = FrameStore.Geometry.stock
        _ = dmd_set_screen(800, 1024)
        guard dmd_init(1) == DMD_SUCCESS else { return }   // firmware 8;7;3
        var selfTestDone = false
        var idleSamples = 0
        loadNVRAM(from: nvram)
        defer { saveNVRAM(to: nvram) }

        let fd = dialLoopback(port: dzPort, deadline: Date().addingTimeInterval(30))
        guard fd >= 0 else {
            note("DZ dial to port \(dzPort) FAILED — terminal has no line")
            return
        }
        note("DZ line up on port \(dzPort)")
        defer { close(fd) }

        var telnet = TelnetFilter()             // refusals fine on a DZ line
        var txbuf: [UInt8] = []
        var rdbuf = [UInt8](repeating: 0, count: 4096)

        var iter: UInt64 = 0
        var steps: UInt64 = 0
        var kbGap: UInt64 = 0
        var ctrX: UInt16 = 0
        var ctrY: UInt16 = 0
        var poked = false
        var t0 = DispatchTime.now()
        var hz = 10_000_000.0 * speed.value

        // Throughput instrumentation: which stage is actually the bottleneck is
        // not guessable from the outside, so measure it.
        var rxBytes: UInt64 = 0
        let tStart = DispatchTime.now()          // never rebased, unlike t0
        var lastStats = DispatchTime.now()
        var lastRxBytes: UInt64 = 0
        var lastSteps: UInt64 = 0

        while !stop.isSet {
            dmd_step_loop(500)
            steps &+= 500
            iter &+= 1

            // Wall-clock pacing to the chosen clock, 2 ms slack (the A0 bridge
            // model). This governs how fast the terminal *draws*; the serial
            // wire is paced separately inside dmd_core's DUART.
            if iter % 100 == 0 {
                let wanted = 10_000_000.0 * speed.value
                if wanted != hz {
                    hz = wanted                     // rebase, or the clock jumps
                    steps = 0
                    t0 = DispatchTime.now()
                }
                let virt = Double(steps) / hz
                let real = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
                if virt > real + 0.002 {
                    usleep(useconds_t((virt - real) * 1e6))
                }
            }

            // Host -> terminal, unthrottled. dmd_core's rx_deque is an
            // unbounded VecDeque drained by the DUART at its own wall-clock
            // char rate (push_front/pop_back, so order is preserved), which
            // means handing it everything cannot overrun the terminal — and
            // the A0 bridge's "one byte per 1000 steps" was an arbitrary cap
            // that silently limited the wire to ~10 KB/s at 10 MHz, below what
            // the turbo DUART can now carry.
            while let v = rxq.pop() {
                if v == 256 {
                    dmd_rs232_break()
                } else {
                    dmd_rs232_rx(UInt8(truncatingIfNeeded: v))
                    rxBytes &+= 1
                }
            }

            // Terminal -> host (escape IAC for telnet).
            var b: UInt8 = 0
            while dmd_rs232_tx(&b) == DMD_SUCCESS {
                txbuf.append(b)
                if b == 255 { txbuf.append(255) }
            }
            while dmd_keyboard_tx(&b) == DMD_SUCCESS {}    // drain bell clicks
            var brk: UInt8 = 0
            _ = dmd_rs232_tx_break(&brk)
            if brk == 1 { txbuf.append(contentsOf: [255, 243]) }   // IAC BREAK

            // Keyboard: the firmware FIFO is 3 deep and wall-clock paced.
            if kbGap > 0 {
                kbGap -= 1
            } else if let k = kbq.pop() {
                dmd_keyboard_rx(k)
                kbGap = 2000                               // ~100 ms/key at 10 MHz
            }

            // Mouse: free-running counters; muxterm integrates deltas with
            // y counting UP the screen — so screen-down subtracts.
            while let ev = mouseq.pop() {
                switch ev {
                case .move(let dx, let dy):
                    ctrX = ctrX &+ UInt16(bitPattern: dx)
                    ctrY = ctrY &- UInt16(bitPattern: dy)
                    dmd_mouse_move(ctrX, ctrY)
                case .down(let btn):
                    dmd_mouse_down(btn)
                case .up(let btn):
                    dmd_mouse_up(btn)
                }
            }

            // Socket I/O.
            if iter % 64 == 0 {
                let n = read(fd, &rdbuf, rdbuf.count)
                if n == 0 { break }                        // SIMH closed the line
                if n > 0 {
                    let (payload, reply, commands) = telnet.filter(Data(rdbuf[0..<n]))
                    for c in commands where c == 243 { rxq.push(256) }
                    for p in payload { rxq.push(UInt16(p)) }
                    if !reply.isEmpty { writeAll(fd, reply) }
                }
                if !txbuf.isEmpty {
                    writeAll(fd, txbuf)
                    txbuf.removeAll(keepingCapacity: true)
                }
            }

            // Start-of-session work, on the same tick as the clock. Doing the
            // resize here is what makes it safe: dmd_resize_screen moves both
            // the framebuffer pointer and its length, and this is the one
            // thread that ever holds either.
            if iter % 100 == 0, !poked {
                // Is the power-on self-test over?
                //
                // "The screen stopped changing" is not a sound answer, and
                // getting this wrong is expensive: selftest.c draws
                // "WAITING FOR KEYBOARD STATUS" and then blocks in t_kbd(),
                // so the screen sits still in the *middle* of the self-test.
                // Resizing there moves the framebuffer out from under the
                // rest of a test that clears screen memory at a hardcoded
                // 0x700000, and the terminal never finishes booting.
                //
                // The sound signal is the firmware's own idle loop. A settled
                // 5620 lives in 0x5354-0x5389 (CLAUDE.md); a firmware still
                // polling the keyboard does not. Measured on this ROM with
                // libdmd/test/resize-scope.c: last self-test draw at 0.65 s,
                // idle loop first reached at 1.15 s, and the longest quiet
                // gap *during* the test is 0.35 s -- so the PC test separates
                // the two cleanly where a timer cannot.
                if !selfTestDone {
                    var pc: UInt32 = 0
                    if dmd_get_pc(&pc) == DMD_SUCCESS, (0x5354...0x5389).contains(pc) {
                        idleSamples += 1
                        if idleSamples >= 3 {
                            selfTestDone = true
                            note("self-test done")
                        }
                    } else {
                        idleSamples = 0
                    }
                }

                // Everything below happens exactly once, the moment the
                // terminal is genuinely ready — and *only* then. All three of
                // these used to be arranged differently, and each arrangement
                // was a bug:
                //
                //   - the resize was conditional on the screen differing from
                //     stock, so the whole block (screen restore and prompt
                //     nudge included) was skipped entirely at the Original
                //     preset;
                //   - the prompt nudge was in the resize's `else` branch, so a
                //     session that *did* restore its screen never asked the
                //     host to speak;
                //   - and a second nudge fired on a raw step count, ~1.0 s in,
                //     which on a 2x clock is before the self-test finishes at
                //     ~1.2 s. The host answered it into a terminal that was
                //     still testing itself, and the reply went nowhere.
                //
                // Cold boots hid all three, because getty prints `login:`
                // unasked when it starts. A restored session has no such
                // luck: the shell said everything it was ever going to say
                // before the snapshot was taken.
                if selfTestDone {
                    poked = true
                    let wanted = screen.value
                    if wanted != appliedScreen,
                       dmd_resize_screen(UInt32(wanted.width),
                                         UInt32(wanted.height)) == DMD_SUCCESS {
                        appliedScreen = wanted
                        // A wider screen is not a wider terminal on its own:
                        // the ROM's text grid is compiled in at 88 columns.
                        // Widen it too, up to the 127 a one-byte operand holds.
                        _ = dmd_set_columns(UInt32(wanted.romColumns))
                    }
                    note("screen \(appliedScreen.width)x\(appliedScreen.height), "
                         + "\(appliedScreen.romColumns) columns")

                    // Put the last session's screen back, if we have one at
                    // this exact size. The 5620 always power-cycles, so a
                    // resumed VAX otherwise faces a terminal that has
                    // forgotten everything, and nothing on the host repaints
                    // unasked.
                    if let restored = loadScreen(from: screenSnapshot,
                                                 geometry: appliedScreen) {
                        restored.withUnsafeBytes { raw in
                            _ = dmd_set_video_ram(raw.bindMemory(to: UInt8.self).baseAddress,
                                                  restored.count)
                        }
                        note("last session's screen repainted (\(restored.count) B)")
                    } else {
                        note("no screen to restore at this size")
                    }
                    // Publish whatever we ended up with — resized, restored or
                    // neither. The ROM only repaints what something writes to,
                    // so without this the view keeps showing the last frame at
                    // the last size until the guest happens to draw.
                    if let vram = dmd_video_ram() {
                        frames.publish(vram, geometry: appliedScreen)
                    }

                    // And ask the far end to say something. getty prints its
                    // banner once and then blocks in getname(); a shell prints
                    // nothing unasked at all. On a fresh carrier this is the
                    // only thing that makes either of them speak.
                    writeAll(fd, [0x0d])
                }
            }

            // Publish frames at most every ~30 ms of virtual time.
            if iter % 600 == 0, dmd_video_ram_dirty() == 1, let vram = dmd_video_ram() {
                frames.publish(vram, geometry: appliedScreen)
            }

            // NVRAM every ~30 s of virtual time: the app can be killed
            // without warning, and the deferred save above would not run.
            if iter % 600_000 == 0 { saveNVRAM(to: nvram) }

            // Stats every ~2 s of wall clock.
            if iter % 2000 == 0, let stats {
                let now = DispatchTime.now()
                let dt = Double(now.uptimeNanoseconds - lastStats.uptimeNanoseconds) / 1e9
                if dt >= 2.0 {
                    let mhz = Double(steps - lastSteps) / dt / 1e6
                    let rxRate = Double(rxBytes - lastRxBytes) / dt
                    let elapsed = Double(now.uptimeNanoseconds - tStart.uptimeNanoseconds) / 1e9
                    let line = String(
                        format: "t=%7.1fs  %5.1f MHz (target %.0f)  rx %6.0f B/s  total %7llu B  backlog %d\n",
                        elapsed, mhz, hz / 1e6, rxRate, rxBytes, rxq.count)
                    appendStats(line, to: stats)
                    lastStats = now
                    lastRxBytes = rxBytes
                    lastSteps = steps
                }
            }
        }
    }

    /// One line on stderr per milestone. Cheap, permanent, and the difference
    /// between "the terminal is mute" and knowing which of the four things
    /// between a keystroke and V8 did not happen.
    nonisolated private static func note(_ message: String) {
        FileHandle.standardError.write(Data("ipnx 5620: \(message)\n".utf8))
    }

    // MARK: - NVRAM (8 KB of terminal settings)

    nonisolated private static func appendStats(_ line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// A saved screen, but only if it is exactly this geometry.
    ///
    /// The file is raw 1-bit rows with no header, so its length *is* its
    /// geometry check: at a different width the same bytes would unpack at
    /// the wrong stride and every row would skew. A mismatch discards it —
    /// a blank screen is better than a scrambled one.
    nonisolated private static func loadScreen(from url: URL?,
                                               geometry: FrameStore.Geometry) -> Data? {
        guard let url, let data = try? Data(contentsOf: url),
              data.count == geometry.byteCount else { return nil }
        return data
    }

    nonisolated private static func loadNVRAM(from url: URL?) {
        guard let url, let data = try? Data(contentsOf: url), data.count == 8192 else { return }
        var bytes = [UInt8](data)
        _ = dmd_set_nvram(&bytes)
    }

    nonisolated private static func saveNVRAM(to url: URL?) {
        guard let url else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        guard dmd_get_nvram(&bytes) == DMD_SUCCESS else { return }
        try? Data(bytes).write(to: url, options: .atomic)
    }

    // MARK: - Socket helpers (BSD; the thread owns the fd, blocking-free)

    nonisolated private static func dialLoopback(port: UInt16, deadline: Date) -> Int32 {
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { return -1 }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc == 0 {
                var flag: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                return fd
            }
            close(fd)
            usleep(300_000)
        }
        return -1
    }

    nonisolated private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: off), bytes.count - off)
            }
            if n > 0 { off += n } else if errno == EAGAIN { usleep(1000) } else { return }
        }
    }
}

extension Notification.Name {
    static let terminal5620Exited = Notification.Name("terminal5620Exited")
}

// MARK: - Thread-safe plumbing

/// Latest-framebuffer store: the dmd thread publishes, the renderer pulls.
///
/// The screen can be resized while the terminal runs, so geometry travels
/// *with* the pixels rather than being agreed separately. A renderer that
/// read a frame and then asked how big it was could be told about a resize
/// that happened in between, and would unpack the old bytes at the new
/// stride — every row skewed. Handing both back from one locked read makes
/// that unrepresentable.
final class FrameStore: @unchecked Sendable {
    /// A framebuffer's dimensions, in 5620 pixels.
    struct Geometry: Equatable, Sendable {
        var width: Int
        var height: Int
        /// The 5620 is 1 bit per pixel, packed MSB-first, no row padding.
        var byteCount: Int { (width / 8) * height }
        static let stock = Geometry(width: 800, height: 1024)

        /// How many columns the ROM's own terminal can be made to lay out on
        /// a screen this wide.
        ///
        /// Its font cell is 9 px with a 3 px margin either side, so the screen
        /// holds `(width - 6) / 9`. The ceiling is not the screen, though: the
        /// grid is a sign-extended one-byte instruction operand, so 127 is as
        /// far as it goes and a wider screen simply leaves a margin. mux
        /// layers are unaffected — they size themselves from their own
        /// rectangle. See docs/screen-size.md.
        var romColumns: Int { min(127, max(40, (width - 6) / 9)) }

        /// The widest screen the ROM terminal can actually *fill*.
        ///
        /// 127 columns is the ceiling, and a column is 9 px with a 3 px margin
        /// either side, so the terminal wants 127·9 + 6 = 1149 px — and 1152
        /// is the next multiple of 32, which is the stride requirement. Wider
        /// than that and the text simply stops, leaving a right margin: the
        /// screen grows but the terminal does not.
        ///
        /// This is the wider of the app's two screens.
        static let wide = Geometry(width: 1152, height: 1024)
    }

    private let lock = NSLock()
    private var geometry = Geometry.stock
    private var buf = [UInt8](repeating: 0, count: Geometry.stock.byteCount)
    private var generation: UInt64 = 0

    /// What the last published frame measured. Only for sizing a renderer's
    /// buffers up front — never unpack pixels against this, use `copy`.
    var currentGeometry: Geometry {
        lock.lock()
        defer { lock.unlock() }
        return geometry
    }

    /// The latest frame as bytes, for writing to disk.
    ///
    /// Taken under the same lock as the geometry, so what is written can never
    /// be one session's pixels labelled with another's size — and the file
    /// needs no header, because its length is the check.
    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return Data(buf)
    }

    func publish(_ vram: UnsafePointer<UInt8>, geometry g: Geometry) {
        lock.lock()
        if g != geometry {
            geometry = g
            buf = [UInt8](repeating: 0, count: g.byteCount)
        }
        buf.withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, vram, g.byteCount) }
        generation &+= 1
        lock.unlock()
    }

    /// Copies the newest frame into `out` when newer than `seen`, growing
    /// `out` if the screen has been resized; returns the generation and the
    /// geometry those bytes are in.
    func copy(into out: inout [UInt8],
              ifNewerThan seen: UInt64) -> (generation: UInt64, geometry: Geometry) {
        lock.lock()
        defer { lock.unlock() }
        if generation != seen {
            if out.count != geometry.byteCount {
                out = [UInt8](repeating: 0, count: geometry.byteCount)
            }
            out.withUnsafeMutableBytes { dst in
                buf.withUnsafeBytes { src in
                    _ = memcpy(dst.baseAddress!, src.baseAddress!, geometry.byteCount)
                }
            }
        }
        return (generation, geometry)
    }
}

/// The screen geometry the UI wants, read by the dmd thread.
///
/// Resizing has to happen on the dmd thread even though `dmd_resize_screen`
/// takes dmd_core's own lock: the thread holds a raw `dmd_video_ram()`
/// pointer across its publish, and a resize from under it would move both
/// the pointer and the length. So the UI states an intent here and the
/// thread acts on it between steps — the same shape as SpeedBox.
///
/// It is a latch, not a queue, so a burst of live-resize events collapses to
/// the last one, and a terminal restart re-applies the current size without
/// the UI having to notice.
final class ScreenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var wanted = FrameStore.Geometry.stock

    var value: FrameStore.Geometry {
        lock.lock()
        defer { lock.unlock() }
        return wanted
    }

    func set(_ g: FrameStore.Geometry) {
        lock.lock()
        wanted = g
        lock.unlock()
    }
}

final class EventQueue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func push(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    func pop() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }
}

/// Live-adjustable CPU clock multiplier, read by the dmd thread every ~100
/// batches and written from the UI.
final class SpeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Double = 1

    var value: Double {
        lock.lock(); defer { lock.unlock() }
        return v
    }

    func set(_ newValue: Double) {
        lock.lock(); v = newValue; lock.unlock()
    }
}

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() { lock.lock(); value = true; lock.unlock() }
    func clear() { lock.lock(); value = false; lock.unlock() }
}
