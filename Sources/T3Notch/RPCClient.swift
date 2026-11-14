import Foundation

/// Speaks T3's internal Effect RPC protocol over `/ws` with JSON serialization.
///
/// Client frames: `Request`, `Ack` (after every stream `Chunk`), `Interrupt`, `Ping`.
/// Server frames: `Chunk` (stream values), `Exit` (end of a request), `Pong`, `Defect`.
/// See `packages/contracts/src/rpc.ts` and `apps/server/src/terminal/OutputProtocol.ts` in T3.
@MainActor
final class RPCClient {
    typealias StreamHandler = (JSON) -> Void
    typealias EndHandler = (Result<JSON, AppError>) -> Void

    private var task: URLSessionWebSocketTask?
    private var nextId = 1
    private var streams: [String: (value: StreamHandler, end: EndHandler)] = [:]
    private var calls: [String: CheckedContinuation<JSON, Error>] = [:]
    private var pingTask: Task<Void, Never>?
    private(set) var isOpen = false

    /// Called once when the socket closes or fails, with a reason.
    var onClose: ((String) -> Void)?
    /// Called when a frame cannot be understood: a likely protocol change.
    var onProtocolError: ((String, String) -> Void)?

    let log = FrameLog()

    /// Exchanges the bearer token for a one-time ticket, then opens the socket.
    /// Throws `AppError.auth` on 401/403 so the caller can reissue the token.
    func connect(runtime: T3Runtime, token: String) async throws {
        var req = URLRequest(url: runtime.httpBase.appendingPathComponent("api/auth/websocket-ticket/rpc"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw AppError.auth("token rejected (\(status))") }
        guard status == 200, let ticket = try? JSON.parse(data)["ticket"].string else {
            throw AppError.protocolMismatch("websocket-ticket returned \(status): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
        }
        var comps = URLComponents()
        comps.scheme = "ws"; comps.host = "127.0.0.1"; comps.port = runtime.port; comps.path = "/ws"
        comps.queryItems = [URLQueryItem(name: "wsTicket", value: ticket),
                            URLQueryItem(name: "orchestrationProtocol", value: "2")]
        let task = URLSession.shared.webSocketTask(with: comps.url!)
        task.maximumMessageSize = 128 * 1024 * 1024 // shell snapshots are often > 1 MB
        self.task = task
        task.resume()
        isOpen = true
        receiveLoop(task)
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.sendFrame(["_tag": "Ping"])
            }
        }
    }

    func close() {
        guard let task else { return }
        self.task = nil
        task.cancel(with: .normalClosure, reason: nil)
        finish(reason: "closed")
    }

    /// Opens a stream request. Returns its id for `interrupt`.
    @discardableResult
    func subscribe(_ tag: String, _ payload: JSON, onValue: @escaping StreamHandler, onEnd: @escaping EndHandler) -> String {
        let id = makeId()
        streams[id] = (onValue, onEnd)
        sendFrame(["_tag": "Request", "id": .string(id), "tag": .string(tag), "payload": payload, "headers": []])
        return id
    }

    /// A unary request; returns the success value of its `Exit`.
    func call(_ tag: String, _ payload: JSON) async throws -> JSON {
        let id = makeId()
        return try await withCheckedThrowingContinuation { cont in
            calls[id] = cont
            sendFrame(["_tag": "Request", "id": .string(id), "tag": .string(tag), "payload": payload, "headers": []])
        }
    }

    func interrupt(_ id: String) {
        guard streams.removeValue(forKey: id) != nil else { return }
        sendFrame(["_tag": "Interrupt", "requestId": .string(id), "interruptors": []])
    }

    // MARK: - Internals

    private func makeId() -> String { defer { nextId += 1 }; return String(nextId) }

    private func sendFrame(_ frame: JSON) {
        guard let task else { return }
        let text = String(decoding: frame.encoded(), as: UTF8.self)
        log.record(direction: "->", text)
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.finish(reason: "send failed: \(error.localizedDescription)") }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do { message = try await task.receive() } catch {
                    self?.finish(reason: "socket closed: \(error.localizedDescription)")
                    return
                }
                guard let self, self.task === task else { return }
                switch message {
                case .string(let s): self.handle(text: s)
                case .data(let d): self.handle(text: String(decoding: d, as: UTF8.self))
                @unknown default: break
                }
            }
        }
    }

    private func handle(text: String) {
        log.record(direction: "<-", text)
        guard let json = try? JSON.parse(Data(text.utf8)) else {
            onProtocolError?("Server frame is not JSON", text)
            return
        }
        // The server may batch several messages into one frame.
        for frame in json.array ?? [json] { handle(frame: frame, raw: text) }
    }

    private func handle(frame: JSON, raw: String) {
        switch frame["_tag"].string {
        case "Chunk":
            guard let id = frame["requestId"].string else { return }
            sendFrame(["_tag": "Ack", "requestId": .string(id)])
            guard let stream = streams[id] else { return }
            for value in frame["values"].array ?? [] { stream.value(value) }
        case "Exit":
            guard let id = frame["requestId"].string else { return }
            let exit = frame["exit"]
            let ok = exit["_tag"].string == "Success"
            let failure = AppError.rpc(Self.describeFailure(exit))
            if let cont = calls.removeValue(forKey: id) {
                ok ? cont.resume(returning: exit["value"]) : cont.resume(throwing: failure)
            } else if let stream = streams.removeValue(forKey: id) {
                stream.end(ok ? .success(exit["value"]) : .failure(failure))
            }
        case "Pong":
            break
        case "Defect", "ClientProtocolError":
            onProtocolError?("Server reported \(frame["_tag"].string ?? "")", raw)
        default:
            onProtocolError?("Unknown server frame tag \(frame["_tag"].string ?? "nil")", raw)
        }
    }

    private static func describeFailure(_ exit: JSON) -> String {
        let text = String(decoding: exit["cause"].encoded(), as: UTF8.self)
        return String(text.prefix(800))
    }

    private func finish(reason: String) {
        guard isOpen else { return }
        isOpen = false
        pingTask?.cancel()
        pingTask = nil
        task = nil
        let error = AppError.rpc("connection lost: \(reason)")
        for (_, cont) in calls { cont.resume(throwing: error) }
        calls.removeAll()
        let ended = streams
        streams.removeAll()
        for (_, s) in ended { s.end(.failure(error)) }
        onClose?(reason)
    }
}

/// Keeps the last frames in memory so a protocol break can be written to disk with context.
@MainActor
final class FrameLog {
    private var frames: [String] = []
    private let limit = 200
    private let perFrameLimit = 20_000

    func record(direction: String, _ text: String) {
        let clipped = text.count > perFrameLimit ? String(text.prefix(perFrameLimit)) + "…[clipped \(text.count) chars]" : text
        frames.append("\(ISO8601DateFormatter().string(from: Date())) \(direction) \(clipped)")
        if frames.count > limit { frames.removeFirst(frames.count - limit) }
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/T3Notch")
    }

    /// Writes the buffered frames plus the failing one; returns the file.
    func dump(reason: String, failingFrame: String) -> URL {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("protocol-break-\(stamp).log")
        let body = "reason: \(reason)\n\nfailing frame:\n\(failingFrame)\n\nrecent frames (oldest first):\n" + frames.joined(separator: "\n")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
