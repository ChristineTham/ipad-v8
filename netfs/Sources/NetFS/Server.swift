//
//  Server.swift -- the connection loop and the nine operations.
//
//  The reference server in usr/src/netfs/ reads with `read(fd, cmdbuf, 256)`
//  and then insists the answer was exactly 1, or exactly 52. That works on
//  Datakit, where a write is a message and a read returns one; it is simply
//  false on TCP in both directions, where a header can be split across two
//  segments and where Nagle will happily hand you a 52-byte header and its
//  14-byte payload coalesced into one 66-byte read. Everything below is
//  length-driven for that reason and never trusts a read boundary. It is the
//  single largest difference from the original, and the one that would have
//  been invisible until it failed under load.
//
//  One transaction is outstanding at a time -- the client serialises with a
//  per-connection lock (`cip->i_un.i_key`, "until demux works, use key as a
//  lock") -- so this is a strictly synchronous request/response loop with no
//  pipelining anywhere.
//
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct NetFSConfig: Sendable {
    public var root: String
    public var port: UInt16
    public var readOnly: Bool
    public var mapUID: UInt16
    public var mapGID: UInt16
    public var verbose: Bool

    public init(root: String, port: UInt16 = 9200, readOnly: Bool = true,
                mapUID: UInt16 = 0, mapGID: UInt16 = 0, verbose: Bool = false) {
        self.root = root; self.port = port; self.readOnly = readOnly
        self.mapUID = mapUID; self.mapGID = mapGID; self.verbose = verbose
    }
}

// MARK: - Framing

/// Length-driven I/O over one connected socket.
struct Wire {
    let fd: Int32

    /// Read exactly `n` bytes or fail. Nil means the peer went away.
    func readExactly(_ n: Int) -> [UInt8]? {
        guard n > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf[got...].withUnsafeMutableBytes {
                #if canImport(Darwin)
                Darwin.read(fd, $0.baseAddress, n - got)
                #else
                Glibc.read(fd, $0.baseAddress, n - got)
                #endif
            }
            if r == 0 { return nil }                      // clean EOF
            if r < 0 { if errno == EINTR { continue }; return nil }
            got += r
        }
        return buf
    }

    /// Write all of it, looping over short writes.
    @discardableResult
    func writeAll(_ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let w = bytes[sent...].withUnsafeBytes {
                #if canImport(Darwin)
                Darwin.write(fd, $0.baseAddress, bytes.count - sent)
                #else
                Glibc.write(fd, $0.baseAddress, bytes.count - sent)
                #endif
            }
            if w <= 0 { if errno == EINTR { continue }; return false }
            sent += w
        }
        return true
    }
}

// MARK: - One mounted connection

final class Connection {
    let wire: Wire
    let export: Export
    let cfg: NetFSConfig
    /// `dtime` -- the client's clock minus ours, learned at NSTART and added to
    /// every timestamp the client later asks us to set. Two machines with
    /// different clocks agree about file times without either changing its own.
    var dtime: Int32 = 0
    var requests = 0

    init(fd: Int32, cfg: NetFSConfig) {
        self.wire = Wire(fd: fd)
        self.cfg = cfg
        self.export = Export(root: cfg.root, readOnly: cfg.readOnly,
                             mapUID: cfg.mapUID, mapGID: cfg.mapGID)
        self.export.trace = { [cfg] msg in if cfg.verbose { log(msg) } }
    }

    func trace(_ s: String) { if cfg.verbose { log(s) } }

    /// `BUFSIZE` from usr/sys/h/param.h -- the client's own ceiling, and so the
    /// natural one for us. `doread`/`donami` in the reference server allocate
    /// whatever `x->count` says without a bound; a server on a socket wants a
    /// limit.
    static let maxCount: Int32 = 8192

    func run() {
        defer { close(wire.fd) }
        guard handshake() else { log("handshake failed; dropping connection"); return }
        log("mounted \(cfg.root) as dev \(export.dev)\(cfg.readOnly ? " (read-only)" : "")")
        while let header = wire.readExactly(Senda.size) {
            let x = Senda(header)
            requests += 1
            guard serve(x) else { break }
        }
        log("connection closed after \(requests) requests")
    }

    // MARK: Handshake

    private func handshake() -> Bool {
        // One byte of version, on its own -- and it really is on its own, even
        // though the reference server reads it with a 256-byte buffer.
        guard let v = wire.readExactly(1), v[0] == netVersion else {
            if let v = wire.readExactly(0) { _ = v }
            return false
        }
        guard let header = wire.readExactly(Senda.size) else { return false }
        let x = Senda(header)
        guard x.version == netVersion else {
            var y = Rcva(); y.trannum = -1
            wire.writeAll(y.encode())
            return false
        }
        // Three fields of the opening senda are overloaded and carry setup data
        // rather than what their names say.
        dtime = x.ta - Int32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
        export.dev = x.dev
        trace("NSTART dev=\(x.dev) debug=\(x.uid) dtime=\(dtime)s "
              + "cmd=\(x.op?.name ?? String(x.cmd))")
        var y = Rcva()
        y.trannum = x.trannum
        return wire.writeAll(y.encode())
    }

    // MARK: Dispatch

    /// Returns false to close the connection, matching `leave()`.
    private func serve(_ x: Senda) -> Bool {
        var y = Rcva()
        y.trannum = x.trannum
        y.dev = export.dev

        guard let op = x.op else {
            log("unknown command \(x.cmd); closing")
            return false
        }
        trace("#\(requests) \(op.name) tag=\(x.tag) ino=\(x.ino) "
              + "count=\(x.count) off=\(x.offset) flags=\(x.flags) uid=\(x.uid)")

        switch op {
        case .get:   return doGet(x, &y)
        case .nami:  return doNami(x, &y)
        case .read:  return doRead(x, &y)
        case .stat:  return doStat(x, &y)
        case .put:   return doPut(x, &y)
        case .free:  return respond(&y, 0)
        case .updat: return doUpdat(x, &y)
        case .wrt:   return doWrite(x, &y)
        case .trunc: return doTrunc(x, &y)
        default:
            // NROOT/NDEL/NLINK/NCREAT/NOMATCH are flags, not commands, and
            // NIOCTL is defined and dead. Seeing one in `cmd` means the stream
            // has desynchronised, which is not recoverable.
            log("\(op.name) is not a command; closing")
            return false
        }
    }

    @discardableResult
    private func respond(_ y: inout Rcva, _ err: UInt8) -> Bool {
        y.errno = err
        if err != 0 { trace("    -> errno \(err)") }
        return wire.writeAll(y.encode())
    }

    // MARK: Operations

    /// NGET -- turn (dev, ino) into a handle. This is also the mount: the
    /// client's first request on a fresh mount is always NGET(dev, ROOTINO),
    /// because `iget()` crosses a mount point by rewriting ino to 2.
    private func doGet(_ x: Senda, _ y: inout Rcva) -> Bool {
        guard x.ino > 0, x.ino <= Int32(UInt16.max) else { return respond(&y, V8Errno.ENOENT) }
        guard let h = export.handle(forIno: UInt16(x.ino)) else {
            return respond(&y, V8Errno.ENOENT)
        }
        export.describe(h, into: &y)
        trace("    -> \(h.path) mode=\(String(h.st.st_mode, radix: 8)) size=\(h.v8Size)")
        return respond(&y, 0)
    }

    /// NPUT -- release a handle. The kernel sends NUPDAT first if the inode is
    /// dirty, so by the time this arrives there is nothing left to flush.
    private func doPut(_ x: Senda, _ y: inout Rcva) -> Bool {
        guard x.tag != 0 else { return respond(&y, V8Errno.EIO) }
        export.release(tag: x.tag)
        return respond(&y, 0)
    }

    /// NSTAT -- the only operation that returns tm[3].
    private func doStat(_ x: Senda, _ y: inout Rcva) -> Bool {
        guard let h = export.handle(tag: x.tag) else { return respond(&y, V8Errno.ENOENT) }
        var st = stat()
        if lstat(h.path, &st) == 0 { h.st = st }
        export.describe(h, into: &y)
        y.tm = (Int32(clamping: h.st.st_atimespec.tv_sec),
                Int32(clamping: h.st.st_mtimespec.tv_sec),
                Int32(clamping: h.st.st_ctimespec.tv_sec))
        return respond(&y, 0)
    }

    /// NNAMI -- one component of path resolution, and the whole namespace
    /// protocol. The name arrives as a payload *after* the header, and must be
    /// consumed even on the error paths or the stream desynchronises.
    private func doNami(_ x: Senda, _ y: inout Rcva) -> Bool {
        guard x.count >= 0, x.count <= Self.maxCount,
              let name = wire.readExactly(Int(x.count)) else { return false }
        let text = String(decoding: name.prefix(while: { $0 != 0 }), as: UTF8.self)

        guard let parent = export.handle(tag: x.tag) else {
            return respond(&y, V8Errno.ENOENT)
        }
        // A side effect was asked for. Read-only means read-only, and saying so
        // here is what makes the guest report a sensible error rather than
        // half-completing something.
        if let flag = x.namiFlag, cfg.readOnly,
           flag == .del || flag == .link || flag == .creat {
            trace("    -> \(flag.name) refused (read-only)")
            return respond(&y, V8Errno.EROFS)
        }

        switch export.lookup(parent: parent, component: name) {
        case .error(let e):
            return respond(&y, e)
        case .noMatch:
            y.flags = Op.nomatch.rawValue
            trace("    -> NOMATCH \(text)")
            if let flag = x.namiFlag, flag == .creat || flag == .link {
                return doNamiCreate(x, &y, parent: parent, name: text, flag: flag)
            }
            return respond(&y, 0)
        case .found(let h, let isRoot):
            export.describe(h, into: &y)
            if isRoot { y.flags = Op.root.rawValue }
            if let flag = x.namiFlag, flag == .del {
                return doNamiDelete(x, &y, target: h, isRoot: isRoot)
            }
            trace("    -> \(text) = ino \(h.ino) \(h.path)"
                  + (isRoot ? " [NROOT]" : ""))
            return respond(&y, 0)
        }
    }

    // MARK: Write side (N7)

    private func doWrite(_ x: Senda, _ y: inout Rcva) -> Bool {
        // The payload is on the wire whether we intend to honour it or not.
        guard x.count >= 0, x.count <= Self.maxCount,
              let data = wire.readExactly(Int(x.count)) else { return false }
        guard !cfg.readOnly else { return respond(&y, V8Errno.EROFS) }
        guard let h = export.handle(tag: x.tag) else { return respond(&y, V8Errno.ENOENT) }
        return respond(&y, export.write(h, offset: x.offset, data: data))
    }

    private func doTrunc(_ x: Senda, _ y: inout Rcva) -> Bool {
        guard !cfg.readOnly else { return respond(&y, V8Errno.EROFS) }
        guard let h = export.handle(tag: x.tag) else { return respond(&y, V8Errno.ENOENT) }
        return respond(&y, export.truncate(h))
    }

    /// NUPDAT -- set mode, owner and times.
    ///
    /// In read-only mode this replies success and does nothing, deliberately.
    /// The kernel emits NUPDAT from `iupdat()` on the ordinary close path, and
    /// answering EROFS there would make a plain `cat` of a remote file fail on
    /// close for no reason the user could act on. A refusal that matters --
    /// chmod, chown -- is still refused below.
    private func doUpdat(_ x: Senda, _ y: inout Rcva) -> Bool {
        guard let h = export.handle(tag: x.tag) else { return respond(&y, V8Errno.ENOENT) }
        let wantsMeta = UInt16(truncatingIfNeeded: x.mode) != UInt16(truncatingIfNeeded: h.st.st_mode)
            || (x.uid == 0 && (x.newuid != export.mapUID || x.newgid != export.mapGID))
        if cfg.readOnly {
            if wantsMeta {
                trace("    -> chmod/chown refused (read-only)")
                return respond(&y, V8Errno.EROFS)
            }
            trace("    -> times ignored (read-only)")
            export.describe(h, into: &y)
            return respond(&y, 0)
        }
        let err = export.update(h, mode: x.mode, ta: x.ta + dtime, tm: x.tm + dtime,
                                dtime: dtime, byRoot: x.uid == 0)
        export.describe(h, into: &y)
        return respond(&y, err)
    }

    private func doNamiCreate(_ x: Senda, _ y: inout Rcva, parent: Handle,
                              name: String, flag: Op) -> Bool {
        let target = (parent.path as NSString).appendingPathComponent(name)
        switch flag {
        case .creat:
            switch export.create(path: target, mode: x.mode) {
            case .failure(let e): return respond(&y, e.code)
            case .success(let h):
                export.describe(h, into: &y)
                y.flags = 0
                trace("    -> created \(target) ino \(h.ino)")
                return respond(&y, 0)
            }
        case .link:
            guard x.ino > 0, x.ino <= Int32(UInt16.max),
                  let src = export.handle(forIno: UInt16(x.ino)) else {
                return respond(&y, V8Errno.EXDEV)
            }
            guard link(src.path, target) == 0 else {
                return respond(&y, V8Errno.from(host: errno))
            }
            guard let h = export.handle(forPath: target) else { return respond(&y, V8Errno.EIO) }
            export.describe(h, into: &y)
            y.flags = 0
            return respond(&y, 0)
        default:
            return respond(&y, V8Errno.EINVAL)
        }
    }

    private func doNamiDelete(_ x: Senda, _ y: inout Rcva, target: Handle, isRoot: Bool) -> Bool {
        if isRoot { return respond(&y, V8Errno.EPERM) }
        let err = export.unlink(target)
        if err == 0 { export.release(tag: target.tag) }
        return respond(&y, err)
    }

    /// NREAD -- header first, then the payload. `y.count` is what follows, and
    /// a short answer is how EOF is signalled; there is no separate EOF.
    private func doRead(_ x: Senda, _ y: inout Rcva) -> Bool {
        guard let h = export.handle(tag: x.tag) else { return respond(&y, V8Errno.ENOENT) }
        let want = min(max(x.count, 0), Self.maxCount)
        switch export.read(h, offset: x.offset, count: want) {
        case .failure(let e):
            return respond(&y, e.code)
        case .success(let bytes):
            y.count = Int32(bytes.count)
            trace("    -> \(bytes.count) bytes of \(h.path)")
            guard respond(&y, 0) else { return false }
            return wire.writeAll(bytes)
        }
    }
}

// MARK: - Listener

public final class NetFSServer {
    let cfg: NetFSConfig
    private var listenFD: Int32 = -1
    private var running = false

    public init(_ cfg: NetFSConfig) { self.cfg = cfg }

    public enum StartError: Error, CustomStringConvertible {
        case socket(String)
        public var description: String {
            switch self { case .socket(let s): return s }
        }
    }

    /// Bind 127.0.0.1 and serve. Loopback only, and that is not a limitation:
    /// SLiRP redirects *any* address inside its virtual network to the host's
    /// loopback (`tcp_fconnect()` in slirp/tcp_subr.c -- "It's an alias"), so
    /// the guest dialling 10.0.2.2:PORT lands here with no port forwarding
    /// configured anywhere. It is also what makes this work unchanged inside
    /// the iOS sandbox, where an app may talk to its own loopback and nothing
    /// else.
    public func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw StartError.socket("socket: \(errnoText())") }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = cfg.port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian   // 127.0.0.1
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(listenFD)
            throw StartError.socket("bind 127.0.0.1:\(cfg.port): \(errnoText())")
        }
        guard listen(listenFD, 4) == 0 else {
            close(listenFD)
            throw StartError.socket("listen: \(errnoText())")
        }
        running = true
        log("netfsd listening on 127.0.0.1:\(cfg.port), exporting \(cfg.root)"
            + (cfg.readOnly ? " read-only" : " read/write"))
        log("the guest reaches this as 10.0.2.2:\(cfg.port) through SLiRP")
    }

    public func serveForever() {
        while running {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; break }
            // Nagle would coalesce a reply header with the payload that follows
            // it. The client survives that -- we are the ones reading by length
            // -- but a 40 ms delay on every one of the n round trips a path
            // costs is the difference between usable and not.
            var yes: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            log("connection accepted")
            let conn = Connection(fd: fd, cfg: cfg)
            let t = Thread { conn.run() }
            t.stackSize = 512 * 1024
            t.start()
        }
    }

    public func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }
}

func errnoText() -> String { String(cString: strerror(errno)) }

nonisolated(unsafe) var logSink: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
func log(_ s: String) { logSink(s) }
