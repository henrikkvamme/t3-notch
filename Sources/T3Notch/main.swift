import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let updater = Updater()
    private var panel: PanelController!
    private var hotkey: Hotkey!
    private var dotHotkey: Hotkey!
    private var settings: SettingsController!
    private var statusDot: StatusDotController!
    private var demo: DemoController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(store: store)
        hotkey = Hotkey(Settings.showIslandKey, id: 1) { [weak self] in self?.panel.toggle() }
        // Hides or shows the status dot, e.g. while watching a film.
        dotHotkey = Hotkey(Settings.toggleDotKey, id: 2) { [weak self] in self?.toggleDot() }
        store.onAttentionNeeded = { [weak self] reason in
            guard let self, self.panel.mode == .hidden else { return }
            // Already in T3 Code: it shows the reply and the request itself.
            if let t3 = self.store.runtime?.app?.processIdentifier,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == t3 { return }
            // Finished replies fade; requests that block the agent stay until handled.
            self.panel.peek(autoHide: reason == .finished)
        }
        statusDot = StatusDotController(store: store, ui: panel.ui,
                                        onClick: { [weak self] in self?.panel.expand() },
                                        onRightClick: { [weak self] in self?.settings.toggle() })
        store.start()
        panel.ui.updater = updater
        updater.start()
        settings = SettingsController(store: store, updater: updater, ui: panel.ui, actions: .init(
            reconnect: { [weak self] in self?.reconnect() },
            newToken: { [weak self] in self?.resetToken() },
            openLogs: { [weak self] in self?.openLogs() },
            quit: { NSApp.terminate(nil) },
            rebind: { [weak self] shortcut, binding in self?.rebind(shortcut, to: binding) ?? false },
            pauseShortcuts: { [weak self] paused in
                for h in [self?.hotkey, self?.dotHotkey] { paused ? h?.suspend() : h?.resume() }
            }))
        panel.onOpenSettings = { [weak self] in self?.settings.toggle() }
        // `--open-settings` shows the card at launch, for checking its design.
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.settings.open() }
        }
        if Store.demo {
            demo = DemoController(panel: panel, store: store)
            demo?.run()
        }
        setUpEditMenu()
    }

    /// Text editing shortcuts (⌘X/C/V/A/Z) reach a text field through the main menu's key
    /// equivalents. A menu-bar-only app has no menu by default, so add a standard Edit menu.
    /// It is never shown, since the app has no menu bar of its own.
    private func setUpEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func openT3() { store.openTargetInT3() }
    @objc private func reconnect() { store.reconnectNow() }
    @objc private func resetToken() { Auth.clear(); store.reconnectNow() }
    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: FrameLog.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(FrameLog.directory)
    }
    @objc private func toggleShowWhenFinished() { Settings.showWhenChatFinishes.toggle() }
    @objc private func toggleToolSteps() { Settings.showToolSteps.toggle() }
    @objc private func installUpdate() { updater.install() }
    @objc private func checkForUpdates() { Task { await updater.check() } }
    /// Applies a new global shortcut and saves it; false if macOS or another app owns it.
    private func rebind(_ shortcut: SettingsModel.Shortcut, to binding: KeyBinding) -> Bool {
        switch shortcut {
        case .showIsland:
            guard hotkey.rebind(binding) else { return false }
            Settings.showIslandKey = binding
        case .toggleDot:
            guard dotHotkey.rebind(binding) else { return false }
            Settings.toggleDotKey = binding
        }
        return true
    }

    @objc private func toggleDot() { panel.ui.dotHiddenByUser.toggle() }
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}


if let i = CommandLine.arguments.firstIndex(of: "--render-dots"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated { DotPreview.render(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

if CommandLine.arguments.contains("--demo") { Store.demo = true }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
