import AppKit
import SwiftUI

/// Borderless, non-activating panel that sits on top of the notch (or a drawn notch on
/// screens without one) and grows downward to fit its content.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar + 1 // above the menu bar so it can cover the notch
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Geometry of the notch on one screen.
struct NotchGeometry: Equatable {
    let screenFrame: NSRect
    let notchSize: CGSize
    let hasRealNotch: Bool

    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(screenFrame: screen.frame, notchSize: CGSize(width: width, height: top), hasRealNotch: true)
        }
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(screenFrame: screen.frame, notchSize: CGSize(width: 190, height: menuBar), hasRealNotch: false)
    }

    /// The notch rectangle in screen coordinates.
    var notchRect: NSRect {
        NSRect(x: screenFrame.midX - notchSize.width / 2, y: screenFrame.maxY - notchSize.height,
               width: notchSize.width, height: notchSize.height)
    }

    static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// Shows, hides and sizes the panel. The SwiftUI view reports its size; the panel
/// stays top-centred on the chosen screen.
@MainActor
final class PanelController {
    enum Mode: Equatable { case hidden, expanded, peek }

    let panel = NotchPanel()
    let ui: OverlayUIState
    private let store: Store
    private var geometry: NotchGeometry
    private var mouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var peekHideTask: Task<Void, Never>?

    init(store: Store) {
        self.store = store
        self.geometry = NotchGeometry.forScreen(NotchGeometry.screenUnderMouse())
        self.ui = OverlayUIState()
        ui.onSizeChange = { [weak self] size in self?.resize(to: size) }
        ui.onClose = { [weak self] in self?.hide() }
        ui.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
        let root = OverlayView(store: store, ui: ui)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        startNotchHoverWatch()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
    }

    /// Overlay shortcuts. Returns true when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        let approval = store.pendingRequest.map { $0.kind != "user_input" } ?? false
        switch event.keyCode {
        case 53: // Esc
            if ui.pickerOpen { ui.pickerOpen = false; return true }
            if approval { Task { await store.respond(decision: "decline") }; return true }
            hide(); return true
        case 40 where cmd: // ⌘K
            ui.pickerOpen.toggle(); ui.pickerIndex = 0; return true
        case 47 where cmd: // ⌘.
            Task { await store.interruptRun() }; return true
        case 36 where cmd && approval: // ⌘⏎
            Task { await store.respond(decision: "acceptForSession") }; return true
        case 36 where approval && !ui.pickerOpen && ui.draft.isEmpty: // ⏎
            Task { await store.respond(decision: "accept") }; return true
        case 125 where ui.pickerOpen: // ↓
            ui.pickerIndex = min(ui.pickerIndex + 1, max(min(store.recentThreads.count, 10) - 1, 0)); return true
        case 126 where ui.pickerOpen: // ↑
            ui.pickerIndex = max(ui.pickerIndex - 1, 0); return true
        default:
            return false
        }
    }

    var mode: Mode { ui.mode }

    func toggle() {
        ui.mode == .expanded ? hide() : expand()
    }

    func expand() {
        peekHideTask?.cancel()
        place(on: NotchGeometry.screenUnderMouse())
        ui.mode = .expanded
        ui.focusToken += 1
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Shows the reply without taking focus; fades after a delay unless hovered.
    func peek(autoHide: Bool) {
        guard ui.mode == .hidden else { return }
        place(on: NotchGeometry.screenUnderMouse())
        ui.mode = .peek
        panel.orderFrontRegardless()
        if autoHide { schedulePeekHide(after: 8) }
    }

    func hide() {
        peekHideTask?.cancel()
        ui.mode = .hidden
        ui.pickerOpen = false
        panel.orderOut(nil)
    }

    private func schedulePeekHide(after seconds: Double) {
        peekHideTask?.cancel()
        peekHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.ui.mode == .peek, !self.ui.hovering else { return }
            self.hide()
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        if ui.mode == .peek, !hovering { schedulePeekHide(after: 1.5) }
        if hovering { peekHideTask?.cancel() }
    }

    private func place(on screen: NSScreen) {
        geometry = NotchGeometry.forScreen(screen)
        ui.notchSize = geometry.notchSize
        ui.hasRealNotch = geometry.hasRealNotch
        ui.maxReplyHeight = screen.frame.height * 0.4
        resize(to: panel.frame.size)
    }

    private func resize(to size: CGSize) {
        let w = max(size.width, geometry.notchSize.width)
        let h = max(size.height, geometry.notchSize.height)
        let frame = NSRect(x: geometry.screenFrame.midX - w / 2, y: geometry.screenFrame.maxY - h, width: w, height: h)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// While a run is active, hovering the notch peeks at the reply. Global mouse-move
    /// monitoring needs no Accessibility permission (only key monitoring does).
    private func startNotchHoverWatch() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.checkNotchHover() }
        }
    }

    private func checkNotchHover() {
        guard ui.mode == .hidden, store.isTargetActive || store.pendingRequest != nil else { return }
        let p = NSEvent.mouseLocation
        let screen = NotchGeometry.screenUnderMouse()
        let g = NotchGeometry.forScreen(screen)
        if NSMouseInRect(p, g.notchRect.insetBy(dx: -8, dy: 0), false) {
            peek(autoHide: false)
            schedulePeekHide(after: 2.5) // stays while hovered
        }
    }
}
