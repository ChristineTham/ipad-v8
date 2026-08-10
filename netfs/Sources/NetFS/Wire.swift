//
//  Wire.swift -- the netfs on-the-wire structures.
//
//  The layout is documented in docs/netfs-protocol.md and was *measured* on the
//  running V8 by tools/v8-netfs-probe.exp rather than inferred from the struct
//  declaration; both structures contain hand-written `rsvd` padding plus one
//  hole each that 1985 VAX pcc inserted on its own, and guessing where a
//  compiler puts a hole is exactly the kind of assumption that has already been
//  wrong once in this project.
//
//  The VAX-11/780 is little-endian, which is the one mercy here: an Apple
//  Silicon host and a VAX agree about byte order, so every field is a straight
//  copy and there is no marshalling anywhere in this file beyond bounds
//  checking.
//
import Foundation

// MARK: - Opcodes

/// The sixteen `cmd` values from `usr/sys/h/neta.h`.
///
/// Only nine are ever seen in `cmd`: 10-14 live in the `flags` byte instead,
/// sharing a number space with the commands, and 16 (`NIOCTL`) is defined and
/// dead. `NSTART` arrives once, from the mounting program, before the kernel
/// takes the connection over.
enum Op: UInt8 {
    case stat = 1
    case wrt = 2
    case read = 3
    case free = 4
    case trunc = 5
    case updat = 6
    case get = 7
    case nami = 8
    case put = 9
    case root = 10      // reply flag on NNAMI
    case del = 11       // request flag on NNAMI
    case link = 12      // request flag on NNAMI
    case creat = 13     // request flag on NNAMI
    case nomatch = 14   // reply flag on NNAMI
    case start = 15
    case ioctl = 16

    var name: String {
        switch self {
        case .stat: "NSTAT";   case .wrt: "NWRT";     case .read: "NREAD"
        case .free: "NFREE";   case .trunc: "NTRUNC"; case .updat: "NUPDAT"
        case .get: "NGET";     case .nami: "NNAMI";   case .put: "NPUT"
        case .root: "NROOT";   case .del: "NDEL";     case .link: "NLINK"
        case .creat: "NCREAT"; case .nomatch: "NOMATCH"
        case .start: "NSTART"; case .ioctl: "NIOCTL"
        }
    }
}

/// `NETVERSION` -- the first byte of every connection, on its own.
let netVersion: UInt8 = 1

// MARK: - V8 errno

/// V8's errno numbers, from `usr/include/errno.h`.
///
/// 1...32 are identical to BSD's and therefore to macOS's, so most of this is a
/// no-op -- but `ELOOP` is 35 here and 62 on macOS, and V8 stops at 35 while
/// macOS runs past 100. Anything the host reports that V8 has never heard of
/// has to become something V8 *has*, or the guest prints an error message out
/// of the end of `sys_errlist[]`.
enum V8Errno {
    static let EPERM: UInt8 = 1
    static let ENOENT: UInt8 = 2
    static let EIO: UInt8 = 5
    static let ENXIO: UInt8 = 6
    static let EBADF: UInt8 = 9
    static let ENOMEM: UInt8 = 12
    static let EACCES: UInt8 = 13
    static let EBUSY: UInt8 = 16
    static let EEXIST: UInt8 = 17
    static let EXDEV: UInt8 = 18
    static let ENOTDIR: UInt8 = 20
    static let EISDIR: UInt8 = 21
    static let EINVAL: UInt8 = 22
    static let EMFILE: UInt8 = 24
    static let EFBIG: UInt8 = 27
    static let ENOSPC: UInt8 = 28
    static let EROFS: UInt8 = 30
    static let EMLINK: UInt8 = 31
    static let ELOOP: UInt8 = 35   // 62 on macOS -- the one that actually differs

    /// Translate a host `errno` into something V8 can name.
    ///
    /// The `Darwin.` qualification is not decoration: unqualified `ENOENT`
    /// inside this enum resolves to *our* `ENOENT` above, which is a UInt8, and
    /// the switch would then compare a host errno against the wrong namespace
    /// entirely. Same names, different types, silently wrong answer.
    static func from(host: Int32) -> UInt8 {
        switch host {
        case 0: return 0
        case Darwin.ENOENT: return Self.ENOENT
        case Darwin.EACCES: return Self.EACCES
        case Darwin.EPERM: return Self.EPERM
        case Darwin.EISDIR: return Self.EISDIR
        case Darwin.ENOTDIR: return Self.ENOTDIR
        case Darwin.EEXIST: return Self.EEXIST
        case Darwin.EINVAL: return Self.EINVAL
        case Darwin.ENOSPC: return Self.ENOSPC
        case Darwin.EROFS: return Self.EROFS
        case Darwin.EMFILE, Darwin.ENFILE: return Self.EMFILE
        case Darwin.ELOOP: return Self.ELOOP        // 62 -> 35
        case Darwin.ENOTEMPTY: return Self.EEXIST   // 66: V8 has no ENOTEMPTY
        case Darwin.EXDEV: return Self.EXDEV
        case Darwin.EMLINK: return Self.EMLINK
        case Darwin.EFBIG: return Self.EFBIG
        case Darwin.EBUSY: return Self.EBUSY
        case Darwin.ENOMEM: return Self.ENOMEM
        case Darwin.EBADF: return Self.EBADF
        case Darwin.ENXIO, Darwin.ENODEV: return Self.ENXIO
        default: return Self.EIO                    // anything V8 never heard of
        }
    }
}

/// A V8 errno being carried through a `Result`. UInt8 cannot be the failure
/// type directly -- `Result` wants an `Error`, and retroactively conforming a
/// standard-library integer to it would be a worse trade than this wrapper.
struct V8Fault: Error {
    let code: UInt8
    init(_ code: UInt8) { self.code = code }
}

// MARK: - Little-endian field access

/// Read/write helpers over a flat byte buffer.
///
/// Deliberately explicit rather than `withUnsafeBytes(load:)`: the offsets are
/// the specification, so they should be visible at every use site, and a
/// `load(as:)` on a misaligned offset (14 and 18 are the two holes, so several
/// real fields land on odd multiples) is undefined behaviour on some
/// architectures even where it happens to work on this one.
extension Array where Element == UInt8 {
    func u8(_ off: Int) -> UInt8 { self[off] }
    func u16(_ off: Int) -> UInt16 {
        UInt16(self[off]) | UInt16(self[off + 1]) << 8
    }
    func i32(_ off: Int) -> Int32 {
        Int32(bitPattern:
            UInt32(self[off]) | UInt32(self[off + 1]) << 8
            | UInt32(self[off + 2]) << 16 | UInt32(self[off + 3]) << 24)
    }
    mutating func put(_ off: Int, u8 v: UInt8) { self[off] = v }
    mutating func put(_ off: Int, u16 v: UInt16) {
        self[off] = UInt8(v & 0xff); self[off + 1] = UInt8(v >> 8)
    }
    mutating func put(_ off: Int, i32 v: Int32) {
        let u = UInt32(bitPattern: v)
        self[off] = UInt8(u & 0xff)
        self[off + 1] = UInt8((u >> 8) & 0xff)
        self[off + 2] = UInt8((u >> 16) & 0xff)
        self[off + 3] = UInt8((u >> 24) & 0xff)
    }
}

// MARK: - struct senda, 52 bytes

/// A request. Offsets are from the measured table in docs/netfs-protocol.md.
struct Senda {
    static let size = 52

    var version: UInt8
    var cmd: UInt8
    var flags: UInt8
    var trannum: Int32
    var uid: UInt16
    var gid: UInt16
    var dev: UInt16
    var tag: Int32
    var mode: Int32
    var newuid: UInt16
    var newgid: UInt16
    var ino: Int32
    var count: Int32
    var offset: Int32
    /// A pointer into the *client kernel's* address space that happens to live
    /// inside the struct, so four bytes of a VAX kernel address cross the wire
    /// on every request. `send()` tests it locally to decide whether a payload
    /// follows; here it is noise, and is decoded only so the debug trace can
    /// show it.
    var buf: Int32
    var ta: Int32
    var tm: Int32

    init(_ b: [UInt8]) {
        version = b.u8(0); cmd = b.u8(1); flags = b.u8(2)
        // b[3] is `rsvd`, hand-written padding, always 0
        trannum = b.i32(4)
        uid = b.u16(8); gid = b.u16(10); dev = b.u16(12)
        // b[14..15] is a compiler hole, not a field
        tag = b.i32(16); mode = b.i32(20)
        newuid = b.u16(24); newgid = b.u16(26)
        ino = b.i32(28); count = b.i32(32); offset = b.i32(36)
        buf = b.i32(40); ta = b.i32(44); tm = b.i32(48)
    }

    var op: Op? { Op(rawValue: cmd) }
    var namiFlag: Op? { flags == 0 ? nil : Op(rawValue: flags) }
}

// MARK: - struct rcva, 48 bytes

/// A reply. Zero-initialised and filled in field by field, exactly as the
/// reference server does with its `y = nilrcv` at the top of each request.
struct Rcva {
    static let size = 48

    var trannum: Int32 = 0
    var errno: UInt8 = 0
    var flags: UInt8 = 0
    var dev: UInt16 = 0
    var size: Int32 = 0
    var mode: UInt16 = 0
    var uid: UInt16 = 0
    var gid: UInt16 = 0
    var tag: Int32 = 0
    var nlink: UInt16 = 0
    var ino: Int32 = 0
    var count: Int32 = 0
    var tm: (Int32, Int32, Int32) = (0, 0, 0)

    func encode() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: Self.size)
        b.put(0, i32: trannum)
        b.put(4, u8: errno); b.put(5, u8: flags)
        b.put(6, u16: dev)
        b.put(8, i32: size)
        b.put(12, u16: mode); b.put(14, u16: uid); b.put(16, u16: gid)
        // b[18..19] is a compiler hole, not a field
        b.put(20, i32: tag)
        b.put(24, u16: nlink)
        // b[26..27] is `rsvd`, hand-written padding
        b.put(28, i32: ino)
        b.put(32, i32: count)
        b.put(36, i32: tm.0); b.put(40, i32: tm.1); b.put(44, i32: tm.2)
        return b
    }
}
