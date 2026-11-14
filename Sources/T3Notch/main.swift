import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var panel: PanelController!
    private var hotkey: Hotkey!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(store: store)
        hotkey = Hotkey { [weak self] in self?.panel.toggle() }
        store.onAttentionNeeded = { [weak self] reason in
            guard let self, self.panel.mode == .hidden else { return }
            // Finished replies fade; requests that block the agent stay until handled.
            self.panel.peek(autoHide: reason == .finished)
        }
        store.start()
        setUpStatusItem()
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
