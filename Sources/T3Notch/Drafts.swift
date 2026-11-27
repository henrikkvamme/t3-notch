import AppKit

/// The unsent work for one chat: the message text and its selections.
struct ChatDraft: Codable {
    var text = ""
    var clips: [Clip] = []
    var savedAt = Date()

    var isEmpty: Bool { text.isEmpty && clips.isEmpty }

    /// `other` first, as the older part.
    func after(_ other: ChatDraft) -> ChatDraft {
        guard !other.isEmpty else { return self }
        guard !isEmpty else { return other }
        // The older text is in front: this draft's chips move right by its length.
        let shift = (other.text as NSString).length + 1
        let moved = clips.map { clip -> Clip in
            var clip = clip
            clip.offset = clip.offset.map { $0 + shift }
            return clip
        }
        return ChatDraft(text: other.text + "\n" + text, clips: other.clips + moved)
    }
}

/// Unsent work, one draft for each chat. The island shows the focused chat's draft and the
/// others wait here. All of it is on disk, so a relaunch, an update or a crash loses nothing.
@MainActor
final class DraftShelf {
    private var waiting: [String: ChatDraft] = [:]
    private var saveTask: Task<Void, Never>?

    private static let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.t3notch.app", isDirectory: true)
            .appendingPathComponent("drafts.json")
    }()

    /// How long a saved selection is kept. Its picture can show private things.
    private static let clipLife: TimeInterval = 24 * 3600

    init() {
        guard !Store.demo, let data = try? Data(contentsOf: Self.file),
              let all = try? JSONDecoder().decode([String: ChatDraft].self, from: data) else { return }
        let old = Date().addingTimeInterval(-Self.clipLife)
        for (key, var draft) in all {
            if draft.savedAt < old { draft.clips = [] }
            if !draft.isEmpty { waiting[key] = draft }
        }
    }

    /// The chats that have a draft waiting.
    var chats: Set<String> { Set(waiting.keys) }

    func take(_ key: String) -> ChatDraft? { waiting.removeValue(forKey: key) }

    /// Adds `draft` to what waits for the chat, after it.
    func put(_ draft: ChatDraft, for key: String) {
        guard !draft.isEmpty else { return }
        waiting[key] = draft.after(waiting[key] ?? ChatDraft())
    }

    /// Writes every draft to disk a moment from now: the waiting ones and the island's own.
    func save(live: ChatDraft, owner: String?) {
        guard !Store.demo else { return }
        var all = waiting
        if let owner, !live.isEmpty { all[owner] = live }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            Self.write(all)
        }
    }

    /// The same, at once: the app is about to quit.
    func saveNow(live: ChatDraft, owner: String?) {
        guard !Store.demo else { return }
        saveTask?.cancel()
        var all = waiting
        if let owner, !live.isEmpty { all[owner] = live }
        Self.write(all)
    }

    private static func write(_ all: [String: ChatDraft]) {
        let manager = FileManager.default
        guard !all.isEmpty else { try? manager.removeItem(at: file); return }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        // Only you read it.
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

extension Clip: Codable {
    private enum CodingKeys: String, CodingKey { case id, png, context, comment, offset }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let png = try c.decode(Data.self, forKey: .png)
        self.init(id: try c.decode(UUID.self, forKey: .id), png: png, thumbnail: NSImage(data: png) ?? NSImage(),
                  context: try c.decodeIfPresent(PickContext.self, forKey: .context),
                  comment: try c.decodeIfPresent(String.self, forKey: .comment) ?? "",
                  offset: try c.decodeIfPresent(Int.self, forKey: .offset))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(png, forKey: .png)
        try c.encodeIfPresent(context, forKey: .context)
        try c.encode(comment, forKey: .comment)
        try c.encodeIfPresent(offset, forKey: .offset)
    }
}
