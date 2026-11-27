import AppKit
import SwiftUI
import WebKit

/// The older part of the chat, above the reply. It is out of view until you scroll up, and
/// the island grows with what you reveal (see `OverlayUIState.replyGeometryChanged`).
struct HistoryList: View {
    let store: Store
    let ui: OverlayUIState
    /// What the reply area shows below: not history yet.
    let liveID: String
    let baseDir: String?

    var body: some View {
        // Only what came before the reply below. While a run has no reply yet, the reply below
        // is the last one, and your newer message is not above it.
        let whole = store.transcript
        let all = whole.firstIndex { $0.id == liveID }.map { Array(whole[..<$0]) } ?? whole
        let shown = all.suffix(ui.historyShown)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(shown) { entry in
                EntryView(store: store, entry: entry, baseDir: baseDir)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, shown.isEmpty ? 0 : 14)
        // Out of sight until the reply is back in its place under it.
        .opacity(ui.historyVisible ? 1 : 0)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            ui.historyHeight = height
            ui.replyGeometryChanged()
        }
        .onChange(of: all.count, initial: true) { _, count in ui.historyTotal = count }
    }
}

/// One entry of the chat, drawn as T3 draws it: your message in a bubble on the right, a
/// reply as text, a page in a frame.
private struct EntryView: View {
    let store: Store
    let entry: Store.Entry
    let baseDir: String?

    var body: some View {
        switch entry.kind {
        case .user:
            UserBubble(store: store, entry: entry)
        case .assistant:
            ReplyContent(text: entry.text.trimmingCharacters(in: .whitespacesAndNewlines), baseDir: baseDir)
        case .page(let title, let height, let heights):
            PageFrame(store: store, attachment: entry.text, title: title, height: height, heights: heights)
        }
    }
}

/// Your message: on the right, on a tinted ground, at most four fifths of the width. A long
/// one is cut short until you ask for the rest.
private struct UserBubble: View {
    let store: Store
    let entry: Store.Entry
    @State private var whole = false

    private var long: Bool {
        entry.text.count > 600 || entry.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } > 9
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !entry.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.images, id: \.self) { id in
                        Group {
                            if let image = store.attachmentImages[id] {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.white.opacity(0.06)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .task(id: id) { await store.loadImage(id) }
                    }
                }
            }
            if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ReplyContent.markdown(entry.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                        .font(.system(size: 13))
                        .lineLimit(long && !whole ? 8 : nil)
                        .textSelection(.enabled)
                    if long {
                        Button(whole ? "Show less" : "Show full message") {
                            withAnimation(Motion.content) { whole.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(.white.opacity(0.1), in: .rect(cornerRadius: 14))
            }
        }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.8 }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A page the agent made with T3's `html_render` tool, in a frame as T3 shows it: the page
/// itself, served by T3, as tall as its content.
private struct PageFrame: View {
    let store: Store
    let attachment: String
    let title: String
    let height: Double
    let heights: [[Double]]
    @State private var request: URLRequest?
    @State private var failed = false
    @State private var fitted: CGFloat?
    @State private var width: CGFloat = 0

    /// T3's rule (`htmlRenderFrameHeight`): the page's own height once it is known, else the
    /// height T3 measured for this width. The island caps it lower than T3 does.
    private var frameHeight: CGFloat {
        let known = fitted ?? CGFloat((heights.last { CGFloat($0[0]) <= max(width, 1) } ?? heights.first)?[1] ?? height)
        return min(max(known, 80), 1200)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "macwindow")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Group {
                if let request {
                    PageWeb(request: request) { fitted = $0 }
                } else if failed {
                    Text("This page could not be loaded.").font(.system(size: 12)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.06))
                } else {
                    Color.white.opacity(0.06)
                }
            }
            .frame(height: frameHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        }
        .task(id: attachment) {
            request = await store.pageRequest(attachment)
            failed = request == nil
        }
    }
}

/// The web view of a page. T3 serves the page with a sandbox policy; here it also gets no
/// stored data, and a link in it opens in the browser, not in the island.
private struct PageWeb: NSViewRepresentable {
    let request: URLRequest
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = PassScrollWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        // T3 shows these pages in the light scheme, whatever the app's own is.
        view.appearance = NSAppearance(named: .aqua)
        context.coordinator.loaded = request.url
        view.load(request)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        guard context.coordinator.loaded != request.url else { return }
        context.coordinator.loaded = request.url
        view.load(request)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onHeight: (CGFloat) -> Void
        var loaded: URL?
        init(onHeight: @escaping (CGFloat) -> Void) { self.onHeight = onHeight }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated else { return .allow }
            if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let script = "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"
            webView.evaluateJavaScript(script) { [weak self] value, _ in
                guard let height = (value as? NSNumber)?.doubleValue, height > 0 else { return }
                self?.onHeight(CGFloat(height))
            }
        }
    }
}

/// The frame is as tall as its page, so a scroll over it is a scroll of the chat.
private final class PassScrollWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// The reply area is as tall as the reply, plus what you have revealed of the history above
/// it. Read here and not in the island's body, so a scroll redraws nothing else.
struct ReplyHeight: ViewModifier {
    let ui: OverlayUIState

    @ViewBuilder func body(content: Content) -> some View {
        if ui.mode == .expanded {
            // The open island has a fixed size: the reply takes the room that is left.
            content.frame(maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    if ui.replyViewport != height { ui.replyViewport = height }
                }
        } else {
            content.frame(height: min(ui.replyTextHeight + ui.reveal, min(220, ui.maxReplyHeight)))
        }
    }
}

/// Holds the reply's scroll position as view state and carries out the orders of
/// `OverlayUIState.scrollReply`. SwiftUI writes the position back while it scrolls; that
/// write stays here and redraws nothing else.
struct ReplyScroller: ViewModifier {
    let ui: OverlayUIState
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: ui.scrollOrder) { _, order in
                withAnimation(order.animation) {
                    switch order.target {
                    case .y(let y): position.scrollTo(y: y)
                    case .bottom: position.scrollTo(edge: .bottom)
                    }
                }
            }
    }
}

/// How long the run has worked, counted each second: 12s, 2m 14s, 1h 05m.
struct RunClock: View {
    let since: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.label(Int(max(0, context.date.timeIntervalSince1970 - since / 1000))))
                .monospacedDigit()
        }
    }

    static func label(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", s % 3600 / 60))m"
    }
}
