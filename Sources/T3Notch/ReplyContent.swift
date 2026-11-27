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
                    ForEach(Array(Self.blocks(t).enumerated()), id: \.offset) { _, block in
                        BlockView(block: block)
                    }
                case .image(let src, let alt):
                    ReplyImage(source: Self.resolve(src, baseDir: baseDir), alt: alt)
                }
            }
        }
    }

    enum Segment { case text(String), image(src: String, alt: String) }

    /// One list line: how deep it sits, its mark ("•" or "2.") and its text.
    struct Item: Equatable { let depth: Int; let mark: String; var text: String }

    enum Block: Equatable {
        case paragraph(String), heading(level: Int, String), list([Item]), code(String), quote(String), rule
    }

    private static let listMark = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d{1,3}[.)])\s+(.*)$"#)
    private static let headingMark = try! NSRegularExpression(pattern: #"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$"#)

    /// The block structure of markdown text: headings, lists, code, quotes, rules and
    /// paragraphs. Inline marks (bold, code, links) stay in each block's text. A table has
    /// no place in a narrow island, so its lines show as code, where its columns line up.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = [], items: [Item] = [], quote: [String] = [], code: [String]?, table: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !items.isEmpty { out.append(.list(items)); items = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { out.append(.code(table.joined(separator: "\n"))); table = [] }
        }
        func groups(_ re: NSRegularExpression, _ line: String) -> [String]? {
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { out.append(.code(code!.joined(separator: "\n"))); code = nil }
                else { code!.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1 {
                if table.isEmpty { flush() }
                // The line of dashes under a table's header says nothing.
                if !trimmed.allSatisfy({ "|-: ".contains($0) }) { table.append(trimmed) }
                continue
            }
            if !table.isEmpty { flush() }
            if let g = groups(headingMark, line) { flush(); out.append(.heading(level: g[0].count, g[1])); continue }
            if trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first),
               trimmed.allSatisfy({ $0 == first || $0 == " " }) { flush(); out.append(.rule); continue }
            if let g = groups(listMark, line) {
                if items.isEmpty { flush() }
                let mark = "-*+".contains(g[1]) ? "\u{2022}" : g[1].replacingOccurrences(of: ")", with: ".")
                items.append(Item(depth: min(g[0].replacingOccurrences(of: "\t", with: "    ").count / 2, 4), mark: mark, text: g[2]))
                continue
            }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            // A line that goes on from a list line or a quote belongs to it.
            if !items.isEmpty { items[items.count - 1].text += "\n" + trimmed; continue }
            if !quote.isEmpty { quote.append(trimmed); continue }
            paragraph.append(line)
        }
        if let code { flush(); out.append(.code(code.joined(separator: "\n"))) } else { flush() }
        return out
    }

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

/// One block of a reply, drawn as what it is.
private struct BlockView: View {
    let block: ReplyContent.Block

    var body: some View {
        switch block {
        case .paragraph(let t):
            Text(ReplyContent.markdown(t)).font(.system(size: 13)).textSelection(.enabled)
        case .heading(let level, let t):
            Text(ReplyContent.markdown(t))
                .font(.system(size: level == 1 ? 16 : level == 2 ? 14.5 : 13, weight: .semibold))
                .textSelection(.enabled)
                .padding(.top, 4)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    // The mark hangs: a long line goes on under its own text, not under the mark.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.mark).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                            .frame(minWidth: 10, alignment: .trailing)
                        Text(ReplyContent.markdown(item.text)).font(.system(size: 13)).textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.depth) * 14)
                }
            }
        case .code(let t):
            Text(t).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.white.opacity(0.07), in: .rect(cornerRadius: 8))
        case .quote(let t):
            Text(ReplyContent.markdown(t)).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Capsule().fill(.white.opacity(0.25)).frame(width: 2) }
        case .rule:
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
        }
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
