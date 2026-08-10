import SwiftUI

/// Preferences, machine housekeeping and credits. Shared by the iOS sheet and
/// the macOS Settings scene.
///
/// Everything that touches media is *staged*: the disk cannot be swapped while
/// a VAX has it mounted, so imports and resets are applied at the next launch.
/// Saying so plainly beats silently doing something dangerous.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var machine: Machine
    @ObservedObject var terminal: Terminal5620

    @State private var showLicences = false
    @State private var importError: String?

    var body: some View {
        Form {
            screenSection
            inputSection
            terminalSection
            glassSection
            sessionSection
            diskSection
            aboutSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLicences) {
            #if os(macOS)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { showLicences = false }.padding(12)
                }
                LicensesView()
            }
            .frame(width: 660, height: 620)
            #else
            NavigationStack {
                LicensesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showLicences = false }
                        }
                    }
            }
            #endif
        }
    }

    // MARK: Screen

    private var screenSection: some View {
        Section("Screen") {
            Picker("Phosphor", selection: $settings.phosphor) {
                ForEach(Settings.Phosphor.allCases) { Text($0.label).tag($0) }
            }
            Picker("Screen shape", selection: $settings.screenShape) {
                ForEach(Settings.ScreenShape.allCases) { Text($0.label).tag($0) }
            }
            Text(settings.screenShape.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Scaling", selection: $settings.scaling) {
                ForEach(Settings.Scaling.allCases) { Text($0.label).tag($0) }
            }
            Text(settings.scaling.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Input

    private var inputSection: some View {
        Section("Input") {
            VStack(alignment: .leading) {
                HStack {
                    Text("Pointer speed")
                    Spacer()
                    Text(String(format: "%.1f×", settings.mouseSensitivity))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.mouseSensitivity, in: 0.25...3.0, step: 0.05)
            }
            #if os(macOS)
            Text("Left, middle and right buttons are 5620 buttons 1, 2 and 3. On a trackpad, ⌥click gives button 2 and ⌘click button 3 — mux's layer menu lives on button 3.")
                .font(.caption).foregroundStyle(.secondary)
            #else
            Text("Drag to move the pointer. The B1/B2/B3 buttons above the screen choose which button a drag holds down — mux's layer menu lives on button 3.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
        }
    }

    // MARK: Terminal

    /// The glass ttys. Deliberately its own section: these are different
    /// terminals on different lines, not a display mode of the 5620.
    private var glassSection: some View {
        Section("Glass terminals") {
            Picker("Colours", selection: $settings.glassTheme) {
                ForEach(Settings.GlassTheme.allCases) { Text($0.label).tag($0) }
            }
            Picker("Text size", selection: Binding(
                get: { settings.glassFontSize ?? 0 },
                set: { settings.glassFontSize = $0 == 0 ? nil : $0 })) {
                Text("Fit the window").tag(CGFloat(0))
                ForEach(TerminalMetrics.fontSizes, id: \.self) { size in
                    Text("\(Int(size)) pt").tag(size)
                }
            }
            Text("The grid stays 80×24 — or 128×24 on tty07 — whatever size the text is. This kernel predates TIOCGWINSZ, so nothing can tell V8 how big a window is and the size comes from termcap. Bigger text means a bigger picture, not more of it.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Log tty01 in as root", isOn: $settings.autoLoginRoot)
            Text("root is the only account and has no password, so the first terminal opens straight into a shell. It waits for the login: prompt rather than typing on a timer, so a resumed session that is already logged in is left alone.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("A glass tty runs without the 5620, which is most of the app's CPU — a session here costs a fraction of the battery.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var terminalSection: some View {
        Section("Terminal") {
            Picker("Terminal speed", selection: $settings.speed) {
                ForEach(Settings.Speed.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: settings.speed) { _, new in
                terminal.speed.set(new.multiplier)
            }
            Text("How fast the 5620's own processor runs, which is what makes mux paint and scroll quickly. It does not change the serial wire — that is paced inside the terminal's DUART. Above 4× the firmware's serial handshakes can be starved.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Remember terminal settings", isOn: $settings.persistNVRAM)
            Text("Keeps the 5620's 8 KB NVRAM between launches, the way the real terminal's battery did.")
                .font(.caption).foregroundStyle(.secondary)

            Button("Restart terminal") {
                terminal.restart(dzPort: machine.blitPort,
                                 screen: settings.activeScreen,
                                 nvram: settings.persistNVRAM ? machine.nvramURL : nil,
                                 stats: settings.statsURL(machine))
            }
            Text("Power-cycles the 5620 and hangs up the line. Use this if a restored session left mux running on the host with no muxterm in the terminal.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Log wire diagnostics", isOn: $settings.logTerminalStats)
            Text("Appends serial throughput and queue depth to term-stats.log in the app's container. Off by default; takes effect when the terminal next starts, so use Restart terminal above.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Session

    private var sessionSection: some View {
        Section("Saved session") {
            if let snap = machine.snapshot {
                LabeledContent("Snapshot") {
                    Text("\(snap.bytes / 1024) KB · \(snap.saved.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.monospaced())
                }
                Button("Discard saved session", role: .destructive) {
                    machine.discardSnapshot()
                }
            } else {
                Text(machine.phase == .up
                     ? "None — the machine is running. A snapshot is written when it suspends."
                     : "None.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("A snapshot is only consistent with the disk while the machine stays paused, so it is discarded the moment the machine runs again. An unclean exit cold-boots instead, and V8's fsck heals the disk — exactly as it did in 1985.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Disk

    private var diskSection: some View {
        Section("Disk") {
            if machine.hasStagedDisk || machine.hasStagedReset {
                LabeledContent("Pending") {
                    Text(machine.hasStagedReset ? "Reset to pristine" : "Imported image")
                        .font(.caption)
                }
                Text("Takes effect the next time the app starts.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel pending change") { machine.cancelStagedChanges() }
            }

            Button("Export disk image…") {
                DiskTransfer.export(machine.workingDiskURL, suggestedName: "v8.disk")
            }
            Button("Import disk image…") {
                DiskTransfer.importDisk { url in
                    Task { @MainActor in
                        do { try machine.stageImport(from: url) }
                        catch { importError = error.localizedDescription }
                    }
                }
            }
            Button("Reset to pristine V8", role: .destructive) { machine.stageReset() }

            if let importError {
                Text(importError).font(.caption).foregroundStyle(.red)
            }
            Text("Exporting copies the live image; the copy is only guaranteed consistent while the machine is suspended. Imports and resets are applied at the next launch, never under a running machine.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(Self.versionString).font(.caption.monospaced())
            }
            Button("Licences and credits") { showLicences = true }
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
