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
    private var selectTrigger: SelectTrigger!
    private var settings: SettingsController!
    private var statusDot: StatusDotController!
    private var demo: DemoController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(store: store)
        hotkey = Hotkey(Settings.showIslandKey, id: 1) { [weak self] in self?.panel.toggle() }
        // Hides or shows the status dot, e.g. while watching a film.
        dotHotkey = Hotkey(Settings.toggleDotKey, id: 2) { [weak self] in self?.toggleDot() }
        selectTrigger = SelectTrigger { [weak self] in self?.panel.startSelecting() }
        store.onAttentionNeeded = { [weak self] reason in
            guard let self, self.panel.mode == .hidden else { return }
            // T3 Code is in view on some display: it shows the reply and the request itself.
            if let t3 = self.store.runtime?.app?.processIdentifier, T3Visibility.isInView(pid: t3) { return }
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
            },
            showWelcome: { [weak self] in
                self?.settings.close()
                self?.panel.startOnboarding()
            }))
        panel.onOpenSettings = { [weak self] in self?.settings.toggle() }
        // `--open-settings` shows the card at launch, for checking its design.
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.settings.open() }
        }
        // `--permission-guide [screenRecording|accessibility]` starts the permission guide at
        // launch, for checking it.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--permission-guide") {
            let named = args.indices.contains(i + 1) ? Permission(rawValue: args[i + 1]) : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.panel.grantPermissions(startingWith: named ?? Permission.missing.first ?? .accessibility)
            }
        }
        // The welcome tour: on first launch, resuming an unfinished one, or with
        // `--onboarding [welcome|connect|hotkey|chats|select|tips|done]`.
        if let i = args.firstIndex(of: "--onboarding") {
            let step = args.indices.contains(i + 1)
                ? OnboardingStep.allCases.first { "\($0)" == args[i + 1] } ?? .welcome : .welcome
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.panel.startOnboarding(at: step) }
        } else if Onboarding.startsAtLaunch, let step = Onboarding.saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.panel.startOnboarding(at: step == .done ? .welcome : step)
            }
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
        case .showChats:
            // Only inside the island: just not one of its other shortcuts.
            guard islandKeyFree(binding, besides: Settings.openInT3Key) else { return false }
            Settings.showChatsKey = binding
        case .openInT3:
            guard islandKeyFree(binding, besides: Settings.showChatsKey) else { return false }
            Settings.openInT3Key = binding
        }
        return true
    }

    /// An island shortcut must not be one of its fixed ones or its other rebindable one.
    private func islandKeyFree(_ binding: KeyBinding, besides other: KeyBinding) -> Bool {
        !KeyBinding.islandReserved.contains { $0.sameKeys(as: binding) } && !other.sameKeys(as: binding)
    }

    @objc private func toggleDot() {
        // The tour's keys card asks you to try this shortcut; trying it there ticks it off.
        if panel.ui.onboarding == .tips { panel.triedTip(.toggleDot); return }
        panel.ui.dotHiddenByUser.toggle()
    }
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

// AppKit's password AutoFill check walks the key views when a text field takes focus. With
// several SwiftUI text fields in the island (composer, chat search, question answers) that
// walk never ends on macOS 27 and hangs the main thread. The island has no password fields.
UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
