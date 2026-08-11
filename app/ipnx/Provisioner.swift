import Foundation

/// First boot: give this installation an account that belongs to the person
/// running it. Runs once, against the working disk, and never again.
///
/// WHY THIS IS NOT IN THE IMAGE. Everything true of *every* installation is
/// built into the golden disk from `v8/etc` — the machine's name, the motd,
/// root's profile, the mount points. The account cannot be: the host user's
/// name is not known when the image is built and cannot be. So the split is
/// build time for the universal, first boot for the personal, and this is the
/// second half (docs/machine-config.md).
///
/// WHY NOT POINT THE HOME AT THE HOST SHARE. It is the obvious idea and it
/// does not survive contact. V8 filenames are 14 bytes and a real macOS home
/// is full of longer ones — the failure is silent truncation and collision,
/// not an error. V8 is case-sensitive and macOS is not, so `Makefile` and
/// `makefile` are one file on one side and two on the other. `login` chdirs
/// to the home directory and falls back to `/` when it cannot, so a login
/// before the share is up would land somewhere else entirely. And `.profile`
/// would be shared between a 1985 shell and a modern one, in both directions.
/// So: a real V8 home at `/usr/<name>`, with the host visible *beside* it at
/// `/n/macos` and `/n/home`.
@MainActor
final class Provisioner {

    /// V8's login name field is 8 characters (`utmp.h`), and its filenames
    /// are 14 bytes, which predates 4.2BSD's long names. A host account
    /// called `christine.tham` has to become something representable, and
    /// deterministically so — the same host user must always map to the same
    /// V8 user or a second run would make a second account.
    ///
    /// Lowercased, non-alphanumerics dropped, leading digits dropped (a name
    /// starting with a digit confuses more 1985 tooling than it is worth),
    /// truncated to 8. Empty or unusable input falls back to `unix`.
    static func v8Name(from host: String) -> String {
        var s = host.lowercased().filter { $0.isLetter || $0.isNumber }
        while let f = s.first, f.isNumber { s.removeFirst() }
        if s.isEmpty { return "unix" }
        return String(s.prefix(8))
    }

    /// The shell lines that create the account, in the order they must run.
    ///
    /// V8 has no `adduser`; `/etc/passwd` is plain text and appending to it
    /// *is* the supported mechanism. uid 1000 is clear of everything the tape
    /// ships (the highest is norman at 1093 — 1000 sits below it and above
    /// every system account), and gid 1 is `other`, the group the tape's own
    /// human accounts use.
    ///
    /// No password. This is a personal machine emulating a personal machine,
    /// on a disk its owner already has in their hands; a password prompt with
    /// no recovery path is a support burden with no security value. Settings
    /// can offer to set one later.
    ///
    /// Every line stays well under CANBSIZ (256, `sys/h/param.h`) — the tty
    /// discards a longer one silently — and each is followed by a marker so
    /// completion is proven by output rather than by a prompt, which the echo
    /// of the command itself would otherwise match.
    static func commands(user: String, gecos: String) -> [String] {
        let home = "/usr/\(user)"
        return [
            // Guard: if the line is already there this is a re-run, and a
            // second passwd entry for one name is worse than doing nothing.
            "grep -s '^\(user):' /etc/passwd || " +
            "echo '\(user)::1000:1:\(gecos):\(home):/bin/sh' >> /etc/passwd",
            "test -d \(home) || mkdir \(home)",
            "cp /etc/skel/.profile \(home)/.profile",
            "/etc/chown \(user) \(home) \(home)/.profile",
            "chmod 755 \(home)",
        ]
    }

    /// The host account's name, as the platform reports it.
    static var hostUserName: String {
        #if os(macOS)
        return NSUserName()
        #else
        // iOS has no account name. The device name is the closest honest
        // answer, and Settings lets the user change it before first boot.
        return UIDeviceNameProvider.current
        #endif
    }

    static var hostFullName: String {
        #if os(macOS)
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
        #else
        return UIDeviceNameProvider.current
        #endif
    }
}

#if !os(macOS)
import UIKit
enum UIDeviceNameProvider {
    static var current: String { UIDevice.current.name }
}
#endif
