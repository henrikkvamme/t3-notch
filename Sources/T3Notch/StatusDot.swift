import AppKit
import SwiftUI

/// A small dot just right of the notch showing the target thread's status while the
/// overlay is hidden. Clicking it opens the overlay.
///
/// It goes on the screen with a real notch, or on the main screen beside where the
/// drawn notch would be when no screen has one. The panel stays on screen so the dot
/// can animate in and out; it ignores the mouse while there is no dot.
@MainActor
final class StatusDotController {
    private let panel: NotchPanel
    private let store: Store
    private let ui: OverlayUIState
    /// Clickable area: from the notch's edge, the full menu-bar height, 44pt wide.
    private static let width: CGFloat = 44

    init(store: Store, ui: OverlayUIState, onClick: @escaping () -> Void) {
        self.store = store
        self.ui = ui
        panel = NotchPanel()
        panel.allowsKey = false
        panel.level = .statusBar + 1
        panel.contentView = FirstClickHostingView(rootView: StatusDotView(store: store, ui: ui, onClick: onClick))
        place()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        observe()
        watchFullscreen()
    }

    // MARK: Fullscreen

    private var fullscreenTimer: Timer?

    /// Re-checks on space and app switches (entering fullscreen moves to a new space),
    /// and every 2s as a fallback for apps that fill the screen without a new space.
    private func watchFullscreen() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkFullscreen()
                    // The fullscreen animation takes a moment; look again once it settles.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.checkFullscreen() }
                }
            }
        }
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFullscreen() }
        }
        checkFullscreen()
    }

    private func checkFullscreen() {
        let screen = Self.notchScreen
        let now = Spaces.isFullscreenSpace(on: screen) || Self.isFullscreen(on: screen)
        if ui.notchScreenFullscreen != now { ui.notchScreenFullscreen = now }
    }

    /// True when another app is fullscreen on this screen. That shows up in the window
    /// list one of two ways (bounds are readable without Screen Recording permission):
    /// - one normal window covering the whole screen, or
    /// - on a notched screen, where fullscreen content sits below the notch: a normal
    ///   window filling the screen below the menu-bar strip, plus a full-width strip
    ///   from the same app covering the menu bar. A maximized window has no such strip.
    private static func isFullscreen(on screen: NSScreen) -> Bool {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        // CoreGraphics window coordinates have their origin at the primary screen's top-left.
        let s = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
                       width: screen.frame.width, height: screen.frame.height)
        let strip = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY, 24)
        let me = ProcessInfo.processInfo.processIdentifier
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 2 }

        var body = Set<Int32>(), top = Set<Int32>()
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let layer = w[kCGWindowLayer as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  near(r.minX, s.minX), r.width >= s.width - 2 else { continue }
            let reachesBottom = r.maxY >= s.maxY - 2
            if layer == 0, near(r.minY, s.minY), reachesBottom { return true } // covers everything
            if layer == 0, r.minY > s.minY, r.minY <= s.minY + strip + 2, reachesBottom { body.insert(pid) }
            if near(r.minY, s.minY), r.height <= strip + 2 { top.insert(pid) }
        }
        return !body.isDisjoint(with: top)
    }

    private static var notchScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func place() {
        let notch = NotchGeometry.forScreen(Self.notchScreen).notchRect
        panel.setFrame(NSRect(x: notch.maxX, y: notch.minY, width: Self.width, height: notch.height), display: true)
    }

    /// Keeps click-through in step with whether a dot is showing.
    private func observe() {
        withObservationTracking {
            panel.ignoresMouseEvents = StatusDotView.effective(store: store, ui: ui) == .hidden
        } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
    }
}

/// Takes the first click even though the app is never active; otherwise macOS spends
/// that click activating the window and the tap never fires.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct StatusDotView: View {
    let store: Store
    let ui: OverlayUIState
    let onClick: () -> Void

    /// No dot while the island is open: the island's own header shows the status.
    static func effective(store: Store, ui: OverlayUIState) -> Store.Indicator {
        ui.mode == .hidden && !ui.notchScreenFullscreen && !ui.dotHiddenByUser ? store.indicator : .hidden
    }

    @State private var hovering = false

    var body: some View {
        let indicator = Self.effective(store: store, ui: ui)
        StatusDotGlyph(indicator: indicator)
            // Wait for the island to shrink into the notch before popping back out.
            .animation(indicator == .hidden ? Motion.snappy : Motion.open.delay(0.22), value: indicator == .hidden)
            .background {
                // Shows the whole clickable area on hover.
                Circle().fill(.white.opacity(hovering && indicator != .hidden ? 0.16 : 0))
                    .frame(width: 26, height: 26)
                    .scaleEffect(hovering ? 1 : 0.6)
            }
            .animation(Motion.snappy, value: hovering)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onClick)
            .help(store.targetThread?["title"].string ?? "T3")
    }
}

/// The dot for one state. One SF Symbol morphs between states (`.replace`), bounces when
/// the state changes. Also used by `--render-dots`.
struct StatusDotGlyph: View {
    let indicator: Store.Indicator
    var animate = true

    private var spec: (symbol: String, color: Color, scale: CGFloat) {
        switch indicator {
        case .hidden, .idle: return ("circle.fill", .gray.opacity(0.6), 0.5)
        case .running: return ("circle.fill", Color(red: 0.12, green: 0.55, blue: 0.24), 0.6) // dark green, steady
        case .needsYou: return ("exclamationmark.circle.fill", .orange, 1)
        case .failed: return ("xmark.circle.fill", .red, 1)
        case .done: return ("checkmark.circle.fill", .blue, 1)
        }
    }

    var body: some View {
        ZStack {
            if indicator != .hidden {
                Image(systemName: spec.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(spec.color)
                    .scaleEffect(spec.scale)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
                    .symbolEffect(.bounce, options: .nonRepeating, value: animate ? indicator : .idle)
                    .transition(.blurReplace.combined(with: .scale(0.2)))
            }
        }
        .frame(width: 22, height: 22)
        .animation(Motion.open, value: indicator)
    }
}

/// Draws every dot state beside a notch into one PNG: `T3Notch --render-dots out.png`.
@MainActor
enum DotPreview {
    static func render(to path: String) {
        let states: [(Store.Indicator, String)] = [
            (.idle, "Idle, or no chat / T3 off"), (.running, "Running"), (.needsYou, "Needs you"),
            (.failed, "Failed"), (.done, "Reply you haven't seen"), (.hidden, "Hidden (overlay open)"),
        ]
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 18) {
                    ZStack {
                        Rectangle().fill(Color(white: 0.16)) // menu bar
                        HStack(spacing: 6) {
                            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                                .fill(.black).frame(width: 190, height: 32)
                            StatusDotGlyph(indicator: s.0, animate: false)
                        }
                        .offset(x: 15)
                    }
                    .frame(width: 300, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(s.1).font(.system(size: 13)).foregroundStyle(.white)
                }
            }
        }
        .padding(20)
        .background(Color(white: 0.08))
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("render failed"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

/// Whether a screen's current desktop space is a fullscreen one, from macOS's own record of
/// spaces (SkyLight's `CGSCopyManagedDisplaySpaces`, as window managers such as yabai use).
/// It is private API, loaded at run time; if it is ever missing, this answers false and the
/// window-shape check above still runs.
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let functions: (MainConnection, CopyDisplaySpaces)? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main = dlsym(lib, "CGSMainConnectionID"),
              let copy = dlsym(lib, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(main, to: MainConnection.self), unsafeBitCast(copy, to: CopyDisplaySpaces.self))
    }()

    /// Space type 4 is a fullscreen app's space.
    static func isFullscreenSpace(on screen: NSScreen) -> Bool {
        guard let (main, copy) = functions,
              let displays = copy(main())?.takeRetainedValue() as? [[String: Any]] else { return false }
        let uuid = displayUUID(screen)
        for display in displays {
            let id = display["Display Identifier"] as? String
            // "Main" when "Displays have separate Spaces" is off: one set of spaces for all.
            guard id == "Main" || id == uuid || displays.count == 1,
                  let current = display["Current Space"] as? [String: Any] else { continue }
            if (current["type"] as? Int) == 4 { return true }
        }
        return false
    }

    private static func displayUUID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
