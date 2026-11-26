import Foundation

/// Answers to a T3 user-input request, built exactly as T3's own clients build them
/// (`packages/client-runtime/src/state/pendingUserInput.ts`), so the agent gets the same
/// answer from the island as from the T3 window.
struct AnswerDraft: Equatable {
    /// Typed text; nil until the user types (the field then shows `initialAnswer`).
    var custom: String?
    /// Picked option values, in the order picked.
    var picks: [String] = []
}

struct UserInputQuestion {
    let id: String
    let title: String
    let options: [(value: String?, label: String)]
    let multiSelect: Bool
    let allowCustomAnswer: Bool
    let initialAnswer: String?
    let required: Bool?

    init(_ q: JSON) {
        id = q["id"].string ?? ""
        title = q["question"].string ?? q["header"].string ?? "Question"
        options = (q["options"].array ?? []).compactMap { o in o["label"].string.map { (o["value"].string, $0) } }
        multiSelect = q["multiSelect"].bool == true
        allowCustomAnswer = q["allowCustomAnswer"].bool != false
        initialAnswer = q["initialAnswer"].string
        required = q["required"].bool
    }

    /// The value T3 expects for an option: its `value`, or its label when it has none.
    func value(of option: (value: String?, label: String)) -> String {
        option.value ?? option.label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text the field shows.
    func customText(_ d: AnswerDraft) -> String { d.custom ?? initialAnswer ?? "" }

    private func trimmedOrNil(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Picks that name an offered option, without repeats, in pick order.
    private func validPicks(_ d: AnswerDraft) -> [String] {
        let offered = Set(options.map(value(of:)))
        var seen = Set<String>()
        return d.picks.filter { offered.contains($0) && seen.insert($0).inserted }
    }

    /// The answer to send, or nil while the question is unanswered.
    func resolve(_ d: AnswerDraft) -> JSON? {
        // With an initial answer the text is kept as typed, even blank; else it is trimmed.
        let custom: String? = !allowCustomAnswer ? nil
            : initialAnswer != nil ? customText(d)
            : trimmedOrNil(d.custom)
        if let custom, !custom.isEmpty { return .string(custom) }
        if required == false && options.isEmpty { return .string("") }
        let picks = validPicks(d)
        if multiSelect {
            // Checking nothing answers "none of these" unless a choice is required.
            if !picks.isEmpty { return .array(picks.map(JSON.string)) }
            return custom.map(JSON.string) ?? (required == true ? nil : .array([]))
        }
        return (picks.first ?? custom).map(JSON.string)
    }

    /// Typing replaces the picks once the text is not blank.
    func settingCustom(_ text: String, on d: AnswerDraft) -> AnswerDraft {
        guard allowCustomAnswer else { return d }
        let keep = initialAnswer == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return AnswerDraft(custom: text, picks: keep ? validPicks(d) : [])
    }

    /// Picking clears the typed text. A multi-select toggles; a single select replaces.
    func toggling(_ value: String, on d: AnswerDraft) -> AnswerDraft {
        guard options.contains(where: { self.value(of: $0) == value }) else { return d }
        var picks = validPicks(d)
        if multiSelect {
            if let i = picks.firstIndex(of: value) { picks.remove(at: i) } else { picks.append(value) }
        } else {
            picks = [value]
        }
        return AnswerDraft(custom: "", picks: picks)
    }

    /// Typed text hides the picks.
    func isPicked(_ value: String, in d: AnswerDraft) -> Bool {
        if allowCustomAnswer, trimmedOrNil(customText(d)) != nil { return false }
        return validPicks(d).contains(value)
    }

    /// Every question's answer, or nil while any is unanswered.
    static func answers(_ questions: [UserInputQuestion], drafts: (String) -> AnswerDraft) -> [String: JSON]? {
        var out: [String: JSON] = [:]
        for q in questions {
            guard let a = q.resolve(drafts(q.id)) else { return nil }
            out[q.id] = a
        }
        return out
    }
}
