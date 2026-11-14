import SwiftUI

@Observable
@MainActor
final class OverlayUIState {
    var mode: PanelController.Mode = .hidden
    var notchSize = CGSize(width: 190, height: 32)
    var hasRealNotch = false
    var maxReplyHeight: CGFloat = 360
    var pickerOpen = false
    var pickerQuery = ""
    var pickerIndex = 0
    /// How many rows the picker shows after filtering, so key navigation stays in range.
    var pickerCount = 0
    var hovering = false
    var draft = ""
    /// Answers being composed for a user-input request, by question id.
    var answers: [String: String] = [:]
    /// The island's frame in the hosting view (top-left origin), for click-through.
    var islandFrame: CGRect = .zero
    /// The reply's scroll position, so ⌃J/⌃K can scroll it from the keyboard.
    var replyScroll = ScrollPosition(edge: .top)
    var replyOffset: CGFloat = 0
    var replyMaxOffset: CGFloat = 0
    /// The reply text's laid-out height; the scroll area is sized to it (up to a cap).
    var replyTextHeight: CGFloat = 0

    var onClose: (() -> Void)?
    var onRequestFocus: (() -> Void)?
    var onIslandFrameChange: (() -> Void)?
}

/// The island: a black shape that grows out of the notch, with glass controls inside.
struct OverlayView: View {
    let store: Store
    @Bindable var ui: OverlayUIState
    @Namespace private var glass
    @Namespace private var selection

    private var shown: Bool { ui.mode != .hidden }
    private var openWidth: CGFloat { ui.mode == .peek ? 520 : 680 }
    /// The real notch's bottom corners are about this round.
    private var notchRadius: CGFloat { ui.hasRealNotch ? 10 : 12 }

    var body: some View {
        island
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    // MARK: Island

    private var island: some View {
        content
            .frame(width: openWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // Content arrives after the shape opens and leaves before it closes.
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 12)
            .scaleEffect(shown ? 1 : 0.9, anchor: .top)
            .animation(shown ? Motion.open.delay(0.06) : .smooth(duration: 0.16), value: shown)
            // The shape: notch-sized when hidden, content-sized when shown.
            .frame(width: shown ? openWidth : ui.notchSize.width,
                   height: shown ? nil : ui.notchSize.height, alignment: .top)
            .background(.black)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: shown ? 26 : notchRadius,
                                              bottomTrailingRadius: shown ? 26 : notchRadius,
                                              style: .continuous))
            .shadow(color: .black.opacity(shown ? 0.45 : 0), radius: shown ? 24 : 0, y: shown ? 10 : 0)
            // A drawn notch on screens without one fades rather than sitting there black.
            .opacity(shown || ui.hasRealNotch ? 1 : 0)
            .animation(Motion.content, value: layoutKey)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                ui.islandFrame = frame
                ui.onIslandFrameChange?()
            }
    }

    /// Changes inside the open island that should animate its size.
    private var layoutKey: [AnyHashable] {
        [store.connection.hashValue, store.protocolBreak?.reason, store.pendingRequest?.id,
         store.pendingRequest?.item != nil, ui.pickerOpen, ui.pickerQuery, store.lastSendError,
         store.latestReply?.text.count, store.targetThreadId, store.overrideThreadId]
    }

    private var content: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear.frame(height: max(ui.notchSize.height - 6, 0))
                if let b = store.protocolBreak {
                    protocolBanner(b).transition(.blurReplace.combined(with: .move(edge: .top)))
                }
                if store.connection != .connected {
                    connectionLine.transition(.blurReplace)
                } else {
                    header
                    if ui.pickerOpen && ui.mode == .expanded {
                        picker.transition(.blurReplace)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 10) {
                                reply.transition(.blurReplace)
                                if let req = store.pendingRequest {
                                    requestCard(req)
                                        .transition(.blurReplace.combined(with: .scale(0.96, anchor: .top)))
                                }
                            }
                            // The input takes no space, spacing included, until you type.
                            if ui.mode == .expanded {
                                input.padding(.top, ui.draft.isEmpty ? 0 : 10).transition(.blurReplace)
                            }
                        }
                    }
                }
                if let err = store.lastSendError {
                    Text(err).font(.caption).foregroundStyle(.red.opacity(0.9)).lineLimit(3)
                        .transition(.blurReplace)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    // MARK: Pieces

    private var connectionLine: some View {
        HStack(spacing: 8) {
            StatusDotGlyph(indicator: .idle)
            Text(connectionText).foregroundStyle(.secondary).lineLimit(2)
                .contentTransition(.opacity)
        }
        .font(.callout)
        .animation(Motion.content, value: connectionText)
    }

    private var connectionText: String {
        switch store.connection {
        case .t3NotRunning: return "T3 Code isn't running"
        case .connecting: return "Connecting to T3…"
        case .failed(let r): return "Can't reach T3: \(r)"
        case .connected: return ""
        }
    }

    private var header: some View {
        let title = store.targetThread?["title"].string ?? "No thread"
        let project = store.projectTitle(for: store.targetThread)
        return HStack(spacing: 8) {
            StatusDotGlyph(indicator: store.indicator == .hidden ? .idle : store.indicator)
            Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                .contentTransition(.interpolate)
                .id(store.targetThreadId) // a new thread blurs in instead of morphing letters
                .transition(.blurReplace)
            if let project {
                Text("· \(project)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .transition(.blurReplace)
            }
            if store.overrideThreadId != nil {
                Text("for next prompt").font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .glassEffect(.regular.tint(.blue.opacity(0.35)), in: .capsule)
                    .transition(.blurReplace.combined(with: .scale(0.8)))
            }
            Spacer(minLength: 8)
            Button { store.openTargetInT3() } label: {
                Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("Open in T3  ⌘O")
        }
        .animation(Motion.content, value: title)
        .animation(Motion.content, value: store.overrideThreadId)
    }

    @ViewBuilder private var reply: some View {
        if let r = store.latestReply {
            ScrollView {
                Text(markdown(r.text))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.identity) // streamed text grows; it should not crossfade
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { ui.replyTextHeight = $0 }
            }
            .scrollIndicators(.never)
            .scrollPosition($ui.replyScroll)
            .onScrollGeometryChange(for: [CGFloat].self, of: { g in
                [g.contentOffset.y, max(0, g.contentSize.height - g.containerSize.height)]
            }) { _, v in
                ui.replyOffset = v[0]
                ui.replyMaxOffset = v[1]
            }
            // Exactly the text's height, capped; a ScrollView's own ideal height can go stale.
            .frame(height: min(ui.replyTextHeight, ui.mode == .peek ? min(220, ui.maxReplyHeight) : ui.maxReplyHeight))
            .onChange(of: r.text) {
                if r.streaming { withAnimation(Motion.content) { ui.replyScroll.scrollTo(edge: .bottom) } }
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
                    Button("Send answers") { submitAnswers(questions) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            } else {
                Text(approvalTitle(req)).font(.callout.weight(.semibold))
                if let detail = approvalDetail(req) {
                    Text(detail).font(.system(size: 12, design: .monospaced)).lineLimit(8)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35)))
                        .transition(.blurReplace)
                }
                HStack(spacing: 8) {
                    Button("Decline  ⎋") { Task { await store.respond(decision: "decline") } }
                        .buttonStyle(.glass)
                    Spacer()
                    Button("For session  ⌘⏎") { Task { await store.respond(decision: "acceptForSession") } }
                        .buttonStyle(.glass)
                    Button("Accept  ⏎") { Task { await store.respond(decision: "accept") } }
                        .buttonStyle(.glassProminent)
                        .tint(.orange)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.22)), in: .rect(cornerRadius: 18))
        .glassEffectID("request", in: glass)
    }

    @ViewBuilder private func question(_ q: JSON) -> some View {
        let id = q["id"].string ?? ""
        VStack(alignment: .leading, spacing: 6) {
            Text(q["question"].string ?? q["header"].string ?? "Question").font(.callout.weight(.semibold))
            let options = q["options"].array ?? []
            if !options.isEmpty {
                OptionList(options: options.compactMap { $0["label"].string }, selected: ui.answers[id]) { label in
                    withAnimation(Motion.snappy) { ui.answers[id] = label }
                }
            }
            if options.isEmpty || q["allowCustomAnswer"].bool == true {
                TextField("Your answer", text: Binding(get: { ui.answers[id] ?? "" }, set: { ui.answers[id] = $0 }))
                    .textFieldStyle(.plain)
                    .padding(8)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
            }
        }
    }

    /// The input stays out of sight until you type: it is mounted (so it holds keyboard
    /// focus) but collapsed to nothing, then springs open with the first character.
    private var input: some View {
        let typing = !ui.draft.isEmpty
        return TextField("", text: $ui.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(1...6)
            .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .glassEffect(typing ? .regular.interactive() : .identity, in: .rect(cornerRadius: 16))
            .glassEffectID("field", in: glass) // morphs into the ⌘K search field
            .frame(height: typing ? nil : 0, alignment: .top)
            .clipped()
            .opacity(typing ? 1 : 0)
            .blur(radius: typing ? 0 : 6)
            .scaleEffect(typing ? 1 : 0.96, anchor: .top)
            .tint(typing ? .accentColor : .clear) // no stray cursor while collapsed
            .onSubmit(sendDraft)
            // Collapsing can drop keyboard focus; take it back so the next key types.
            .onChange(of: typing) { _, now in if !now { ui.onRequestFocus?() } }
            .animation(Motion.open, value: typing)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Send next prompt to…", text: $ui.pickerQuery)
                .textFieldStyle(.plain).font(.system(size: 14))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                .glassEffectID("field", in: glass)
                .onSubmit { pick(index: ui.pickerIndex) }
                .onChange(of: ui.pickerQuery) { withAnimation(Motion.snappy) { ui.pickerIndex = 0 } }
            ForEach(Array(pickerThreads.enumerated()), id: \.element["id"].string) { i, t in
                HStack {
                    Text(t["title"].string ?? "Untitled").lineLimit(1)
                    Text(store.projectTitle(for: t) ?? "").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background {
                    // One highlight that slides between rows.
                    if i == ui.pickerIndex {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.white.opacity(0.14))
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { pick(index: i) }
                .transition(.blurReplace)
            }
        }
        .animation(Motion.snappy, value: ui.pickerIndex)
        .animation(Motion.content, value: ui.pickerQuery)
        .onChange(of: pickerThreads.count, initial: true) { _, n in ui.pickerCount = n }
    }

    private func protocolBanner(_ b: Store.ProtocolBreak) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("T3 protocol changed").font(.callout.weight(.semibold)).foregroundStyle(.orange)
            Text(b.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Button("Dismiss") { withAnimation(Motion.content) { store.dismissProtocolBreak() } }
                    .buttonStyle(.glass)
                Spacer()
                Button("Open fix draft in T3") { store.openFixDraft() }
                    .buttonStyle(.glassProminent).tint(.orange)
            }.controlSize(.small)
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 18))
        .glassEffectID("banner", in: glass)
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
        withAnimation(Motion.content) {
            store.overrideThreadId = list[index]["id"].string
            ui.pickerOpen = false
            ui.pickerQuery = ""
            ui.pickerIndex = 0
        }
        ui.onRequestFocus?()
    }

    private func sendDraft() {
        let text = ui.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(Motion.content) { ui.draft = "" }
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

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Options for a question, with a radio symbol that morphs on selection.
private struct OptionList: View {
    let options: [String]
    let selected: String?
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options, id: \.self) { label in
                Button { onPick(label) } label: {
                    HStack {
                        Image(systemName: selected == label ? "largecircle.fill.circle" : "circle")
                            .contentTransition(.symbolEffect(.replace))
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
