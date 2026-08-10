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
            store.set(allowWrites, forKey: Key.writes)
            if running { restart() }
        }
    }

    /// Fixed rather than rotated per launch, because the mount command the
    /// user types in the guest names it. tmxr's TIME_WAIT problem does not
    /// apply: this is our own listener with SO_REUSEADDR set.
    let port: UInt16 = 9200

    private var server: NetFSServer?
    private let store: UserDefaults

    private enum Key {
        static let bookmark = "share.bookmark"
        static let writes = "share.allowWrites"
        static let enabled = "share.enabled"
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        allowWrites = store.bool(forKey: Key.writes)          // absent == false
        if let data = store.data(forKey: Key.bookmark) {
            folder = Self.resolve(bookmark: data, store: store)
        }
        if store.bool(forKey: Key.enabled), folder != nil { start() }
    }

    // MARK: - The folder

    /// Remember a folder the user chose in the file picker.
    ///
    /// A path is not enough: a sandboxed app loses access to anything outside
    /// its container the moment it relaunches, so what gets persisted is a
    /// security-scoped bookmark and what gets used is the URL resolved from it.
    func adopt(_ url: URL) {
        do {
            #if os(macOS)
            let data = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            #else
            let data = try url.bookmarkData(includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            #endif
            store.set(data, forKey: Key.bookmark)
            folder = Self.resolve(bookmark: data, store: store) ?? url
            lastError = nil
            if running { restart() } else { start() }
        } catch {
            lastError = "Could not remember that folder: \(error.localizedDescription)"
        }
    }

    func forget() {
        stop()
        store.removeObject(forKey: Key.bookmark)
        store.set(false, forKey: Key.enabled)
        folder?.stopAccessingSecurityScopedResource()
        folder = nil
    }

    private static func resolve(bookmark: Data, store: UserDefaults) -> URL? {
        var stale = false
        do {
            #if os(macOS)
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            let url = try URL(resolvingBookmarkData: bookmark, options: [],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            // The access has to be started and then *never* stopped for as long
            // as the share is up: the server reads on its own thread, long after
            // whatever UI event resolved this has finished.
            guard url.startAccessingSecurityScopedResource() else { return nil }
            return url
        } catch {
            return nil
        }
    }

    // MARK: - The server

    func start() {
        guard !running, let folder else { return }
        let cfg = NetFSConfig(root: folder.path, port: port,
                              readOnly: !allowWrites, verbose: false)
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
        store.set(true, forKey: Key.enabled)
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
        store.set(false, forKey: Key.enabled)
    }

    private func restart() { stop(); start() }

    /// What to type in the guest, shown in Settings so it can be copied rather
    /// than remembered. The unique id is netfs's mount identity; 64 is the
    /// bottom of the range netfs(8) documents.
    var mountCommand: String { "nmount 10.0.2.2 \(port) 64 /n/macos" }
}
