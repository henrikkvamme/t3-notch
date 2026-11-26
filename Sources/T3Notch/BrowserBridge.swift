import Foundation
import Network
import os

/// A page element that the browser extension knows by handle, in one tab of one browser.
struct DOMNode: Sendable, Equatable {
    let client: Int
    let tab: Int
    let handle: Int
}

/// Talks to the T3 Notch browser extension (`Extension/`), so clip mode can pick page
/// elements and not only the boxes that a browser's accessibility tree shows.
///
/// The app is the WebSocket server, on 127.0.0.1 only: port 47823 for the release app and
/// 47824 for the dev build, so both can run. It accepts only connections whose `Origin` is
/// the extension (a web page cannot set that header). Each browser with the extension holds
/// one connection; requests go to every connection and the first useful answer wins.
///
/// Requests block the caller with a short timeout, so call them off the main thread (the
/// element probe's queue).
final class BrowserBridge: @unchecked Sendable {
    static let shared = BrowserBridge()

    static let extensionID = "aaialiblkjbkniojpbiclkenpbainplf"
    static let port: UInt16 = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev") ? 47824 : 47823

    private let queue = DispatchQueue(label: "t3notch.browser-bridge")
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.t3notch.app", category: "browser")
    private var listener: NWListener?
    // Touched only on `queue`.
    private var clients: [Int: NWConnection] = [:]
    private var nextClient = 1
    private var pending: [Int: Pending] = [:]
    private var nextRequest = 1

    private final class Pending {
        var waiting: Set<Int>
        var result: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        init(waiting: Set<Int>) { self.waiting = waiting }
    }

    /// True while at least one browser is connected. Read from any thread.
    var isConnected: Bool { queue.sync { !clients.isEmpty } }

    /// Called on the main thread when a browser connects or goes away. Set it once at launch.
    nonisolated(unsafe) var onChange: (@MainActor () -> Void)?

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            ws.maximumMessageSize = 4 * 1024 * 1024
            ws.setClientRequestHandler(queue) { _, headers in
                let origin = headers.first { $0.name.lowercased() == "origin" }?.value
                let ok = origin == "chrome-extension://\(Self.extensionID)"
                return NWProtocolWebSocket.Response(status: ok ? .accept : .reject, subprotocol: nil, additionalHeaders: nil)
            }
            let params = NWParameters.tcp
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            do {
                let l = try NWListener(using: params)
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { [weak self] state in
                    guard let self, case .failed(let e) = state else { return }
                    log.error("browser bridge failed: \(e.localizedDescription, privacy: .public)")
                    listener?.cancel()
                    listener = nil
                    // The port may be busy for a moment (a previous instance): try again.
                    queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
                }
                l.start(queue: queue)
                listener = l
            } catch {
                log.error("browser bridge did not start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func accept(_ c: NWConnection) {
        let id = nextClient
        nextClient += 1
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                clients[id] = c
                log.notice("browser connected (\(id, privacy: .public))")
                changed()
                receive(id, c)
            case .failed, .cancelled:
                drop(id)
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func drop(_ id: Int) {
        guard let c = clients.removeValue(forKey: id) else { return }
        c.cancel()
        log.notice("browser disconnected (\(id, privacy: .public))")
        for p in pending.values where p.waiting.remove(id) != nil && p.waiting.isEmpty { p.done.signal() }
        changed()
    }

    private func changed() {
        let handler = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?() } }
    }

    private func receive(_ id: Int, _ c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { drop(id); return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close { drop(id); return }
            if let data, meta?.opcode == .text,
               let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let rid = msg["id"] as? Int, let p = pending[rid], p.waiting.remove(id) != nil {
                if msg["ok"] as? Bool == true, var result = msg["result"] as? [String: Any], p.result == nil {
                    result["client"] = id
                    p.result = result
                    p.done.signal()
                } else if p.waiting.isEmpty {
                    p.done.signal()
                }
            }
            receive(id, c)
        }
    }

    /// Sends a request to one client (or all) and waits for the first useful answer.
    /// Returns nil on timeout, when no browser is connected, or when none had an answer.
    func request(_ body: [String: Any], to client: Int? = nil, timeout: TimeInterval) -> [String: Any]? {
        let (p, rid): (Pending?, Int) = queue.sync {
            let targets = client.map { clients[$0] != nil ? [$0] : [] } ?? Array(clients.keys)
            guard !targets.isEmpty else { return (nil, 0) }
            let rid = nextRequest
            nextRequest += 1
            var msg = body
            msg["id"] = rid
            guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return (nil, 0) }
            let p = Pending(waiting: Set(targets))
            pending[rid] = p
            for t in targets {
                let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                let ctx = NWConnection.ContentContext(identifier: "t3n", metadata: [meta])
                clients[t]?.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
            }
            return (p, rid)
        }
        guard let p else { return nil }
        let started = Date()
        _ = p.done.wait(timeout: .now() + timeout)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.debug("\(body["type"] as? String ?? "?", privacy: .public) answered=\(p.result != nil, privacy: .public) in \(ms, privacy: .public) ms")
        return queue.sync {
            pending[rid] = nil
            return p.result
        }
    }

    // MARK: - Requests

    /// A page's element chain in global points, smallest first.
    struct Chain {
        var nodes: [DOMNode]
        var frames: [CGRect]
        var labels: [String]
        var preferred: Int?
    }

    /// The elements under a point in the page shown in `area` (the AXWebArea frame).
    func hit(at p: CGPoint, area: CGRect, window: CGRect, url: String) -> Chain? {
        guard area.width > 0 else { return nil }
        let r = request(["type": "hit", "x": p.x, "y": p.y, "url": url,
                         "area": ["x": area.minX, "y": area.minY, "w": area.width, "h": area.height],
                         "window": ["x": window.minX, "y": window.minY, "w": window.width, "h": window.height]],
                        timeout: 0.25)
        return r.flatMap { Self.chain($0, area: area) }
    }

    /// The previous (−1) or next (+1) visible sibling of a node, with its chain.
    func sibling(of node: DOMNode, direction: Int, area: CGRect) -> Chain? {
        let r = request(["type": "sibling", "tab": node.tab, "handle": node.handle, "dir": direction],
                        to: node.client, timeout: 0.3)
        return r.flatMap { Self.chain($0, area: area) }
    }

    /// What the agent learns about a picked node.
    func describe(_ node: DOMNode) -> [String: Any]? {
        request(["type": "describe", "tab": node.tab, "handle": node.handle], to: node.client, timeout: 0.4)
    }

    /// Converts the page's CSS-pixel viewport rects to global points.
    static func chain(_ r: [String: Any], area: CGRect) -> Chain? {
        guard let client = r["client"] as? Int, let tab = r["tab"] as? Int,
              let nodes = r["nodes"] as? [[String: Any]], let width = r["innerWidth"] as? Double, width > 0
        else { return nil }
        let ptPerCSS = area.width / width
        var out = Chain(nodes: [], frames: [], labels: [], preferred: nil)
        let preferred = r["preferred"] as? Int
        for (i, n) in nodes.enumerated() {
            guard let h = n["id"] as? Int, let x = n["x"] as? Double, let y = n["y"] as? Double,
                  let w = n["w"] as? Double, let hh = n["h"] as? Double else { continue }
            let f = CGRect(x: area.minX + x * ptPerCSS, y: area.minY + y * ptPerCSS,
                           width: w * ptPerCSS, height: hh * ptPerCSS).intersection(area)
            guard !f.isNull, f.width >= 4, f.height >= 4 else { continue }
            if i == preferred { out.preferred = out.frames.count }
            out.nodes.append(DOMNode(client: client, tab: tab, handle: h))
            out.frames.append(f)
            out.labels.append(n["label"] as? String ?? "")
        }
        return out.frames.isEmpty ? nil : out
    }
}
