import SwiftUI

@Observable
@MainActor
final class OverlayUIState {
    var mode: PanelController.Mode = .hidden
    var notchSize = CGSize(width: 190, height: 32)
    var hasRealNotch = false
    var maxReplyHeight: CGFloat = 360
    var focusToken = 0
    var pickerOpen = false
    var pickerQuery = ""
    var pickerIndex = 0
    var hovering = false
    var draft = ""
    /// Answers being composed for a user-input request, by question id.
    var answers: [String: String] = [:]

    var onSizeChange: ((CGSize) -> Void)?
    var onClose: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onRequestFocus: (() -> Void)?
    var onPicked: (() -> Void)?
}

struct OverlayView: View {
    let store: Store
    @Bindable var ui: OverlayUIState

    private var width: CGFloat { ui.mode == .peek ? 520 : 680 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: max(ui.notchSize.height - 6, 0))
            if let b = store.protocolBreak { protocolBanner(b) }
            if store.connection != .connected {
                connectionLine
            } else {
                header
                if ui.pickerOpen && ui.mode == .expanded { picker } else {
                    reply
                    if let req = store.pendingRequest { requestCard(req) }
                    if ui.mode == .expanded { input }
                }
            }
            if let err = store.lastSendError {
                Text(err).font(.caption).foregroundStyle(.red.opacity(0.9)).lineLimit(3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(width: width, alignment: .leading)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
                .fill(.black)
        )
        .environment(\.colorScheme, .dark)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { ui.onSizeChange?($0) })
        .onHover { h in ui.hovering = h; ui.onHoverChange?(h) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Focus on the next runloop turn, after the field has been mounted.
        .onChange(of: ui.focusToken) { ui.onRequestFocus?() }
        .onChange(of: ui.pickerOpen) { ui.onRequestFocus?() }
    }

    // MARK: Pieces

    private var connectionLine: some View {
        HStack(spacing: 8) {
            Circle().fill(.gray).frame(width: 7, height: 7)
            switch store.connection {
            case .t3NotRunning: Text("T3 Code isn't running").foregroundStyle(.secondary)
            case .connecting: Text("Connecting to T3…").foregroundStyle(.secondary)
            case .failed(let r): Text("Can't reach T3: \(r)").foregroundStyle(.secondary).lineLimit(2)
            case .connected: EmptyView()
            }
        }
        .font(.callout)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(store.targetThread?["title"].string ?? "No thread")
                .font(.callout.weight(.semibold)).lineLimit(1)
            if let p = store.projectTitle(for: store.targetThread) {
                Text("· \(p)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            if store.overrideThreadId != nil {
                Text("for next prompt").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            Spacer(minLength: 8)
            Text(statusLabel).font(.caption).foregroundStyle(.secondary)
            Button { store.openTargetInT3() } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open in T3")
        }
    }

    @ViewBuilder private var reply: some View {
        if let r = store.latestReply {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(markdown(r.text))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("end")
                }
                .frame(maxHeight: min(ui.maxReplyHeight, ui.mode == .peek ? 220 : ui.maxReplyHeight))
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: r.text) { if r.streaming { proxy.scrollTo("end", anchor: .bottom) } }
            }
        } else if ui.mode == .expanded {
            Text("No reply yet").font(.callout).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func requestCard(_ req: Store.PendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if req.kind == "user_input", let questions = req.item?["questions"].array {
                ForEach(Array(questions.enumerated()), id: \.offset) { _, q in question(q) }
                HStack {
                    Spacer()
                    Button("Send answers") { submitAnswers(questions) }.keyboardShortcut(.return, modifiers: .command)
                }
            } else {
                Text(approvalTitle(req)).font(.callout.weight(.semibold))
                if let detail = approvalDetail(req) {
                    Text(detail).font(.system(size: 12, design: .monospaced)).lineLimit(8)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                }
                HStack(spacing: 8) {
                    Button("Decline  ⎋") { Task { await store.respond(decision: "decline") } }
                    Spacer()
                    Button("For session  ⌘⏎") { Task { await store.respond(decision: "acceptForSession") } }
                    Button("Accept  ⏎") { Task { await store.respond(decision: "accept") } }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.6)))
    }

    @ViewBuilder private func question(_ q: JSON) -> some View {
        let id = q["id"].string ?? ""
        VStack(alignment: .leading, spacing: 6) {
            Text(q["question"].string ?? q["header"].string ?? "Question").font(.callout.weight(.semibold))
            let options = q["options"].array ?? []
            if !options.isEmpty {
                FlowButtons(options: options.compactMap { $0["label"].string }, selected: ui.answers[id]) { label in
                    ui.answers[id] = label
                }
            }
            if options.isEmpty || q["allowCustomAnswer"].bool == true {
                TextField("Your answer", text: Binding(get: { ui.answers[id] ?? "" }, set: { ui.answers[id] = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var input: some View {
        TextField("Message \(store.targetThread?["title"].string ?? "thread")…", text: $ui.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(1...6)
            
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.1)))
            .onSubmit(sendDraft)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Send next prompt to…", text: $ui.pickerQuery)
                .textFieldStyle(.plain).font(.system(size: 14))
                .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.1)))
                .onSubmit { pick(index: ui.pickerIndex) }
                .onChange(of: ui.pickerQuery) { ui.pickerIndex = 0 }
            ForEach(Array(pickerThreads.enumerated()), id: \.offset) { i, t in
                HStack {
                    Text(t["title"].string ?? "Untitled").lineLimit(1)
                    Text(store.projectTitle(for: t) ?? "").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(i == ui.pickerIndex ? .white.opacity(0.15) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { pick(index: i) }
            }
        }
    }

    private func protocolBanner(_ b: Store.ProtocolBreak) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("T3 protocol changed").font(.callout.weight(.semibold)).foregroundStyle(.orange)
            Text(b.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Button("Dismiss") { store.dismissProtocolBreak() }
                Spacer()
                Button("Open fix draft in T3") { store.openFixDraft() }.buttonStyle(.borderedProminent)
            }.controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.orange.opacity(0.12)))
    }

    // MARK: Helpers

    var pickerThreads: [JSON] {
        let q = ui.pickerQuery.lowercased()
        return Array(store.recentThreads.filter { t in
            q.isEmpty || (t["title"].string ?? "").lowercased().contains(q)
                || (store.projectTitle(for: t) ?? "").lowercased().contains(q)
        }.prefix(10))
    }

    private func pick(index: Int) {
        let list = pickerThreads
        guard list.indices.contains(index) else { return }
        store.overrideThreadId = list[index]["id"].string
        ui.pickerOpen = false
        ui.pickerQuery = ""
        ui.pickerIndex = 0
        ui.onPicked?()
    }

    private func sendDraft() {
        let text = ui.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ui.draft = ""
        Task { await store.send(text) }
    }

    private func submitAnswers(_ questions: [JSON]) {
        var out: [String: JSON] = [:]
        for q in questions {
            guard let id = q["id"].string, let a = ui.answers[id], !a.isEmpty else { continue }
            out[id] = q["multiSelect"].bool == true ? .array([.string(a)]) : .string(a)
        }
        ui.answers = [:]
        Task { await store.answer(out) }
    }

    private func approvalTitle(_ req: Store.PendingRequest) -> String {
        switch req.item?["requestKind"].string ?? req.kind {
        case "command": return "Run this command?"
        case "file-change": return "Allow this file change?"
        case "file-read": return "Allow reading this file?"
        case "mcp-elicitation": return "\(req.item?["appName"].string ?? "A tool") is asking"
        default: return "Approval needed"
        }
    }

    private func approvalDetail(_ req: Store.PendingRequest) -> String? {
        let item = req.item
        let parts = [item?["prompt"].string, item?["reason"].string, item?["title"].string, item?["input"].string]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private var statusColor: Color {
        if store.pendingRequest != nil { return .orange }
        switch store.targetStatus {
        case "running", "starting", "preparing", "queued": return .green
        case "failed": return .red
        default: return .gray
        }
    }

    private var statusLabel: String {
        if store.pendingRequest != nil { return "needs you" }
        let s = store.targetStatus
        return s == "idle" || s == "completed" ? "" : s
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Option buttons for a question; wraps onto as many rows as needed.
private struct FlowButtons: View {
    let options: [String]
    let selected: String?
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options, id: \.self) { label in
                Button { onPick(label) } label: {
                    HStack {
                        Image(systemName: selected == label ? "largecircle.fill.circle" : "circle")
                        Text(label).multilineTextAlignment(.leading)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
            }
        }
    }
}
