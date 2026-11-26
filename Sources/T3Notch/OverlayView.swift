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
    /// A selection is on its way to the island: its place in the row is kept free.
    var landing = false
    /// That place in the island's window, top-left origin.
    var landingSlot: CGRect?
    /// The selection whose comment is open under the row.
    var editingClip: UUID?
    var draft = ""
    /// Messages on their way to T3. They left the draft, but the focused chat must stay until
    /// each one has its chat (see `Store.holdsTarget`).
    var sending = 0
    /// The input bar shows: there is text or a selection, or the chat has nothing to show yet.
    var inputShows = false
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
    /// The draft is about to leave for the chat.
    var onDraftSent: (() -> Void)?
    /// Typing started or stopped; the controller shows or hides the text cursor.
    var onTypingChange: ((Bool) -> Void)?
    var onIslandFrameChange: (() -> Void)?

    /// The welcome tour's step while it shows, else nil.
    var onboarding: OnboardingStep?
    /// The tour's keycaps glow: the shortcut was just pressed.
    var onboardingKeysLit = false
    /// Keys held down right now, by keycap symbol, so the tour's keycaps go down with them.
    var onboardingHeld: Set<String> = []
    /// The tour's Select step: a scroll changed the level, so the step stops asking for one.
    var onboardingScrolled = false
    /// The keys card's shortcuts tried so far.
    var onboardingTried: Set<OnboardingTip> = []
    /// Counts the tour's successes; each change plays the success moment.
    var onboardingSuccess = 0
    var onOnboardingStep: ((OnboardingStep) -> Void)?
    var onOnboardingPickerClosed: (() -> Void)?
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
            // The tour's successes stretch the island a little and let it spring back.
            .modifier(IslandBreath(trigger: ui.onboardingSuccess, big: ui.onboarding == .done))
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
         store.latestReply?.text.count, store.latestReply?.images.count, store.latestReply?.thinking, store.targetThreadId, ui.clips.count, ui.missingPermissions.count, hoveredClip,
         ui.onboarding, ui.onboardingKeysLit, ui.onboardingTried]
    }

    private var content: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear.frame(height: max(ui.notchSize.height - 6, 0))
                if let b = store.protocolBreak {
                    protocolBanner(b).transition(.blurReplace.combined(with: .move(edge: .top)))
                }
                if let step = ui.onboarding, !(step == .chats && ui.pickerOpen && store.connection == .connected) {
                    OnboardingView(store: store, ui: ui, step: step) { ui.onOnboardingStep?($0) }
                        .transition(.blurReplace)
                } else if store.connection != .connected {
                    connectionLine.transition(.blurReplace)
                } else {
                    header
                    if ui.pickerOpen && ui.mode == .expanded {
                        if ui.onboarding == .chats {
                            Text("Move with ↑ and ↓, pick with ⏎.").font(.callout).foregroundStyle(.secondary)
                                .transition(.blurReplace)
                        }
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
                            if ui.mode == .expanded && (!ui.clips.isEmpty || ui.landing) {
                                clipRow.padding(.top, 10).transition(.blurReplace)
                            }
                            if ui.mode == .expanded {
                                input.padding(.top, ui.inputShows ? 10 : 0).transition(.blurReplace)
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
        .onChange(of: ui.pickerOpen) { was, open in
            if was && !open { ui.onOnboardingPickerClosed?() }
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
        let machine = store.environmentLabel(for: store.targetThread)
        let project = [store.projectTitle(for: store.targetThread), machine].compactMap { $0 }
            .joined(separator: " · ")
        let subtitle: String? = project.isEmpty ? nil : project
        return HStack(spacing: 8) {
            if let title {
                StatusDotGlyph(indicator: store.indicator == .hidden ? .idle : store.indicator)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    .contentTransition(.interpolate)
                    .id(store.targetThreadId) // a new thread blurs in instead of morphing letters
                    .transition(.blurReplace)
                if let project = subtitle {
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

    /// The input shows whenever the island is open on a chat, so you see where you type. It
    /// is out of sight only without a chat, and while the agent asks for an answer and you
    /// have typed nothing: then it is mounted (so it holds keyboard focus) but collapsed.
    private var input: some View {
        let typing = !ui.draft.isEmpty || !ui.clips.isEmpty
            || (store.pendingRequest == nil && store.targetThreadId != nil)
        return TextField("Message", text: $ui.draft, axis: .vertical)
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
            .onChange(of: typing, initial: true) { _, now in
                ui.inputShows = now
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
            store.focusedThreadId = list[index]["key"].string
            ui.pickerOpen = false
            ui.pickerQuery = ""
            ui.pickerIndex = 0
        }
        ui.onRequestFocus?()
    }

    private func sendDraft() {
        let text = ui.draft
        let clips = ui.clips
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !clips.isEmpty else { return }
        // Keep the draft when the selections cannot go in one message.
        guard Store.clipPlan(clips) != nil else {
            store.lastSendError = "Too many or too large selections for one message. Remove some and send again."
            return
        }
        ui.onDraftSent?()
        withAnimation(Motion.content) { ui.draft = ""; ui.clips = []; ui.removedClips = []; ui.clipDepth = 0 }
        ui.sending += 1
        let to = store.targetThreadId
        Task {
            let sent = await store.send(text, steer: Settings.enterSteers, clips: clips, to: to)
            ui.sending -= 1
            // Not sent: the message and its selections come back.
            if !sent {
                ui.draft = ui.draft.isEmpty ? text : text + "\n" + ui.draft
                ui.clips = clips + ui.clips
            }
            store.focusLastOpened()
        }
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

    /// Selections waiting to be sent, as chips: a small picture and the comment, or what the
    /// selection is. A click on one opens its comment; its ✕ removes it.
    private var clipRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChipFlow(spacing: 6) {
                ForEach(ui.clips) { clip in
                    let hovered = hoveredClip == clip.id
                    let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                    HStack(spacing: 6) {
                        Image(nsImage: clip.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(clip.comment.isEmpty ? clip.label : clip.comment)
                            .font(.system(size: 12))
                            .foregroundStyle(clip.comment.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 4)
                    .frame(maxWidth: 190, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(.white.opacity(hovered ? 0.14 : 0.08), in: shape)
                    .overlay(shape.strokeBorder(ui.editingClip == clip.id ? Color.accentColor : .white.opacity(0.12),
                                                lineWidth: ui.editingClip == clip.id ? 1.5 : 1))
                    .contentShape(shape)
                    .onTapGesture {
                        withAnimation(Motion.content) { ui.editingClip = ui.editingClip == clip.id ? nil : clip.id }
                        ui.onRequestFocus?()
                    }
                    .overlay(alignment: .topTrailing) {
                        // The ✕ removes the selection.
                        if hovered {
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                                .frame(width: 16, height: 16)
                                .glassEffect(.regular, in: .circle)
                                .contentShape(Circle())
                                .onTapGesture {
                                    withAnimation(Motion.content) {
                                        if let i = ui.clips.firstIndex(of: clip) {
                                            ui.removedClips.append((clip, i))
                                            ui.draftAtClipRemoval = ui.draft
                                            ui.clips.remove(at: i)
                                        }
                                        if hoveredClip == clip.id { hoveredClip = nil }
                                        if ui.editingClip == clip.id { ui.editingClip = nil }
                                    }
                                }
                                .offset(x: 5, y: -5)
                                .transition(.blurReplace.combined(with: .scale(0.6)))
                        }
                    }
                    .onHover { inside in
                        withAnimation(Motion.snappy) {
                            if inside { hoveredClip = clip.id } else if hoveredClip == clip.id { hoveredClip = nil }
                        }
                    }
                    .transition(.blurReplace.combined(with: .scale(0.8)))
                }
                // Where the selection that is flying in will sit.
                if ui.landing {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .frame(width: 44, height: 28)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ui.landingSlot = $0 }
                        .transition(.opacity)
                }
            }
            // A larger preview of the hovered clip, or of the one whose comment is open.
            if let clip = ui.clips.first(where: { $0.id == hoveredClip }) ?? ui.clips.first(where: { $0.id == ui.editingClip }) {
                Image(nsImage: clip.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 240, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .id(clip.id)
                    .transition(.blurReplace)
            }
            // The open selection's comment. ⏎ and Esc go back to the message.
            if let i = ui.clips.firstIndex(where: { $0.id == ui.editingClip }) {
                TextField("Comment on this selection", text: Binding(
                    get: { ui.clips.indices.contains(i) ? ui.clips[i].comment : "" },
                    set: { if ui.clips.indices.contains(i) { ui.clips[i].comment = $0 } }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...4)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
                    .onSubmit {
                        withAnimation(Motion.content) { ui.editingClip = nil }
                        ui.onRequestFocus?()
                    }
                    .id(ui.editingClip)
                    .transition(.blurReplace)
            }
        }
        .animation(Motion.content, value: ui.editingClip)
        .animation(Motion.content, value: ui.clips)
        .animation(Motion.content, value: ui.landing)
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
                         ?? store.project(for: store.targetThread)?["workspaceRoot"].string)
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

/// Lays chips out in rows, left to right, and starts a new row when one is full.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (sub, frame) in zip(subviews, rows(subviews, width: bounds.width).frames) {
            sub.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }
}
