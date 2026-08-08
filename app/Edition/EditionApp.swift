import SwiftUI
import UIKit

/// "Edition" (working title — must never contain "UNIX", see docs/licensing.md).
/// A1 scope: boot the bundled V8 disk to login: in a console view, and keep
/// the machine alive across background/foreground via SIMH save/restore.
@main
struct EditionApp: App {
    @StateObject private var machine = Machine()
    @StateObject private var terminal = Terminal5620()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MachineView(machine: machine, terminal: terminal)
                .onAppear { machine.start() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Snapshot inside a UIKit background task; iOS grants a few
                // seconds, the save handshake needs well under one.
                let token = UIApplication.shared.beginBackgroundTask(withName: "simh-save")
                Task {
                    await machine.background()
                    UIApplication.shared.endBackgroundTask(token)
                }
            case .active:
                machine.foreground()
            default:
                break
            }
        }
    }
}
