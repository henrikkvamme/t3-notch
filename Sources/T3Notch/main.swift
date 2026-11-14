import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var panel: PanelController!
    private var hotkey: Hotkey!
    private var statusItem: NSStatusItem!
    private var statusDot: StatusDotController!
    private var demo: DemoController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(store: store)
        hotkey = Hotkey { [weak self] in self?.panel.toggle() }
        store.onAttentionNeeded = { [weak self] reason in
            guard let self, self.panel.mode == .hidden else { return }
            // Already in T3 Code: it shows the reply and the request itself.
            if let t3 = self.store.runtime?.app?.processIdentifier,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == t3 { return }
            // Finished replies fade; requests that block the agent stay until handled.
            self.panel.peek(autoHide: reason == .finished)
        }
        statusDot = StatusDotController(store: store, ui: panel.ui) { [weak self] in self?.panel.expand() }
        store.start()
        setUpStatusItem()
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

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "T3 Notch")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
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

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        switch store.connection {
        case .connected: status = "Connected to T3 \(store.runtime?.serverVersion ?? "")"
        case .connecting: status = "Connecting…"
        case .t3NotRunning: status = "T3 isn't running"
        case .failed(let r): status = "Error: \(r.prefix(60))"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
        if let t = store.targetThread?["title"].string {
            menu.addItem(withTitle: "Target: \(t.prefix(50))", action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        add(menu, "Show/Hide  (⌥Space)", #selector(togglePanel))
        add(menu, "Open Thread in T3", #selector(openT3))
        add(menu, "Reconnect", #selector(reconnect))
        add(menu, "Reissue Token", #selector(resetToken))
        add(menu, "Open Logs Folder", #selector(openLogs))
        let finish = add(menu, "Show When Chat Finishes", #selector(toggleShowWhenFinished))
        finish.state = Settings.showWhenChatFinishes ? .on : .off
        let login = add(menu, "Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "Quit T3 Notch", #selector(quit))
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
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
