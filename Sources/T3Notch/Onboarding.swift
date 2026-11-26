import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// The welcome tour. It runs inside the island on first launch and teaches by doing: connect to
/// T3, press the island's shortcut, open the chat list, select something on screen, then a card
/// with the other keys.
enum OnboardingStep: Int, CaseIterable {
    // The raw value is saved to resume the tour, so a new step goes last here.
    case welcome, connect, hotkey, chats, tips, done, select

    /// The steps in the order the tour shows them, one progress dot each.
    static let tour: [OnboardingStep] = [.welcome, .connect, .hotkey, .chats, .select, .tips]

    /// The step after this one.
    var next: OnboardingStep {
        guard let i = Self.tour.firstIndex(of: self), i + 1 < Self.tour.count else { return .done }
        return Self.tour[i + 1]
    }

    /// The key steps; Esc skips them. Welcome and Connect cannot be skipped, since the island
    /// does nothing until it reaches T3.
    var skippable: Bool { self != .welcome && self != .connect && self != .done }
}

enum Onboarding {
    private static let stepKey = "onboardingStep"
    private static let doneKey = "onboardingDone"

    /// The step to resume at, or nil once the tour is done or skipped.
    static var saved: OnboardingStep? {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return nil }
        return OnboardingStep(rawValue: UserDefaults.standard.integer(forKey: stepKey)) ?? .welcome
    }

    static func save(_ step: OnboardingStep) {
        if step == .done { finish() } else { UserDefaults.standard.set(step.rawValue, forKey: stepKey) }
    }

    /// A new tour, also a replay: a quit midway resumes it at the next launch.
    static func begin() {
        UserDefaults.standard.set(false, forKey: doneKey)
    }

    static func finish() {
        UserDefaults.standard.set(true, forKey: doneKey)
        UserDefaults.standard.removeObject(forKey: stepKey)
    }

    /// Whether to start the tour at launch. Someone who used the app before the tour existed
    /// already has a token, so they skip it.
    static var startsAtLaunch: Bool {
        guard !Store.demo else { return false }
        // A saved step means a tour is under way: resume it even though a token exists.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: doneKey) == nil, defaults.object(forKey: stepKey) == nil, Auth.storedToken() != nil {
            finish()
            return false
        }
        return saved != nil
    }

    /// The T3 Code desktop app, if it is installed.
    static var t3AppURL: URL? { NSWorkspace.shared.urlForApplication(toOpen: URL(string: "t3code://")!) }
    static var t3Installed: Bool {
        t3AppURL != nil || FileManager.default.isExecutableFile(atPath: T3Runtime.cli.path)
    }
    static let t3Download = URL(string: "https://github.com/pingdotgg/t3code/releases/latest")!

    /// Whether select mode can run now. Without its permissions the Select step still takes
    /// the tap; select mode asks for them when it is first used.
    static var canSelect: Bool { Permission.screenRecording.isGranted && Permission.accessibility.isGranted }

    static func openT3() {
        guard let url = t3AppURL else { NSWorkspace.shared.open(t3Download); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Flow

/// The shortcuts the keys card asks you to try.
enum OnboardingTip: CaseIterable {
    case clip, openInT3, toggleDot

    var binding: KeyBinding {
        switch self {
        case .clip: return KeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey), key: "P")
        case .openInT3: return Settings.openInT3Key
        case .toggleDot: return Settings.toggleDotKey
        }
    }

    var text: String {
        switch self {
        case .clip: return "Clip part of the screen into your message"
        case .openInT3: return "Open the chat in T3 Code"
        case .toggleDot: return "Hide or show the status dot"
        }
    }
}

extension PanelController {
    /// Opens the island on the tour, at `step`.
    func startOnboarding(at step: OnboardingStep = .welcome) {
        Onboarding.begin()
        Chime.prepare()
        onboardingHidOnce = false
        onboardingNote = 0
        ui.onboardingKeysLit = false
        ui.onboarding = step
        expand()
        go(to: step)
    }

    /// Moves to `step`, saves it so a relaunch resumes there, and starts what the step waits for.
    func go(to step: OnboardingStep) {
        // The tap is off (its setting, VoiceOver, a password field): nothing to teach.
        if step == .select, !SelectTrigger.enabled { go(to: step.next); return }
        Onboarding.save(step)
        onboardingTask?.cancel()
        withAnimation(Motion.content) {
            ui.onboarding = step
            ui.onboardingKeysLit = false
            ui.onboardingTried = []
        }
        switch step {
        case .welcome:
            onboardingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.8))
                guard !Task.isCancelled else { return }
                self?.go(to: .connect)
            }
        case .connect:
            // The store finds and connects to T3 by itself; move on once it has.
            onboardingTask = Task { [weak self] in
                // Show the list first, also when T3 is connected already.
                try? await Task.sleep(for: .milliseconds(700))
                while !Task.isCancelled {
                    if self?.store.connection == .connected {
                        // Let the last check mark draw, then mark the success.
                        try? await Task.sleep(for: .milliseconds(450))
                        guard let self, !Task.isCancelled else { return }
                        // Folded away, it moves on without a sound.
                        if self.ui.mode != .hidden { self.celebrate() }
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled else { return }
                        self.go(to: OnboardingStep.connect.next)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        case .hotkey:
            onboardingHidOnce = false
        case .chats, .select, .tips:
            break
        case .done:
            onboardingTask = Task { [weak self] in
                // The step settles first, so the check mark, the wave and the sound land together.
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled else { return }
                self.celebrate(big: true)
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self.hide()
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self.ui.onboarding = nil
            }
        }
    }

    /// A step's success, as one moment: the keys bottom out and spring back, a wave of light
    /// runs out from them, the island breathes, and a note and a trackpad tap land with it.
    func celebrate(big: Bool = false) {
        withAnimation(Motion.snappy) { ui.onboardingKeysLit = true }
        ui.onboardingSuccess += 1
        playSuccessNote(resolve: big)
    }

    /// The tour's sound: each success plays the next note up, and the end resolves them.
    /// The tap lands when the keys reach the bottom.
    private func playSuccessNote(resolve: Bool = false) {
        if resolve { Chime.resolve() } else { Chime.note(onboardingNote) }
        onboardingNote += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Keycap.bottomOut) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    /// The island's shortcut during the Hotkey step: the first press folds the island, the
    /// second brings it back, lit, and the tour moves on.
    func onboardingHotkeyPressed() {
        if ui.mode != .hidden && !onboardingHidOnce {
            onboardingHidOnce = true
            hide()
            return
        }
        guard ui.mode == .hidden else { hide(); return }
        expand()
        guard onboardingHidOnce else { return }
        onboardingTask?.cancel()
        onboardingTask = Task { [weak self] in
            // Light up once the island has opened, so the success is seen.
            try? await Task.sleep(for: .milliseconds(380))
            guard let self, !Task.isCancelled else { return }
            self.celebrate()
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self.go(to: OnboardingStep.hotkey.next)
        }
    }

    /// The Chats step: the shortcut lights its keys, then opens the real chat list.
    private func onboardingShowChats() {
        guard !ui.onboardingKeysLit else { return }
        celebrate()
        onboardingTask?.cancel()
        onboardingTask = Task { [weak self] in
            // The wave runs out first.
            try? await Task.sleep(for: .milliseconds(850))
            guard let self, !Task.isCancelled, self.ui.onboarding == .chats else { return }
            self.setPicker(true)
        }
    }

    /// The Select step: the tap lights its keys, then starts the real select mode.
    func onboardingSelectTapped() {
        guard !ui.onboardingKeysLit else { return }
        celebrate()
        let real = Onboarding.canSelect
        onboardingTask?.cancel()
        onboardingTask = Task { [weak self] in
            // The wave runs out first. With nothing to try, the words get time to be read.
            try? await Task.sleep(for: .milliseconds(real ? 850 : 1800))
            guard let self, !Task.isCancelled, self.ui.onboarding == .select else { return }
            if real { self.startSelecting(inTour: true) } else { self.go(to: OnboardingStep.select.next) }
        }
    }

    /// Select mode ended during the Select step, with or without picks.
    func onboardingSelectEnded() {
        guard ui.onboarding == .select else { return }
        expand()
        go(to: OnboardingStep.select.next)
    }

    /// One of the keys card's shortcuts was pressed. It ticks off instead of acting, and the
    /// tour ends once all are tried.
    func triedTip(_ tip: OnboardingTip) {
        guard ui.onboarding == .tips, !ui.onboardingTried.contains(tip) else { return }
        withAnimation(Motion.snappy) { _ = ui.onboardingTried.insert(tip) }
        playSuccessNote()
        guard ui.onboardingTried.count == OnboardingTip.allCases.count else { return }
        onboardingTask?.cancel()
        onboardingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            self?.go(to: .done)
        }
    }

    /// Keeps `ui.onboardingHeld` to the keys held down, while the tour shows.
    func trackHeldKeys(_ event: NSEvent) {
        guard ui.onboarding != nil else { return }
        var held = ui.onboardingHeld
        let flags = event.modifierFlags
        for (flag, symbol) in [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] {
            if flags.contains(flag) { held.insert(symbol) } else { held.remove(symbol) }
        }
        if event.type == .keyUp { held.subtract(held.filter { !["⌃", "⌥", "⇧", "⌘"].contains($0) }) }
        if held != ui.onboardingHeld { withAnimation(Motion.select) { ui.onboardingHeld = held } }
    }

    /// Keys while the tour shows. True when the key was handled.
    func handleOnboardingKey(_ event: NSEvent) -> Bool {
        guard let step = ui.onboarding else { return false }
        // In the Chats step the real chat list is open; it handles its own keys.
        if step == .chats && ui.pickerOpen { return false }
        if let name = KeyBinding(event: event)?.key ?? event.charactersIgnoringModifiers?.uppercased() {
            withAnimation(Motion.select) { _ = ui.onboardingHeld.insert(name) }
        }
        // Shortcuts first: a rebound one may use Return or another key the tour handles.
        if step == .chats && Settings.showChatsKey.matches(event) { onboardingShowChats(); return true }
        if step == .tips, let tip = OnboardingTip.allCases.first(where: { $0.binding.matches(event) }) {
            triedTip(tip)
            return true
        }
        switch Int(event.keyCode) {
        case kVK_Escape:
            if step.skippable { go(to: .done) } else { hide() }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if step == .welcome { go(to: .connect) }
            if step == .tips { go(to: .done) }
            return true
        default:
            if event.modifierFlags.contains(.command) && event.keyCode == UInt16(kVK_ANSI_Comma) { return false }
            return true // nothing else to type into during the tour
        }
    }

    /// The chat list closed during the Chats step.
    func onboardingPickerClosed() {
        guard ui.onboarding == .chats else { return }
        go(to: OnboardingStep.chats.next)
    }
}

// MARK: - Views

/// The tour's content, in place of the island's usual content.
struct OnboardingView: View {
    let store: Store
    let ui: OverlayUIState
    let step: OnboardingStep
    var onAction: (OnboardingStep) -> Void
    /// Where the success wave starts, in the tour's space: the last key pressed, or the final
    /// check mark.
    @State private var waveOrigin = CGPoint(x: 340, y: 80)

    static let space = "tour"

    /// From the tour's content out to the island's edge (see `content` in OverlayView).
    private var bleed: EdgeInsets {
        EdgeInsets(top: max(ui.notchSize.height - 6, 0) + 10, leading: 16, bottom: 14, trailing: 16)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                stepContent.id(step).transition(StepChange())
            }
            .frame(maxWidth: .infinity)
            if step != .done {
                footer.padding(.top, 18)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
        // The wave's layer covers the whole island, so the light ends at the island's edge.
        .padding(bleed)
        .background(LightWave(origin: waveOrigin, trigger: ui.onboardingSuccess, strength: step == .done ? 0.13 : 0.09))
        .coordinateSpace(.named(Self.space))
        .padding(EdgeInsets(top: -bleed.top, leading: -bleed.leading, bottom: -bleed.bottom, trailing: -bleed.trailing))
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome: welcome
        case .connect: connect
        case .hotkey: hotkey
        case .chats: chats
        case .select: select
        case .tips: tips
        case .done: done
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                .shadow(color: .white.opacity(0.18), radius: 18)
            title("Your T3 chats, in the notch.")
            caption("Ask, follow and answer your agents from any app.")
        }
        .padding(.top, 6)
    }

    private var connect: some View {
        let installed = Onboarding.t3Installed
        let running = store.connection != .t3NotRunning
        let connected = store.connection == .connected
        return VStack(spacing: 16) {
            title("Connect to T3 Code")
            VStack(spacing: 0) {
                checkRow("T3 Code is installed", state: installed ? .ok : .missing,
                         action: installed ? nil : ("Download", { _ = NSWorkspace.shared.open(Onboarding.t3Download) }))
                divider
                checkRow("T3 Code is running", state: running ? .ok : installed ? .waiting : .idle,
                         action: running || !installed ? nil : ("Open T3 Code", { Onboarding.openT3() }))
                divider
                checkRow(connectedTitle, state: connected ? .ok : running ? (failure != nil ? .missing : .waiting) : .idle,
                         action: failure == nil ? nil : ("Retry", { store.reconnectNow() }))
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
            .frame(width: 440)
        }
    }

    private var failure: String? {
        if case .failed(let reason) = store.connection { return reason }
        return nil
    }

    private var connectedTitle: String {
        if let failure { return "Can't connect: \(failure)" }
        return store.connection == .connected ? "Connected" : "Connect"
    }

    private var hotkey: some View {
        let lit = ui.onboardingKeysLit
        return keyStep(Settings.showIslandKey.keycaps,
                       title: lit ? "That's the one to remember" : "Hide the island, then bring it back",
                       caption: lit ? "It works from any app." : "Press the keys, then press them again.")
    }

    private var chats: some View {
        keyStep(Settings.showChatsKey.keycaps,
                title: ui.onboardingKeysLit ? "Your chats" : "Open your chats",
                caption: "Pick one. Its replies show up here.")
    }

    private var select: some View {
        let lit = ui.onboardingKeysLit
        return keyStep(SelectTrigger.keycaps,
                       title: lit ? (Onboarding.canSelect ? "Now pick something" : "That starts select mode")
                                  : "Select anything on screen",
                       caption: lit ? "What you pick goes into your message." : "Tap both keys at once, in any app.")
    }

    private var tips: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                title("A few more keys")
                caption("Try each one.")
            }
            VStack(spacing: 0) {
                ForEach(OnboardingTip.allCases, id: \.self) { tip in
                    tipRow(tip)
                    divider
                }
                LoginRow()
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
            .frame(width: 500)
            Button { onAction(.done) } label: {
                HStack(spacing: 8) {
                    Text("Done").font(.system(size: 13, weight: .semibold))
                    Text("⏎").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).frame(height: 32).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    private var done: some View {
        catchesLight(VStack(spacing: 12) {
            CheckMark(on: ui.onboardingKeysLit, size: 48)
                .waveOrigin($waveOrigin)
            title("All set")
            caption("Right-click the dot by the notch for settings.")
        }
        .padding(.top, 4).padding(.bottom, 6))
    }

    /// A step that teaches one shortcut: big keycaps that go down while held, and on success
    /// bottom out, spring back and light up. The wave starts at the last key.
    func keyStep(_ caps: [KeyCap], title text: String, caption note: String) -> some View {
        catchesLight(VStack(spacing: 18) {
            KeycapRow(caps: caps, lit: ui.onboardingKeysLit, held: ui.onboardingHeld,
                      click: ui.onboardingSuccess, origin: $waveOrigin)
            VStack(spacing: 6) {
                title(text, done: ui.onboardingKeysLit)
                caption(note)
            }
        })
    }

    /// The success wave lights what it passes: the keys and the words catch it as a sheen.
    /// Only for steps drawn by SwiftUI alone, since it flattens them into one layer.
    private func catchesLight(_ content: some View) -> some View {
        content
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(Self.space))
                    LightWave(origin: CGPoint(x: waveOrigin.x - frame.minX, y: waveOrigin.y - frame.minY),
                              trigger: ui.onboardingSuccess, strength: 0.5)
                        .blendMode(.sourceAtop)
                }
            }
            .compositingGroup()
    }

    // MARK: Pieces

    /// One progress dot per step, and how to skip. The current dot turns green on success.
    private var footer: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.tour, id: \.self) { s in
                    Capsule().fill(dotColor(s)).frame(width: s == step ? 18 : 6, height: 6)
                }
            }
            .animation(Motion.snappy, value: step)
            HStack {
                Spacer()
                Text(step.skippable ? "esc to skip" : step == .welcome ? "⏎ to continue" : "")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    private func dotColor(_ s: OnboardingStep) -> Color {
        let tour = OnboardingStep.tour
        if s == step { return ui.onboardingKeysLit ? .green : .white }
        let passed = (tour.firstIndex(of: s) ?? 0) < (tour.firstIndex(of: step) ?? 0)
        return .white.opacity(passed ? 0.45 : 0.18)
    }

    private func title(_ text: String, done: Bool = false) -> some View {
        HStack(spacing: 8) {
            if done {
                DrawnCheck(size: 20).transition(.scale(0.4).combined(with: .opacity))
            }
            ZStack {
                Text(text).id(text).transition(.blurReplace)
            }
        }
        .font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
        .animation(Motion.content, value: text)
        .animation(Motion.open, value: done)
    }

    private func caption(_ text: String) -> some View {
        ZStack {
            Text(text).id(text).transition(.blurReplace)
        }
        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .animation(Motion.content, value: text)
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }

    enum CheckState { case ok, waiting, missing, idle }

    private func checkRow(_ text: String, state: CheckState, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 10) {
            ZStack {
                CheckMark(on: state == .ok, size: 16)
                switch state {
                case .ok: EmptyView()
                case .waiting: ProgressView().controlSize(.small).scaleEffect(0.8).transition(.blurReplace)
                case .missing:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).transition(.blurReplace)
                case .idle: Image(systemName: "circle").foregroundStyle(.tertiary).transition(.blurReplace)
                }
            }
            .font(.system(size: 16))
            .frame(width: 20, height: 20)
            Text(text).font(.system(size: 13)).foregroundStyle(state == .idle ? .secondary : .primary).lineLimit(2)
                .contentTransition(.opacity)
            Spacer(minLength: 8)
            if let action {
                Button(action: action.1) {
                    Text(action.0).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).frame(height: 26).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .transition(.blurReplace)
            }
        }
        .frame(minHeight: 30)
        .padding(.vertical, 6)
        .animation(Motion.snappy, value: state)
    }

    /// A shortcut to try: its keys go down while held, and it ticks off once pressed.
    private func tipRow(_ tip: OnboardingTip) -> some View {
        let tried = ui.onboardingTried.contains(tip)
        return HStack(spacing: 12) {
            KeycapRow(caps: tip.binding.keycaps, lit: tried, held: tried ? [] : ui.onboardingHeld, size: 26,
                      click: tried ? 1 : 0)
                .frame(width: 128, alignment: .leading)
            Text(tip.text).font(.system(size: 13)).foregroundStyle(tried ? .secondary : .primary)
            Spacer(minLength: 0)
            CheckMark(on: tried, size: 16, ring: true)
        }
        .padding(.vertical, 8)
    }
}

/// Launch at login, as in the settings card.
private struct LoginRow: View {
    @State private var on = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack {
            Text("Launch at login").font(.system(size: 13))
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(get: { on }, set: { value in
                let service = SMAppService.mainApp
                try? value ? service.register() : service.unregister()
                on = service.status == .enabled
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Keycaps

/// One key of a shortcut: its symbol, and its name for big keycaps.
struct KeyCap: Hashable {
    let symbol: String
    var name: String?
}

/// A shortcut drawn as keyboard keys.
struct KeycapRow: View {
    let caps: [KeyCap]
    var lit: Bool
    /// Keys held down now, by symbol; those keycaps go down.
    var held: Set<String> = []
    var size: CGFloat = 60
    /// Changes once per success; the keys bottom out and spring back.
    var click = 0
    /// Gets the centre of the last key, where the success wave starts.
    var origin: Binding<CGPoint>?

    var body: some View {
        HStack(spacing: size * 0.16) {
            ForEach(Array(caps.enumerated()), id: \.offset) { i, cap in
                Keycap(cap: cap, lit: lit, pressed: held.contains(cap.symbol), size: size, click: click)
                    .waveOrigin(i == caps.count - 1 ? origin : nil)
            }
        }
    }
}

/// One key: a dark glass cap with a lit top edge, on a darker side. It goes down while pressed.
/// On success it bottoms out, springs back past its rest, and lights green.
struct Keycap: View {
    let cap: KeyCap
    var lit = false
    var pressed = false
    var size: CGFloat = 60
    var click = 0

    /// How long the key takes to reach the bottom; the sound and the trackpad tap land then.
    static let bottomOut = 0.07

    private struct Pose {
        /// 1 at the bottom, 0 at rest, below 0 past rest on the way back.
        var travel = 0.0
        /// The light the key gives off at the click.
        var flash = 0.0
    }

    private var wide: Bool { cap.symbol == "Space" }
    private var name: String? { size >= 40 ? cap.name : nil }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: size * 0.24, style: .continuous) }
    private var depth: CGFloat { max(2, size * 0.085) }

    var body: some View {
        VStack(spacing: size * 0.04) {
            // A big space bar has its name under it; a small one only fits the name.
            Text(wide ? (name == nil ? "space" : "") : cap.symbol)
                .font(.system(size: max(10, size * (cap.symbol.count > 1 ? 0.26 : 0.38)), weight: .medium, design: .rounded))
            if let name {
                Text(name).font(.system(size: size * 0.15, weight: .medium)).opacity(0.6)
            }
        }
        .foregroundStyle(lit ? Color.green : .primary)
        .frame(width: wide ? size * (name == nil ? 2.2 : 2.8) : size, height: size)
        .keyframeAnimator(initialValue: Pose(), trigger: click) { label, pose in
            // A held key rests partway down; the click takes it the rest of the way.
            let held = pressed ? 0.55 : 0.0
            let y = depth * (held + (pose.travel >= 0 ? pose.travel * (1 - held) : pose.travel * 0.6))
            label
                .background { Self.face(shape, lit: lit, flash: pose.flash, down: max(held, pose.travel)) }
                .scaleEffect(1 - 0.03 * max(0, pose.travel))
                // The key's side, under it. Its foot stays put while the cap moves.
                .background(shape.fill(Color(white: 0.055)).offset(y: depth - y))
                .offset(y: y)
                .shadow(color: lit ? .green.opacity(0.28 + 0.4 * pose.flash) : .black.opacity(0.5),
                        radius: lit ? 12 + 8 * pose.flash : 5, y: lit ? 0 : 3)
        } keyframes: { _ in
            KeyframeTrack(\.travel) {
                CubicKeyframe(1, duration: Self.bottomOut)
                SpringKeyframe(0, duration: 0.55, spring: Spring(response: 0.28, dampingRatio: 0.42))
            }
            KeyframeTrack(\.flash) {
                LinearKeyframe(1, duration: Self.bottomOut)
                LinearKeyframe(0, duration: 0.6, timingCurve: .easeOut)
            }
        }
    }

    private nonisolated static func face(_ shape: RoundedRectangle, lit: Bool, flash: Double, down: Double) -> some View {
        let top = 0.21 - 0.05 * min(1, max(0, down))
        return shape.fill(LinearGradient(colors: [Color(white: top), Color(white: top - 0.07)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(Color.green.opacity(lit ? 0.2 : 0)))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)))
            .overlay(shape.fill(Color.white.opacity(0.32 * flash)))
            .overlay(shape.strokeBorder(LinearGradient(colors: lit ? [.green.opacity(0.75), .green.opacity(0.12)]
                                                                   : [.white.opacity(0.26), .white.opacity(0.03)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

extension KeyBinding {
    /// The keys one by one, in ⌃⌥⇧⌘ order, each with its name for big keycaps.
    var keycaps: [KeyCap] {
        var caps: [KeyCap] = []
        if modifiers & UInt32(controlKey) != 0 { caps.append(KeyCap(symbol: "⌃", name: "control")) }
        if modifiers & UInt32(optionKey) != 0 { caps.append(KeyCap(symbol: "⌥", name: "option")) }
        if modifiers & UInt32(shiftKey) != 0 { caps.append(KeyCap(symbol: "⇧", name: "shift")) }
        if modifiers & UInt32(cmdKey) != 0 { caps.append(KeyCap(symbol: "⌘", name: "command")) }
        caps.append(KeyCap(symbol: key, name: key == "Space" ? "space" : nil))
        return caps
    }
}

// MARK: - The success moment

/// Light that spreads out from `origin` and fades, once per `trigger` change. Off with
/// Reduce Motion, as is the island's stretch.
struct LightWave: View {
    var origin: CGPoint
    var trigger: Int
    var strength = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Far enough to pass the island's corners from anywhere inside it.
    private static let reach: CGFloat = 560
    private static let duration = 0.9

    /// The light's brightness from the centre (0) to the front (1): a bloom that fills the
    /// circle, with a soft, slightly brighter front. No dark middle and no hard edge, so it
    /// reads as light that spreads, not as a ring.
    private static let stops: [Gradient.Stop] = (0...20).map { i in
        let x = Double(i) / 20
        let bloom = 0.55 * pow(1 - x, 0.8)
        let front = 0.62 * exp(-pow((x - 0.74) / 0.15, 2))
        return Gradient.Stop(color: .white.opacity(i == 20 ? 0 : min(1, bloom + front)), location: x)
    }

    var body: some View {
        Circle()
            .fill(RadialGradient(stops: Self.stops, center: .center, startRadius: 0, endRadius: Self.reach))
            .frame(width: Self.reach * 2, height: Self.reach * 2)
            // At rest (t = 1) and before the first success it is invisible.
            .keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, t in
                view.scaleEffect(0.03 + 0.97 * t).opacity(t < 1 && !reduceMotion ? strength * pow(1 - t, 1.4) : 0)
            } keyframes: { _ in
                MoveKeyframe(0.0)
                LinearKeyframe(1.0, duration: Self.duration, timingCurve: .easeOut)
            }
            .position(origin)
            .allowsHitTesting(false)
    }
}

/// The island takes the hit: it stretches a little from the notch and springs back, once per
/// `trigger` change.
struct IslandBreath: ViewModifier {
    var trigger: Int
    var big = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, breath in
            let amount = reduceMotion ? 0 : breath
            view.scaleEffect(x: 1 + 0.006 * amount, y: 1 + 0.022 * amount, anchor: .top)
        } keyframes: { _ in
            // It starts as the keys reach the bottom.
            LinearKeyframe(0.0, duration: Keycap.bottomOut)
            SpringKeyframe(big ? 1.6 : 1.0, duration: 0.13, spring: .snappy)
            SpringKeyframe(0.0, duration: 0.7, spring: Spring(response: 0.36, dampingRatio: 0.48))
        }
    }
}

/// A check mark that draws itself: the disc pops in, then the stroke runs. It undraws the
/// same way.
struct CheckMark: View {
    var on: Bool
    var size: CGFloat = 16
    /// Shows an empty ring while off.
    var ring = false

    var body: some View {
        ZStack {
            if ring {
                Circle().strokeBorder(.quaternary, lineWidth: 1.5).opacity(on ? 0 : 1)
            }
            Circle().fill(Color.green)
                .scaleEffect(on ? 1 : 0.4).opacity(on ? 1 : 0)
                .shadow(color: .green.opacity(on && size >= 40 ? 0.4 : 0), radius: size * 0.3)
                .animation(on ? .bouncy(duration: 0.42, extraBounce: 0.12) : Motion.close, value: on)
            CheckShape().trim(from: 0, to: on ? 1 : 0)
                .stroke(Color.black.opacity(0.88), style: StrokeStyle(lineWidth: size * 0.115, lineCap: .round, lineJoin: .round))
                .animation(on ? .easeOut(duration: 0.26).delay(0.14) : .easeIn(duration: 0.1), value: on)
        }
        .frame(width: size, height: size)
        .animation(Motion.snappy, value: on)
    }
}

/// A check mark that draws itself when it appears.
struct DrawnCheck: View {
    var size: CGFloat = 16
    @State private var on = false

    var body: some View {
        CheckMark(on: on, size: size).onAppear { on = true }
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.53))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.68))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.73, y: rect.minY + rect.height * 0.35))
        return path
    }
}

/// One step leaves to the left as the next comes in from the right.
struct StepChange: Transition {
    var distance: CGFloat = 20

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .offset(x: phase == .willAppear ? distance : phase == .didDisappear ? -distance : 0)
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : 8)
    }
}

extension View {
    /// Reports this view's centre in the tour's space to `origin`.
    func waveOrigin(_ origin: Binding<CGPoint>?) -> some View {
        onGeometryChange(for: CGPoint.self, of: { proxy in
            let frame = proxy.frame(in: .named(OnboardingView.space))
            return CGPoint(x: frame.midX, y: frame.midY)
        }) { centre in
            origin?.wrappedValue = centre
        }
    }
}

// MARK: - Sound

/// The tour's sounds, made here so each lands on its moment: a soft mallet note per success,
/// one step higher each time, and a chord that resolves them at the end.
@MainActor
enum Chime {
    private static var sounds: [String: NSSound] = [:]
    /// D5, then up a major pentatonic scale.
    nonisolated private static let base = 587.33
    nonisolated private static let scale = [0, 2, 4, 7, 9]

    nonisolated private static func frequency(_ step: Int) -> Double {
        let semitones = scale[step % scale.count] + 12 * (step / scale.count)
        return base * pow(2, Double(min(semitones, 24)) / 12)
    }

    nonisolated private static func noteData(_ index: Int) -> Data {
        wave([(frequency(index), 0)], decay: 0.11, length: 0.55)
    }

    nonisolated private static func resolveData() -> Data {
        wave([(base, 0), (base * 1.5, 0.055), (base * 2, 0.11), (base * 2.52, 0.165)], decay: 0.42, length: 1.9)
    }

    /// Makes the tour's sounds off the main thread, so the first success does not wait on them.
    static func prepare() {
        guard sounds.isEmpty else { return }
        Task {
            let made = await Task.detached(priority: .utility) {
                (0..<8).map { ("note \($0)", noteData($0)) } + [("resolve", resolveData())]
            }.value
            for (key, data) in made where sounds[key] == nil { sounds[key] = NSSound(data: data) }
        }
    }

    /// The `index`th note of the tour.
    static func note(_ index: Int) {
        play("note \(index)", volume: 0.34) { noteData(index) }
    }

    /// The end of the tour: a rising D major chord.
    static func resolve() {
        play("resolve", volume: 0.3) { resolveData() }
    }

    private static func play(_ key: String, volume: Float, make: () -> Data) {
        let sound = sounds[key] ?? NSSound(data: make())
        sounds[key] = sound
        sound?.stop()
        sound?.volume = volume
        sound?.play()
    }

    /// A WAV file of mallet tones: each a sine with a short-lived octave above it, a 4 ms
    /// attack and an exponential decay.
    nonisolated static func wave(_ tones: [(frequency: Double, start: Double)], decay: Double, length: Double) -> Data {
        let rate = 44_100.0
        let count = Int(length * rate)
        var samples = [Double](repeating: 0, count: count)
        for tone in tones {
            let first = Int(tone.start * rate)
            for i in first..<count {
                let t = Double(i - first) / rate
                let body = sin(2 * .pi * tone.frequency * t) + 0.3 * sin(4 * .pi * tone.frequency * t) * exp(-t / 0.04)
                samples[i] += (1 - exp(-t / 0.004)) * exp(-t / decay) * body
            }
        }
        let peak = max(samples.map(abs).max() ?? 1, 1e-6)
        let tail = 0.03 * rate // fade to silence, so the end does not click
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(count * 2))
        for (i, sample) in samples.enumerated() {
            let fade = min(1, Double(count - i) / tail)
            append(Int16(sample / peak * fade * 0.8 * 32_767))
        }
        return data
    }
}
