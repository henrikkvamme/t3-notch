import AppKit
import ScreenCaptureKit
import SwiftUI

/// `T3Notch --demo [--demo-shots <dir>]`: a scripted tour for recording the README demo.
///
/// It covers the screen with a fake desktop (wallpaper, menu bar, code editor), loads fake
/// chats instead of connecting to T3, and drives the real island through every feature while
/// showing each shortcut as keycaps in the bottom-right corner. No keystrokes are sent: the
/// script calls the same functions the shortcuts call. With `--demo-shots`, it also saves
/// stills of the fake desktop at key moments. It quits when done.
@MainActor
final class DemoController {
    private let panel: PanelController
    private let store: Store
    private let stage = DemoStage()
    private let keys = KeycapOverlay()
    private let shotsDir: URL?
    private var sequence = 0

    init(panel: PanelController, store: Store) {
        self.panel = panel
        self.store = store
        let args = CommandLine.arguments
        shotsDir = args.firstIndex(of: "--demo-shots").flatMap { i in
            args.indices.contains(i + 1) ? URL(fileURLWithPath: args[i + 1], isDirectory: true) : nil
        }
    }

    func run() {
        NSApp.activate()
        NSCursor.hide()
        stage.show()
        keys.show()
        loadChats()
        store.onDemoSend = { [weak self] text, steer, clips in self?.agentRuns(after: text, steer: steer, clips: clips) }
        store.onDemoRespond = { [weak self] _ in self?.approved() }
        Task { await script() }
    }

    // MARK: Script

    private func script() async {
        await pause(1.6)
        // Open the island on the focused chat.
        press("⌥", "Space"); panel.toggle()
        await pause(2.4)
        await shot("island")

        // Pick another chat.
        press("⌘", "K"); panel.setPicker(true)
        await pause(1.4)
        await shot("chats")
        // Down three, back up one: lands on "Fix flaky login test" (third in the list).
        for _ in 0..<3 { press("⌃", "J"); panel.movePicker(by: 1); await pause(0.45) }
        press("⌃", "K"); panel.movePicker(by: -1); await pause(0.6)
        press("⏎"); panel.pickHighlighted()
        await pause(1.6)

        // Type and send; the island tucks away while the agent works.
        await type("Why does the login test flake on CI?")
        await pause(0.5)
        await shot("typing")
        press("⏎"); panel.sendDraft(steer: false)
        await pause(5.2) // the run finishes and the reply pops up (see agentRuns)
        await shot("reply")
        await pause(1.6)

        // Clip part of the screen into the next message.
        press("⌥", "Space"); panel.expand()
        await pause(1.0)
        // Clear the keycaps first, so the frozen frame clipping captures has none in it.
        keys.clear()
        await pause(0.4)
        panel.startClipping()
        await pause(0.35)
        press("⌘", "P")
        await pause(0.8)
        if let clip = ClipController.current {
            let f = stage.frames
            let chain = [f["line"], f["function"], f["pane"], f["window"]].compactMap { $0 }
            clip.demoHover(pointer: f["line"].map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero, chain: chain)
            await pause(1.0)
            press("Scroll ↑"); clip.demoScroll(1)
            await pause(1.2)
            await shot("clip")
            press("Click"); clip.demoClick()
        }
        await pause(1.4)
        await type("Is this retry loop the cause?")
        await pause(0.4)
        press("⌘", "⏎"); panel.sendDraft(steer: true)
        await pause(3.4) // the agent asks to run a command (see agentRuns)

        // Answer the approval.
        press("⌥", "Space"); panel.expand()
        await pause(1.4)
        await shot("approval")
        press("⏎"); Task { await store.respond(decision: "accept") }
        await pause(4.0)
        press("⌥", "Space"); panel.toggle()
        await pause(2.4) // the dot shows a reply you haven't opened
        await shot("dot")
        NSApp.terminate(nil)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func press(_ k: String...) { keys.press(k) }

    /// Types into the island one character at a time, like a person would.
    private func type(_ text: String) async {
        for ch in text {
            panel.ui.draft.append(ch)
            try? await Task.sleep(for: .milliseconds(Int.random(in: 35...70)))
        }
    }

    /// Saves a still of the main screen when `--demo-shots` is given.
    private func shot(_ name: String) async {
        guard let dir = shotsDir, let screen = DemoStage.screen else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let rect = CGRect(x: screen.frame.minX, y: primaryMaxY - screen.frame.maxY,
                          width: screen.frame.width, height: screen.frame.height)
        guard let image = try? await SCScreenshotManager.captureImage(in: rect),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    // MARK: The fake agent

    private static let focusId = "demo-login"

    private func agentRuns(after text: String, steer: Bool, clips: Int) {
        update(Self.focusId) { t in
            t["activityRunStatus"] = "running"; t["status"] = "running"
            t["latestUserMessageAt"] = .string(Self.iso(0))
        }
        Task {
            if clips > 0 {
                // With a clip: the agent wants to run the tests first.
                try? await Task.sleep(for: .milliseconds(1800))
                store.demoSetRequestItem("req-1", [
                    "type": "approval_request", "requestId": "req-1", "requestKind": "command",
                    "prompt": "swift test --filter LoginTests --repeat 20",
                ])
                update(Self.focusId) { t in
                    t["activityRunStatus"] = "waiting"; t["status"] = "waiting"
                    t["pendingRuntimeRequest"] = ["id": "req-1", "kind": "command", "blocking": true,
                                                  "createdAt": .string(Self.iso(0))]
                }
            } else {
                try? await Task.sleep(for: .milliseconds(2600))
                finish(with: """
                The test reads the session cookie before `signIn()` has stored it. Locally the keychain \
                answers in under a millisecond, so it always wins; on CI it can take 40 ms, and the test \
                sees no cookie. Awaiting `sessionStore.ready` before the assertion fixes it.
                """)
            }
        }
    }

    private func approved() {
        update(Self.focusId) { t in
            t["pendingRuntimeRequest"] = .null
            t["activityRunStatus"] = "running"; t["status"] = "running"
        }
        Task {
            try? await Task.sleep(for: .milliseconds(2200))
            finish(with: """
            Yes. The retry loop re-reads the cookie without waiting, so the race from before repeats \
            on every retry. With `await sessionStore.ready` added, all 20 runs of LoginTests pass.
            """)
        }
    }

    private func finish(with reply: String) {
        update(Self.focusId) { t in
            t["activityRunStatus"] = .null; t["status"] = "completed"
            t["latestRunCompletedAt"] = .string(Self.iso(0))
            t["latestVisibleMessage"] = ["id": .string("msg-\(UUID().uuidString)"), "role": "assistant",
                                         "text": .string(reply), "updatedAt": .string(Self.iso(0))]
        }
    }

    // MARK: Fake chats

    private var threads: [String: JSON] = [:]

    private func update(_ id: String, _ change: (inout [String: JSON]) -> Void) {
        guard var t = threads[id]?.object else { return }
        change(&t)
        threads[id] = .object(t)
        sequence += 1
        store.demoApply(["kind": "thread.updated", "sequence": .number(Double(sequence)),
                         "location": "active", "thread": .object(t)])
    }

    private func loadChats() {
        let projects: [JSON] = [
            ["id": "p-web", "title": "acme-web", "workspaceRoot": "/Users/demo/code/acme-web"],
            ["id": "p-ios", "title": "acme-ios", "workspaceRoot": "/Users/demo/code/acme-ios"],
            ["id": "p-scratch", "title": "No project", "workspaceRoot": "/Users/demo/.t3/scratch",
             "projectIcon": ["kind": "lucide", "name": "message-square-dashed", "color": "gray"]],
        ]
        let chats: [JSON] = [
            Self.chat("demo-dark", "Add dark mode to settings", project: "p-web", minutes: 3, pinned: true,
                      branch: "feat/dark-mode", reply: "Dark mode is in. Settings now follow the system appearance, with an override under Appearance."),
            Self.chat("demo-api", "Paginate the orders API", project: "p-web", minutes: 9, running: true,
                      branch: "orders-pagination", provider: "codex"),
            Self.chat(Self.focusId, "Fix flaky login test", project: "p-ios", minutes: 26,
                      branch: "fix/login-flake", reply: "I found two tests that share a keychain item. Want me to isolate them?"),
            Self.chat("demo-notes", "Summarize this week's PRs", project: "p-scratch", minutes: 70,
                      reply: "Twelve PRs merged this week: four features, six fixes and two refactors."),
            Self.chat("demo-onboard", "Redesign onboarding copy", project: "p-ios", minutes: 180,
                      reply: "Here are three shorter versions of the welcome screen."),
            Self.chat("demo-ci", "Speed up CI caching", project: "p-web", minutes: 1500, provider: "codex",
                      reply: "Caching the Swift build folder cut CI from 11 to 4 minutes."),
        ]
        for c in chats { if let id = c["id"].string { threads[id] = c } }
        store.demoConnect()
        store.demoApply(["kind": "snapshot", "snapshot": ["snapshotSequence": .number(1), "threads": .array(chats),
                                                          "projects": .array(projects)]])
        store.focusedThreadId = "demo-dark"
    }

    private static func chat(_ id: String, _ title: String, project: String, minutes: Double,
                             pinned: Bool = false, running: Bool = false, branch: String? = nil,
                             provider: String = "claudeAgent", reply: String? = nil) -> JSON {
        var t: [String: JSON] = [
            "id": .string(id), "title": .string(title), "projectId": .string(project),
            "providerInstanceId": .string(provider), "lineage": ["parentThreadId": .null],
            "createdAt": .string(iso(minutes * 60 + 600)), "updatedAt": .string(iso(minutes * 60)),
            "latestUserMessageAt": .string(iso(minutes * 60)), "status": running ? "running" : "completed",
            "deletedAt": .null, "archivedAt": .null, "settledAt": .null, "pendingRuntimeRequest": .null,
            "pinnedAt": pinned ? .string(iso(9999)) : .null, "branch": branch.map(JSON.string) ?? .null,
        ]
        if running { t["activityRunStatus"] = "running" }
        if let reply {
            t["latestVisibleMessage"] = ["id": .string("msg-\(id)"), "role": "assistant", "text": .string(reply),
                                         "updatedAt": .string(iso(minutes * 60))]
        }
        return .object(t)
    }

    private static func iso(_ secondsAgo: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(-secondsAgo))
    }
}

// MARK: - Fake desktop

/// A full-screen window under the island: wallpaper, a menu bar and a code editor.
@MainActor
final class DemoStage {
    private var window: NSWindow?
    private let model = DemoStageModel()

    /// Element frames in global top-left coordinates, for the scripted clip.
    var frames: [String: CGRect] { model.frames }

    static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    func show() {
        guard let screen = Self.screen else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .statusBar // over the menu bar, under the island
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.setFrame(screen.frame, display: false)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let origin = CGPoint(x: screen.frame.minX, y: primaryMaxY - screen.frame.maxY)
        w.contentView = NSHostingView(rootView: DemoDesktop(model: model, origin: origin,
                                                            menuBarHeight: max(screen.safeAreaInsets.top, 28)))
        w.orderFrontRegardless()
        window = w
    }
}

@Observable
@MainActor
final class DemoStageModel {
    var frames: [String: CGRect] = [:]
}

private struct DemoDesktop: View {
    let model: DemoStageModel
    let origin: CGPoint
    let menuBarHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.30), Color(red: 0.42, green: 0.20, blue: 0.48),
                                    Color(red: 0.95, green: 0.55, blue: 0.40)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                menuBar
                Spacer(minLength: 40)
                editor
                    .frame(maxWidth: 1080, maxHeight: 640)
                    .padding(.horizontal, 60)
                Spacer(minLength: 80)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var menuBar: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo")
            Text("Xcode").fontWeight(.bold)
            ForEach(["File", "Edit", "View", "Find", "Navigate"], id: \.self) { Text($0) }
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Fri 9:41")
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: menuBarHeight)
        .background(.black.opacity(0.35))
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                Spacer()
                Text("LoginTests.swift").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 52)
            }
            .padding(.horizontal, 14).frame(height: 40)
            .background(Color(white: 0.16))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["AcmeApp", "  Login", "    LoginView.swift", "    SessionStore.swift", "  Tests",
                             "    LoginTests.swift", "    CheckoutTests.swift"], id: \.self) { name in
                        Text(name).font(.system(size: 12)).foregroundStyle(name.contains("LoginTests") ? .white : .secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .frame(width: 210, alignment: .leading)
                .background(Color(white: 0.13))
                code
            }
        }
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.frames["window"] = global($0) }
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 0) {
            line("import XCTest")
            line("@testable import AcmeApp")
            line("")
            line("final class LoginTests: XCTestCase {")
            VStack(alignment: .leading, spacing: 0) {
                line("    func testSignInStoresSession() async throws {")
                line("        let store = SessionStore()")
                line("        try await signIn(store: store, user: .demo)")
                line("        for _ in 0..<3 where store.cookie == nil {")
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.frames["line"] = global($0) }
                line("            try await Task.sleep(for: .milliseconds(10))")
                line("        }")
                line("        XCTAssertNotNil(store.cookie)")
                line("    }")
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.frames["function"] = global($0) }
            line("}")
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.frames["pane"] = global($0) }
    }

    private func line(_ text: String) -> some View {
        Text(highlighted(text))
            .font(.system(size: 14, design: .monospaced))
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }

    /// Light syntax colouring: keywords pink, strings and types blue.
    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = Color(white: 0.88)
        for word in ["import", "final", "class", "func", "async", "throws", "let", "try", "await", "for", "in", "where"] {
            var search = out.startIndex
            while let r = out[search...].range(of: word) {
                let before = r.lowerBound == out.startIndex ? " " : String(out.characters[out.characters.index(before: r.lowerBound)])
                let after = r.upperBound == out.endIndex ? " " : String(out.characters[r.upperBound])
                if !before.first!.isLetter && !after.first!.isLetter { out[r].foregroundColor = Color(red: 0.99, green: 0.37, blue: 0.64) }
                search = r.upperBound
            }
        }
        for type in ["XCTest", "XCTestCase", "LoginTests", "SessionStore", "AcmeApp", "Task", "XCTAssertNotNil"] {
            if let r = out.range(of: type) { out[r].foregroundColor = Color(red: 0.55, green: 0.80, blue: 0.98) }
        }
        return out
    }

    private func global(_ r: CGRect) -> CGRect { r.offsetBy(dx: origin.x, dy: origin.y) }
}

// MARK: - Keycaps

/// Shows each "pressed" shortcut as keycaps in the bottom-right corner.
@MainActor
final class KeycapOverlay {
    private let model = KeycapModel()
    private var panel: NSPanel?
    private var clearTask: Task<Void, Never>?

    func show() {
        guard let screen = DemoStage.screen else { return }
        let size = CGSize(width: 460, height: 120)
        let p = NSPanel(contentRect: NSRect(x: screen.frame.maxX - size.width - 24, y: screen.frame.minY + 24,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1) // over clipping too
        p.backgroundColor = .clear
        p.isOpaque = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: KeycapView(model: model))
        p.orderFrontRegardless()
        panel = p
    }

    func clear() {
        clearTask?.cancel()
        model.keys = []
        model.id += 1
    }

    func press(_ keys: [String]) {
        withAnimation(.bouncy(duration: 0.35, extraBounce: 0.1)) {
            model.keys = keys
            model.id += 1
        }
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { self.model.keys = [] }
        }
    }
}

@Observable
@MainActor
final class KeycapModel {
    var keys: [String] = []
    var id = 0
}

private struct KeycapView: View {
    let model: KeycapModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, key.count > 1 ? 18 : 0)
                    .frame(minWidth: 58, minHeight: 58)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.72)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18)))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            }
        }
        .id(model.id)
        // A new press springs in; the previous one is gone almost at once, so they never overlap.
        .transition(.asymmetric(insertion: AnyTransition(.blurReplace).combined(with: .scale(scale: 0.85)),
                                removal: .opacity.animation(.easeOut(duration: 0.08))))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}
