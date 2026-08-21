import Foundation
import SimhVAX
#if os(macOS)
import AppKit
#endif

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

    /// Called once, after a snapshot has been restored and the machine is
    /// running again. Cold boots do not fire it: /etc/rc has already done the
    /// equivalent work for them.
    var onRestored: (() -> Void)?

    /// Quit this process and start a new one.
    ///
    /// The simulator is a thread inside this app, and SIMH cannot be run twice
    /// in one process: its globals are never reinitialised, so a second
    /// `simh_main` walks the first session's event queue and `sim_cancel`
    /// calls abort(). A genuinely fresh machine therefore means a genuinely
    /// fresh process, which is what this does.
    ///
    /// Used once in the life of a disk, after first-boot provisioning: the
    /// account is created by a root shell whose transcript would otherwise be
    /// the first thing a new user ever saw. The guest is halted first, so the
    /// disk is flushed and consistent before anything restarts.
    /// Wait for the kernel's own halt marker on the console.
    ///
    /// `halting (in tight loop)` is printed by boot() AFTER update() has run
    /// and the I/O has drained, so it means the disk is safe — which a timer
    /// never would.
    func waitForHalt(timeout: TimeInterval) async -> Bool {
        await console.waitFor("halting", timeout: timeout)
    }

    func relaunchProcess() {
        #if os(macOS)
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            // Exit only once the replacement has been asked for, so there is
            // never a moment with no ipnx and never two holding the disk: the
            // new process provisions nothing (the marker is on disk now) and
            // cold-boots while this one is already on its way out.
            DispatchQueue.main.async { exit(0) }
        }
        #else
        // iOS cannot relaunch itself, and an app that exits on its own is a
        // rejection. The machine is provisioned and consistent; the transcript
        // is cosmetic, and the next ordinary launch is clean.
        Machine.note("provisioned — restart the app for a clean first screen")
        #endif
    }

    /// Console bytes for the terminal view (wired up by the view layer).
    var onOutput: (([UInt8]) -> Void)?

    /// Whether to give the emulated VAX its Ethernet card. Set from Settings
    /// before start(); read when the configs are written, because `attach il`
    /// is a boot-time decision -- V8 autoconfigures once and has no way to be
    /// told a device appeared or vanished afterwards.
    var networkEnabled = true

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

    /// The listen port for one DZ line. `tty00` is the 5620, `tty07` the wide
    /// glass tty, `tty01`..`tty06` the plain ones.
    ///
    /// **One listener per line, not one mux-wide listener.** Which line a
    /// session lands on decides what terminal V8 thinks it is talking to:
    /// there is no `/etc/ttytype` and no `TIOCGWINSZ` here, so `/.profile`
    /// runs `case \`tty\` in` and picks TERM from the device name. With a
    /// single mux-wide listener `tmxr_poll_conn` hands each new connection to
    /// the next *free* line, so the terminal you got depended on the order you
    /// happened to open tabs — and a tab labelled `tty03` would be lying.
    /// A per-line listen port makes the mapping a property of the port dialled.
    /// `tmxr` supports this directly ("Each line can have a separate listen
    /// port and the mux can have its own as well" — sim_tmxr.c), and
    /// `tmxr_attach_ex` sets the polling unit on whichever attach comes first,
    /// so no mux-wide attach is needed at all.
    func dzPort(_ line: Int) -> UInt16 { portBase + 2 + UInt16(line) }

    /// DZ line 0 → `tty00` → `TERM=dmd`. The 5620's line, and only its.
    var blitPort: UInt16 { dzPort(0) }

    /// The eight attach commands, in line order.
    ///
    /// `-m` rides the first one only: modem control is a device-wide setting
    /// (`dz_mctl`), and it is what makes a dropped connection drop carrier so
    /// V8 hangs up the session and getty starts over.
    private var dzAttachments: String {
        (0...7).map { line in
            // `;nomessage' suppresses tmxr's "Connected to the VAX 11/780
            // simulator DZ device, line N" greeting, which is SIMH talking to
            // the user over a line that is supposed to carry only V8. NOT
            // `;notelnet', which would also switch the line to a raw socket:
            // these lines speak the telnet wire protocol and ConsoleLink's IAC
            // handling depends on it.
            "att dz \(line == 0 ? "-m " : "")Line=\(line),Speed=*32,127.0.0.1:\(dzPort(line));nomessage"
        }.joined(separator: "\n")
    }
    private var simThread: Thread?
    private var restartedAfterFailedRestore = false

    /// Which machine this is. Defaults to the Eighth Edition, which is the
    /// only one wired up today; see MachineSpec for what the Tenth needs.
    let spec: MachineSpec

    init(spec: MachineSpec = .v8) {
        self.spec = spec
        self.supportDir = Self.support(for: spec.id)
        console.onBytes = { [weak self] bytes in self?.onOutput?(bytes) }
    }

    // MARK: - Paths

    /// Where this installation's machine lives: `ipnx/v8`.
    ///
    /// The APP owns the directory and the EDITION is a folder inside it,
    /// because V10 is the point of the project and will be a second machine
    /// beside this one rather than a replacement for it. It was a flat `v8/`
    /// until 2026-08-16, which put the edition where the app belongs and left
    /// the next one nowhere to go.
    ///
    /// Resolved once per process, and anything already at the old path is
    /// MOVED rather than abandoned — the disk in it is somebody's machine,
    /// with their account and their files on it.
    private static func support(for id: String) -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root.appendingPathComponent("ipnx", isDirectory: true)
                      .appendingPathComponent(id, isDirectory: true)
        // The flat legacy path only ever existed for v8, so the move is
        // conditional on that: a `v10' directory at the root was never ours and
        // must not be adopted.
        let legacy = root.appendingPathComponent(id, isDirectory: true)
        if id == "v8", !fm.fileExists(atPath: dir.path),
           fm.fileExists(atPath: legacy.path) {
            try? fm.createDirectory(at: dir.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.moveItem(at: legacy, to: dir)
        }
        return dir
    }

    /// Resolved once, in `init`, rather than computed: it is read from the SIMH
    /// thread as well as the main one.
    private let supportDir: URL

    /// The live working disk — what the user exports.
    var workingDiskURL: URL { supportDir.appendingPathComponent(spec.diskFile) }
    /// The 5620's 8 KB NVRAM, kept beside the machine it belongs to.
    var nvramURL: URL { supportDir.appendingPathComponent("nvram.bin") }
    /// Terminal throughput log — which stage limits the wire is not guessable
    /// from the outside, so the dmd thread records it.
    var termStatsURL: URL { supportDir.appendingPathComponent("term-stats.log") }

    /// The 5620's screen as it was when we last stopped.
    ///
    /// SIMH can resume the VAX exactly, but the terminal always power-cycles —
    /// there is no way to resume a WE32100 mid-instruction — so a restored
    /// session comes back to a machine that has forgotten everything on screen,
    /// and neither getty nor a shell repaints unasked. Painting the last frame
    /// back is what makes the two halves look like one continuous session.
    var screenURL: URL { supportDir.appendingPathComponent("screen.bin") }

    /// Where a glass tty's picture is kept between launches -- the exact
    /// counterpart of screen.bin for the 5620. Per line, because each terminal
    /// has its own screen and its own scrollback.
    func transcriptURL(for line: Line) -> URL? {
        guard line.shape.isGlass else { return nil }
        return supportDir.appendingPathComponent("screen-\(line.device).bin")
    }

    private var snapshotURL: URL { supportDir.appendingPathComponent("state.sav") }
    private var attemptURL: URL { supportDir.appendingPathComponent("restore.attempt") }
    private var pendingDiskURL: URL {
        supportDir.appendingPathComponent(spec.diskFile + ".pending")
    }
    private var resetMarkerURL: URL { supportDir.appendingPathComponent("reset.pending") }

    /// WHICH SYSTEM IMAGE THE WORKING DISK WAS CUT FROM.
    ///
    /// The working copy diverges from the golden the instant the guest writes
    /// to it — a mounted V8 rewrites its superblock on the way up — so it can
    /// never be recognised by hashing its own content. What it needs is a
    /// record of its ORIGIN, and that is what this is: the sha256 of the
    /// golden, written into the bundle beside the image by the `Embed V8
    /// media` build phase and copied here when the image is installed.
    ///
    /// Without it a rebuilt golden reached the bundle and stopped there, since
    /// provision() only copies the image when no working disk exists. The app
    /// would launch, boot, and run last week's system with no sign anything
    /// was stale — every fix present in the repo, absent on the machine.
    private var bundledImageID: String? {
        guard let u = Bundle.main.url(forResource: spec.diskFile, withExtension: "id"),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    private var imageIDURL: URL { supportDir.appendingPathComponent("image.id") }
    private var installedImageID: String? {
        (try? String(contentsOf: imageIDURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Records that this installation's account has been created, so first
    /// boot happens exactly once. Beside v8.disk deliberately: `Reset disk`
    /// removes the disk and this together, and a disk imported from elsewhere
    /// arrives without it and is provisioned for whoever imported it.
    var provisionedURL: URL { supportDir.appendingPathComponent("provisioned") }

    var isProvisioned: Bool {
        FileManager.default.fileExists(atPath: provisionedURL.path)
    }

    func markProvisioned(_ user: String) {
        try? user.write(to: provisionedURL, atomically: true, encoding: .utf8)
    }

    /// What we last told the guest about the screen, so we can tell whether it
    /// still needs telling. `/etc/dmdwide` lives on the DISK and therefore
    /// persists by itself; writing it costs a root login, and a root login on
    /// the user's terminal is exactly the thing that must not happen twice.
    /// So: remember, compare, and touch the guest only when the answer changed.
    private var screenMarkerURL: URL { supportDir.appendingPathComponent("screenmarker") }

    func screenMarkerMatches(wide: Bool) -> Bool {
        (try? String(contentsOf: screenMarkerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == (wide ? "wide" : "orig")
    }

    func recordScreenMarker(wide: Bool) {
        try? (wide ? "wide" : "orig").write(to: screenMarkerURL, atomically: true, encoding: .utf8)
    }

    /// The account first boot created, if it has. The marker file holds the
    /// name precisely so later launches can log in AS that user rather than as
    /// root: root is needed once, to create the account, and after that this is
    /// somebody's machine and they should arrive in their own home directory.
    var provisionedUser: String? {
        guard let name = try? String(contentsOf: provisionedURL, encoding: .utf8) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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

    // `set cpu idle=4.1BSD` is worth far more than it looks. SIMH watches for
    // an FFS that finds nothing, at IPL 0, low in system space — which is
    // exactly V8's scheduler:
    //
    //     sw1:  ffs  $0,$32,_whichqs,r0   # look for non-empty queue
    //           bneq sw1a
    //           mtpr $0,$IPL              # must allow interrupts here
    //           brw  sw1                  # this is an idle loop!
    //
    // V8's kernel is 4.1BSD-derived, so the pattern SIMH already ships for
    // 4.1BSD matches with no kernel change at all. Measured at the `login:`
    // prompt: ~97% of a core before, ~18% after.

    private var bootConf: String {
        ([
            "set console telnet=127.0.0.1:\(consolePort)",
            "set remote telnet=127.0.0.1:\(controlPort)",
            "set remote timeout=600",
        ] + spec.cpu + spec.preDevices + [
            "set tto 7b",
            "set dz lines=8",
            dzAttachments,
        ] + spec.disk + spec.extraDevices + [
            ilAttachment,
        ] + spec.boot).joined(separator: "\n")
    }

    /// The Interlan NI1010, on SLiRP's user-mode NAT.
    ///
    /// The kernel has carried this driver since the N track (`device il0` in
    /// usr/sys/ipnx/conf, and `ilrint` is in the shipped /unix), but for a
    /// while the app attached no card at all — so autoconfig found nothing,
    /// no `il0` line appeared, and a machine whose kernel could do TCP/IP
    /// looked exactly like one that could not.
    ///
    /// `nat:` rather than a real interface is what makes this legal in the
    /// sandbox: SLiRP is a user-mode stack, so there is no BPF, no raw
    /// socket and no entitlement involved, and the guest's 10.0.2.2 is
    /// rewritten to the host's own loopback (`tcp_fconnect`, "It's an
    /// alias") — which is also why the netfs share needs no port forwarding
    /// on either platform.
    /// Enabling the device is configuration and must precede `restore`, the
    /// same as `set dz lines=8`: it changes the device table the snapshot's
    /// registers are restored into.
    private var ilEnable: String { networkEnabled ? "set il enable" : "" }

    /// The host-side connection, which must follow `restore` for the same
    /// reason the DZ attachments do — a snapshot cannot carry a live host
    /// socket, only the ATTACH string, so the attach has to land on
    /// registers that have already been restored.
    private var ilAttach: String { networkEnabled ? "attach il nat:" : "" }

    private var ilAttachment: String { ilEnable + "\n" + ilAttach }

    // Restore-path subtleties, all desktop/simulator-bisected:
    // - **`restore -D`, and attach everything ourselves.** This is the big
    //   one. A plain `restore` re-attaches every unit that was attached at
    //   save time, in device order, to the filename recorded in the
    //   snapshot — and for the DZ that filename is the PREVIOUS launch's
    //   port. tmxr binds without SO_REUSEADDR, so the terminal connection
    //   that was live a moment ago still holds that port in TIME_WAIT and
    //   the bind fails. That alone would be survivable; what is not is
    //   scp.c's loop, which is gated on `r == SCPE_OK` and therefore
    //   **silently skips every remaining attach** once one fails. The DZ
    //   precedes RP0 in device order, so the machine came back with **no
    //   disk**: console alive (the kernel is in memory), every filesystem
    //   read dead, getty stuck, exec'd programs SIGKILLed. It presents as a
    //   terminal that has stopped talking, which is nothing like the truth.
    //   `-D` tells restore to neither detach nor re-attach, and `-Q`
    //   suppresses the resulting "was attached to..." warnings.
    // - So the disk is attached BEFORE the restore, and the DZ AFTER it —
    //   that order matters. `dz_attach` carries the restore-aware fixup that
    //   re-asserts DTR/RTS and `lp->rcve` from the restored CSR/TCR, and it
    //   only runs when CSR_MSE is already set. Attach the DZ before the
    //   restore and the CSR is still zero, the fixup does nothing, and the
    //   line comes back with receive disabled — the original mute-DZ bug.
    // - The console must also be re-established on this launch's port.
    //   Do NOT "fix" a restore problem with `reset tti` — that zeroes the
    //   CSR the guest kernel configured (interrupt enable included) and V8
    //   stops noticing console input entirely.
    // - Idling must be re-established AFTER the restore. `save` records
    //   sim_idle_enab and cpu_idle_type (both are REGs) but not
    //   cpu_idle_mask, and the mask is what the FFS test actually reads —
    //   so a restored machine would come back looking idle-enabled while
    //   matching VMS's pattern instead of 4.1BSD's, and quietly spin.
    // - `set dz lines=8` must be repeated here, BEFORE the restore. The line
    //   count is a device modifier, not a REG, so no snapshot carries it: a
    //   resumed machine otherwise comes back with the compiled default, a
    //   4-mux DZ spanning 2013E040-2013E05F with vectors C0-DC, while the
    //   restored kernel autoconfigured against a 1-mux DZ at C0-C4. It has to
    //   precede `restore` — dz_setnl resets the device, which would wipe the
    //   guest-configured CSR if it ran after.
    private var resumeConf: String {
        ([
            "set remote telnet=127.0.0.1:\(controlPort)",
            "set remote timeout=600",
        ] + spec.preDevices + [
            "set dz lines=8",
        ] + spec.disk + [
            ilEnable,
            "restore -D -Q state.sav",
        ] + spec.resumeCpu + [
            "set console telnet=127.0.0.1:\(consolePort)",
            dzAttachments,
            ilAttach,
            "cont",
        ]).joined(separator: "\n")
    }

    // MARK: - Lifecycle

    /// Bring the machine up. Safe to call from every window that appears —
    /// and it has to be, because any of them may be the first.
    ///
    /// `phase` cannot be the guard on its own, and that mistake crashed the
    /// app the moment there was a second window. `start()` only *schedules*
    /// `bringUp()`; the phase does not leave `.idle` until that task runs, so
    /// two windows appearing in the same runloop turn both saw `.idle` and
    /// both spawned a SIMH thread — two VAX-11/780s inside one process,
    /// binding the same ports and attached to the same `v8.disk`. It died on
    /// the spot, which was the lucky outcome: two simulators writing one RP06
    /// is the filesystem-corruption hazard this project takes care to avoid
    /// everywhere else. The flag is set synchronously, so the second caller
    /// cannot get past it however the scheduler interleaves.
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task { await bringUp() }
    }

    private func bringUp() async {
        do {
            phase = .provisioning
            let resuming = try await provision()
            Machine.note("\(resuming ? "resuming a saved session" : "cold boot") "
                         + "— console \(consolePort), control \(controlPort), "
                         + "dz tty00..tty07 \(dzPort(0))..\(dzPort(7))")
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
                    Machine.note("restore produced no console output — cold boot next launch")
                    phase = .failed("saved session did not restore — relaunch to boot fresh")
                    return
                }
                consumeSnapshot()   // machine is running again: sav now stale
                Machine.note("restored")
                phase = .up
                // A resumed machine has no shares: they were dropped before the
                // snapshot precisely so they could be taken up cleanly now.
                // /etc/rc mounts them on a cold boot and never runs again, so
                // this is the only thing that can -- and putting the user back
                // exactly where they were is the whole point of a resume.
                onRestored?()
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
        noBackup.isExcludedFromBackup = true          // 516 MB of rebuildable state
        try? dir.setResourceValues(noBackup)

        // SIMH's remote console opens `sim_remote_console_<pid>.temporary_log'
        // in the working directory and never removes it, so one accumulates
        // per launch under a name that can never repeat. Left alone they are
        // the only thing in here that grows without bound. Swept at startup
        // rather than at exit, because the launch that made one is often the
        // launch that was killed.
        if let strays = try? fm.contentsOfDirectory(atPath: supportDir.path) {
            for f in strays where f.hasPrefix("sim_remote_console_")
                              && f.hasSuffix(".temporary_log") {
                try? fm.removeItem(at: supportDir.appendingPathComponent(f))
            }
        }

        let disk = workingDiskURL

        // Media changes the user asked for are applied HERE, at launch, while
        // nothing is mounted — swapping a disk under a running VAX (or worse,
        // under a snapshot taken against the old one) corrupts filesystems.
        // A SNAPSHOT BELONGS TO THE DISK IT WAS TAKEN AGAINST, and both paths
        // below replace the disk. state.sav is a running VAX's memory: its
        // in-core superblock, inode and buffer caches, and mount table all
        // describe the OLD filesystem. Restore it over a different disk and the
        // guest writes that stale metadata straight back onto media it has
        // never seen -- silent corruption of a filesystem that was fine, and
        // the machine looks perfectly healthy while it happens. Keep both or
        // discard both; there is no third option.
        let dropSnapshot = { try? fm.removeItem(at: self.snapshotURL) }

        if fm.fileExists(atPath: resetMarkerURL.path) {
            try? fm.removeItem(at: disk)
            try? fm.removeItem(at: resetMarkerURL)
            // The account lives on the disk, so it goes when the disk does.
            // Leaving the marker would give the replacement image no account
            // and no way to notice it needed one.
            try? fm.removeItem(at: provisionedURL)
            // ...and what we think we told it about the screen: a pristine disk
            // has no /etc/dmdwide, so a remembered "wide" would make the first
            // boot skip writing one and mux would download the wrong muxterm.
            try? fm.removeItem(at: screenMarkerURL)
            dropSnapshot()
        }
        if fm.fileExists(atPath: pendingDiskURL.path) {
            try? fm.removeItem(at: disk)
            try? fm.moveItem(at: pendingDiskURL, to: disk)
            // Same reasoning as the reset above: an imported disk is somebody
            // else's machine and carries their /etc/passwd, so this
            // installation has to be provisioned into it afresh.
            try? fm.removeItem(at: provisionedURL)
            // ...and what we think we told it about the screen: a pristine disk
            // has no /etc/dmdwide, so a remembered "wide" would make the first
            // boot skip writing one and mux would download the wrong muxterm.
            try? fm.removeItem(at: screenMarkerURL)
            dropSnapshot()
        }
        // A REBUILT SYSTEM IMAGE SUPERSEDES THE WORKING COPY, WITHOUT ASKING.
        //
        // The two clauses above are things the USER asked for. This one is not:
        // it is the app noticing that the system image it ships is no longer
        // the one installed, which happens on every app update and after every
        // golden rebuild. Left to a user-initiated Reset, a fix could be built,
        // verified, committed and shipped while the running machine quietly
        // kept the old behaviour -- and nothing anywhere would say so.
        //
        // Safe to do silently because the DISK IS THE SYSTEM, not the user's
        // data: the account is re-provisioned on first boot, and what people
        // actually keep lives on the host shares. The outgoing disk is
        // DELETED, not kept aside — a half-superseded machine lying around is
        // 516 MB of something nothing will ever boot again, and the one thing
        // worse than a stale working copy is two of them.
        if let want = bundledImageID, fm.fileExists(atPath: disk.path),
           installedImageID != want {
            try? fm.removeItem(at: disk)
            // The account was on the disk that just went, and so was
            // /etc/dmdwide. Both markers describe a machine that no longer
            // exists, and a kept `provisioned' would leave the replacement
            // with no account and no way to notice it needed one.
            try? fm.removeItem(at: provisionedURL)
            try? fm.removeItem(at: screenMarkerURL)
            dropSnapshot()
        }

        if !fm.fileExists(atPath: disk.path) {
            guard let bundled = Bundle.main.url(forResource: spec.diskFile,
                                                withExtension: nil) else {
                throw MachineError.mediaMissing
            }
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: bundled, to: disk)
            }.value
            // Stamp AFTER the copy succeeds: a stamp written first would claim
            // a disk that a failed copy never produced, and the next launch
            // would agree it was current.
            if let want = bundledImageID {
                try? want.write(to: imageIDURL, atomically: true, encoding: .utf8)
            }
        }

        let boot = supportDir.appendingPathComponent(spec.bootFile)
        if !fm.fileExists(atPath: boot.path) {
            guard let bundled = Bundle.main.url(forResource: spec.bootFile,
                                                withExtension: nil) else {
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

    /// One line on stderr per lifecycle milestone — see Terminal5620.note.
    nonisolated static func note(_ message: String) {
        FileHandle.standardError.write(Data("ipnx vax: \(message)\n".utf8))
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
        Machine.note("simulator exited (rc \(rc)) in phase \(phase)")
        if (phase == .restoring || phase == .starting),
           !restartedAfterFailedRestore,
           FileManager.default.fileExists(atPath: snapshotURL.path) {
            // Snapshot didn't restore and scp died: drop it, cold-boot once.
            restartedAfterFailedRestore = true
            consumeSnapshot()
            phase = .idle
            started = false          // this is the one legitimate restart
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
