import Foundation
import SimhVAX

/// One V8 machine: provisions media into Application Support, runs the SIMH
/// vax780 main loop on its own thread, and speaks to it over two localhost
/// sockets — the V8 console byte pipe (2323) for the terminal view, and the
/// SIMH remote console (2324) as the control channel: ^E suspends the
/// simulator into command mode, `save` snapshots it there, `continue`
/// resumes. Cold relaunch replays the snapshot via `restore` in the startup
/// config. Edition-agnostic by design: everything V8-specific lives in the
/// config templates and the boot-automation pattern.
///
/// Channel semantics proven on the desktop harness (see
/// work/verify-libcli.sh): over a *telnet* console the WRU character is an
/// inert data byte and scp's sim> prompt only ever lives on stdin — hence
/// the separate remote-console control socket.
@MainActor
final class Machine: ObservableObject {

    enum Phase: Equatable {
        case idle
        case provisioning          // first-launch disk copy (~174 MB)
        case starting              // simh thread spawn + socket connects
        case booting               // autoboot: fsck -> multiuser login:
        case restoring             // `restore state.sav` path
        case up                    // console live
        case pausing               // suspend + save in flight
        case paused                // stopped in remote command mode, snapshot on disk
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Whether a suspend+save handshake can run right now (the Mac's quit
    /// path asks before deciding to defer termination).
    var canSuspend: Bool { phase == .up && control.isConnected }

    /// Console bytes for the terminal view (wired up by the view layer).
    var onOutput: (([UInt8]) -> Void)?

    private let console = ConsoleLink()
    private let control = ConsoleLink(replyToIAC: false)   // see ConsoleLink

    // Ports rotate per launch (pid-derived): a quick relaunch's listeners
    // would otherwise hit "bind error 48" against the previous
    // incarnation's TIME_WAIT pairs (tmxr binds without SO_REUSEADDR) and
    // scp then runs with NO listeners — the app collides with its own
    // ghost. Also distinct from the desktop harness's 2323/2324/8888,
    // since Mac and simulator share one localhost.
    private let portBase: UInt16 = {
        let pid = UInt32(bitPattern: getpid())
        return 42000 + UInt16((pid &* 2_654_435_761) % 8_997)
    }()
    private var consolePort: UInt16 { portBase }
    private var controlPort: UInt16 { portBase + 1 }
    /// The DZ11 mux listener — the 5620 terminal dials line 0 here.
    var dzPort: UInt16 { portBase + 2 }
    private var simThread: Thread?
    private var restartedAfterFailedRestore = false

    init() {
        console.onBytes = { [weak self] bytes in self?.onOutput?(bytes) }
    }

    // MARK: - Paths

    private var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("v8", isDirectory: true)
    }

    /// The live working disk — what the user exports.
    var workingDiskURL: URL { supportDir.appendingPathComponent("v8.disk") }
    /// The 5620's 8 KB NVRAM, kept beside the machine it belongs to.
    var nvramURL: URL { supportDir.appendingPathComponent("nvram.bin") }
    /// Terminal throughput log — which stage limits the wire is not guessable
    /// from the outside, so the dmd thread records it.
    var termStatsURL: URL { supportDir.appendingPathComponent("term-stats.log") }

    private var snapshotURL: URL { supportDir.appendingPathComponent("state.sav") }
    private var attemptURL: URL { supportDir.appendingPathComponent("restore.attempt") }
    private var pendingDiskURL: URL { supportDir.appendingPathComponent("v8.disk.pending") }
    private var resetMarkerURL: URL { supportDir.appendingPathComponent("reset.pending") }

    // MARK: - Config templates
    //
    // `Speed=*32` on the DZ attach is the fix for the download being slow.
    // pdp11_dz.c declares tmxr_set_port_speed_control, so every time V8's tty
    // driver programs the line parameter register SIMH faithfully throttles
    // the socket to the guest's baud rate — 9600, measured as ~950 B/s with an
    // empty injector backlog. tmxr keeps a separate bps *factor* that survives
    // those reprogrammings (it is only reset for real serial ports), and its
    // attach parser deliberately allows a bare factor even for devices that
    // control their own speed. So this multiplies whatever V8 asks for by 32
    // without lying to the guest about its line settings.
    // No `set noasynch` needed (and it errors "Command not allowed" here):
    // the library is compiled without SIM_ASYNCH_IO, so synchronous I/O
    // (the V8-safe mode, simh issue #425) is guaranteed at build time.
    // remote timeout=600 keeps the paused state deterministic if iOS
    // delays freezing us.

    private var bootConf: String { """
    set console telnet=127.0.0.1:\(consolePort)
    set remote telnet=127.0.0.1:\(controlPort)
    set remote timeout=600
    set tto 7b
    set dz lines=8
    att dz -m Speed=*32,127.0.0.1:\(dzPort)
    set rp0 rp06
    at rp0 v8.disk
    set tu0 te16
    load -o bootV8 0
    run 2
    """ }

    // Restore-path subtleties, all desktop/simulator-bisected:
    // - The snapshot records the PREVIOUS launch's ports; both the console
    //   and the DZ must be re-attached on this launch's ports, and those
    //   binds must SUCCEED. `save` persists UNIT_TM_POLL in each unit's
    //   dynflags, but `uptr->tmxr` is a runtime pointer only a successful
    //   tmxr_attach can set — so a restore whose re-attach fails brings the
    //   unit back tagged for mux polling with a NULL backpointer and `cont`
    //   segfaults in _tmxr_activate_delay (open-simh/simh#576; restore
    //   reports success either way). Per-launch port rotation is what
    //   guarantees the bind. Do NOT "fix" this with `reset tti` — that
    //   zeroes the CSR the guest kernel configured (interrupt enable
    //   included) and V8 stops noticing console input entirely.
    private var resumeConf: String { """
    set remote telnet=127.0.0.1:\(controlPort)
    set remote timeout=600
    restore state.sav
    set console telnet=127.0.0.1:\(consolePort)
    att dz -m Speed=*32,127.0.0.1:\(dzPort)
    cont
    """ }

    // MARK: - Lifecycle

    func start() {
        guard phase == .idle else { return }
        Task { await bringUp() }
    }

    private func bringUp() async {
        do {
            phase = .provisioning
            let resuming = try await provision()
            phase = .starting
            launchSimhThread(config: resuming ? "resume.conf" : "boot.conf")
            guard await console.connect(port: consolePort) else {
                phase = .failed("console connection failed")
                return
            }
            guard await control.connect(port: controlPort) else {
                phase = .failed("control connection failed")
                return
            }
            if resuming {
                phase = .restoring
                // The machine resumes exactly where it was saved; poke the
                // console and require SOME output within a beat — a failed
                // `restore` leaves scp running garbage silently (observed
                // on the desktop), it does not exit.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                console.send([0x0d])
                guard await console.waitForAnyOutput(timeout: 10) else {
                    consumeSnapshot()
                    phase = .failed("saved session did not restore — relaunch to boot fresh")
                    return
                }
                consumeSnapshot()   // machine is running again: sav now stale
                phase = .up
            } else {
                phase = .booting
                // With a telnet console V8 autoboots — fsck (self-healing
                // after an unclean kill), then straight to multiuser login:
                // with no single-user stop. Verified on the desktop harness.
                guard await console.waitFor("login:", timeout: 480) else {
                    phase = .failed("no login prompt after autoboot")
                    return
                }
                phase = .up
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Copy bundled media into Application Support on first launch and write
    /// the config files. Returns true when a saved snapshot should be resumed.
    private func provision() async throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        var dir = supportDir
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true          // 174 MB of rebuildable state
        try? dir.setResourceValues(noBackup)

        let disk = workingDiskURL

        // Media changes the user asked for are applied HERE, at launch, while
        // nothing is mounted — swapping a disk under a running VAX (or worse,
        // under a snapshot taken against the old one) corrupts filesystems.
        if fm.fileExists(atPath: resetMarkerURL.path) {
            try? fm.removeItem(at: disk)
            try? fm.removeItem(at: resetMarkerURL)
        }
        if fm.fileExists(atPath: pendingDiskURL.path) {
            try? fm.removeItem(at: disk)
            try? fm.moveItem(at: pendingDiskURL, to: disk)
        }
        if !fm.fileExists(atPath: disk.path) {
            guard let bundled = Bundle.main.url(forResource: "v8", withExtension: "disk") else {
                throw MachineError.mediaMissing
            }
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: bundled, to: disk)
            }.value
        }

        let boot = supportDir.appendingPathComponent("bootV8")
        if !fm.fileExists(atPath: boot.path) {
            guard let bundled = Bundle.main.url(forResource: "bootV8", withExtension: nil) else {
                throw MachineError.mediaMissing
            }
            try fm.copyItem(at: bundled, to: boot)
        }

        try bootConf.write(to: supportDir.appendingPathComponent("boot.conf"),
                           atomically: true, encoding: .utf8)
        try resumeConf.write(to: supportDir.appendingPathComponent("resume.conf"),
                             atomically: true, encoding: .utf8)

        // simh resolves attach/save/restore paths against cwd; relative paths
        // keep state.sav valid across app-container relocations.
        FileManager.default.changeCurrentDirectoryPath(supportDir.path)

        // One-shot restore attempts: if a previous launch died mid-restore
        // (marker still present), drop the snapshot and cold-boot rather
        // than crash-looping on it.
        guard fm.fileExists(atPath: snapshotURL.path) else {
            try? fm.removeItem(at: attemptURL)
            return false
        }
        if fm.fileExists(atPath: attemptURL.path) {
            try? fm.removeItem(at: snapshotURL)
            try? fm.removeItem(at: attemptURL)
            return false
        }
        fm.createFile(atPath: attemptURL.path, contents: nil)
        return true
    }

    // MARK: - Media (all changes staged for the next launch)

    struct SnapshotInfo {
        let bytes: Int
        let saved: Date
    }

    /// A saved session waiting to be resumed, if any. Present only while the
    /// machine is paused or between launches.
    var snapshot: SnapshotInfo? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: snapshotURL.path),
              let bytes = attrs[.size] as? Int,
              let saved = attrs[.modificationDate] as? Date else { return nil }
        return SnapshotInfo(bytes: bytes, saved: saved)
    }

    var hasStagedDisk: Bool { FileManager.default.fileExists(atPath: pendingDiskURL.path) }
    var hasStagedReset: Bool { FileManager.default.fileExists(atPath: resetMarkerURL.path) }

    /// Copy a user-chosen image into place for the next launch. The snapshot
    /// goes with it: saved kernel state describes the *old* disk, and
    /// restoring it over a different one would corrupt the filesystem.
    func stageImport(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: pendingDiskURL)
        try fm.copyItem(at: url, to: pendingDiskURL)
        try? fm.removeItem(at: resetMarkerURL)
        discardSnapshot()
    }

    /// Throw the working disk away and re-copy the pristine bundled one.
    func stageReset() {
        try? FileManager.default.removeItem(at: pendingDiskURL)
        FileManager.default.createFile(atPath: resetMarkerURL.path, contents: nil)
        discardSnapshot()
    }

    func cancelStagedChanges() {
        try? FileManager.default.removeItem(at: pendingDiskURL)
        try? FileManager.default.removeItem(at: resetMarkerURL)
    }

    func discardSnapshot() { consumeSnapshot() }

    private func launchSimhThread(config: String) {
        let path = supportDir.appendingPathComponent(config).path
        let t = Thread { [weak self] in
            let rc = simh_vax780_run(path)
            Task { @MainActor [weak self] in self?.simhExited(rc: rc) }
        }
        t.name = "simh-vax780"
        t.qualityOfService = .userInitiated
        t.stackSize = 4 << 20
        simThread = t
        t.start()
    }

    private func simhExited(rc: Int32) {
        console.close()
        control.close()
        if (phase == .restoring || phase == .starting),
           !restartedAfterFailedRestore,
           FileManager.default.fileExists(atPath: snapshotURL.path) {
            // Snapshot didn't restore and scp died: drop it, cold-boot once.
            restartedAfterFailedRestore = true
            consumeSnapshot()
            phase = .idle
            start()
            return
        }
        phase = .failed("simulator exited (rc \(rc))")
    }

    /// Keystrokes from the terminal view. Nothing needs filtering: over a
    /// telnet console SIMH's WRU character is inert, so even ^E is just a
    /// byte for V8; the control channel is a separate socket.
    func sendInput(_ bytes: [UInt8]) {
        switch phase {
        case .up, .booting, .restoring:
            console.send(bytes)
        default:
            break
        }
    }

    // MARK: - Background / foreground (SIMH save & restore)

    /// Called on scenePhase .background inside a UIKit background task:
    /// ^E on the remote console suspends the simulator into command mode,
    /// `save` snapshots the stopped machine, and it stays suspended (zero
    /// CPU) until foreground sends `continue`.
    func background() async {
        guard phase == .up, control.isConnected else { return }
        phase = .pausing
        control.send([0x05])                               // suspend to sim>
        guard await control.waitFor("sim>", timeout: 8) else {
            phase = .up
            return
        }
        // Remote-console protocol (desktop-verified): sim> prints lazily,
        // and in multi-command mode a double tmxr_getc_ln swallows the
        // first byte of typeahead — hence the sacrificial leading space on
        // every command (scp trims it when it survives). The completion
        // marker matches "\nSAVED" because the input echo never has a
        // newline before the word — only real echo OUTPUT does.
        control.send(" save state.sav\r\n")
        control.send(" echo SAVED\r\n")
        let saved = await control.waitFor("\nSAVED", timeout: 30)
        if saved {
            phase = .paused
        } else {
            control.send(" continue\r\n")                  // never leave it stopped
            phase = .up
        }
    }

    func foreground() {
        guard phase == .paused else { return }
        Task { @MainActor in
            self.control.send(" continue\r\n")
            let resumed = await self.control.waitFor("Simulator Running", timeout: 8)
            if !resumed {
                self.control.send(" continue\r\n")         // one retry, then trust it
            }
            self.consumeSnapshot()   // machine is running again: sav now stale
            self.phase = .up
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.console.send([0x0d])                      // nudge a fresh prompt
        }
    }

    /// A snapshot is only consistent with the disk while the machine stays
    /// paused. The moment it runs again the disk mutates underneath the
    /// saved kernel state, so restoring it later could corrupt the
    /// filesystem — delete it and let an unclean kill cold-boot instead
    /// (V8's autoboot fsck self-heals, the authentic behavior).
    private func consumeSnapshot() {
        try? FileManager.default.removeItem(at: snapshotURL)
        try? FileManager.default.removeItem(at: attemptURL)
    }
}

enum MachineError: LocalizedError {
    case mediaMissing

    var errorDescription: String? {
        switch self {
        case .mediaMissing:
            return "V8 media not bundled — build work/myv8 per docs/spike-a0.md, then rebuild the app"
        }
    }
}
