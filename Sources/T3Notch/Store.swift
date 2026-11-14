import AppKit
import Foundation
import Observation

/// What the overlay knows about T3, kept in sync over one WebSocket.
@Observable
@MainActor
final class Store {
    enum Connection: Hashable {
        case t3NotRunning
        case connecting
        case connected
        case failed(String)
    }

    struct ProtocolBreak: Equatable {
        let reason: String
        let logFile: URL
        let serverVersion: String
    }

    struct PendingRequest: Equatable {
        let id: String
        let kind: String
        let blocking: Bool
        /// The `approval_request` or `user_input_request` turn item, when it has arrived.
        let item: JSON?
    }

    private(set) var connection: Connection = .t3NotRunning
    private(set) var protocolBreak: ProtocolBreak?
    private(set) var runtime: T3Runtime?
    private(set) var environmentId: String?

    /// Active (non-archived) thread shells and projects, keyed by id.
    private(set) var threads: [String: JSON] = [:]
    private(set) var projects: [String: JSON] = [:]

    /// Set by ⌘K for the next prompt only.
    var overrideThreadId: String?
    /// Threads sent to from the overlay, so a send counts before the server echoes it.
    private var localSends: [String: Double] = [:]

    // The subscribed thread's live detail.
    private(set) var subscribedThreadId: String?
    private var threadStreamId: String?
    private var shellStreamId: String?
    private var shellSnapshotSequence: Double?
    private(set) var messages: [String: JSON] = [:]
    private(set) var runtimeRequests: [String: JSON] = [:]
    private(set) var requestItems: [String: JSON] = [:]

    /// Thread the user sent to from the overlay and is waiting on, for the re-show on completion.
    private(set) var awaitingThreadId: String?
    var lastSendError: String?
    /// A run started from the overlay finished and the overlay hasn't been opened since.
    private(set) var unseenReply = false
    func markReplySeen() { unseenReply = false }

    /// The status shown by the dot next to the notch while the overlay is hidden.
    enum Indicator: Equatable { case hidden, idle, running, needsYou, failed, done }

    var indicator: Indicator {
        guard connection == .connected, targetThread != nil else { return .hidden }
        if pendingRequest != nil || protocolBreak != nil { return .needsYou }
        if isTargetActive { return .running }
        if targetStatus == "failed" { return .failed }
        if unseenReply { return .done }
        return .idle
    }

    /// Fired when the overlay should show itself without focus (run finished or needs you).
    var onAttentionNeeded: ((AttentionReason) -> Void)?
    enum AttentionReason { case finished, needsYou }

    let rpc = RPCClient()
    private var presenceTimer: Timer?
    private var reconnectTask: Task<Void, Never>?

    init() {
        rpc.onClose = { [weak self] reason in self?.socketClosed(reason) }
        rpc.onProtocolError = { [weak self] reason, raw in self?.reportProtocolBreak(reason, raw: raw) }
    }

    // MARK: - Presence and connection

    /// Watches `server-runtime.json` and connects while T3 runs.
    func start() {
        checkPresence()
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPresence() }
        }
    }

    private func checkPresence() {
        let now = T3Runtime.current()
        if now == nil {
            if runtime != nil { disconnect(); connection = .t3NotRunning }
            runtime = nil
            return
        }
        if now != runtime || (connection != .connected && connection != .connecting && reconnectTask == nil) {
            runtime = now
            if case .failed = connection, reconnectTask != nil { return }
            connect()
        }
    }

    func reconnectNow() {
        reconnectTask?.cancel(); reconnectTask = nil
        disconnect()
        connect()
    }

    private func connect() {
        guard let runtime else { return }
        disconnect()
        connection = .connecting
        Task {
            do {
                var token = Auth.storedToken()
                if token == nil { token = try await Auth.issueToken() }
                do {
                    try await rpc.connect(runtime: runtime, token: token!)
                } catch AppError.auth {
                    // Expired or revoked: mint a fresh token once.
                    Auth.clear()
                    try await rpc.connect(runtime: runtime, token: try await Auth.issueToken())
                }
                connection = .connected
                await loadEnvironmentId(runtime)
                subscribeShell()
            } catch let error as AppError {
                if case .protocolMismatch(let s) = error { reportProtocolBreak(s, raw: s) }
                fail(error.description)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ reason: String) {
        connection = .failed(reason)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            if self.runtime != nil { self.connect() }
        }
    }

    private func disconnect() {
        rpc.close()
        shellStreamId = nil
        threadStreamId = nil
        subscribedThreadId = nil
    }

    private func socketClosed(_ reason: String) {
        shellStreamId = nil
        threadStreamId = nil
        subscribedThreadId = nil
        guard runtime != nil, reason != "closed" else { return }
        fail(reason)
    }

    private func loadEnvironmentId(_ runtime: T3Runtime) async {
        let url = runtime.httpBase.appendingPathComponent(".well-known/t3/environment")
        if let (data, _) = try? await URLSession.shared.data(from: url), let json = try? JSON.parse(data) {
            environmentId = json["environmentId"].string ?? json["id"].string ?? json["environment"]["id"].string
        }
    }

    // MARK: - Shell stream

    private func subscribeShell() {
        shellSnapshotSequence = nil
        shellStreamId = rpc.subscribe("orchestration.subscribeShell", [:], onValue: { [weak self] item in
            self?.applyShell(item)
        }, onEnd: { [weak self] result in
            if case .failure(let e) = result, self?.rpc.isOpen == true { self?.fail("shell stream ended: \(e)") }
        })
    }

    private func applyShell(_ item: JSON) {
        switch item["kind"].string {
        case "snapshot":
            let snap = item["snapshot"]
            guard let ts = snap["threads"].array, let ps = snap["projects"].array else {
                reportProtocolBreak("Shell snapshot has no threads/projects arrays", raw: String(decoding: item.encoded().prefix(20_000), as: UTF8.self))
                return
            }
            // A snapshot arrives in several parts that share one sequence: merge parts,
            // and start over only when a new sequence begins.
            let seq = snap["snapshotSequence"].double
            if seq != shellSnapshotSequence {
                shellSnapshotSequence = seq
                threads = [:]
                projects = [:]
            }
            for t in ts { if let id = t["id"].string { threads[id] = t } }
            for p in ps { if let id = p["id"].string { projects[id] = p } }
        case "thread.updated":
            guard let t = item["thread"].object, let id = t["id"]?.string else { return }
            let old = threads[id]
            if item["location"].string == "active" { threads[id] = .object(t) } else { threads[id] = nil }
            noticeTransition(id: id, old: old, new: threads[id])
        case "thread.removed":
            if let id = item["threadId"].string { threads[id] = nil }
        case "project.updated":
            if let p = item["project"].object, let id = p["id"]?.string { projects[id] = .object(p) }
        case "project.removed":
            if let id = item["projectId"].string { projects[id] = nil }
        default:
            break // "synchronized", "snapshot-required", or a kind added later
        }
        syncThreadSubscription()
    }

    // MARK: - Target thread

    /// The thread prompts go to: ⌘K override, else the one most recently opened in T3
    /// (`opens.openedAt`) or sent to (from T3 or this overlay).
    var targetThreadId: String? {
        if let o = overrideThreadId, threads[o] != nil { return o }
        return recentThreads.first.flatMap { $0["id"].string }
    }

    var targetThread: JSON? { targetThreadId.flatMap { threads[$0] } }

    /// Threads by recency, top-level only (subagent children are skipped).
    var recentThreads: [JSON] {
        threads.values
            .filter { $0["lineage"]["parentThreadId"].isNull && $0["deletedAt"].isNull }
            .sorted { recency($0) > recency($1) }
    }

    private func recency(_ t: JSON) -> Double {
        let id = t["id"].string ?? ""
        return max(t["opens"]["openedAt"].epochMs ?? 0,
                   t["latestUserAuthoredMessageAt"].epochMs ?? 0,
                   localSends[id] ?? 0)
    }

    func projectTitle(for thread: JSON?) -> String? {
        thread.flatMap { projects[$0["projectId"].string ?? ""]?["title"].string }
    }

    private func syncThreadSubscription() {
        guard rpc.isOpen, let target = targetThreadId, target != subscribedThreadId else { return }
        if let old = threadStreamId { rpc.interrupt(old) }
        subscribedThreadId = target
        messages = [:]; runtimeRequests = [:]; requestItems = [:]
        threadStreamId = rpc.subscribe("orchestration.subscribeThread",
                                       ["threadId": .string(target), "acceptBoundedSnapshot": true],
                                       onValue: { [weak self] item in self?.applyThread(item, threadId: target) },
                                       onEnd: { [weak self] _ in
                                           guard let self, self.subscribedThreadId == target else { return }
                                           self.subscribedThreadId = nil
                                           self.threadStreamId = nil
                                       })
    }

    private func applyThread(_ item: JSON, threadId: String) {
        guard threadId == subscribedThreadId else { return }
        switch item["kind"].string {
        case "snapshot":
            let p = item["projection"]
            guard p["messages"].array != nil else {
                reportProtocolBreak("Thread snapshot has no projection.messages", raw: String(decoding: item.encoded().prefix(20_000), as: UTF8.self))
                return
            }
            messages = index(p["messages"])
            runtimeRequests = index(p["runtimeRequests"])
            let items = (p["turnItems"].array ?? []) + (p["visibleTurnItems"].array ?? []).map { $0["item"] }
            requestItems = [:]
            for i in items { keepRequestItem(i) }
        case "event":
            let e = item["event"]
            let payload = e["payload"]
            switch e["type"].string {
            case "message.updated": if let id = payload["id"].string { messages[id] = payload }
            case "runtime-request.updated": if let id = payload["id"].string { runtimeRequests[id] = payload }
            case "turn-item.updated": keepRequestItem(payload)
            default: break
            }
        default:
            break
        }
    }

    private func index(_ arr: JSON) -> [String: JSON] {
        Dictionary((arr.array ?? []).compactMap { x in x["id"].string.map { ($0, x) } }, uniquingKeysWith: { _, b in b })
    }

    private func keepRequestItem(_ item: JSON) {
        let type = item["type"].string
        guard type == "approval_request" || type == "user_input_request", let rid = item["requestId"].string else { return }
        requestItems[rid] = item
    }

    // MARK: - Derived view state

    /// The latest assistant message in the target thread, streaming or finished.
    var latestReply: (text: String, streaming: Bool)? {
        if subscribedThreadId == targetThreadId,
           let m = messages.values
            .filter({ $0["role"].string == "assistant" && $0["notification"].isNull && !($0["text"].string ?? "").isEmpty })
            .max(by: { ($0["createdAt"].epochMs ?? 0) < ($1["createdAt"].epochMs ?? 0) }) {
            return (m["text"].string ?? "", m["streaming"].bool ?? false)
        }
        // Before the thread stream arrives, the shell's summary is enough.
        let lvm = targetThread?["latestVisibleMessage"]
        if let text = lvm?["text"].string, lvm?["role"].string == "assistant" { return (text, false) }
        return nil
    }

    /// The target thread's status, e.g. "running", "waiting", "completed", "idle".
    var targetStatus: String {
        guard let t = targetThread else { return "idle" }
        return t["activityRunStatus"].string ?? t["status"].string ?? "idle"
    }

    var isTargetActive: Bool {
        ["preparing", "queued", "starting", "running", "waiting"].contains(targetStatus)
    }

    var pendingRequest: PendingRequest? {
        guard let summary = targetThread?["pendingRuntimeRequest"], let id = summary["id"].string else { return nil }
        return PendingRequest(id: id, kind: summary["kind"].string ?? "approval",
                              blocking: summary["blocking"].bool ?? true,
                              item: requestItems[id])
    }

    private func noticeTransition(id: String, old: JSON?, new: JSON?) {
        guard id == targetThreadId, let new else { return }
        let wasRequest = old?["pendingRuntimeRequest"]["id"].string
        let request = new["pendingRuntimeRequest"]
        if let rid = request["id"].string, rid != wasRequest, request["blocking"].bool ?? true {
            onAttentionNeeded?(.needsYou)
            return
        }
        let active: Set<String> = ["preparing", "queued", "starting", "running", "waiting"]
        let oldStatus = old?["activityRunStatus"].string ?? old?["status"].string ?? ""
        let newStatus = new["activityRunStatus"].string ?? new["status"].string ?? ""
        if awaitingThreadId == id, active.contains(oldStatus), !active.contains(newStatus) {
            awaitingThreadId = nil
            unseenReply = true
            onAttentionNeeded?(.finished)
        }
    }

    // MARK: - Commands

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let threadId = targetThreadId else { return }
        let id = UUID().uuidString.lowercased()
        lastSendError = nil
        localSends[threadId] = Date().timeIntervalSince1970 * 1000
        overrideThreadId = nil
        do {
            _ = try await rpc.call("orchestration.dispatchCommand", [
                "type": "message.dispatch",
                "commandId": .string(id),
                "threadId": .string(threadId),
                "messageId": .string(id),
                "text": .string(trimmed),
                "attachments": [],
                "dispatchMode": ["type": "queue_after_active"],
                "createdBy": "user",
                "creationSource": "web",
            ])
            awaitingThreadId = threadId
        } catch {
            handleCommandError(error)
        }
        syncThreadSubscription()
    }

    func respond(decision: String) async {
        guard let req = pendingRequest, let threadId = targetThreadId else { return }
        await dispatch(["type": "runtime-request.respond", "commandId": .string(UUID().uuidString.lowercased()),
                        "threadId": .string(threadId), "requestId": .string(req.id), "decision": .string(decision)])
    }

    func answer(_ answers: [String: JSON]) async {
        guard let req = pendingRequest, let threadId = targetThreadId else { return }
        await dispatch(["type": "runtime-request.respond", "commandId": .string(UUID().uuidString.lowercased()),
                        "threadId": .string(threadId), "requestId": .string(req.id), "answers": .object(answers)])
    }

    func interruptRun() async {
        guard let t = targetThread, let threadId = t["id"].string, let runId = t["activeRunId"].string else { return }
        await dispatch(["type": "run.interrupt", "commandId": .string(UUID().uuidString.lowercased()),
                        "threadId": .string(threadId), "runId": .string(runId)])
    }

    private func dispatch(_ command: JSON) async {
        lastSendError = nil
        do { _ = try await rpc.call("orchestration.dispatchCommand", command) }
        catch { handleCommandError(error) }
    }

    private func handleCommandError(_ error: Error) {
        let text = "\(error)"
        lastSendError = String(text.prefix(300))
        // Schema failures mean T3 no longer accepts what this client sends.
        if text.contains("SchemaError") || text.contains("ParseError") || text.contains("Expected") {
            reportProtocolBreak("dispatchCommand rejected the command shape: \(text.prefix(400))", raw: text)
        }
    }

    // MARK: - Protocol break

    func reportProtocolBreak(_ reason: String, raw: String) {
        guard protocolBreak == nil else { return }
        let file = rpc.log.dump(reason: reason, failingFrame: raw)
        protocolBreak = ProtocolBreak(reason: reason, logFile: file, serverVersion: runtime?.serverVersion ?? "unknown")
        onAttentionNeeded?(.needsYou)
    }

    func dismissProtocolBreak() { protocolBreak = nil }

    /// Opens a T3 draft (never sent) in this app's repo with everything an agent needs to fix the client.
    func openFixDraft() {
        guard let b = protocolBreak else { return }
        let prompt = """
        The T3 Notch overlay (this repo) can no longer talk to T3 Code: its WebSocket protocol changed.

        - Built against T3 server version: \(BuildInfo.builtAgainstServerVersion) (commit \(BuildInfo.builtAgainstT3Commit))
        - Running T3 server version: \(b.serverVersion)
        - Failure: \(b.reason)
        - Raw frame log: \(b.logFile.path)

        Update the Swift client (Sources/T3Notch/RPCClient.swift and Store.swift) to the current \
        `packages/contracts` of github.com/pingdotgg/t3code at the running version. Diff \
        `packages/contracts/src/orchestrationV2.ts` and `rpc.ts` between commit \(BuildInfo.builtAgainstT3Commit) \
        and the running version, fix the client, update BuildInfo.swift, then run `make install` and check it connects.
        """
        var comps = URLComponents(string: "\(Self.appScheme)://new")!
        comps.queryItems = [URLQueryItem(name: "prompt", value: String(prompt.prefix(7900))),
                            URLQueryItem(name: "repo", value: BuildInfo.repo)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    /// The desktop app's own URL scheme. Links with it go straight to the app instead of
    /// through app.t3.codes in the browser. T3 parses them in `promptLinkAppPath`
    /// (`packages/shared/src/promptLinks.ts`): `t3code://new?prompt=…&repo=…` and
    /// `t3code://threads/<environmentId>/<threadId>`.
    static let appScheme = "t3code"

    /// Opens the target thread in T3.
    func openTargetInT3() {
        guard let id = targetThreadId, environmentId != nil else {
            if let pid = runtime?.pid { NSRunningApplication(processIdentifier: pid)?.activate() }
            return
        }
        // Thread ids can contain ":" (e.g. "mcp:…"), so encode each path segment.
        let segment = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? s }
        if let env = environmentId,
           let url = URL(string: "\(Self.appScheme)://threads/\(segment(env))/\(segment(id))") {
            NSWorkspace.shared.open(url)
        }
    }
}
