import AppKit
import SwiftUI

/// A reply's text with the images it embeds (`![alt](src)`) shown in place, in order.
/// Agents embed screenshots and charts as local file paths; those are read from disk
/// (the island runs on the same Mac as T3), and http(s) images are downloaded.
struct ReplyContent: View {
    let text: String
    /// Where relative image paths resolve from: the chat's worktree or project folder.
    let baseDir: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let t):
                    Text(Self.markdown(t)).font(.system(size: 13)).textSelection(.enabled)
                case .image(let src, let alt):
                    ReplyImage(source: Self.resolve(src, baseDir: baseDir), alt: alt)
                }
            }
        }
    }

    enum Segment { case text(String), image(src: String, alt: String) }

    private static let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)

    /// Splits markdown into text runs and images, dropping empty text between them.
    static func segments(_ text: String) -> [Segment] {
        let ns = text as NSString
        var out: [Segment] = []
        var cursor = 0
        for m in imagePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { out.append(.text(before)) }
            out.append(.image(src: ns.substring(with: m.range(at: 2)), alt: ns.substring(with: m.range(at: 1))))
            cursor = m.range.location + m.range.length
        }
        let rest = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(.text(rest)) }
        return out
    }

    /// An absolute URL for the image: web links as is, everything else as a file.
    static func resolve(_ src: String, baseDir: String?) -> URL? {
        let raw = src.removingPercentEncoding ?? src
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: src) }
        if raw.hasPrefix("file://") { return URL(string: src) }
        var path = (raw as NSString).expandingTildeInPath
        // Drop a trailing ":line" that some agents append to file links.
        if let r = path.range(of: #":\d+$"#, options: .regularExpression) { path.removeSubrange(r) }
        if !path.hasPrefix("/"), let baseDir { path = (baseDir as NSString).appendingPathComponent(path) }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// One embedded image: loads off the main thread, keeps its aspect ratio, caps its height,
/// and opens in Preview (or the browser) when clicked.
private struct ReplyImage: View {
    let source: URL?
    let alt: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture { if let source { NSWorkspace.shared.open(source) } }
                    .transition(.blurReplace)
            } else if failed {
                Text(alt.isEmpty ? "Image" : alt).font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06))
                    .frame(width: 160, height: 90)
            }
        }
        .animation(Motion.content, value: image != nil)
        .task(id: source) { await load() }
    }

    private func load() async {
        guard let source else { failed = true; return }
        if let cached = ReplyImageCache.shared.object(forKey: source as NSURL) { image = cached; return }
        let loaded: NSImage? = await Task.detached(priority: .userInitiated) {
            if source.isFileURL { return NSImage(contentsOf: source) }
            guard let (data, _) = try? await URLSession.shared.data(from: source) else { return nil }
            return NSImage(data: data)
        }.value
        if let loaded {
            ReplyImageCache.shared.setObject(loaded, forKey: source as NSURL)
            image = loaded
        } else {
            failed = true
        }
    }
}

/// Decoded images by URL, so streaming re-renders do not reload them.
enum ReplyImageCache {
    nonisolated(unsafe) static let shared: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 40
        return c
    }()
}
