//
//  FileShare.swift -- serve a folder the user picked to the emulated VAX.
//
//  Phase N7. The server itself is netfs/Sources/NetFS/, compiled straight into
//  this target rather than vendored or duplicated: it was written for this from
//  the start and depends on nothing a phone lacks. `netfsd` on the desktop and
//  this object run the same code, so anything proven by tools/drive-netfs.sh is
//  proven here too.
//
//  HOW THE GUEST REACHES IT, and why this works on iOS at all. SIMH's SLiRP
//  rewrites any address inside its virtual network to the host's loopback
//  (slirp/tcp_subr.c, tcp_fconnect: "It's an alias"), so the guest dialling
//  10.0.2.2:PORT arrives at 127.0.0.1:PORT inside this process. No port
//  forwarding, no host interface, no entitlement -- an app may always talk to
//  its own loopback, which is the same reason the DZ terminal lines work.
//
//  WHAT IS STILL MISSING, stated plainly: the bundled disk image has no
//  Ethernet-configured kernel and no netfs-over-TCP fix, so nothing in the
//  guest can mount this yet. Both exist and are proven on work/myv8/rp07v8.net
//  (tools/n3-ilkernel.sh, tools/drive-streamfix.sh); folding them into the
//  shipped image is B0.6 image work with an App Store size decision attached,
//  not part of this file. Until then the share is off by default and the
//  Settings screen says so.
//
import Foundation
import SwiftUI

@MainActor
final class FileShare: ObservableObject {

    /// Which mount this share feeds. Two of them exist because
    /// docs/machine-config.md asks for two, and they are genuinely different
    /// things: `/n/macos` is a folder the user picks, and `/n/home` is meant
    /// to be their own home directory. Keeping them separate servers on
    /// separate ports means the guest can have one without the other, and a
    /// failure to grant access to one does not take the other down.
    ///
    /// Neither is the V8 account's home directory — see Provisioner for why
    /// pointing a 1985 home at a macOS one does not survive contact.
    enum Role: String, CaseIterable {
        case macos, home

        /// Fixed rather than rotated per launch, because /etc/rc names them.
        /// tmxr's TIME_WAIT problem does not apply: these are our own
        /// listeners with SO_REUSEADDR set.
        var port: UInt16 { self == .macos ? 9200 : 9201 }
        /// Where the guest mounts it, and the unique-id nmount(8) wants.
        var mountPoint: String { "/n/" + rawValue }
        var mountID: Int { self == .macos ? 64 : 65 }
        /// Separate defaults namespaces so the two never share a bookmark.
        var keyPrefix: String { self == .macos ? "share" : "homeshare" }
    }

    let role: Role

    /// The folder being exported, or nil if none has been chosen.
    @Published private(set) var folder: URL?
    /// Whether the server is listening.
    @Published private(set) var running = false
    @Published private(set) var lastError: String?

    /// Read-only until the user says otherwise. A remote machine writing into
    /// a folder in the user's Documents deserves an explicit yes, and V8's
    /// 14-byte filenames mean anything it creates is a name the host may find
    /// surprising.
    @Published var allowWrites: Bool {
        didSet {
            store.set(allowWrites, forKey: keys.writes)
            if running { restart() }
        }
    }

    var port: UInt16 { role.port }

    private var server: NetFSServer?
    private let store: UserDefaults

    private struct Keys {
        let prefix: String
        var bookmark: String { prefix + ".bookmark" }
        var writes: String { prefix + ".allowWrites" }
        var enabled: String { prefix + ".enabled" }
    }
    private let keys: Keys

    init(role: Role = .macos, store: UserDefaults = .standard) {
        self.role = role
        self.keys = Keys(prefix: role.keyPrefix)
        self.store = store
        allowWrites = store.bool(forKey: keys.writes)          // absent == false
        if let data = store.data(forKey: keys.bookmark) {
            folder = Self.resolve(bookmark: data, store: store)
        }
        if store.bool(forKey: keys.enabled), folder != nil { start() }
    }

    // MARK: - The folder

    /// Remember a folder the user chose in the file picker.
    ///
    /// A path is not enough: a sandboxed app loses access to anything outside
    /// its container the moment it relaunches, so what gets persisted is a
    /// security-scoped bookmark and what gets used is the URL resolved from it.
    func adopt(_ url: URL) {
        // THE URL THE PICKER HANDS BACK IS SECURITY-SCOPED AND NOT YET OPEN.
        // `.fileImporter' returns a URL the app may reach only between
        // startAccessingSecurityScopedResource() and its stop, and that covers
        // merely READING it -- which is what bookmarkData() does. Skip this and
        // the bookmark call throws NSFileReadUnknownError, surfaced as
        //
        //     Could not remember that folder: The file "christie" cannot be opened
        //
        // which names the folder and so reads as a problem with the folder. It
        // is not: every folder fails identically, and the entitlement is
        // already right. Two separate things are needed and each looks like the
        // other's symptom -- com.apple.security.files.bookmarks.app-scope to be
        // ALLOWED to make a bookmark at all, and this to be able to read the
        // URL you are making it from.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            // A PLAIN bookmark on both platforms now. `.withSecurityScope' is a
            // SANDBOX mechanism: it is the sandbox that hands out scoped access
            // and the sandbox that needs it handed back. The Mac app dropped the
            // sandbox so /n/macos and /n/home could be what they claim to be
            // (see ipnx-macOS.entitlements), and asking for a scoped bookmark
            // without one fails -- which would present, once again, as a folder
            // that cannot be remembered.
            let data = try url.bookmarkData(includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            // Resolve rather than keep `url': resolve() starts an access that is
            // deliberately never stopped, because the server reads on its own
            // thread long after this returns. The picker's scope, stopped by the
            // defer above, would be gone by then -- so a fallback to `url' here
            // would hand the share a URL it cannot read, and the failure would
            // land much later and look like a netfs bug.
            guard let resolved = Self.resolve(bookmark: data, store: store) else {
                lastError = "Could not reopen that folder after remembering it."
                return
            }
            store.set(data, forKey: keys.bookmark)
            folder = resolved
            lastError = nil
            if running { restart() } else { start() }
        } catch {
            lastError = "Could not remember that folder: \(error.localizedDescription)"
        }
    }

    func forget() {
        stop()
        store.removeObject(forKey: keys.bookmark)
        store.set(false, forKey: keys.enabled)
        folder?.stopAccessingSecurityScopedResource()
        folder = nil
    }

    private static func resolve(bookmark: Data, store: UserDefaults) -> URL? {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: [],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            // Start access and never stop it while the share is up: the server
            // reads on its own thread long after whatever resolved this has
            // returned. Outside a sandbox this is a no-op returning false, and
            // that must NOT be treated as failure -- the previous `guard' here
            // would have rejected every folder on the unsandboxed Mac build.
            _ = url.startAccessingSecurityScopedResource()
            return url
        } catch {
            return nil
        }
    }

    // MARK: - The server

    func start() {
        guard !running, let folder else { return }
        // OWNED BY THE PERSON WHOSE MACHINE THIS IS, not by root.
        //
        // The server presents every file as owned by mapUID/mapGID and the
        // GUEST kernel runs the permission check -- iaccess() against exactly
        // what NGET reported. Left at the default 0, a home directory arrives
        // as root-owned mode 700, so the account first boot created (uid 1000)
        // is refused by its own kernel and ls(1) says
        //
        //     /n/home unreadable
        //
        // which reads as a host permission problem and is not: the host let go
        // of it long before. root could read the share and the user could not,
        // which is the exact opposite of who it is for.
        //
        // 1000/1 are Provisioner's own numbers -- keep them in step.
        let cfg = NetFSConfig(root: folder.path, port: port,
                              readOnly: !allowWrites,
                              mapUID: Provisioner.guestUID,
                              mapGID: Provisioner.guestGID, verbose: false)
        let s = NetFSServer(cfg)
        do {
            try s.start()
        } catch {
            lastError = "\(error)"
            return
        }
        server = s
        running = true
        lastError = nil
        store.set(true, forKey: keys.enabled)
        // serveForever() blocks on accept(), so it gets a thread of its own.
        // One connection is one mount and the protocol is strictly serialised,
        // so there is no concurrency here worth a queue.
        let t = Thread { s.serveForever() }
        t.name = "netfs-server"
        t.stackSize = 512 * 1024
        t.start()
    }

    func stop() {
        server?.stop()
        server = nil
        running = false
        store.set(false, forKey: keys.enabled)
    }

    private func restart() { stop(); start() }

    /// What to type in the guest, shown in Settings so it can be copied rather
    /// than remembered. The unique id is netfs's mount identity; 64 is the
    /// bottom of the range netfs(8) documents.
    /// What to type in the guest to mount this share by hand. /etc/rc does it
    /// at boot, so this is for when someone has unmounted it or wants a
    /// second look — and it has to follow the role, or the Home section would
    /// tell you to mount it over /n/macos.
    ///
    /// 10.0.2.2 is the host: SLiRP rewrites every address inside its virtual
    /// network to the host's loopback, so this works unchanged in the iOS
    /// sandbox with nothing forwarded.
    var mountCommand: String {
        "/etc/nmount 10.0.2.2 \(port) \(role.mountID) \(role.mountPoint)"
    }
}
