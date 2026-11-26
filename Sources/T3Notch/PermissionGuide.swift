import AppKit
import SwiftUI

/// A small card that sits under System Settings while you grant permissions. It names the exact
/// copy of the app to turn on, ticks each permission off the moment macOS grants it, opens the
/// next missing one, and goes away when all are on. If the app is not in the list, you can drag
/// its icon from the card into the list.
@MainActor
final class PermissionGuide {
    private let panel = GuidePanel()
    private let model = PermissionGuideModel()
    private var timer: Timer?
    private var hideTask: Task<Void, Never>?
    /// The request in flight. A new pick or closing the card cancels it, so a late request
    /// never opens the wrong list.
    private var requestTask: Task<Void, Never>?
    private static let size = CGSize(width: 400, height: 132)

    init() {
        model.onPick = { [weak self] permission in self?.ask(permission) }
        model.onClose = { [weak self] in self?.stop() }
        let host = FirstClickHostingView(rootView: PermissionGuideView(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    var isOpen: Bool { model.shown }

    /// Starts with `first`, then goes through the other missing permissions.
    func start(_ first: Permission) {
        hideTask?.cancel()
        model.permissions = [first] + Permission.missing.filter { $0 != first }
        model.granted = []
        model.done = false
        ask(first)
        place()
        panel.orderFrontRegardless()
        withAnimation(Motion.open) { model.shown = true }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        requestTask?.cancel()
        requestTask = nil
        timer?.invalidate()
        timer = nil
        withAnimation(Motion.close) { model.shown = false }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, !self.model.shown else { return }
            self.panel.orderOut(nil)
        }
    }

    private func ask(_ permission: Permission) {
        withAnimation(Motion.snappy) { model.current = permission }
        requestTask?.cancel()
        requestTask = Task { await permission.request() }
    }

    private func tick() {
        if model.permissions.contains(.screenRecording) && !model.granted.contains(.screenRecording) {
            Task { await Permission.confirmScreenRecordingLive() }
        }
        let granted = Set(model.permissions.filter(\.isGranted))
        if granted != model.granted {
            withAnimation(Motion.snappy) { model.granted = granted }
            if let next = model.permissions.first(where: { !granted.contains($0) }) {
                if let current = model.current, granted.contains(current) { ask(next) }
            } else {
                withAnimation(Motion.content) { model.done = true; model.current = nil }
                timer?.invalidate()
                timer = nil
                hideTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.6))
                    guard !Task.isCancelled else { return }
                    self?.stop()
                }
            }
        }
        place()
    }

    /// Just below the System Settings window, centred on it; inside its bottom edge when there
    /// is no room below. Window bounds need no Screen Recording permission.
    private func place() {
        let s = Self.size
        var frame: NSRect
        if let settings = Self.settingsWindowFrame() {
            let screen = NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            // Just below the window, as PermissionFlow does; beside it, level with its bottom
            // (where the app's row usually is, the list being alphabetical) when there is no
            // room below; over its sidebar last.
            let bottom = max(settings.minY + 16, visible.minY + 8)
            if settings.minY - s.height - 4 >= visible.minY + 8 {
                let x = min(max(settings.midX - s.width / 2, visible.minX + 8), visible.maxX - s.width - 8)
                frame = NSRect(x: x, y: settings.minY - s.height - 4, width: s.width, height: s.height)
            } else if settings.maxX + 12 + s.width <= visible.maxX - 8 {
                frame = NSRect(x: settings.maxX + 12, y: bottom, width: s.width, height: s.height)
            } else if settings.minX - 12 - s.width >= visible.minX + 8 {
                frame = NSRect(x: settings.minX - 12 - s.width, y: bottom, width: s.width, height: s.height)
            } else {
                frame = NSRect(x: max(settings.minX + 12, visible.minX + 8), y: bottom, width: s.width, height: s.height)
            }
        } else {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            frame = NSRect(x: screen.visibleFrame.midX - s.width / 2, y: screen.visibleFrame.minY + 80,
                           width: s.width, height: s.height)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// The largest on-screen System Settings window, in AppKit coordinates.
    private static func settingsWindowFrame() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        let rects: [CGRect] = list.compactMap { info in
            guard info[kCGWindowOwnerName as String] as? String == "System Settings",
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 300 else { return nil }
            return rect
        }
        guard let cg = rects.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        // CoreGraphics measures from the top of the primary screen; AppKit from its bottom.
        return NSRect(x: cg.minX, y: primary.frame.maxY - cg.maxY, width: cg.width, height: cg.height)
    }
}

/// Floats over System Settings without taking focus from it.
private final class GuidePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@Observable
@MainActor
final class PermissionGuideModel {
    var shown = false
    var permissions: [Permission] = []
    var granted: Set<Permission> = []
    var current: Permission?
    var done = false
    var onPick: ((Permission) -> Void)?
    var onClose: (() -> Void)?
}

struct PermissionGuideView: View {
    let model: PermissionGuideModel
    @State private var hoveringIcon = false

    /// The name the list shows, so the right copy gets turned on ("T3 Notch Dev" for a local build).
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "T3 Notch"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.done ? "All set" : "Turn on \(appName)")
                        .font(.system(size: 15, weight: .semibold))
                        .contentTransition(.opacity)
                    Spacer(minLength: 8)
                    Button { model.onClose?() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 22, height: 22).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    ForEach(model.permissions) { permission in chip(permission) }
                }
                Text("Not in the list? Drag the icon into it, or use +.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .opacity(model.done ? 0 : 1)
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .glassEffect(.regular.tint(.black.opacity(0.55)), in: .rect(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
        .scaleEffect(model.shown ? 1 : 0.9, anchor: .top)
        .opacity(model.shown ? 1 : 0)
        .blur(radius: model.shown ? 0 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The app's own icon. Dragging it drops the app's bundle, which the list accepts.
    private var icon: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
            .scaleEffect(hoveringIcon ? 1.06 : 1)
            .animation(Motion.snappy, value: hoveringIcon)
            .onHover { hoveringIcon = $0 }
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            .help("Drag into the list in System Settings")
    }

    /// One permission: a check once granted, orange while it is the one to turn on now.
    /// Clicking it opens its list again.
    private func chip(_ permission: Permission) -> some View {
        let granted = model.granted.contains(permission)
        let active = model.current == permission
        return Button { model.onPick?(permission) } label: {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark" : "lock.fill").font(.system(size: 10, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(permission.title).font(.callout)
            }
            .foregroundStyle(granted ? AnyShapeStyle(.green) : active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 12).padding(.vertical, 6)
            // Flat tints: glass inside the glass card would not show its tint.
            .background(Capsule().fill(granted ? .green.opacity(0.16) : active ? .orange.opacity(0.32) : .white.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(granted)
    }
}
