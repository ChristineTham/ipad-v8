import Foundation
import UIKit
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

    /// Console bytes for the terminal view (wired up by the view layer).
    var onOutput: (([UInt8]) -> Void)?

    private let console = ConsoleLink()
    private let control = ConsoleLink()
    private let consolePort: UInt16 = 2323
    private let controlPort: UInt16 = 2324
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

    // MARK: - Config templates
    // `set noasynch` is defensive documentation: the library is compiled
    // without SIM_ASYNCH_IO, so synchronous I/O (the V8-safe mode, simh
    // issue #425) is already guaranteed at build time. remote timeout=600
    // keeps the paused state deterministic if iOS delays freezing us.

    private static let bootConf = """
    set noasynch
    set console telnet=127.0.0.1:2323
    set remote telnet=127.0.0.1:2324
    set remote timeout=600
    set tto 7b
    set dz lines=8
    att dz -m 127.0.0.1:8888
    set rp0 rp06
    at rp0 v8.disk
    set tu0 te16
    load -o bootV8 0
    run 2
    """

    private static let resumeConf = """
    set noasynch
    set console telnet=127.0.0.1:2323
    set remote telnet=127.0.0.1:2324
    set remote timeout=600
    restore state.sav
    cont
    """

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
                    try? FileManager.default.removeItem(
                        at: supportDir.appendingPathComponent("state.sav"))
                    phase = .failed("saved session did not restore — relaunch to boot fresh")
                    return
                }
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

        let disk = supportDir.appendingPathComponent("v8.disk")
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

        try Self.bootConf.write(to: supportDir.appendingPathComponent("boot.conf"),
                                atomically: true, encoding: .utf8)
        try Self.resumeConf.write(to: supportDir.appendingPathComponent("resume.conf"),
                                  atomically: true, encoding: .utf8)

        // simh resolves attach/save/restore paths against cwd; relative paths
        // keep state.sav valid across app-container relocations.
        FileManager.default.changeCurrentDirectoryPath(supportDir.path)

        return fm.fileExists(atPath: supportDir.appendingPathComponent("state.sav").path)
    }

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
        let sav = supportDir.appendingPathComponent("state.sav")
        if (phase == .restoring || phase == .starting),
           !restartedAfterFailedRestore,
           FileManager.default.fileExists(atPath: sav.path) {
            // Snapshot didn't restore and scp died: drop it, cold-boot once.
            restartedAfterFailedRestore = true
            try? FileManager.default.removeItem(at: sav)
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
        // Remote-console protocol (desktop-verified, attempt-3 transcript):
        // sim> prints lazily; a bare \r line ending loses the next byte, so
        // commands end \r\n; the completion marker matches "\nSAVED" because
        // the input echo never has a newline before the word — only real
        // echo OUTPUT does.
        control.send("save state.sav\r\n")
        control.send("echo SAVED\r\n")
        let saved = await control.waitFor("\nSAVED", timeout: 30)
        if saved {
            phase = .paused
        } else {
            control.send("continue\r\n")                   // never leave it stopped
            phase = .up
        }
    }

    func foreground() {
        guard phase == .paused else { return }
        Task { @MainActor in
            self.control.send("continue\r\n")
            let resumed = await self.control.waitFor("Simulator Running", timeout: 8)
            if !resumed {
                self.control.send("continue\r\n")          // one retry, then trust it
            }
            self.phase = .up
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.console.send([0x0d])                      // nudge a fresh prompt
        }
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
