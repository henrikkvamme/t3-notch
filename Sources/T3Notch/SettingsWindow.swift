import AppKit
import ServiceManagement
import SwiftUI

/// The settings popover: a glass card that springs out below the status dot. Opened by
/// right-clicking the dot or ⌘, in the island; Esc or clicking elsewhere closes it.
@MainActor
final class SettingsController {
    private let panel = NotchPanel()
    private let model: SettingsModel
    private var resignObserver: Any?
    private var keyMonitor: Any?
    private var closeTask: Task<Void, Never>?
    private static let size = CGSize(width: 340, height: 600)

    init(store: Store, updater: Updater, ui: OverlayUIState, actions: SettingsModel.Actions) {
        model = SettingsModel(store: store, updater: updater, ui: ui, actions: actions)
        panel.level = .statusBar + 2 // over the island and the dot
        panel.contentView = FirstClickHostingView(rootView: SettingsView(model: model))
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            // `--open-settings` (a design check) keeps it open; normally losing focus closes it.
            MainActor.assumeIsolated { if !CommandLine.arguments.contains("--open-settings") { self?.close() } }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            let recording = MainActor.assumeIsolated { self.model.recording != nil }
            if recording {
                MainActor.assumeIsolated {
                    if e.keyCode == 53 { self.model.cancelRecording() } else { self.model.record(e) }
                }
                return nil
            }
            let cmd = e.modifierFlags.contains(.command)
            if e.keyCode == 53 || (cmd && e.keyCode == 43) || (cmd && e.keyCode == 13) { // Esc, ⌘, or ⌘W
                MainActor.assumeIsolated { self.close() }
                return nil
            }
            return e
        }
    }

    var isOpen: Bool { model.shown }

    func toggle() { isOpen ? close() : open() }

    func open() {
        closeTask?.cancel()
        model.refresh()
        place()
        panel.orderFrontRegardless()
        panel.makeKey()
        withAnimation(Motion.open) { model.shown = true }
    }

    func close() {
        guard model.shown else { return }
        if model.recording != nil { model.cancelRecording() }
        withAnimation(Motion.close) { model.shown = false }
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, !Task.isCancelled, !self.model.shown else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Top right, just below the status dot beside the notch.
    private func place() {
        let screen = StatusDotController.dotScreen
        let notch = NotchGeometry.forScreen(screen).notchRect
        let s = Self.size
        let x = min(notch.maxX + 44 - s.width + 24, screen.frame.maxX - s.width - 8)
        panel.setFrame(NSRect(x: x, y: notch.minY - s.height - 6, width: s.width, height: s.height), display: false)
    }
}

/// What the settings card shows and changes. Toggles write the same UserDefaults keys the
/// rest of the app reads.
@Observable
@MainActor
final class SettingsModel {
    struct Actions {
        var reconnect: () -> Void
        var newToken: () -> Void
        var openLogs: () -> Void
        var quit: () -> Void
        var rebind: (Shortcut, KeyBinding) -> Bool
        var pauseShortcuts: (Bool) -> Void
    }

    enum Shortcut { case showIsland, toggleDot, showChats, openInT3 }

    /// The shortcut being recorded, if any; the next key press sets it.
    var recording: Shortcut?
    /// The shortcut whose last recording was refused (already in use).
    var taken: Shortcut?
    var showIslandKey = Settings.showIslandKey
    var toggleDotKey = Settings.toggleDotKey
    var showChatsKey = Settings.showChatsKey
    var openInT3Key = Settings.openInT3Key

    func startRecording(_ shortcut: Shortcut) {
        taken = nil
        recording = shortcut
        actions.pauseShortcuts(true)
    }

    func cancelRecording() {
        recording = nil
        actions.pauseShortcuts(false)
    }

    /// Applies a recorded key press. Returns false when it is not a usable shortcut.
    @discardableResult
    func record(_ event: NSEvent) -> Bool {
        guard let shortcut = recording, let binding = KeyBinding(event: event) else { return false }
        recording = nil
        actions.pauseShortcuts(false)
        if actions.rebind(shortcut, binding) {
            switch shortcut {
            case .showIsland: showIslandKey = binding
            case .toggleDot: toggleDotKey = binding
            case .showChats: showChatsKey = binding
            case .openInT3: openInT3Key = binding
            }
        } else {
            taken = shortcut
        }
        return true
    }

    let store: Store
    let updater: Updater
    let ui: OverlayUIState
    let actions: Actions
    var shown = false
    var showWhenChatFinishes = Settings.showWhenChatFinishes {
        didSet { Settings.showWhenChatFinishes = showWhenChatFinishes }
    }
    var showToolSteps = Settings.showToolSteps {
        didSet { Settings.showToolSteps = showToolSteps }
    }
    var expandOnHover = Settings.expandOnHover {
        didSet { Settings.expandOnHover = expandOnHover }
    }
    var controlOptionSelect = Settings.controlOptionSelect {
        didSet { Settings.controlOptionSelect = controlOptionSelect }
    }
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var checking = false
    var upToDate = false

    init(store: Store, updater: Updater, ui: OverlayUIState, actions: Actions) {
        self.store = store
        self.updater = updater
        self.ui = ui
        self.actions = actions
    }

    func refresh() {
        showWhenChatFinishes = Settings.showWhenChatFinishes
        showToolSteps = Settings.showToolSteps
        expandOnHover = Settings.expandOnHover
        controlOptionSelect = Settings.controlOptionSelect
        launchAtLogin = SMAppService.mainApp.status == .enabled
        upToDate = false
    }

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {}
        launchAtLogin = service.status == .enabled
    }

    func checkForUpdates() {
        checking = true
        Task {
            await updater.check()
            checking = false
            upToDate = updater.availableVersion == nil
            if upToDate {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(Motion.snappy) { upToDate = false }
            }
        }
    }
}

private struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switches
            buttons
        }
        .padding(16)
        .frame(width: 340, alignment: .topLeading)
        // Tinted dark so text behind the card does not bleed through.
        .glassEffect(.regular.tint(.black.opacity(0.55)), in: .rect(cornerRadius: 26))
        .environment(\.colorScheme, .dark)
        // Springs out from the dot, top right.
        .scaleEffect(model.shown ? 1 : 0.6, anchor: .topTrailing)
        .opacity(model.shown ? 1 : 0)
        .blur(radius: model.shown ? 0 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("T3 Notch").font(.system(size: 15, weight: .semibold))
                    // Marks a local `make` build, which can run beside the release.
                    if BuildInfo.isDev {
                        Text("DEV").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.orange))
                    }
                }
                Text(BuildInfo.isDev ? "v\(Updater.currentVersion) · local build" : "v\(Updater.currentVersion)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(connectionColor).frame(width: 7, height: 7)
                Text(connectionText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var switches: some View {
        VStack(spacing: 0) {
            row("Expand on notch hover", isOn: $model.expandOnHover)
            divider
            row("Show when chat finishes", caption: "Only applies when T3 is not in view",
                isOn: $model.showWhenChatFinishes)
            divider
            row("Show commands while working", isOn: $model.showToolSteps)
            divider
            row("Select with ⌃⌥", caption: "Tap Control and Option in any app to select what is under the pointer",
                isOn: $model.controlOptionSelect)
            divider
            row("Hide status dot", isOn: Binding(get: { model.ui.dotHiddenByUser }, set: { model.ui.dotHiddenByUser = $0 }))
            divider
            row("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            divider
            shortcutRow("Show island", .showIsland, model.showIslandKey)
            divider
            shortcutRow("Toggle dot", .toggleDot, model.toggleDotKey)
            divider
            shortcutRow("Show chats", .showChats, model.showChatsKey)
            divider
            shortcutRow("Open in T3", .openInT3, model.openInT3Key)
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
    }

    private var buttons: some View {
        // Even row: the same padding in every button and the same gap between all five,
        // stretched to the card's edges.
        HStack(spacing: 0) {
            pill("Reconnect") { model.actions.reconnect() }
            Spacer(minLength: 6)
            pill("New token") { model.actions.newToken() }
            Spacer(minLength: 6)
            pill("Logs") { model.actions.openLogs() }
            Spacer(minLength: 6)
            updateButton
            Spacer(minLength: 6)
            iconButton("power") { model.actions.quit() }
        }
    }

    /// Circular arrows: click to check for updates (they spin while checking, a check mark
    /// shows when current). With an update out, it turns green with an up arrow and the new
    /// version, and a click installs it.
    @ViewBuilder private var updateButton: some View {
        let green = Color(red: 0.16, green: 0.78, blue: 0.38)
        if let version = model.updater.availableVersion {
            let installing: Bool = { if case .installing = model.updater.state { return true }; return false }()
            Button { model.updater.install() } label: {
                HStack(spacing: 5) {
                    if installing {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .heavy))
                    }
                    Text("v\(version)").font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).frame(height: 30)
                .background(Capsule().fill(green))
                .shadow(color: green.opacity(0.6), radius: 6)
            }
            .buttonStyle(.plain)
            .disabled(installing)
            .transition(.blurReplace.combined(with: .scale(0.8)))
        } else {
            Button { model.checkForUpdates() } label: {
                Image(systemName: model.upToDate ? "checkmark" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.rotate, options: .repeating, isActive: model.checking)
                    .foregroundStyle(model.upToDate ? green : .primary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(model.checking)
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }

    /// Label left (with an optional caption under it), switch right.
    private func row(_ title: String, caption: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.vertical, 8)
    }

    /// A shortcut and its recorder: click it, press the new keys.
    private func shortcutRow(_ title: String, _ shortcut: SettingsModel.Shortcut, _ binding: KeyBinding) -> some View {
        let recording = model.recording == shortcut
        let label = recording ? "Press keys" : model.taken == shortcut ? "Taken" : binding.label
        return HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            Button {
                recording ? model.cancelRecording() : model.startRecording(shortcut)
            } label: {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(recording ? Color.accentColor : model.taken == shortcut ? .red : .primary)
                    .contentTransition(.opacity)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(minWidth: 70)
            }
            .buttonStyle(.plain)
            .glassEffect(recording ? .regular.tint(.accentColor.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
            .animation(Motion.snappy, value: label)
        }
        .padding(.vertical, 6)
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var connectionText: String {
        switch model.store.connection {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .t3NotRunning: return "T3 not running"
        case .failed: return "Can't reach T3"
        }
    }

    private var connectionColor: Color {
        model.store.connection == .connected ? .green : .gray
    }
}
