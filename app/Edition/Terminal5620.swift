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
    func start(dzPort: UInt16, nvram: URL? = nil, stats: URL? = nil) {
        guard state == .idle else { return }
        state = .running
        stopFlag.clear()
        let t = Thread { [rxq, kbq, mouseq, frames, stopFlag, speed] in
            Terminal5620.threadMain(dzPort: dzPort, nvram: nvram, stats: stats,
                                    rxq: rxq, kbq: kbq,
                                    mouseq: mouseq, frames: frames, stop: stopFlag,
                                    speed: speed)
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
    func restart(dzPort: UInt16, nvram: URL? = nil, stats: URL? = nil) {
        guard state == .running else {
            start(dzPort: dzPort, nvram: nvram, stats: stats)
            return
        }
        stopFlag.set()
        Task { @MainActor in
            // The dmd thread tests the flag every 500 steps; this is orders of
            // magnitude longer than it needs, and dmd_core is a process-wide
            // singleton that must not be re-initialised under the old thread.
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.state = .idle
            self.start(dzPort: dzPort, nvram: nvram, stats: stats)
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

    // MARK: - The dmd thread

    nonisolated private static func threadMain(dzPort: UInt16, nvram: URL?, stats: URL?,
                                               rxq: EventQueue<UInt16>,
                                               kbq: EventQueue<UInt8>, mouseq: EventQueue<MouseEvent>,
                                               frames: FrameStore, stop: AtomicFlag,
                                               speed: SpeedBox) {
        guard dmd_init(1) == DMD_SUCCESS else { return }   // firmware 8;7;3
        loadNVRAM(from: nvram)
        defer { saveNVRAM(to: nvram) }

        let fd = dialLoopback(port: dzPort, deadline: Date().addingTimeInterval(30))
        guard fd >= 0 else { return }
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
                // One nudge so the getty prompts on our fresh carrier.
                if !poked && steps > 20_000_000 {
                    poked = true
                    writeAll(fd, [0x0d])
                }
            }

            // Publish frames at most every ~30 ms of virtual time.
            if iter % 600 == 0, dmd_video_ram_dirty() == 1, let vram = dmd_video_ram() {
                frames.publish(vram)
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
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = [UInt8](repeating: 0, count: 102_400)
    private var generation: UInt64 = 0

    func publish(_ vram: UnsafePointer<UInt8>) {
        lock.lock()
        buf.withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, vram, 102_400) }
        generation &+= 1
        lock.unlock()
    }

    /// Copies the newest frame into `out` when newer than `seen`; returns
    /// the current generation either way.
    func copy(into out: inout [UInt8], ifNewerThan seen: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if generation != seen {
            out.withUnsafeMutableBytes { dst in
                buf.withUnsafeBytes { src in
                    _ = memcpy(dst.baseAddress!, src.baseAddress!, 102_400)
                }
            }
        }
        return generation
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
