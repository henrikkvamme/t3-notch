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
    /// Each picker row's frame, so the selection highlight can slide between them.
    var pickerRowFrames: [Int: CGRect] = [:]
    var hovering = false
    var draft = ""
    /// Screen clips waiting to go with the next message.
    var clips: [Clip] = []
    /// Removed clips, newest last, with their old position, for ⌘Z / ⌃Z.
    var removedClips: [(clip: Clip, index: Int)] = []
    /// The element level picked while clipping; kept across clipping until the message is sent.
    var clipDepth = 0
    /// The draft when the last clip was removed; undo restores clips only while it is unchanged,
    /// so ⌘Z after typing still undoes typing.
    var draftAtClipRemoval = ""

    /// Brings back the most recently removed clip. False when there is nothing to restore.
    func undoClipRemoval() -> Bool {
        guard let last = removedClips.last, draft == draftAtClipRemoval else { return false }
        removedClips.removeLast()
        clips.insert(last.clip, at: min(last.index, clips.count))
        return true
    }
    /// Permissions clipping still needs; each shows as a button that opens its settings.
    var missingPermissions: [Permission] = []
    var onOpenPermission: ((Permission) -> Void)?
    /// Answers being composed, keyed by request and question id, so a new request or another
    /// chat never inherits them.
    var answerDrafts: [String: AnswerDraft] = [:]
    /// The island's frame in the hosting view (top-left origin), for click-through.
    var islandFrame: CGRect = .zero
    /// An app is fullscreen on the notch screen; the status dot hides.
    var notchScreenFullscreen = false
    /// Hidden with ⌥⇧Space (or the menu); remembered across launches.
    var dotHiddenByUser = UserDefaults.standard.bool(forKey: "statusDotHidden") {
        didSet { UserDefaults.standard.set(dotHiddenByUser, forKey: "statusDotHidden") }
    }
    /// The reply's scroll position, so ⌃J/⌃K can scroll it from the keyboard.
    var replyScroll = ScrollPosition(edge: .top)
    var replyOffset: CGFloat = 0
    var replyMaxOffset: CGFloat = 0
    /// The reply text's laid-out height; the scroll area is sized to it (up to a cap).
    var replyTextHeight: CGFloat = 0

    var onClose: (() -> Void)?
    /// Set at launch; shows the update button when a newer release exists.
    var updater: Updater?
    var onOpenInT3: (() -> Void)?
    var onRequestFocus: (() -> Void)?
    /// Typing started or stopped; the controller shows or hides the text cursor.
    var onTypingChange: ((Bool) -> Void)?
    var onIslandFrameChange: (() -> Void)?
}

/// The island: a black shape that grows out of the notch, with glass controls inside.
struct OverlayView: View {
    let store: Store
    @Bindable var ui: OverlayUIState
    @Namespace private var glass
    /// The clip thumbnail under the pointer, which shows a preview and a remove mark.
    @State private var hoveredClip: UUID?

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
         store.latestReply?.text.count, store.latestReply?.images.count, store.latestReply?.thinking, store.targetThreadId, ui.clips.count, ui.missingPermissions.count, hoveredClip]
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
                            if ui.mode == .expanded && !ui.missingPermissions.isEmpty {
                                permissionRow.padding(.top, 10).transition(.blurReplace)
                            }
                            if ui.mode == .expanded && !ui.clips.isEmpty {
                                clipRow.padding(.top, 10).transition(.blurReplace)
                            }
                            if ui.mode == .expanded {
                                input.padding(.top, ui.draft.isEmpty ? 0 : 10).transition(.blurReplace)
                            }
                        }
                    }
                }
                if case .failed(let message) = ui.updater?.state {
                    Text(message).font(.caption).foregroundStyle(.red.opacity(0.9)).lineLimit(3)
                        .transition(.blurReplace)
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
        let title = store.targetThread?["title"].string
        let project = store.projectTitle(for: store.targetThread)
        return HStack(spacing: 8) {
            if let title {
                StatusDotGlyph(indicator: store.indicator == .hidden ? .idle : store.indicator)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    .contentTransition(.interpolate)
                    .id(store.targetThreadId) // a new thread blurs in instead of morphing letters
                    .transition(.blurReplace)
                if let project {
                    Text(project).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .transition(.blurReplace)
                }
            }
            Spacer(minLength: 8)
            // Own container with no merge distance, so the two circles stay apart.
            GlassEffectContainer(spacing: 0) {
                // Negative spacing keeps the circles 6pt apart while their larger hit areas touch.
                HStack(spacing: -6) {
                    if let updater = ui.updater, updater.availableVersion != nil {
                        updateButton(updater).transition(.blurReplace.combined(with: .scale(0.6)))
                    }
                    headerButton("minus") { ui.onClose?() }
                    headerButton("arrow.up.forward") { ui.onOpenInT3?() }
                }
            }
            // Lay out as the 22pt circles; the extra hit area overhangs without moving anything.
            .padding(.vertical, -6)
            .padding(.trailing, -6)
        }
        .animation(Motion.content, value: title)
    }

    @ViewBuilder private var reply: some View {
        if let r = store.latestReply {
            ScrollView {
                // One view per message: a new message slides the old one up and out while
                // the new one rises in, both crossfading through a blur.
                ZStack(alignment: .topLeading) {
                    replyText(r)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.identity) // streamed text grows; it should not crossfade
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                            // Only the current message sizes the reply, not one animating out.
                            if r.id == store.latestReply?.id { ui.replyTextHeight = h }
                        }
                        .id(r.id)
                        .transition(MessageChange())
                }
                .animation(Motion.message, value: r.id)
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
            if !r.images.isEmpty {
                ReplyImages(store: store, images: r.images)
                    .transition(.blurReplace)
            }
        } else if ui.mode == .expanded {
            Text("No reply yet").font(.callout).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func requestCard(_ req: Store.PendingRequest) -> some View {
        // A question in T3's indigo, an approval in amber, with T3's sidebar labels.
        let isQuestion = req.kind == "user_input"
        let stateColor = isQuestion ? ThreadRow.indigo : ThreadRow.amber
        VStack(alignment: .leading, spacing: 8) {
            Text(isQuestion ? "Awaiting Input" : "Pending Approval")
                .font(.caption.weight(.semibold))
                .foregroundStyle(stateColor)
            if req.kind == "user_input", let questions = req.item?["questions"].array {
                let parsed = questions.map(UserInputQuestion.init)
                ForEach(Array(parsed.enumerated()), id: \.offset) { _, q in question(q, request: req.id) }
                let answers = UserInputQuestion.answers(parsed) { draft(req.id, $0) }
                HStack {
                    Spacer()
                    Button("Send answers") { if let answers { submitAnswers(answers, request: req.id) } }
                        .disabled(answers == nil) // as in T3: every question needs an answer
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
        .glassEffect(.regular.tint(stateColor.opacity(0.22)), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(stateColor.opacity(0.35), lineWidth: 1))
        .glassEffectID("request", in: glass)
    }

    @ViewBuilder private func question(_ q: UserInputQuestion, request: String) -> some View {
        let d = draft(request, q.id)
        let key = Self.draftKey(request, q.id)
        VStack(alignment: .leading, spacing: 6) {
            Text(q.title).font(.callout.weight(.semibold))
            if !q.options.isEmpty {
                OptionList(options: q.options.map { (q.value(of: $0), $0.label) }, multi: q.multiSelect,
                           selected: q.options.map(q.value(of:)).filter { q.isPicked($0, in: d) }) { value in
                    withAnimation(Motion.snappy) { ui.answerDrafts[key] = q.toggling(value, on: draft(request, q.id)) }
                }
            }
            if q.allowCustomAnswer {
                TextField(q.options.isEmpty ? "Your answer" : "Or type your own answer",
                          text: Binding(get: { q.customText(draft(request, q.id)) },
                                        set: { ui.answerDrafts[key] = q.settingCustom($0, on: draft(request, q.id)) }),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
            }
        }
    }

    private static func draftKey(_ request: String, _ question: String) -> String { request + "\u{1F}" + question }

    private func draft(_ request: String, _ question: String) -> AnswerDraft {
        ui.answerDrafts[Self.draftKey(request, question)] ?? AnswerDraft()
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
            .glassEffect(typing ? .regular.interactive() : .identity, in: .rect(cornerRadius: 16))
            .glassEffectID("field", in: glass) // morphs into the ⌘K search field
            .frame(height: typing ? nil : 0, alignment: .top)
            .clipped()
            .opacity(typing ? 1 : 0)
            .blur(radius: typing ? 0 : 6)
            .scaleEffect(typing ? 1 : 0.96, anchor: .top)
            .onSubmit(sendDraft)
            // Collapsing can drop keyboard focus; take it back so the next key types.
            .onChange(of: typing) { _, now in
                if !now { ui.onRequestFocus?() }
                ui.onTypingChange?(now)
            }
            .animation(Motion.open, value: typing)
    }

    private var picker: some View {
        ChatPicker(store: store, ui: ui, glass: glass, onPick: pick(index:))
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

    private func pick(index: Int) {
        let list = store.pickerRows(query: ui.pickerQuery)
        guard list.indices.contains(index) else { return }
        withAnimation(Motion.content) {
            store.focusedThreadId = list[index]["id"].string
            ui.pickerOpen = false
            ui.pickerQuery = ""
            ui.pickerIndex = 0
        }
        ui.onRequestFocus?()
    }

    private func sendDraft() {
        let text = ui.draft
        let images = ui.clips.map(\.png)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        withAnimation(Motion.content) { ui.draft = ""; ui.clips = []; ui.removedClips = []; ui.clipDepth = 0 }
        Task { await store.send(text, images: images) }
        ui.onClose?() // sent: tuck the island away and hand focus back
    }

    private func submitAnswers(_ answers: [String: JSON], request: String) {
        ui.answerDrafts = ui.answerDrafts.filter { !$0.key.hasPrefix(request + "\u{1F}") }
        Task { await store.answer(answers) }
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

    /// One button per missing permission; each opens System Settings on that list.
    private var permissionRow: some View {
        HStack(spacing: 8) {
            ForEach(ui.missingPermissions) { permission in
                Button { ui.onOpenPermission?(permission) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                        Text(permission.title).font(.callout)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular.tint(.orange.opacity(0.25)).interactive(), in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .transition(.blurReplace.combined(with: .scale(0.9)))
            }
        }
        .animation(Motion.content, value: ui.missingPermissions)
    }

    /// Clips waiting to be sent; click one to remove it.
    private var clipRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(ui.clips) { clip in
                    let hovered = hoveredClip == clip.id
                    Image(nsImage: clip.thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.15)))
                        .overlay {
                            // A press removes the clip.
                            if hovered {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                    .frame(width: 22, height: 22)
                                    .glassEffect(.regular, in: .circle)
                                    .transition(.blurReplace.combined(with: .scale(0.6)))
                            }
                        }
                        .contentShape(Rectangle())
                        .onHover { inside in
                            withAnimation(Motion.snappy) {
                                if inside { hoveredClip = clip.id } else if hoveredClip == clip.id { hoveredClip = nil }
                            }
                        }
                        .onTapGesture {
                            withAnimation(Motion.content) {
                                if let i = ui.clips.firstIndex(of: clip) {
                                    ui.removedClips.append((clip, i))
                                    ui.draftAtClipRemoval = ui.draft
                                    ui.clips.remove(at: i)
                                }
                                if hoveredClip == clip.id { hoveredClip = nil }
                            }
                        }
                        .transition(.blurReplace.combined(with: .scale(0.8)))
                }
            }
            // A larger preview of the hovered clip, under the row.
            if let clip = ui.clips.first(where: { $0.id == hoveredClip }) {
                Image(nsImage: clip.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 240, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .id(clip.id)
                    .transition(.blurReplace)
            }
        }
        .animation(Motion.content, value: ui.clips)
        .animation(Motion.content, value: hoveredClip)
    }

    /// A reply in full text; the agent's thinking or current step dimmed; and before its
    /// first step, a softly pulsing "Thinking".
    @ViewBuilder private func replyText(_ r: Store.Reply) -> some View {
        // Trimmed: replies often end in blank lines, which would show as empty space.
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.thinking && text.isEmpty {
            ThinkingLabel()
        } else if r.thinking {
            Text(markdown(text))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            ReplyContent(text: text, baseDir: store.targetThread?["worktreePath"].string
                         ?? store.projects[store.targetThread?["projectId"].string ?? ""]?["workspaceRoot"].string)
        }
    }

    /// A solid green circle, so it stands out from the grey controls: a newer release is out.
    /// One click installs it and relaunches; a spinner shows while it installs.
    private func updateButton(_ updater: Updater) -> some View {
        let installing: Bool = { if case .installing = updater.state { return true }; return false }()
        return Button { updater.install() } label: {
            ZStack {
                Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.38))
                if installing {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: "arrow.down").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            .shadow(color: Color(red: 0.16, green: 0.78, blue: 0.38).opacity(0.6), radius: 6)
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(installing)
    }

    /// A bare icon inside a 34pt hit area; it brightens under the pointer.
    private func headerButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        HeaderIcon(symbol: symbol, action: action)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Options for a question, with a radio symbol that morphs on selection.
private struct OptionList: View {
    let options: [(value: String, label: String)]
    /// Checkboxes in place of radio buttons.
    let multi: Bool
    let selected: [String]
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options, id: \.value) { option in
                let on = selected.contains(option.value)
                Button { onPick(option.value) } label: {
                    HStack {
                        Image(systemName: multi ? (on ? "checkmark.square.fill" : "square")
                                                : (on ? "largecircle.fill.circle" : "circle"))
                            .contentTransition(.symbolEffect(.replace))
                        Text(option.label).multilineTextAlignment(.leading)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
            }
        }
    }
}

/// A message replacing another: the old one leaves upward, the new one arrives from
/// below, both fading through a blur.
struct MessageChange: Transition {
    var distance: CGFloat = 18

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .offset(y: phase == .willAppear ? distance : phase == .didDisappear ? -distance : 0)
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : 8)
    }
}

/// "Thinking", gently pulsing, while a run has started but has no step or reply yet.
private struct ThinkingLabel: View {
    @State private var dim = false

    var body: some View {
        Text("Thinking")
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .opacity(dim ? 0.45 : 0.9)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// Images of the shown exchange as thumbnails; hovering one shows it larger underneath.
private struct ReplyImages: View {
    let store: Store
    let images: [JSON]
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(images.compactMap { $0["id"].string }, id: \.self) { id in
                    thumbnail(id)
                        .task(id: id) { await store.loadImage(id) }
                        .onHover { inside in
                            withAnimation(Motion.snappy) {
                                if inside { hovered = id } else if hovered == id { hovered = nil }
                            }
                        }
                }
            }
            if let id = hovered, let image = store.attachmentImages[id] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 240, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .id(id)
                    .transition(.blurReplace)
            }
        }
        .animation(Motion.content, value: hovered)
    }

    @ViewBuilder private func thumbnail(_ id: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            if let image = store.attachmentImages[id] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                shape.fill(.white.opacity(0.08))
            }
        }
        .frame(width: 64, height: 44)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.15)))
        .animation(Motion.content, value: store.attachmentImages[id] != nil)
    }
}

/// A header icon with no background: grey, white under the pointer.
private struct HeaderIcon: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
    }
}
