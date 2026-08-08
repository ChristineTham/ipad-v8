import Foundation

/// Minimal telnet-protocol filter for SIMH's tmxr console: strips IAC
/// sequences from the byte stream (they may split across reads, hence the
/// explicit state machine) and refuses every option the server proposes —
/// DO → WONT, WILL → DONT — which leaves the session in the plain
/// character-at-a-time mode the desktop probes proved out.
struct TelnetFilter {
    private enum State {
        case data
        case iac
        case option(UInt8)   // pending WILL/WONT/DO/DONT verb
    }

    private var state: State = .data

    private static let IAC: UInt8 = 255
    private static let DONT: UInt8 = 254
    private static let DO: UInt8 = 253
    private static let WONT: UInt8 = 252
    private static let WILL: UInt8 = 251

    /// Returns the payload bytes and any protocol replies to send back.
    mutating func filter(_ input: Data) -> (payload: [UInt8], reply: [UInt8]) {
        var payload: [UInt8] = []
        payload.reserveCapacity(input.count)
        var reply: [UInt8] = []
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
                default:                             // NOP/GA/etc: swallow
                    state = .data
                }
            case .option(let verb):
                if verb == Self.DO {
                    reply.append(contentsOf: [Self.IAC, Self.WONT, b])
                } else if verb == Self.WILL {
                    reply.append(contentsOf: [Self.IAC, Self.DONT, b])
                }
                state = .data
            }
        }
        return (payload, reply)
    }
}
