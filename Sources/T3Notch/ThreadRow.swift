import SwiftUI

/// A chat in the ⌘K list, laid out like T3's sidebar row
/// (`apps/web/src/components/sidebar/SidebarThreadRow.tsx`):
/// 1. project icon, pin, project name, and the status or time since the last activity
/// 2. title, with the provider glyph at the end when there is no third line
/// 3. branch, or the machine for chats without a project, with the provider glyph
///
/// A chat on a linked environment also names that machine on line 1, as T3's sidebar does.
struct ThreadRow: View {
    let thread: JSON
    let project: JSON?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                projectIcon
                if !thread["pinnedAt"].isNull {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(project?["title"].string ?? "No project")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                if let machine = linkedMachine {
                    Label(machine, systemImage: "server.rack")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .lineLimit(1).fixedSize()
                }
                Spacer(minLength: 6)
                trailingStatus
            }
            .frame(height: 18)
            HStack(spacing: 6) {
                Text(thread["title"].string ?? "Untitled")
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                if metaText == nil { providerGlyph }
            }
            if let meta = metaText {
                HStack(spacing: 6) {
                    Image(systemName: branch != nil ? "arrow.triangle.branch" : "laptopcomputer")
                        .font(.system(size: 10))
                    Text(meta).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    providerGlyph
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    // MARK: Pieces

    /// The project's own icon setting when it has one (T3 uses Lucide icons, mapped here to
    /// SF Symbols), else a monogram badge standing in for its favicon.
    @ViewBuilder private var projectIcon: some View {
        let icon = project?["projectIcon"]
        if let name = icon?["name"].string, icon?["kind"].string == "lucide" {
            Image(systemName: Self.symbol(forLucide: name)).font(.system(size: 12))
                .foregroundStyle(Self.color(icon?["color"].string))
                .frame(width: 16, height: 16)
        } else if let title = project?["title"].string {
            Text(Self.monogram(title))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.orange.opacity(0.18)))
        } else {
            Image(systemName: "square.dashed").font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder private var trailingStatus: some View {
        if let (label, color) = status {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
        } else if let ms = Store.activityMs(thread) {
            Text(Self.elapsed(since: ms, now: now)).font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// T3's sidebar statuses and colours (`resolveThreadStatusPill` in
    /// `apps/web/src/components/Sidebar.logic.ts`): a question is "Awaiting Input" in indigo,
    /// an approval "Pending Approval" in amber.
    private var status: (String, Color)? {
        if let request = thread["pendingRuntimeRequest"].object {
            return request["kind"]?.string == "user_input" ? ("Awaiting Input", Self.indigo) : ("Pending Approval", Self.amber)
        }
        switch thread["activityRunStatus"].string ?? thread["status"].string {
        case "preparing", "starting": return ("Setting up", .blue)
        case "running", "queued": return ("Working", .blue)
        case "waiting": return ("Waiting", .secondary)
        case "failed": return ("Failed", .red)
        default: return nil
        }
    }

    /// T3's dark-theme indigo-300 and amber-300.
    static let indigo = Color(red: 0.65, green: 0.71, blue: 0.99)
    static let amber = Color(red: 0.99, green: 0.83, blue: 0.30)

    private var branch: String? { thread["branch"].string }

    /// The linked environment the chat runs on; nil for chats on this Mac.
    private var linkedMachine: String? { thread["environmentLabel"].string }

    /// T3's "No project" is a scratch workspace under ~/.t3/scratch.
    private var isScratch: Bool {
        project == nil || (project?["workspaceRoot"].string ?? "").hasSuffix("/.t3/scratch")
    }

    /// The branch, or for a scratch chat, the machine it runs on.
    private var metaText: String? {
        if let branch { return branch }
        return isScratch ? (linkedMachine ?? Self.machineName) : nil
    }

    @ViewBuilder private var providerGlyph: some View {
        let provider = (thread["providerInstanceId"].string ?? "").lowercased()
        if provider.contains("claude") {
            Image(systemName: "asterisk").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
        } else if provider.contains("codex") {
            Image(systemName: "hexagon").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            Image(systemName: "cpu").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private static let machineName = Host.current().localizedName ?? "This Mac"

    /// Lucide icon names T3 projects use, as the nearest SF Symbol.
    static func symbol(forLucide name: String) -> String {
        switch name {
        case "message-square-dashed": return "square.dashed"
        case "folder": return "folder"
        case "code", "code-xml": return "chevron.left.forwardslash.chevron.right"
        case "terminal": return "terminal"
        case "globe": return "globe"
        case "book", "book-open": return "book"
        case "star": return "star"
        case "heart": return "heart"
        default: return "folder"
        }
    }

    static func color(_ name: String?) -> Color {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple", "violet": return .purple
        case "pink": return .pink
        default: return .secondary
        }
    }

    static func monogram(_ name: String) -> String {
        String(name.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
    }

    /// T3's `formatElapsedDurationLabel`: just now, 12s, 5m, 3h, 2d.
    static func elapsed(since ms: Double, now: Date) -> String {
        let seconds = Int((now.timeIntervalSince1970 * 1000 - ms) / 1000)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}
