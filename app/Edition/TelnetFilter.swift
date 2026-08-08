import Foundation

/// Minimal telnet-protocol filter for SIMH's tmxr sockets: strips IAC
/// sequences from the byte stream (they may split across reads, hence the
/// explicit state machine). With `sendRefusals` it also refuses every
/// option the server proposes — DO → WONT, WILL → DONT — the correct
/// behavior for the V8 console socket. The SIMH *remote console* cannot
/// tolerate client IAC replies at all (they desync its command reader and
/// the session goes permanently silent — desktop-bisected), so the control
/// link constructs this filter with `sendRefusals: false`.
struct TelnetFilter {
    private enum State {
        case data
        case iac
        case option(UInt8)   // pending WILL/WONT/DO/DONT verb
    }

    private var state: State = .data
    private let sendRefusals: Bool

    init(sendRefusals: Bool = true) {
        self.sendRefusals = sendRefusals
    }

    private static let IAC: UInt8 = 255
    private static let DONT: UInt8 = 254
    private static let DO: UInt8 = 253
    private static let WONT: UInt8 = 252
    private static let WILL: UInt8 = 251

    /// Returns the payload bytes, any protocol replies to send back, and
    /// bare IAC commands seen (e.g. 243 = BREAK, which the 5620 serial
    /// link must deliver to the terminal as a break condition).
    mutating func filter(_ input: Data) -> (payload: [UInt8], reply: [UInt8], commands: [UInt8]) {
        var payload: [UInt8] = []
        payload.reserveCapacity(input.count)
        var reply: [UInt8] = []
        var commands: [UInt8] = []
        for b in input {
            switch state {
            case .data:
                if b == Self.IAC { state = .iac } else { payload.append(b) }
            case .iac:
                switch b {
                case Self.IAC:                       // escaped 0xff data byte
                    payload.append(b)
                    state = .data
                case Self.WILL, Self.WONT, Self.DO, Self.DONT:
                    state = .option(b)
                default:                             // NOP/GA/BRK/etc
                    commands.append(b)
                    state = .data
                }
            case .option(let verb):
                if sendRefusals {
                    if verb == Self.DO {
                        reply.append(contentsOf: [Self.IAC, Self.WONT, b])
                    } else if verb == Self.WILL {
                        reply.append(contentsOf: [Self.IAC, Self.DONT, b])
                    }
                }
                state = .data
            }
        }
        return (payload, reply, commands)
    }
}
