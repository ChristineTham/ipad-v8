import Foundation
import Network

/// One localhost telnet-ish socket into the embedded SIMH: dials with retry,
/// strips IAC via TelnetFilter, delivers payload bytes, and supports
/// await-style pattern matching for automation.
///
/// Used twice per machine: the V8 console byte pipe (2323) and the SIMH
/// remote-console control channel (2324) that suspend/save/continue speak.
@MainActor
final class ConsoleLink {

    var onBytes: (([UInt8]) -> Void)?

    private var conn: NWConnection?
    private var telnet: TelnetFilter

    /// `replyToIAC: false` is REQUIRED for the SIMH remote-console control
    /// channel — client IAC replies permanently silence that session.
    init(replyToIAC: Bool = true) {
        telnet = TelnetFilter(sendRefusals: replyToIAC)
    }
    private var matchBuf = [UInt8]()
    private var pending: (pattern: [UInt8], continuation: CheckedContinuation<Bool, Never>)?
    private var pendingAny: CheckedContinuation<Bool, Never>?
    private var generation = 0

    var isConnected: Bool { conn != nil }

    func connect(port: UInt16, attempts: Int = 60) async -> Bool {
        guard conn == nil else { return true }
        for _ in 0..<attempts {
            if let c = await Self.dial(port: port) {
                conn = c
                receiveLoop(on: c)
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    func close() {
        conn?.cancel()
        conn = nil
    }

    func send(_ bytes: [UInt8]) {
        conn?.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    func send(_ text: String) {
        send(Array(text.utf8))
    }

    /// Wait until `pattern` appears in the (7-bit-stripped) stream.
    func waitFor(_ pattern: String, timeout: TimeInterval) async -> Bool {
        precondition(pending == nil, "one expectation per link at a time")
        let pat = Array(pattern.utf8)
        if Self.find(pat, in: matchBuf) {
            matchBuf.removeAll(keepingCapacity: true)
            return true
        }
        generation += 1
        let gen = generation
        return await withCheckedContinuation { cont in
            pending = (pat, cont)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.generation == gen, let p = self.pending else { return }
                self.pending = nil
                p.continuation.resume(returning: false)
            }
        }
    }

    /// One-shot "did anything at all arrive" wait (restore liveness probe).
    func waitForAnyOutput(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            pendingAny = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let c = self.pendingAny else { return }
                self.pendingAny = nil
                c.resume(returning: false)
            }
        }
    }

    // MARK: - Internals

    private static func dial(port: UInt16) async -> NWConnection? {
        // Reference-boxed so the handler (main queue, serial) can mark
        // one-shot resumption without capturing a mutable local.
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<NWConnection?, Never>) in
            let c = NWConnection(host: NWEndpoint.Host("127.0.0.1"),
                                 port: NWEndpoint.Port(rawValue: port)!,
                                 using: .tcp)
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !once.done { once.done = true; cont.resume(returning: c) }
                case .failed, .cancelled:
                    if !once.done { once.done = true; c.cancel(); cont.resume(returning: nil) }
                case .waiting:
                    // On loopback, .waiting(ECONNREFUSED) never self-resolves
                    // (no reachability change is coming). Fail this attempt
                    // fast; the caller's retry loop dials a fresh connection.
                    // This bit: the app raced its own simh listener by ~½ s
                    // and then hung here forever.
                    if !once.done { once.done = true; c.cancel(); cont.resume(returning: nil) }
                default:
                    break
                }
            }
            c.start(queue: .main)
        }
    }

    private func receiveLoop(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.conn === c else { return }
                if let data, !data.isEmpty {
                    let (payload, reply) = self.telnet.filter(data)
                    if !reply.isEmpty { self.send(reply) }
                    if !payload.isEmpty { self.consume(payload) }
                }
                if complete || error != nil { return }   // owner notices via thread exit
                self.receiveLoop(on: c)
            }
        }
    }

    private func consume(_ bytes: [UInt8]) {
        onBytes?(bytes)
        if let any = pendingAny {
            pendingAny = nil
            any.resume(returning: true)
        }
        // V8's getty sends early prompts with mark parity; match 7-bit clean.
        matchBuf.append(contentsOf: bytes.map { $0 & 0x7f })
        if matchBuf.count > 8192 { matchBuf.removeFirst(matchBuf.count - 8192) }
        if let p = pending, Self.find(p.pattern, in: matchBuf) {
            pending = nil
            matchBuf.removeAll(keepingCapacity: true)
            p.continuation.resume(returning: true)
        }
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        outer: for i in 0...(hay.count - needle.count) {
            for j in 0..<needle.count where hay[i + j] != needle[j] { continue outer }
            return true
        }
        return false
    }
}
