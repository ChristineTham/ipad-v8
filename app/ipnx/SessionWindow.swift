import SwiftUI

/// One window, holding every session of one terminal shape.
///
/// Windows are grouped by shape because the shapes cannot be reflowed into one
/// another — see `TerminalShape`. Tabs therefore only ever group sessions that
/// are already the same size, which is why switching tabs never resizes
/// anything and never disturbs the far end.
struct SessionWindow: View {
    let shape: TerminalShape

    @ObservedObject var store: SessionStore
    @ObservedObject var machine: Machine
    @ObservedObject var settings: Settings
    @ObservedObject var dmd: Terminal5620
    #if os(macOS)
    @ObservedObject var capture: PointerCapture
    #endif

    @Environment(\.openWindow) private var openWindow
    @State private var selected: Line?
    @State private var showSettings = false
    /// Set the moment the user picks a tab themselves, which stops the
    /// boot-finished handoff below from moving the ground under them.
    @State private var userChoseTab = false
    @State private var shapedWindow = false

    private var lines: [Line] { store.openLines(of: shape) }
    private var current: Line { selected ?? lines.first ?? shape.lines[0] }
    private var session: Session { store[current] }

    var body: some View {
        VStack(spacing: 0) {
            if shape.lines.count > 1 { chrome }
            terminals
        }
        .background(Color.black)
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) { status }
        #if os(macOS)
        .navigationTitle(shape == .vt100 ? "ipnx" : shape.windowTitle)
        .toolbar { toolbarItems }
        // Only the 5620's window is shaped to a tube, because only it draws
        // one. The glass ttys scale their text to whatever window they are
        // given, so locking their aspect would be a constraint with nothing
        // behind it.
        .background {
            if shape == .dmd {
                WindowReader { window in
                    guard !shapedWindow else { return }
                    shapedWindow = true
                    CRTWindow.shape(window, to: settings.chooseScreen())
                }
            }
        }
        #endif
        .onAppear {
            if selected == nil { selected = lines.first ?? openFirst() }
            if shape == .vt100, let extra = Settings.debugOpenWindow, extra != .vt100 {
                openWindow(value: extra)
            }
        }
        .onChange(of: machine.phase) { _, phase in
            guard phase == .up else { return }
            store.machineIsUp()
            // Boot is over: hand the user from the machine coming up to a
            // place they can type. The console is the right thing to watch
            // while V8 fscks and mounts, and the wrong thing to be left
            // staring at afterwards — but only if they have not already
            // picked a tab for themselves.
            if shape == .vt100, !userChoseTab, store.isOpen(.tty(1)) {
                selected = .tty(1)
            }
        }
        .onDisappear {
            // A window that holds exactly one terminal *is* that terminal, so
            // closing it hangs up the line. This matters most for the 5620:
            // its WE32100 thread does not idle, and a window nobody can see is
            // not a reason to keep burning most of a core.
            if shape.lines.count == 1, let only = shape.lines.first {
                store.close(only)
            }
        }
        .sheet(isPresented: $showSettings) {
            #if os(macOS)
            EmptyView()
            #else
            NavigationStack {
                SettingsView(settings: settings, machine: machine, terminal: dmd)
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
            #endif
        }
        .preferredColorScheme(.dark)
    }

    /// Open the shape's first line when a window comes up empty — the 5620 and
    /// wide windows exist only to hold one session, so opening the window is
    /// the request to start it.
    private func openFirst() -> Line? {
        guard let first = shape.lines.first else { return nil }
        store.open(first)
        return first
    }

    // MARK: The terminals

    /// Every open session of this shape, all mounted, only one visible.
    ///
    /// Mounted rather than swapped because these are nine independent logins,
    /// not nine views of one thing: V8 runs a getty per line, so a session that
    /// is not on screen is still running, still receiving, and must still be
    /// there — with its scrollback — when the user comes back to it.
    private var terminals: some View {
        ZStack {
            Color.black
            ForEach(lines) { line in
                let visible = line == current
                Group {
                    if line == .tty(0) {
                        #if os(macOS)
                        Blit5620View(terminal: dmd, settings: settings,
                                     isActive: visible, capture: capture)
                        #else
                        Blit5620View(terminal: dmd, settings: settings, isActive: visible)
                        #endif
                    } else {
                        SessionView(session: store[line], settings: settings)
                    }
                }
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
            }
        }
    }

    // MARK: Chrome

    /// The tab bar. Only drawn for shapes that can hold more than one session —
    /// `tty00` and `tty07` are the only lines of their shape, so a tab bar over
    /// them would be one tab that never changes.
    private var chrome: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(lines) { line in tab(line) }
                    }
                    .padding(.vertical, 2)
                }
                newSessionMenu
                Spacer(minLength: 8)
                #if !os(macOS)
                inlineActions
                #endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.black)
    }

    private func tab(_ line: Line) -> some View {
        let isCurrent = line == current
        return HStack(spacing: 6) {
            Image(systemName: line.symbol)
                .font(.caption2)
            Text(line.title)
                .font(.callout)
                .lineLimit(1)
            if line != .console {
                Button {
                    close(line)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .opacity(isCurrent ? 0.8 : 0.35)
                .help("Hang up \(line.device)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(isCurrent
                     ? .regular.tint(settings.glassTheme.accent.opacity(0.5)).interactive()
                     : .regular.interactive(),
                     in: .capsule)
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        .contentShape(Capsule())
        .onTapGesture { userChoseTab = true; selected = line }
    }

    /// The lines this machine has but the user has not opened. There is no
    /// "new tab" in the usual sense — the eight ttys are hardware, so this is a
    /// list of what exists, not a button that creates something.
    private var newSessionMenu: some View {
        let available = store.availableLines(of: shape)
        return Menu {
            if available.isEmpty {
                Text("Every line of this shape is open")
            } else {
                ForEach(available) { line in
                    Button {
                        store.open(line)
                        userChoseTab = true
                        selected = line
                    } label: {
                        Label(line.title, systemImage: line.symbol)
                    }
                }
            }
            Divider()
            windowButtons
        } label: {
            Image(systemName: "plus")
                .font(.callout.weight(.medium))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .menuIndicator(.hidden)
        .help("Open another terminal")
    }

    /// The other two shapes get their own windows, because they are other
    /// sizes of glass and nothing can be told to reflow.
    @ViewBuilder
    private var windowButtons: some View {
        ForEach(TerminalShape.allCases.filter { $0 != shape }) { other in
            Button {
                openWindow(value: other)
            } label: {
                Label("Open \(other.label)", systemImage: other.symbol)
            }
        }
    }

    #if !os(macOS)
    /// iPad has no toolbar without a navigation stack, so the session actions
    /// ride the same bar as the tabs.
    private var inlineActions: some View {
        HStack(spacing: 8) {
            sessionActions
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .help("Settings")
        }
    }
    #endif

    /// Actions that belong to whichever session is in front. Glass here
    /// because on iPad these ride the tab bar; the Mac's toolbar draws its own
    /// and stacking a second one on top of it reads as a blob.
    @ViewBuilder
    private var sessionActions: some View {
        if current == .console {
            Button { session.readOnly.toggle() } label: {
                Image(systemName: session.readOnly ? "lock.fill" : "lock.open")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .help(consoleLockHelp)
        }
    }

    private var consoleLockHelp: String {
        session.readOnly
            ? "The console is read-only. Unlock to type into it."
            : "The console accepts input. Lock it to stop stray keystrokes."
    }

    #if os(macOS)
    /// Real window chrome on the Mac. Everything the user might reach for
    /// lives in the title bar, so nothing floats over the emulated screen and
    /// nothing has to wrap: AppKit moves whatever does not fit into the
    /// overflow menu, which a hand-rolled strip cannot do.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if shape.lines.count == 1 {
            ToolbarItem(placement: .navigation) {
                Menu {
                    windowButtons
                } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .help("Open another terminal")
            }
        }
        if current == .console {
            ToolbarItem {
                Button { session.readOnly.toggle() } label: {
                    Label(session.readOnly ? "Unlock Console" : "Lock Console",
                          systemImage: session.readOnly ? "lock.fill" : "lock.open")
                }
                .help(consoleLockHelp)
            }
        }
        if current == .tty(0) {
            ToolbarItem {
                Text(capture.captured ? "pointer grabbed" : "⌥click B2 · ⌘click B3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("""
                        The 5620 has three mouse buttons. Left, middle and right map \
                        to B1, B2 and B3; on a trackpad, ⌥click gives B2 and ⌘click \
                        gives B3. mux's layer menu is on B3.
                        """)
            }
            ToolbarItem {
                Button(capture.captured ? "Release Pointer" : "Grab Pointer") {
                    capture.captured.toggle()
                }
                .help("""
                    The 5620's mouse is a relative device, so its cursor and the \
                    Mac's drift apart at the screen edge. Grabbing hides the Mac's \
                    entirely (⌘G).
                    """)
            }
            ToolbarItem {
                Button("BREAK") { dmd.sendBreak() }
                    .help("Send a serial BREAK to the terminal.")
            }
        }
    }
    #endif

    private func close(_ line: Line) {
        store.close(line)
        if selected == line { selected = store.openLines(of: shape).first }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        if let text = statusText {
            HStack(spacing: 10) {
                if !isFailure { ProgressView().tint(.green) }
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(isFailure ? Color.red : Color.green)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(.black.opacity(0.5)), in: .capsule)
            .padding(.top, 10)
        }
    }

    private var isFailure: Bool {
        if case .failed = machine.phase { return true }
        return false
    }

    private var statusText: String? {
        switch machine.phase {
        case .idle, .starting: return "Starting VAX-11/780…"
        case .provisioning: return "First launch: installing the V8 disk…"
        case .booting: return "Booting Research Unix…"
        case .restoring: return "Restoring session…"
        case .pausing: return "Saving machine state…"
        case .up, .paused: return nil
        case .failed(let msg): return "Failed: \(msg)"
        }
    }
}
