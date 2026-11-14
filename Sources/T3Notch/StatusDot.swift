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
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch store.indicator {
            case .hidden:
                EmptyView()
            case .idle:
                Circle().fill(.gray.opacity(0.55)).frame(width: 7, height: 7)
            case .running:
                Circle().fill(.green).frame(width: 8, height: 8)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
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
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .help(store.targetThread?["title"].string ?? "T3")
    }
}
