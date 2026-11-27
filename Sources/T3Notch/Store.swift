import AppKit
import Foundation
import Observation

/// What the overlay knows about T3: the local server over one WebSocket, plus each
/// environment it links to (`LinkedEnvironment`) over that environment's own WebSocket.
///
/// Chats and projects from all of them share one list. Their keys are `Store.key(env, id)`,
/// and every row carries `key`, `environmentId` and, for a linked environment,
/// `environmentLabel`.
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

    /// Active (non-archived) thread shells and projects of every environment, by `key(env, id)`.
    private(set) var threads: [String: JSON] = [:]
    private(set) var projects: [String: JSON] = [:]

    /// The environments the local one links to, by environment id.
    private(set) var linked: [String: LinkedEnvironment] = [:]

    /// The key of a thread or project of an environment. Environment ids never hold "/".
    static func key(_ environmentId: String, _ id: String) -> String { environmentId + "/" + id }

    /// The key of the project a thread row belongs to.
    static func projectKey(for thread: JSON) -> String {
        key(thread["environmentId"].string ?? "", thread["projectId"].string ?? "")
    }

    /// The chat prompts go to (its `key`), picked in the ⌘K list. There is no default: with none
    /// (or once it is archived or deleted), opening the island shows the list. Kept across
    /// launches. A value without "/" is a thread id from before linked environments, on the
    /// local server; `loadEnvironmentId` turns it into a key.
    var focusedThreadId: String? = Store.demo ? nil : UserDefaults.standard.string(forKey: "focusedThreadId") {
        didSet {
            if !Store.demo { UserDefaults.standard.set(focusedThreadId, forKey: "focusedThreadId") }
            syncThreadSubscription()
        }
    }

    // MARK: - Demo mode (`T3Notch --demo`, see Demo.swift)

    /// Demo mode: no T3 connection; a script feeds fake chats in and receives sends.
    nonisolated(unsafe) static var demo = false
    var onDemoSend: ((String, Bool, Int) -> Void)?
    var onDemoRespond: ((String) -> Void)?

    func demoConnect() { connection = .connected; environmentId = "demo" }
    func demoApply(_ item: JSON) { applyShell(item, environmentId: "demo") }
    func demoSetRequestItem(_ requestId: String, _ item: JSON) { requestItems[requestId] = item }

    // The subscribed thread's live detail. `subscribedThreadId` is a key.
    private(set) var subscribedThreadId: String?
    private var threadStreamId: String?
    private var threadStreamRpc: RPCClient?
    private var shellStreamId: String?
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
    enum Indicator: Equatable { case hidden, idle, running, awaitingInput, needsYou, failed, done }

    var indicator: Indicator {
        // Always at least a grey dot, so the overlay can be opened with the mouse.
        guard connection == .connected, targetThread != nil else { return protocolBreak != nil ? .needsYou : .idle }
        if let request = pendingRequest { return request.kind == "user_input" ? .awaitingInput : .needsYou }
        if protocolBreak != nil { return .needsYou }
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
        guard !Store.demo else { return }
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
                    try await rpc.connect(httpBase: runtime.httpBase, token: token!)
                } catch AppError.auth {
                    // Expired or revoked: mint a fresh token once.
                    Auth.clear()
                    try await rpc.connect(httpBase: runtime.httpBase, token: try await Auth.issueToken())
                }
                connection = .connected
                await loadEnvironmentId(runtime)
                subscribeShell()
                await refreshLinkedEnvironments()
                watchLinks()
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
        linkWatchTask?.cancel(); linkWatchTask = nil
        rpc.close()
        shellStreamId = nil
        if threadStreamRpc === rpc { threadStreamId = nil; threadStreamRpc = nil; subscribedThreadId = nil }
        // Linked environments are found through the local server, so they start over with it.
        for env in linked.values { env.stop() }
        linked = [:]
        threads = [:]
        projects = [:]
        shellVersion &+= 1
    }

    private func socketClosed(_ reason: String) {
        shellStreamId = nil
        if threadStreamRpc === rpc { threadStreamId = nil; threadStreamRpc = nil; subscribedThreadId = nil }
        guard runtime != nil, reason != "closed" else { return }
        fail(reason)
    }

    private func loadEnvironmentId(_ runtime: T3Runtime) async {
        let url = runtime.httpBase.appendingPathComponent(".well-known/t3/environment")
        if let (data, _) = try? await URLSession.shared.data(from: url), let json = try? JSON.parse(data) {
            environmentId = json["environmentId"].string ?? json["id"].string ?? json["environment"]["id"].string
        }
        // A chat picked before linked environments is a bare thread id on this server.
        if let env = environmentId, let old = focusedThreadId, !old.contains("/") {
            focusedThreadId = Self.key(env, old)
        }
    }

    // MARK: - Linked environments

    private var linkWatchTask: Task<Void, Never>?

    /// T3 sends no event when a link is added or removed, so read the links again now and then.
    private func watchLinks() {
        linkWatchTask?.cancel()
        linkWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, self.rpc.isOpen else { return }
                await self.refreshLinkedEnvironments()
            }
        }
    }

    /// Reads which environments the local one links to (`peerLinks.names`) and connects to each
    /// new one; closes those no longer linked. Older servers lack the method: then none.
    func refreshLinkedEnvironments() async {
        guard rpc.isOpen, !Store.demo else { return }
        guard let result = try? await rpc.call("peerLinks.names", [:]), let links = result["links"].array else { return }
        var seen = Set<String>()
        for link in links {
            guard let id = link["environmentId"].string, id != environmentId else { continue }
            seen.insert(id)
            let label = link["label"].string ?? id
            if let env = linked[id] { env.label = label; continue }
            let env = LinkedEnvironment(id: id, label: label)
            env.requestPairing = { [weak self] id in
                guard let self else { throw AppError.rpc("closed") }
                return try await self.requestPairing(id)
            }
            env.onConnected = { [weak self] env in self?.subscribeShell(of: env) }
            env.onDisconnected = { [weak self] env in self?.environmentClosed(env) }
            env.rpc.onProtocolError = { [weak self] reason, raw in self?.reportProtocolBreak("\(env.label): \(reason)", raw: raw) }
            linked[id] = env
            env.start()
        }
        for (id, env) in linked where !seen.contains(id) {
            env.stop()
            linked[id] = nil
            dropEnvironment(id)
        }
    }

    /// Asks the local server for a pairing with a linked environment. A token from before
    /// linked environments lacks `access:write`; mint one with it once, then ask again.
    private func requestPairing(_ environmentId: String) async throws -> JSON {
        do {
            return try await rpc.call("peerLinks.pairClient", ["environmentId": .string(environmentId)])
        } catch let error as AppError where "\(error)".contains("missing required scope") && !reissuedForScopes {
            reissuedForScopes = true
            Auth.clear()
            _ = try await Auth.issueToken()
            // Reconnects the local socket with the new token; linked environments start again.
            reconnectNow()
            throw AppError.auth("asked T3 for a token that may pair linked environments; trying again")
        }
    }
    @ObservationIgnored private var reissuedForScopes = false

    private func environmentClosed(_ env: LinkedEnvironment) {
        if threadStreamRpc === env.rpc { threadStreamId = nil; threadStreamRpc = nil; subscribedThreadId = nil }
        env.shellStreamId = nil
        dropEnvironment(env.id)
    }

    /// Removes an environment's chats and projects from the list.
    private func dropEnvironment(_ environmentId: String) {
        let prefix = environmentId + "/"
        threads = threads.filter { !$0.key.hasPrefix(prefix) }
        projects = projects.filter { !$0.key.hasPrefix(prefix) }
        shellVersion &+= 1
    }

    /// The socket for an environment: the local one or a connected linked one.
    func rpc(for environmentId: String?) -> RPCClient? {
        guard let environmentId else { return nil }
        if environmentId == self.environmentId { return rpc }
        guard let env = linked[environmentId], env.state == .connected else { return nil }
        return env.rpc
    }

    /// The base address and token for an environment's HTTP routes, such as attachments.
    private func http(for environmentId: String?) -> (URL, String?)? {
        guard let environmentId else { return nil }
        if environmentId == self.environmentId { return runtime.map { ($0.httpBase, Auth.storedToken()) } }
        guard let env = linked[environmentId], let base = env.httpBase else { return nil }
        return (base, env.token)
    }

    /// What a chat's environment is called, for chats on a linked environment only.
    func environmentLabel(for thread: JSON?) -> String? { thread?["environmentLabel"].string }

    // MARK: - Shell stream

    private func subscribeShell() {
        guard let env = environmentId else { return }
        dropEnvironment(env)
        shellStreamId = rpc.subscribe("orchestration.subscribeShell", [:], onValue: { [weak self] item in
            self?.applyShell(item, environmentId: env)
        }, onEnd: { [weak self] result in
            if case .failure(let e) = result, self?.rpc.isOpen == true { self?.fail("shell stream ended: \(e)") }
        })
    }

    private func subscribeShell(of env: LinkedEnvironment) {
        dropEnvironment(env.id)
        env.shellStreamId = env.rpc.subscribe("orchestration.subscribeShell", [:], onValue: { [weak self, weak env] item in
            guard let self, let env else { return }
            self.applyShell(item, environmentId: env.id, label: env.label)
        }, onEnd: { [weak env] result in
            // The stream ended with the socket open: start over on that environment.
            if case .failure = result, let env, env.rpc.isOpen { env.reconnectNow() }
        })
    }

    /// Adds where a row lives, so the list can name its machine and commands find its socket.
    private static func scoped(_ row: [String: JSON], environmentId: String, label: String?) -> JSON {
        var row = row
        row["key"] = .string(key(environmentId, row["id"]?.string ?? ""))
        row["environmentId"] = .string(environmentId)
        if let label { row["environmentLabel"] = .string(label) }
        return .object(row)
    }

    /// `label` is set for a linked environment, nil for the local one.
    private func applyShell(_ item: JSON, environmentId env: String, label: String? = nil) {
        switch item["kind"].string {
        case "snapshot":
            let snap = item["snapshot"]
            guard let ts = snap["threads"].array, let ps = snap["projects"].array else {
                reportProtocolBreak("Shell snapshot has no threads/projects arrays", raw: String(decoding: item.encoded().prefix(20_000), as: UTF8.self))
                return
            }
            // A snapshot arrives in parts, and parts can carry different sequences (some
            // only projects). Merge every part; the lists were cleared when this
            // subscription started, and removals arrive as thread.removed events.
            for t in ts { if let o = t.object, let id = o["id"]?.string { threads[Self.key(env, id)] = Self.scoped(o, environmentId: env, label: label) } }
            for p in ps { if let o = p.object, let id = o["id"]?.string { projects[Self.key(env, id)] = Self.scoped(o, environmentId: env, label: label) } }
        case "thread.updated":
            guard let t = item["thread"].object, let id = t["id"]?.string else { return }
            let key = Self.key(env, id)
            let old = threads[key]
            if item["location"].string == "active" { threads[key] = Self.scoped(t, environmentId: env, label: label) } else { threads[key] = nil }
            noticeTransition(id: key, old: old, new: threads[key])
        case "thread.removed":
            if let id = item["threadId"].string { threads[Self.key(env, id)] = nil }
        case "project.updated":
            if let p = item["project"].object, let id = p["id"]?.string { projects[Self.key(env, id)] = Self.scoped(p, environmentId: env, label: label) }
        case "project.removed":
            if let id = item["projectId"].string { projects[Self.key(env, id)] = nil }
        default:
            break // "synchronized", "snapshot-required", or a kind added later
        }
        shellVersion &+= 1
        syncThreadSubscription()
    }

    // MARK: - Target thread

    /// The focused chat, if it still exists in the sidebar.
    var targetThreadId: String? {
        guard let id = focusedThreadId, let t = threads[id], t["archivedAt"].isNull, t["deletedAt"].isNull
        else { return nil }
        return id
    }

    /// Mirrors T3's sidebar order (`packages/client-runtime/src/state/threadSort.ts`):
    /// pinned threads by `pinOrderKey` (unkeyed ones newest first, after keyed), then
    /// active threads by `activeOrderKey` (unkeyed ones first, newest first).
    /// Every top-level chat in T3's sidebar order: pinned, then active, then settled or
    /// snoozed ones by latest activity (as T3's settled list).
    var sidebarThreads: [JSON] {
        // Sorting ~hundreds of chats is costly; redo it only after the shell changed.
        if let cached = sidebarCache, cached.version == shellVersion { return cached.rows }
        let rows = computeSidebarThreads()
        sidebarCache = (shellVersion, rows)
        return rows
    }

    /// The ⌘K list for a search text, cached per shell change and query.
    func pickerRows(query: String) -> [JSON] {
        let q = query.lowercased()
        if let cached = pickerCache, cached.version == shellVersion, cached.query == q { return cached.rows }
        let rows = Array(sidebarThreads.filter { t in
            q.isEmpty || (t["title"].string ?? "").lowercased().contains(q)
                || (projectTitle(for: t) ?? "").lowercased().contains(q)
                || (t["environmentLabel"].string ?? "").lowercased().contains(q)
        }.prefix(60))
        pickerCache = (shellVersion, q, rows)
        return rows
    }

    /// Bumped on every shell change; views that read the chat list depend on it.
    private(set) var shellVersion = 0
    @ObservationIgnored private var sidebarCache: (version: Int, rows: [JSON])?
    @ObservationIgnored private var pickerCache: (version: Int, query: String, rows: [JSON])?

    private func computeSidebarThreads() -> [JSON] {
        let candidates = threads.values.filter {
            $0["lineage"]["parentThreadId"].isNull && $0["deletedAt"].isNull && $0["archivedAt"].isNull
        }
        let pinned = candidates.filter { !$0["pinnedAt"].isNull }.sorted(by: pinnedBefore)
        let rest = candidates.filter { $0["pinnedAt"].isNull }
        let active = rest.filter(isActive).sorted(by: activeBefore)
        let settled = rest.filter { !isActive($0) }
            .sorted { (Self.activityMs($0) ?? 0) > (Self.activityMs($1) ?? 0) }
        return pinned + active + settled
    }

    /// T3's `resolveThreadActivityTimestamp`: the latest of the last user message and the
    /// latest run's request, start and completion, else `updatedAt`.
    static func activityMs(_ t: JSON) -> Double? {
        let candidates = [t["latestUserMessageAt"], t["latestRunRequestedAt"], t["latestRunStartedAt"],
                          t["latestRunCompletedAt"]].compactMap(\.epochMs)
        return candidates.max() ?? t["updatedAt"].epochMs
    }

    private func pinnedBefore(_ a: JSON, _ b: JSON) -> Bool {
        switch (a["pinOrderKey"].string, b["pinOrderKey"].string) {
        case let (ka?, kb?): return ka != kb ? ka < kb : (a["key"].string ?? "") < (b["key"].string ?? "")
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return (a["createdAt"].epochMs ?? 0) > (b["createdAt"].epochMs ?? 0)
        }
    }

    private func activeBefore(_ a: JSON, _ b: JSON) -> Bool {
        let anchor = { (t: JSON) in max(t["createdAt"].epochMs ?? 0, t["unsettledAt"].epochMs ?? 0) }
        switch (a["activeOrderKey"].string, b["activeOrderKey"].string) {
        case let (ka?, kb?): return ka != kb ? ka < kb : (a["key"].string ?? "") < (b["key"].string ?? "")
        case (nil, .some): return true
        case (.some, nil): return false
        case (nil, nil): return anchor(a) > anchor(b)
        }
    }

    /// Not settled or snoozed, so it shows in the sidebar's active list.
    private func isActive(_ t: JSON) -> Bool {
        if let until = t["snoozedUntil"].epochMs, until > Date().timeIntervalSince1970 * 1000 { return false }
        switch t["settledOverride"].string {
        case "settled": return false
        case "unsettled": return true
        default: return t["settledAt"].isNull
        }
    }

    var targetThread: JSON? { targetThreadId.flatMap { threads[$0] } }

    func project(for thread: JSON?) -> JSON? {
        thread.flatMap { projects[Self.projectKey(for: $0)] }
    }

    func projectTitle(for thread: JSON?) -> String? { project(for: thread)?["title"].string }

    /// The focused chat's environment and its id there.
    private var target: (environmentId: String, threadId: String, rpc: RPCClient)? {
        guard let t = targetThread, let env = t["environmentId"].string, let id = t["id"].string,
              let rpc = rpc(for: env), rpc.isOpen else { return nil }
        return (env, id, rpc)
    }

    private func syncThreadSubscription() {
        guard let key = targetThreadId, key != subscribedThreadId, let target else { return }
        if let old = threadStreamId { threadStreamRpc?.interrupt(old) }
        subscribedThreadId = key
        threadStreamRpc = target.rpc
        messages = [:]; runtimeRequests = [:]; requestItems = [:]
        threadStreamId = target.rpc.subscribe("orchestration.subscribeThread",
                                       ["threadId": .string(target.threadId), "acceptBoundedSnapshot": true],
                                       onValue: { [weak self] item in self?.applyThread(item, threadId: key) },
                                       onEnd: { [weak self] _ in
                                           guard let self, self.subscribedThreadId == key else { return }
                                           self.subscribedThreadId = nil
                                           self.threadStreamId = nil
                                           self.threadStreamRpc = nil
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
            activityItems = [:]
            for i in items { keepRequestItem(i); keepActivityItem(i) }
        case "event":
            let e = item["event"]
            let payload = e["payload"]
            switch e["type"].string {
            case "message.updated": if let id = payload["id"].string { messages[id] = payload }
            case "runtime-request.updated": if let id = payload["id"].string { runtimeRequests[id] = payload }
            case "turn-item.updated": keepRequestItem(payload); keepActivityItem(payload)
            default: break
            }
        default:
            break
        }
    }

    private func index(_ arr: JSON) -> [String: JSON] {
        Dictionary((arr.array ?? []).compactMap { x in x["id"].string.map { ($0, x) } }, uniquingKeysWith: { _, b in b })
    }

    /// What the agent is doing in a run: its reasoning and tool steps.
    private(set) var activityItems: [String: JSON] = [:]
    private static let activityTypes: Set<String> = [
        "reasoning", "command_execution", "file_change", "file_search", "web_search", "dynamic_tool",
    ]

    private func keepActivityItem(_ item: JSON) {
        guard let type = item["type"].string, Self.activityTypes.contains(type), let id = item["id"].string else { return }
        activityItems[id] = item
        if activityItems.count > 400 {
            // Keep the newest; old runs' steps are never shown.
            let oldest = activityItems.values.sorted { Self.started($0) < Self.started($1) }.prefix(100)
            for o in oldest { if let id = o["id"].string { activityItems[id] = nil } }
        }
    }

    private func keepRequestItem(_ item: JSON) {
        let type = item["type"].string
        guard type == "approval_request" || type == "user_input_request", let rid = item["requestId"].string else { return }
        requestItems[rid] = item
    }

    // MARK: - Derived view state

    /// What the reply area shows.
    struct Reply: Equatable {
        let id: String
        let text: String
        let streaming: Bool
        /// The agent is working and this is its reasoning or current step, not a reply.
        let thinking: Bool
        /// Image attachments of the reply.
        let images: [JSON]
    }

    /// While a run works: its newest step (reasoning text, or the tool step) or its reply as it
    /// streams, never the previous run's reply. Otherwise the latest reply. `id` changes when
    /// a different message or step takes over, which the view animates.
    var latestReply: Reply? {
        if subscribedThreadId == targetThreadId {
            if isTargetActive, let run = targetThread?["activeRunId"].string ?? targetThread?["latestRunId"].string {
                let reply = assistantMessages.filter { $0["runId"].string == run }.max { Self.started($0) < Self.started($1) }
                // Thinking only, unless the setting also shows commands and other tool steps.
                let step = activityItems.values
                    .filter { $0["runId"].string == run && (Settings.showToolSteps || $0["type"].string == "reasoning") }
                    .max { Self.started($0) < Self.started($1) }
                if let reply, step.map({ Self.started(reply) >= Self.started($0) }) ?? true {
                    return makeReply(reply)
                }
                if let step {
                    return Reply(id: step["id"].string ?? run, text: Self.describe(step),
                                 streaming: step["streaming"].bool ?? true, thinking: true, images: [])
                }
                return Reply(id: "starting-\(run)", text: "", streaming: true, thinking: true, images: [])
            }
            if let m = assistantMessages.max(by: { Self.started($0) < Self.started($1) }) {
                return makeReply(m)
            }
        }
        // Before the thread stream arrives, the shell's summary is enough.
        let lvm = targetThread?["latestVisibleMessage"]
        if let text = lvm?["text"].string, lvm?["role"].string == "assistant" {
            return Reply(id: lvm?["id"].string ?? "", text: text, streaming: false, thinking: false, images: [])
        }
        return nil
    }

    private var assistantMessages: [JSON] {
        messages.values.filter {
            $0["role"].string == "assistant" && $0["notification"].isNull && !($0["text"].string ?? "").isEmpty
        }
    }

    /// Images the agent attached to its reply (images it embeds in the text show inline).
    private func makeReply(_ m: JSON) -> Reply {
        let images = (m["attachments"].array ?? [])
            .filter { $0["type"].string == "image" && $0["id"].string != nil }
        return Reply(id: m["id"].string ?? "", text: m["text"].string ?? "", streaming: m["streaming"].bool ?? false,
                     thinking: false, images: images)
    }

    private static func started(_ x: JSON) -> Double {
        x["startedAt"].epochMs ?? x["createdAt"].epochMs ?? x["updatedAt"].epochMs ?? 0
    }

    /// One line for a step: the reasoning itself, or what the tool is doing.
    private static func describe(_ step: JSON) -> String {
        let text = { (k: String) in (step[k].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch step["type"].string {
        case "reasoning": return text("text")
        case "command_execution": return "$ " + (text("input").split(separator: "\n").first.map(String.init) ?? "")
        case "file_change": return "Editing " + text("fileName")
        case "file_search": return "Searching " + text("pattern")
        case "web_search": return "Searching the web"
        default: return text("title")
        }
    }

    // MARK: - Images

    /// Attachment images by id, loaded through T3's `assets.createUrl`.
    private(set) var attachmentImages: [String: NSImage] = [:]
    @ObservationIgnored private var loadingImages = Set<String>()

    func loadImage(_ attachmentId: String) async {
        let env = targetThread?["environmentId"].string
        guard !Store.demo, attachmentImages[attachmentId] == nil, !loadingImages.contains(attachmentId),
              let rpc = rpc(for: env), let (base, token) = http(for: env) else { return }
        loadingImages.insert(attachmentId)
        defer { loadingImages.remove(attachmentId) }
        guard let result = try? await rpc.call("assets.createUrl", [
            "resource": ["_tag": "attachment", "attachmentId": .string(attachmentId), "disposition": "inline"],
        ]), let relative = result["relativeUrl"].string,
              let url = URL(string: relative, relativeTo: base) else { return }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await URLSession.shared.data(for: request), let image = NSImage(data: data) else { return }
        attachmentImages[attachmentId] = image
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
        // The focused chat's run ended (finished, failed or stopped), whoever started it.
        if active.contains(oldStatus), !active.contains(newStatus) {
            awaitingThreadId = nil
            unseenReply = true
            if Settings.showWhenChatFinishes { onAttentionNeeded?(.finished) }
        }
    }

    // MARK: - Commands

    /// Sends a prompt. ⏎ queues it after the running turn; ⌘⏎ steers the running turn.
    /// Steer mirrors T3's own UI (`packages/client-runtime/src/operations/commands.ts`):
    /// `start_immediately` with `deliveryIntent: "steer"`, which starts normally when idle.
    func send(_ text: String, steer: Bool = false, clips: [Clip] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !clips.isEmpty else { return }
        guard let key = targetThreadId else {
            lastSendError = threads.isEmpty
                ? "No threads loaded from T3 yet. Reconnecting…"
                : "No thread to send to. Pin one in T3 or pick one with ⌘K."
            if threads.isEmpty { reconnectNow() }
            return
        }
        if Store.demo {
            onDemoSend?(trimmed, steer, clips.count)
            return
        }
        guard let target else {
            lastSendError = "\(environmentLabel(for: targetThread) ?? "T3") is not connected. Trying again…"
            linked[targetThread?["environmentId"].string ?? ""]?.reconnectNow()
            return
        }
        let threadId = target.threadId
        let id = UUID().uuidString.lowercased()
        lastSendError = nil
        var command: [String: JSON] = [
            "type": "message.dispatch",
            "commandId": .string(id),
            "threadId": .string(threadId),
            "messageId": .string(id),
            "text": .string(trimmed),
            "attachments": [],
            "dispatchMode": ["type": "queue_after_active"],
            "createdBy": "user",
            "creationSource": "web",
        ]
        if steer {
            command["dispatchMode"] = ["type": "start_immediately"]
            command["deliveryIntent"] = "steer"
        }
        do {
            if !clips.isEmpty {
                let upload = Self.clipUploads(clips)
                command["attachments"] = try await uploadImages(upload.images, threadId: threadId, messageId: id, rpc: target.rpc)
                if let block = upload.prompt { command["text"] = .string(trimmed.isEmpty ? block : trimmed + "\n\n" + block) }
            }
            _ = try await target.rpc.call("orchestration.dispatchCommand", .object(command))
            awaitingThreadId = key
        } catch {
            handleCommandError(error)
        }
        syncThreadSubscription()
    }

    /// Stores PNGs with T3 (`assets.persistChatAttachments`, base64 data URLs) and returns
    /// the attachment records `message.dispatch` takes.
    /// Each clip as images plus its entry in the `<selected-ui>` block: the window with the
    /// clip outlined (carrying the app data as T3's `source`) and the close-up. A clip with no
    /// context sends its close-up alone. Close-ups go first when T3's limits would be passed.
    static func clipUploads(_ clips: [Clip]) -> (images: [JSON], prompt: String?) {
        var images: [JSON] = []
        var entries: [JSON] = []
        func image(_ name: String, _ png: Data, source: JSON? = nil) -> JSON {
            var o: [String: JSON] = ["type": "image", "name": .string(name), "mimeType": "image/png",
                                     "sizeBytes": .number(Double(png.count)),
                                     "dataUrl": .string("data:image/png;base64," + png.base64EncodedString())]
            if let source { o["source"] = source }
            return .object(o)
        }
        guard let plan = clipPlan(clips) else { return ([], nil) }
        for (i, (clip, p)) in zip(clips, plan).enumerated() {
            let n = i + 1
            guard let ctx = clip.context else {
                images.append(image("selection-\(n).png", clip.png))
                continue
            }
            var windowName: String?, detailName: String?
            if p.window, let window = ctx.windowPNG {
                windowName = "selection-\(n)-window.png"
                images.append(image(windowName!, window, source: ctx.source()))
            }
            if p.detail {
                detailName = "selection-\(n)-detail.png"
                images.append(image(detailName!, clip.png))
            }
            entries.append(ctx.promptEntry(index: n, windowImage: windowName, detailImage: detailName))
        }
        return (images, PickContext.promptBlock(entries))
    }

    /// T3's limits for one message: 100 images and 80 MiB.
    static let maxClipBytes = 80 * 1024 * 1024, maxClipImages = 100

    /// Which images each clip sends within T3's limits: first one image per clip (the
    /// window, or the close-up when that is all there is or the window does not fit), then
    /// close-ups while they fit. Nil when even one image per clip is too much.
    static func clipPlan(_ clips: [Clip]) -> [(window: Bool, detail: Bool)]? {
        guard clips.count <= maxClipImages else { return nil }
        var plan = clips.map { c in (window: c.context?.windowPNG != nil, detail: c.context?.windowPNG == nil) }
        func size(_ i: Int) -> Int { plan[i].window ? clips[i].context!.windowPNG!.count : clips[i].png.count }
        var bytes = clips.indices.reduce(0) { $0 + size($1) }
        // Over budget: send the smaller image for the clips with the biggest windows.
        for i in clips.indices.sorted(by: { size($0) > size($1) }) where bytes > maxClipBytes && plan[i].window {
            let window = clips[i].context!.windowPNG!.count, detail = clips[i].png.count
            if detail < window { plan[i] = (false, true); bytes -= window - detail }
        }
        guard bytes <= maxClipBytes else { return nil }
        var count = clips.count
        for i in clips.indices where plan[i].window && !plan[i].detail && !clips[i].context!.detailIsRedundant {
            guard count < maxClipImages, bytes + clips[i].png.count <= maxClipBytes else { continue }
            plan[i].detail = true
            bytes += clips[i].png.count
            count += 1
        }
        return plan
    }

    private func uploadImages(_ uploads: [JSON], threadId: String, messageId: String, rpc: RPCClient) async throws -> JSON {
        let result = try await rpc.call("assets.persistChatAttachments", [
            "threadId": .string(threadId), "messageId": .string(messageId), "attachments": .array(uploads),
        ])
        guard let attachments = result["attachments"].array else {
            throw AppError.protocolMismatch("persistChatAttachments returned no attachments")
        }
        return .array(attachments)
    }

    func respond(decision: String) async {
        guard let req = pendingRequest else { return }
        if Store.demo { onDemoRespond?(decision); return }
        guard let threadId = target?.threadId else { return }
        await dispatch(["type": "runtime-request.respond", "commandId": .string(UUID().uuidString.lowercased()),
                        "threadId": .string(threadId), "requestId": .string(req.id), "decision": .string(decision)])
    }

    func answer(_ answers: [String: JSON]) async {
        guard let req = pendingRequest, let threadId = target?.threadId else { return }
        await dispatch(["type": "runtime-request.respond", "commandId": .string(UUID().uuidString.lowercased()),
                        "threadId": .string(threadId), "requestId": .string(req.id), "answers": .object(answers)])
    }

    func interruptRun() async {
        guard let threadId = target?.threadId, let runId = targetThread?["activeRunId"].string else { return }
        await dispatch(["type": "run.interrupt", "commandId": .string(UUID().uuidString.lowercased()),
                        "threadId": .string(threadId), "runId": .string(runId)])
    }

    private func dispatch(_ command: JSON) async {
        lastSendError = nil
        guard let rpc = target?.rpc else { lastSendError = "Not connected to the chat's environment"; return }
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
    /// Opens the focused chat in T3. With `prompt`, T3 fills its chat box with it (its own
    /// prompt-link format; T3 asks first if that chat already has a draft).
    func openTargetInT3(prompt: String? = nil) {
        // A linked environment's chat opens under that environment's id, as T3 shows it.
        guard let t = targetThread, let id = t["id"].string, let env = t["environmentId"].string else {
            runtime?.app?.activate()
            return
        }
        // Thread ids can contain ":" (e.g. "mcp:…"), so encode each path segment.
        let segment = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? s }
        guard var comps = URLComponents(string: "\(Self.appScheme)://threads/\(segment(env))/\(segment(id))")
        else { return }
        if let prompt, !prompt.isEmpty {
            comps.queryItems = [URLQueryItem(name: "prompt", value: String(prompt.prefix(7900)))]
        }
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}

/// User settings, kept in UserDefaults.
enum Settings {
    /// Global shortcut that shows or hides the island. ⌥Space by default.
    static var showIslandKey: KeyBinding {
        get { binding("showIslandKey") ?? .showIsland }
        set { setBinding(newValue, "showIslandKey") }
    }

    /// Global shortcut that hides or shows the status dot. ⌥⇧Space by default.
    static var toggleDotKey: KeyBinding {
        get { binding("toggleDotKey") ?? .toggleDot }
        set { setBinding(newValue, "toggleDotKey") }
    }

    /// The island's shortcut for the chat list. ⌘K by default.
    static var showChatsKey: KeyBinding {
        get { binding("showChatsKey") ?? .showChats }
        set { setBinding(newValue, "showChatsKey") }
    }

    /// The island's shortcut for opening the chat in T3. ⌘O by default.
    static var openInT3Key: KeyBinding {
        get { binding("openInT3Key") ?? .openInT3 }
        set { setBinding(newValue, "openInT3Key") }
    }

    private static func binding(_ key: String) -> KeyBinding? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyBinding.self, from: $0) }
    }

    private static func setBinding(_ b: KeyBinding, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(b), forKey: key)
    }

    /// While the agent works, also show its commands and tool steps, not only its thinking.
    /// Off by default: commands can be long.
    static var showToolSteps: Bool {
        get { UserDefaults.standard.bool(forKey: "showToolSteps") }
        set { UserDefaults.standard.set(newValue, forKey: "showToolSteps") }
    }

    /// Peek at the focused chat when the pointer moves onto the notch. On by default.
    static var expandOnHover: Bool {
        get { UserDefaults.standard.object(forKey: "expandOnHover") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "expandOnHover") }
    }

    /// Pop the island open when the focused chat's run ends. On by default.
    static var showWhenChatFinishes: Bool {
        get { Store.demo || (UserDefaults.standard.object(forKey: "showWhenChatFinishes") as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: "showWhenChatFinishes") }
    }
}
