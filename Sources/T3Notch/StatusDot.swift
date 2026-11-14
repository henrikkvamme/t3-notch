import AppKit
import SwiftUI

/// A small dot just right of the notch showing the target thread's status while the
/// overlay is hidden. Clicking it opens the overlay.
///
/// It goes on the screen with a real notch, or on the main screen beside where the
/// drawn notch would be when no screen has one.
@MainActor
final class StatusDotController {
    private let panel: NotchPanel
    private let store: Store
    private let ui: OverlayUIState
    private static let size = CGSize(width: 22, height: 22)

    init(store: Store, ui: OverlayUIState, onClick: @escaping () -> Void) {
        self.store = store
        self.ui = ui
        panel = NotchPanel()
        panel.level = .statusBar + 1
        panel.contentView = NSHostingView(rootView: StatusDotView(store: store, onClick: onClick))
        place()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        observe()
    }

    private func place() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let notch = NotchGeometry.forScreen(screen).notchRect
        let s = Self.size
        panel.setFrame(NSRect(x: notch.maxX + 8, y: notch.midY - s.height / 2, width: s.width, height: s.height),
                       display: true)
    }

    /// Re-runs whenever the store or overlay mode changes (Observation tracking).
    private func observe() {
        withObservationTracking {
            let visible = ui.mode == .hidden && store.indicator != .hidden
            if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
    }
}

private struct StatusDotView: View {
    let store: Store
    let onClick: () -> Void

    var body: some View {
        StatusDotGlyph(indicator: store.indicator)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onTapGesture(perform: onClick)
            .help(store.targetThread?["title"].string ?? "T3")
    }
}

/// The dot itself for one state; also used by `--render-dots` to draw previews.
struct StatusDotGlyph: View {
    let indicator: Store.Indicator
    var animate = true
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch indicator {
            case .hidden:
                EmptyView()
            case .idle:
                Circle().fill(.gray.opacity(0.55)).frame(width: 7, height: 7)
            case .running:
                Circle().fill(.green).frame(width: 8, height: 8)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { if animate { pulse = true } }
                    .onDisappear { pulse = false }
            case .needsYou:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(.orange)
            case .failed:
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.red)
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.blue)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// Draws every dot state beside a notch into one PNG: `T3Notch --render-dots out.png`.
@MainActor
enum DotPreview {
    static func render(to path: String) {
        let states: [(Store.Indicator, String)] = [
            (.idle, "Idle"), (.running, "Running (pulses)"), (.needsYou, "Needs you"),
            (.failed, "Failed"), (.done, "Reply you haven't seen"), (.hidden, "Hidden (overlay open / T3 off)"),
        ]
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 18) {
                    ZStack {
                        Rectangle().fill(Color(white: 0.16)) // menu bar
                        HStack(spacing: 8) {
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
