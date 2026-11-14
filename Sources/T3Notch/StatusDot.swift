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
    }

    private func place() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let notch = NotchGeometry.forScreen(screen).notchRect
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
        ui.mode == .hidden ? store.indicator : .hidden
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
