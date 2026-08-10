//
//  Export.swift -- one exported host directory, seen through 1985 eyes.
//
//  This is where the impedance mismatch lives. The protocol is a thin thing;
//  the hard part is that the client is a kernel with 16-bit inode numbers,
//  14-byte filenames and no notion of a directory read that isn't just
//  read(2) on a file. Four consequences drive everything below.
//
//  1. INODE NUMBERS ARE SYNTHETIC, AND HAVE TO BE. `usr/sys/h/types.h` has
//     `typedef u_short ino_t`, and `struct direct` is a 2-byte ino plus a
//     14-byte name. APFS hands out 64-bit inode numbers as a matter of course.
//     So the server keeps its own 1...65535 namespace and a host(dev,ino) ->
//     ours map, which also gives us the stability the client's inode cache
//     needs: the same host file must always come back as the same number, or
//     the guest ends up with two inodes for one file.
//
//  2. THE EXPORT ROOT IS ALWAYS INODE 2. Not a choice. `iget()` crosses a
//     mount by setting `ino = ROOTINO` and re-looking-up, so the client's very
//     first request on a fresh mount is NGET(dev, 2) and there is no other way
//     to name the root.
//
//  3. DIRECTORIES ARE SYNTHESISED. There is no readdir opcode -- `ls` opens a
//     directory and read(2)s 16-byte records out of it, which arrives here as
//     an ordinary NREAD. macOS will not let you read(2) a directory at all, so
//     the server builds the V8-format image itself and caches it on the handle,
//     which also keeps the size reported by NGET/NSTAT consistent with what a
//     subsequent NREAD returns even if the host directory changes underneath.
//
//  4. NAMES ARE TRUNCATED TO 14 BYTES, in the listing *and* in lookup. A
//     component arriving in NNAMI is matched against each child's truncated
//     name, so a file the guest can see is a file the guest can open. Two
//     children that truncate alike are a genuine collision; first match wins
//     and it is logged.
//
import Foundation

/// One open object on the server: the netfs `netf` of `usr/src/netfs/fserv.h`.
final class Handle {
    let tag: Int32
    let ino: UInt16
    let path: String
    var st: stat
    /// For directories: the V8-format image, built once when the handle is
    /// created so that `size` and the bytes a later NREAD returns agree.
    var dirImage: [UInt8]?
    /// Lazily opened host descriptor for regular files.
    var fd: Int32 = -1
    /// Whether `fd` was opened for writing -- `how` in the reference server's
    /// `netf`, which reopens the file when the mode it has disagrees with the
    /// mode it now needs.
    var writable = false

    init(tag: Int32, ino: UInt16, path: String, st: stat) {
        self.tag = tag; self.ino = ino; self.path = path; self.st = st
    }

    deinit { if fd >= 0 { close(fd) } }

    var isDir: Bool { st.st_mode & S_IFMT == S_IFDIR }
    var isLink: Bool { st.st_mode & S_IFMT == S_IFLNK }
    var isReg: Bool { st.st_mode & S_IFMT == S_IFREG }

    /// The size the guest should be told, which for a directory is the size of
    /// the image we made up rather than whatever the host filesystem says a
    /// directory weighs.
    var v8Size: Int32 {
        if let d = dirImage { return Int32(d.count) }
        return Int32(clamping: st.st_size)
    }
}

/// V8's `DIRSIZ`, and the reason half of this file exists.
let dirSiz = 14
/// `struct direct` is `ino_t d_ino; char d_name[DIRSIZ];`
let direntSize = 16
/// `ROOTINO` from `usr/sys/h/param.h`.
let rootIno: UInt16 = 2

final class Export {
    let root: String
    let readOnly: Bool
    /// Everything is presented as owned by this uid/gid. The client kernel runs
    /// its own permission checks against whatever we report (`iaccess` on the
    /// values NGET returned), so these have to be filled in coherently even
    /// when the server itself does not care -- otherwise the guest refuses
    /// things the host would happily allow.
    let mapUID: UInt16
    let mapGID: UInt16
    var trace: (String) -> Void

    /// The client's device number for this mount, learned from NSTART and
    /// echoed on every reply. `naget()` matches `mp->m_dev != (dev & ~0xff)`,
    /// so the minor byte is ours to use and we do not.
    var dev: UInt16 = 0

    private var nextIno: UInt16 = 3          // 2 is the root
    private var nextTag: Int32 = 1           // 0 means "error" to the server
    private var inoByHost: [UInt64: UInt16] = [:]
    private var pathByIno: [UInt16: String] = [:]
    private var handles: [Int32: Handle] = [:]
    /// Handles are also indexed by inode, because NGET arrives with (dev, ino)
    /// and must find an existing entry rather than mint a second tag for a file
    /// the client already holds.
    private var handleByIno: [UInt16: Handle] = [:]

    init(root: String, readOnly: Bool, mapUID: UInt16 = 0, mapGID: UInt16 = 0,
         trace: @escaping (String) -> Void = { _ in }) {
        self.root = root
        self.readOnly = readOnly
        self.mapUID = mapUID
        self.mapGID = mapGID
        self.trace = trace
        pathByIno[rootIno] = root
    }

    // MARK: - The synthetic inode namespace

    private static func hostKey(_ st: stat) -> UInt64 {
        UInt64(UInt32(bitPattern: st.st_dev)) << 32 | UInt64(st.st_ino & 0xffff_ffff)
    }

    /// Allocate (or recall) the 16-bit number this host object is known by.
    private func inoFor(path: String, st: stat) -> UInt16? {
        if path == root { return rootIno }
        let key = Self.hostKey(st)
        if let n = inoByHost[key] {
            // Recall, but refresh the path: a hard link or a rename means the
            // same host inode is now reachable under a different name, and the
            // path is what we actually open.
            pathByIno[n] = path
            return n
        }
        if nextIno == UInt16.max { return nil }     // 65534 files is a lot of 1985
        let n = nextIno
        nextIno += 1
        inoByHost[key] = n
        pathByIno[n] = path
        return n
    }

    func path(forIno ino: UInt16) -> String? { pathByIno[ino] }

    // MARK: - Handles

    func handle(tag: Int32) -> Handle? { handles[tag] }

    /// Make, or return, the handle for a host path. Mirrors `newnetf()`.
    func handle(forPath path: String) -> Handle? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        guard let ino = inoFor(path: path, st: st) else { errno = ENOMEM; return nil }
        if let existing = handleByIno[ino] {
            existing.st = st
            if existing.isDir { existing.dirImage = buildDirImage(path: path, ino: ino) }
            return existing
        }
        let h = Handle(tag: nextTag, ino: ino, path: path, st: st)
        nextTag += 1
        if h.isDir { h.dirImage = buildDirImage(path: path, ino: ino) }
        handles[h.tag] = h
        handleByIno[ino] = h
        return h
    }

    func handle(forIno ino: UInt16) -> Handle? {
        if let h = handleByIno[ino] {
            // Refresh: the client may have held this across a host-side change.
            var st = stat()
            if lstat(h.path, &st) == 0 {
                h.st = st
                if h.isDir { h.dirImage = buildDirImage(path: h.path, ino: ino) }
            }
            return h
        }
        guard let p = pathByIno[ino] else { return nil }
        return handle(forPath: p)
    }

    /// `clrnetf()`: drop a handle. The root is never released -- the reference
    /// server says so in as many words ("hold on to the root") and the client
    /// will ask for it again.
    func release(tag: Int32) {
        guard let h = handles[tag] else { return }
        if h.ino == rootIno { return }
        handles.removeValue(forKey: tag)
        handleByIno.removeValue(forKey: h.ino)
    }

    // MARK: - Directory images

    /// Is this a type V8 can make any sense of? Sockets and FIFOs are not, and
    /// letting the guest open one would hand a 1985 kernel a host object it has
    /// no driver for. Devices are excluded too: a remote `/dev/null` would
    /// carry a host major/minor that means something else entirely on a VAX.
    private static func visible(_ mode: mode_t) -> Bool {
        let t = mode & S_IFMT
        return t == S_IFREG || t == S_IFDIR || t == S_IFLNK
    }

    /// Truncate to what a `struct direct` can hold. Not `String.prefix(14)`:
    /// the field is 14 *bytes*, and a name with any multi-byte character in it
    /// has to be cut on a byte boundary the way the guest will see it.
    static func v8Name(_ name: String) -> [UInt8] {
        Array(Array(name.utf8).prefix(dirSiz))
    }

    private func buildDirImage(path: String, ino: UInt16) -> [UInt8] {
        var out = [UInt8]()
        func add(_ name: [UInt8], _ n: UInt16) {
            out.append(UInt8(n & 0xff)); out.append(UInt8(n >> 8))
            var f = name; f.append(contentsOf: [UInt8](repeating: 0, count: dirSiz - name.count))
            out.append(contentsOf: f)
        }
        add(Array(".".utf8), ino)
        // `..` of the export root is the export root: the guest never sees past
        // the mount, and NNAMI answers a real `..` with NROOT so the client
        // substitutes its own mount point.
        let parentIno: UInt16
        if path == root {
            parentIno = rootIno
        } else {
            let parent = (path as NSString).deletingLastPathComponent
            var pst = stat()
            parentIno = lstat(parent, &pst) == 0
                ? (inoFor(path: parent, st: pst) ?? rootIno) : rootIno
        }
        add(Array("..".utf8), parentIno)

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return out
        }
        var seen = Set<[UInt8]>()
        for name in names.sorted() {
            let child = (path as NSString).appendingPathComponent(name)
            var st = stat()
            guard lstat(child, &st) == 0, Self.visible(st.st_mode) else { continue }
            let short = Self.v8Name(name)
            if !seen.insert(short).inserted {
                trace("collision: \(name) truncates onto an existing entry in \(path)")
                continue
            }
            guard let n = inoFor(path: child, st: st) else { continue }
            add(short, n)
        }
        return out
    }

    // MARK: - Lookup

    enum Lookup {
        case found(Handle, isRoot: Bool)
        case noMatch
        case error(UInt8)
    }

    /// One component of a path, which is all netfs ever resolves at a time.
    ///
    /// The name arrives as `count` bytes NUL-padded to DIRSIZ; `fixnbuf()`
    /// takes everything up to the first NUL, and so do we.
    func lookup(parent: Handle, component raw: [UInt8]) -> Lookup {
        guard parent.isDir else { return .error(V8Errno.ENOTDIR) }
        let bytes = Array(raw.prefix(while: { $0 != 0 }))
        let name = String(decoding: bytes, as: UTF8.self)

        if bytes.isEmpty || name == "." {
            return .found(parent, isRoot: false)   // "." never raises NROOT
        }
        if name == ".." {
            if parent.path == root {
                // Walked out of the export. Hand back the root with NROOT set
                // and let the client splice in its own mount point -- without
                // this, `cd ..` from a netfs root would escape the export.
                guard let h = handle(forPath: root) else { return .error(V8Errno.EIO) }
                return .found(h, isRoot: true)
            }
            let up = (parent.path as NSString).deletingLastPathComponent
            guard let h = handle(forPath: up) else { return .error(V8Errno.ENOENT) }
            return .found(h, isRoot: h.path == root)
        }

        // The exact name first -- the overwhelmingly common case, and it avoids
        // listing a big directory for every component of every path.
        let direct = (parent.path as NSString).appendingPathComponent(name)
        var st = stat()
        if bytes.count < dirSiz, lstat(direct, &st) == 0 {
            guard Self.visible(st.st_mode) else { return .noMatch }
            guard let h = handle(forPath: direct) else { return .error(V8Errno.EIO) }
            return .found(h, isRoot: h.path == root)
        }

        // Exactly DIRSIZ bytes means the guest may be holding a truncation of
        // something longer, so fall back to scanning for the first child whose
        // truncated name matches.
        if bytes.count == dirSiz,
           let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
            for candidate in names.sorted() where Self.v8Name(candidate) == bytes {
                let child = (parent.path as NSString).appendingPathComponent(candidate)
                var cst = stat()
                guard lstat(child, &cst) == 0, Self.visible(cst.st_mode) else { continue }
                guard let h = handle(forPath: child) else { return .error(V8Errno.EIO) }
                return .found(h, isRoot: false)
            }
        }
        return .noMatch
    }

    // MARK: - Reading

    /// `doread()`. Directories come out of the cached image, symlinks out of
    /// readlink(2), everything else off the disk.
    func read(_ h: Handle, offset: Int32, count: Int32) -> Result<[UInt8], V8Fault> {
        if let image = h.dirImage {
            let start = max(0, Int(offset))
            guard start < image.count else { return .success([]) }
            let end = min(image.count, start + Int(count))
            return .success(Array(image[start..<end]))
        }
        if h.isLink {
            var buf = [CChar](repeating: 0, count: 1024)
            let n = readlink(h.path, &buf, buf.count)
            guard n >= 0 else { return .failure(V8Fault(V8Errno.from(host: errno))) }
            let bytes = buf[0..<n].map { UInt8(bitPattern: $0) }
            let start = min(Int(offset), bytes.count)
            let end = min(bytes.count, start + Int(count))
            return .success(Array(bytes[start..<end]))
        }
        if h.fd < 0 {
            h.fd = open(h.path, O_RDONLY)
            guard h.fd >= 0 else { return .failure(V8Fault(V8Errno.from(host: errno))) }
        }
        guard lseek(h.fd, off_t(offset), SEEK_SET) >= 0 else {
            return .failure(V8Fault(V8Errno.from(host: errno)))
        }
        var buf = [UInt8](repeating: 0, count: Int(count))
        let n = buf.withUnsafeMutableBytes { Foundation.read(h.fd, $0.baseAddress, Int(count)) }
        guard n >= 0 else { return .failure(V8Fault(V8Errno.from(host: errno))) }
        return .success(Array(buf[0..<n]))
    }

    // MARK: - Writing (used only when readOnly is false)

    /// `dowrite()`. The handle may have been opened read-only by an earlier
    /// NREAD, so the descriptor is reopened on the first write -- `opennf(p, fl)`
    /// in the reference server does exactly this, closing and reopening when
    /// `p->how` disagrees with what is now wanted.
    func write(_ h: Handle, offset: Int32, data: [UInt8]) -> UInt8 {
        guard !h.isDir else { return V8Errno.EISDIR }
        if h.fd < 0 || !h.writable {
            if h.fd >= 0 { close(h.fd) }
            h.fd = open(h.path, O_RDWR)
            guard h.fd >= 0 else { return V8Errno.from(host: errno) }
            h.writable = true
        }
        guard lseek(h.fd, off_t(offset), SEEK_SET) >= 0 else {
            return V8Errno.from(host: errno)
        }
        var sent = 0
        while sent < data.count {
            let w = data[sent...].withUnsafeBytes {
                #if canImport(Darwin)
                Darwin.write(h.fd, $0.baseAddress, data.count - sent)
                #else
                Glibc.write(h.fd, $0.baseAddress, data.count - sent)
                #endif
            }
            if w <= 0 { if errno == EINTR { continue }; return V8Errno.from(host: errno) }
            sent += w
        }
        _ = lstat(h.path, &h.st)
        return 0
    }

    /// `truncnf()`. The original does `creat(p->name, 0)`, which truncates and
    /// leaves the file mode-0; `truncate(2)` is what it meant.
    func truncate(_ h: Handle) -> UInt8 {
        guard !h.isDir else { return V8Errno.EISDIR }
        guard Foundation.truncate(h.path, 0) == 0 else { return V8Errno.from(host: errno) }
        _ = lstat(h.path, &h.st)
        return 0
    }

    /// `doupdat()`. A `ta`/`tm` of 0 means "leave it", which the client
    /// expresses as a timestamp equal to the clock skew once the server has
    /// added `dtime` back on -- hence the comparison against `dtime` rather
    /// than against zero.
    func update(_ h: Handle, mode: Int32, ta: Int32, tm: Int32,
                dtime: Int32, byRoot: Bool) -> UInt8 {
        let atime = ta == dtime ? Int(clamping: h.st.st_atimespec.tv_sec) : Int(ta)
        let mtime = tm == dtime ? Int(clamping: h.st.st_mtimespec.tv_sec) : Int(tm)
        var ts = [timespec](repeating: timespec(), count: 2)
        ts[0].tv_sec = atime
        ts[1].tv_sec = mtime
        _ = utimensat(AT_FDCWD, h.path, &ts, AT_SYMLINK_NOFOLLOW)

        let want = mode_t(UInt16(truncatingIfNeeded: mode))
        if want & 0o7777 != h.st.st_mode & 0o7777 {
            guard byRoot || getuid() == h.st.st_uid else { return V8Errno.EPERM }
            guard chmod(h.path, want & 0o7777) == 0 else { return V8Errno.from(host: errno) }
        }
        // Ownership is deliberately not forwarded. Every file is presented as
        // mapUID/mapGID, so a chown from the guest is a change to a mapping the
        // guest cannot see, and applying it to the host would hand a 1985
        // machine control over host file ownership.
        _ = lstat(h.path, &h.st)
        return 0
    }

    /// The NCREAT arm of `donami()`. `mode` has already been masked by the
    /// client's umask.
    func create(path: String, mode: Int32) -> Result<Handle, V8Fault> {
        let type = mode_t(UInt32(bitPattern: mode)) & S_IFMT
        let perm = mode_t(UInt16(truncatingIfNeeded: mode)) & 0o7777
        switch type {
        case 0, S_IFREG:
            let fd = open(path, O_CREAT | O_RDWR, perm)
            guard fd >= 0 else { return .failure(V8Fault(V8Errno.from(host: errno))) }
            close(fd)
        case S_IFDIR:
            guard mkdir(path, perm) == 0 else { return .failure(V8Fault(V8Errno.from(host: errno))) }
        default:
            // V8 asks for a symlink by creating a file and then fchmod()ing
            // S_IFLNK onto it -- a trick that only works on a filesystem whose
            // mode bits are the inode's. Nothing on macOS will do that.
            return .failure(V8Fault(V8Errno.EPERM))
        }
        guard let h = handle(forPath: path) else { return .failure(V8Fault(V8Errno.EIO)) }
        invalidateParent(of: path)
        return .success(h)
    }

    /// The NDEL arm of `donami()`.
    func unlink(_ h: Handle) -> UInt8 {
        let err: Int32
        if h.isDir {
            err = rmdir(h.path) == 0 ? 0 : errno
        } else {
            err = Foundation.unlink(h.path) == 0 ? 0 : errno
        }
        guard err == 0 else { return V8Errno.from(host: err) }
        invalidateParent(of: h.path)
        return 0
    }

    /// A directory image is a snapshot, so anything that changes a directory's
    /// contents has to rebuild the parent's or the guest keeps reading a
    /// listing that no longer describes what is there.
    private func invalidateParent(of path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        guard let h = handleByIno.values.first(where: { $0.path == parent }) else { return }
        h.dirImage = buildDirImage(path: h.path, ino: h.ino)
    }

    // MARK: - Reply assembly

    /// Fill the attribute fields every operation shares. Kept in one place
    /// because getting `mode` or `size` wrong in one operation and right in
    /// another produces a guest that half-works, which is much harder to debug
    /// than one that fails outright.
    func describe(_ h: Handle, into y: inout Rcva) {
        y.mode = UInt16(truncatingIfNeeded: h.st.st_mode)
        y.nlink = UInt16(clamping: h.st.st_nlink)
        y.uid = mapUID
        y.gid = mapGID
        y.size = h.v8Size
        y.tag = h.tag
        y.ino = Int32(h.ino)
        y.dev = dev
    }
}
