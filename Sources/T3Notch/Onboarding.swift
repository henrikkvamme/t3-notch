import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// The welcome tour. It runs inside the island on first launch and teaches by doing: connect to
/// T3, press the island's shortcut, open the chat list, then a card with the other keys.
enum OnboardingStep: Int, CaseIterable {
    case welcome, connect, hotkey, chats, tips, done

    /// Steps 3 to 5 teach keys; Esc skips them. Welcome and Connect cannot be skipped, since
    /// the island does nothing until it reaches T3.
    var skippable: Bool { self == .hotkey || self == .chats || self == .tips }
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

    static func finish() {
        UserDefaults.standard.set(true, forKey: doneKey)
        UserDefaults.standard.removeObject(forKey: stepKey)
    }

    /// Whether to start the tour at launch. Someone who used the app before the tour existed
    /// already has a token, so they skip it.
    static var startsAtLaunch: Bool {
        guard !Store.demo else { return false }
        if UserDefaults.standard.object(forKey: doneKey) == nil, Auth.storedToken() != nil {
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

    static func openT3() {
        guard let url = t3AppURL else { NSWorkspace.shared.open(t3Download); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Flow

extension PanelController {
    /// Opens the island on the tour, at `step`.
    func startOnboarding(at step: OnboardingStep = .welcome) {
        onboardingHidOnce = false
        ui.onboardingKeysLit = false
        ui.onboarding = step
        expand()
        go(to: step)
    }

    /// Moves to `step`, saves it so a relaunch resumes there, and starts what the step waits for.
    func go(to step: OnboardingStep) {
        Onboarding.save(step)
        onboardingTask?.cancel()
        withAnimation(Motion.content) {
            ui.onboarding = step
            ui.onboardingKeysLit = false
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
                while !Task.isCancelled {
                    if self?.store.connection == .connected {
                        try? await Task.sleep(for: .seconds(1.1))
                        guard !Task.isCancelled else { return }
                        self?.go(to: .hotkey)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        case .hotkey:
            onboardingHidOnce = false
        case .chats, .tips:
            break
        case .done:
            onboardingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                self.hide()
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self.ui.onboarding = nil
            }
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
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            withAnimation(Motion.snappy) { self.ui.onboardingKeysLit = true }
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self.go(to: .chats)
        }
    }

    /// Keys while the tour shows. True when the key was handled.
    func handleOnboardingKey(_ event: NSEvent) -> Bool {
        guard let step = ui.onboarding else { return false }
        // In the Chats step the real chat list is open; it handles its own keys.
        if step == .chats && ui.pickerOpen { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            if step.skippable { go(to: .done) } else { hide() }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if step == .welcome { go(to: .connect) }
            if step == .tips { go(to: .done) }
            return true
        default:
            if step == .chats && Settings.showChatsKey.matches(event) { return false }
            if event.modifierFlags.contains(.command) && event.keyCode == UInt16(kVK_ANSI_Comma) { return false }
            return true // nothing else to type into during the tour
        }
    }

    /// The chat list closed during the Chats step.
    func onboardingPickerClosed() {
        guard ui.onboarding == .chats else { return }
        go(to: .tips)
    }

}

// MARK: - Views

/// The tour's content, in place of the island's usual content.
struct OnboardingView: View {
    let store: Store
    let ui: OverlayUIState
    let step: OnboardingStep
    var onAction: (OnboardingStep) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                stepContent.id(step).transition(.blurReplace.combined(with: .scale(0.97)))
            }
            .frame(maxWidth: .infinity)
            if step != .done {
                footer.padding(.top, 18)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome: welcome
        case .connect: connect
        case .hotkey: hotkey
        case .chats: chats
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
            caption("Ask, follow and answer your agents without leaving what you are doing.")
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
        return "Connected, with its own access token"
    }

    private var hotkey: some View {
        VStack(spacing: 18) {
            KeycapRow(binding: Settings.showIslandKey, lit: ui.onboardingKeysLit)
            VStack(spacing: 6) {
                title(ui.onboardingKeysLit ? "That's the one to remember" : "Press \(Settings.showIslandKey.label)")
                caption(ui.onboardingKeysLit ? "It opens the island from any app."
                        : "Press it to fold the island away, then again to bring it back.")
            }
        }
    }

    private var chats: some View {
        VStack(spacing: 18) {
            KeycapRow(binding: Settings.showChatsKey, lit: false)
            VStack(spacing: 6) {
                title("Press \(Settings.showChatsKey.label) to see your chats")
                caption("Pick one, and its replies show up here as they come in.")
            }
        }
    }

    private var tips: some View {
        VStack(spacing: 16) {
            title("A few more keys")
            VStack(spacing: 0) {
                tipRow(KeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey), key: "P"),
                       "Clip part of the screen into your message")
                divider
                tipRow(Settings.openInT3Key, "Open the chat in T3 Code")
                divider
                tipRow(Settings.toggleDotKey, "Hide or show the status dot")
                divider
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
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                .symbolEffect(.bounce, value: step)
            title("All set")
            caption("Right-click the dot by the notch for settings.")
        }
        .padding(.bottom, 4)
    }

    // MARK: Pieces

    /// Progress dots for the five steps, and how to skip.
    private var footer: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases.filter { $0 != .done }, id: \.self) { s in
                    Capsule().fill(s == step ? Color.white : Color.white.opacity(s.rawValue < step.rawValue ? 0.45 : 0.18))
                        .frame(width: s == step ? 18 : 6, height: 6)
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

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
            .contentTransition(.opacity)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .contentTransition(.opacity)
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }

    enum CheckState { case ok, waiting, missing, idle }

    private func checkRow(_ text: String, state: CheckState, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 10) {
            ZStack {
                switch state {
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .waiting: ProgressView().controlSize(.small).scaleEffect(0.8)
                case .missing: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .idle: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 16))
            .frame(width: 20, height: 20)
            .transition(.blurReplace)
            Text(text).font(.system(size: 13)).foregroundStyle(state == .idle ? .secondary : .primary).lineLimit(2)
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

    private func tipRow(_ binding: KeyBinding, _ text: String) -> some View {
        HStack(spacing: 12) {
            KeycapRow(binding: binding, lit: false, size: 26)
                .frame(width: 128, alignment: .leading)
            Text(text).font(.system(size: 13))
            Spacer(minLength: 0)
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

/// A shortcut drawn as keyboard keys.
struct KeycapRow: View {
    let binding: KeyBinding
    var lit: Bool
    var size: CGFloat = 60

    var body: some View {
        HStack(spacing: size * 0.16) {
            ForEach(Array(binding.keycaps.enumerated()), id: \.offset) { i, cap in
                Keycap(symbol: cap.symbol, name: size >= 40 ? cap.name : nil,
                       wide: cap.symbol == "Space", lit: lit, size: size)
                    .animation(Motion.snappy.delay(Double(i) * 0.06), value: lit)
            }
        }
    }
}

/// One key: a dark cap with a lit top edge, which sinks and glows green when pressed.
struct Keycap: View {
    let symbol: String
    var name: String?
    var wide = false
    var lit = false
    var size: CGFloat = 60

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: size * 0.22, style: .continuous) }
    private var depth: CGFloat { max(2, size * 0.06) }

    var body: some View {
        VStack(spacing: size * 0.04) {
            // A big space bar has its name under it; a small one only fits the name.
            Text(symbol == "Space" ? (name == nil ? "space" : "") : symbol)
                .font(.system(size: max(10, size * (symbol.count > 1 ? 0.26 : 0.38)), weight: .medium, design: .rounded))
            if let name {
                Text(name).font(.system(size: size * 0.15, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(lit ? Color.green : .primary)
        .frame(width: wide ? size * (name == nil ? 2.2 : 2.8) : size, height: size)
        .background {
            shape.fill(lit ? Color.green.opacity(0.22) : Color(white: 0.17))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(lit ? 0.35 : 0.22), .white.opacity(0.03)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
        // The key's side, under it; it shortens as the key goes down.
        .background(shape.fill(Color(white: 0.06)).offset(y: lit ? depth * 0.3 : depth))
        .offset(y: lit ? depth * 0.7 : 0)
        .shadow(color: lit ? .green.opacity(0.45) : .black.opacity(0.5), radius: lit ? 14 : 5, y: lit ? 0 : 3)
    }
}

extension KeyBinding {
    /// The keys one by one, in ⌃⌥⇧⌘ order, each with its name for big keycaps.
    var keycaps: [(symbol: String, name: String?)] {
        var caps: [(String, String?)] = []
        if modifiers & UInt32(controlKey) != 0 { caps.append(("⌃", "control")) }
        if modifiers & UInt32(optionKey) != 0 { caps.append(("⌥", "option")) }
        if modifiers & UInt32(shiftKey) != 0 { caps.append(("⇧", "shift")) }
        if modifiers & UInt32(cmdKey) != 0 { caps.append(("⌘", "command")) }
        caps.append((key, key == "Space" ? "space" : nil))
        return caps
    }
}
