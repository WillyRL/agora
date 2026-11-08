import Foundation
import Synchronization

@testable import AgoraCore

/// A fake Hermes that replays a recorded protocol conversation (a fixture, see `Recording.swift`).
/// It plays every edge Agora talks through: the control socket, the WebSocket, and REST.
final class FakeHermes: SocketFactory, HTTPClient, ControlSocket, GatewayStarter, TailnetSource, @unchecked Sendable {
    struct Exchange {
        var expect: JSON
        var result: JSON?
        var error: JSON?
        var then: [JSON]
        var used = false
    }

    struct Script {
        var onOpen: [JSON]
        var exchanges: [Exchange]
        var refuse: SocketClosed?
        var stall = false
    }

    private struct State {
        var control: [JSON]
        var controlUsed: Set<Int> = []
        var http: [(expect: JSON, reply: JSON, repeats: Bool, used: Bool)]
        var scripts: [Script]
        var opened = 0
        var live: FakeSocket?
        var dials: [WebSocketDial] = []
        var sent: [JSON] = []
        var httpRequests: [HTTPRequest] = []
        var unexpected: [String] = []
        var ensureReply: JSON?
        var ensureCalls = 0
        var controlDown = false
        var controlVerbs: [String] = []
        var tailscale: JSON?
    }

    private let state: Mutex<State>

    init(fixture: JSON) {
        let control = fixture["control"].array ?? []
        let http = (fixture["http"].array ?? []).map { (expect: $0["expect"], reply: $0["reply"], repeats: $0["repeat"].bool ?? false, used: false) }
        let scripts = (fixture["connections"].array ?? []).map { c in
            Script(
                onOpen: c["onOpen"].array ?? [],
                exchanges: (c["exchanges"].array ?? []).map {
                    Exchange(expect: $0["expect"], result: Self.optional($0["result"]), error: Self.optional($0["error"]), then: $0["then"].array ?? [])
                },
                refuse: c["refuse"].int.map { SocketClosed(code: $0, reason: c["reason"].string ?? "") }, stall: c["stall"].bool ?? false)
        }
        state = Mutex(State(control: control, http: http, scripts: scripts, ensureReply: Self.optional(fixture["ensure"])))
        if fixture["controlDown"].bool == true { state.withLock { $0.controlDown = true } }
        state.withLock { $0.tailscale = Self.optional(fixture["tailscale"]) }
    }

    static func optional(_ j: JSON) -> JSON? { j.isNull ? Optional<JSON>.none : j }

    convenience init(named name: String) throws {
        self.init(fixture: try Fixtures.load(name))
    }

    // MARK: Inspection

    /// Every JSON-RPC frame Agora sent (requests and responses), in order.
    var sent: [JSON] { state.withLock { $0.sent } }
    var sentMethods: [String] { sent.compactMap { $0["method"].string } }
    func sent(_ method: String) -> [JSON] { sent.filter { $0["method"].string == method } }
    var responses: [JSON] { sent.filter { $0["method"].isNull } }
    var unexpected: [String] { state.withLock { $0.unexpected } }
    var dials: [WebSocketDial] { state.withLock { $0.dials } }
    var httpRequests: [HTTPRequest] { state.withLock { $0.httpRequests } }
    var ensureCalls: Int { state.withLock { $0.ensureCalls } }
    var ticketsMinted: Int { state.withLock { $0.controlVerbs.filter { $0 == "session-ticket" }.count } }

    // MARK: Driving

    /// Sends a frame from the server now.
    func push(_ frame: JSON) {
        state.withLock { $0.live }?.deliver(frame)
    }

    func pushEvent(_ type: String, session: String? = nil, seq: Int? = nil, generation: Int? = nil, payload: JSON = [:]) {
        var params: [String: JSON] = ["type": .string(type), "payload": payload]
        if let session { params["session_id"] = .string(session) }
        if let seq { params["seq"] = .number(Double(seq)) }
        if let generation { params["execution_generation"] = .number(Double(generation)) }
        push(["jsonrpc": "2.0", "method": "event", "params": .object(params)])
    }

    /// Drops the live socket with a close code (as Hermes restarting or the network would).
    func drop(code: Int = 1006, reason: String = "") {
        state.withLock { $0.live }?.closeFromServer(SocketClosed(code: code, reason: reason))
    }

    // MARK: SocketFactory

    func open(_ dial: WebSocketDial) async throws -> FrameSocket {
        let (script, socket): (Script?, FakeSocket) = state.withLock { s in
            s.dials.append(dial)
            let index = s.opened
            s.opened += 1
            let socket = FakeSocket(owner: self, index: index)
            if index < s.scripts.count {
                if s.scripts[index].refuse == nil, !s.scripts[index].stall { s.live = socket }
                return (s.scripts[index], socket)
            }
            return (nil, socket)
        }
        guard let script else {
            throw SocketClosed(code: 1006, reason: "no scripted connection #\(dials.count)")
        }
        if let refuse = script.refuse { throw refuse }
        if script.stall {
            try await Task.sleep(for: .seconds(3600))
        }
        for frame in script.onOpen { socket.deliver(frame) }
        return socket
    }

    fileprivate func clientSent(_ text: String, on socket: FakeSocket) {
        guard let frame = try? JSON(text: text) else { return }
        if frame["method"].string == "gateway.ping" {
            socket.deliver(["jsonrpc": "2.0", "id": frame["id"], "result": ["ok": true]])
            return
        }
        state.withLock { $0.sent.append(frame) }
        let (reply, then): (JSON?, [JSON]) = state.withLock { s in
            guard s.scripts.indices.contains(socket.index) else { return (nil, []) }
            var script = s.scripts[socket.index]
            defer { s.scripts[socket.index] = script }
            guard let i = script.exchanges.indices.first(where: { !script.exchanges[$0].used && Self.matches(script.exchanges[$0].expect, frame) }) else {
                if let method = frame["method"].string {
                    s.unexpected.append("\(method) \(frame["params"].text)")
                    return (["jsonrpc": "2.0", "id": frame["id"], "error": ["code": -32601, "message": .string("FakeHermes: unscripted \(method)")]], [])
                }
                return (nil, [])
            }
            script.exchanges[i].used = true
            let ex = script.exchanges[i]
            guard frame["method"].string != nil else { return (nil, ex.then) }
            var reply: [String: JSON] = ["jsonrpc": "2.0", "id": frame["id"]]
            if let error = ex.error { reply["error"] = error } else { reply["result"] = ex.result ?? .null }
            return (.object(reply), ex.then)
        }
        if let reply { socket.deliver(reply) }
        for f in then {
            if let code = f["close"].int {
                socket.closeFromServer(SocketClosed(code: code, reason: f["reason"].string ?? ""))
            } else {
                socket.deliver(f)
            }
        }
    }

    /// `expect` is a partial pattern: every key it names must match the frame.
    static func matches(_ expect: JSON, _ frame: JSON) -> Bool {
        if let id = expect["response_to"].string {
            guard frame["method"].isNull, frame["id"].string == id else { return false }
            return expect["result"].isNull || subset(expect["result"], of: frame["result"])
        }
        guard frame["method"].string == expect["method"].string else { return false }
        return expect["params"].isNull || subset(expect["params"], of: frame["params"])
    }

    static func subset(_ a: JSON, of b: JSON) -> Bool {
        switch (a, b) {
        case (.object(let ao), .object(let bo)):
            return ao.allSatisfy { k, v in
                if v.string == "*" { return bo[k] != nil }
                return subset(v, of: bo[k] ?? .null)
            }
        case (.number(let x), .number(let y)): return x == y
        default: return a == b
        }
    }

    // MARK: ControlSocket

    func request(_ message: JSON) async throws -> JSON {
        let verb = message["verb"].string ?? ""
        return try state.withLock { s in
            s.controlVerbs.append(verb)
            if s.controlDown { throw HermesError.hermesUnavailable("socket missing") }
            let candidates = s.control.indices.filter { s.control[$0]["expect"]["verb"].string == verb }
            guard let pick = candidates.first(where: { !s.controlUsed.contains($0) }) ?? candidates.last else {
                throw HermesError.hermesUnavailable("FakeHermes: no control reply for \(verb)")
            }
            s.controlUsed.insert(pick)
            return s.control[pick]["reply"]
        }
    }

    // MARK: GatewayStarter

    func ensure() async throws -> JSON {
        try state.withLock { s in
            s.ensureCalls += 1
            guard let reply = s.ensureReply else { throw HermesError.hermesUnavailable("FakeHermes: no ensure") }
            s.controlDown = false
            return reply
        }
    }

    // MARK: TailnetSource

    func status() async throws -> JSON {
        guard let status = state.withLock({ $0.tailscale }) else { throw TailnetUnavailable.notInstalled }
        return status
    }

    // MARK: HTTPClient

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        state.withLock { s in
            s.httpRequests.append(request)
            let comps = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            var query: [String: JSON] = [:]
            for item in comps?.queryItems ?? [] { query[item.name] = .string(item.value ?? "") }
            let actual: JSON = [
                "method": .string(request.method), "host": .string(comps?.host ?? ""), "port": comps?.port.map { .number(Double($0)) } ?? .null,
                "path": .string(comps?.path ?? ""), "query": .object(query), "body": request.bodyJSON ?? .null,
            ]
            guard let i = s.http.indices.first(where: { !s.http[$0].used && Self.subset(s.http[$0].expect, of: actual) }) else {
                s.unexpected.append("HTTP \(request.method) \(request.url.absoluteString)")
                return HTTPResponse(status: 404, body: Data(#"{"detail":"FakeHermes: unscripted"}"#.utf8))
            }
            if !s.http[i].repeats { s.http[i].used = true }
            let reply = s.http[i].reply
            let body = reply["body"]
            return HTTPResponse(status: reply["status"].int ?? 200, body: body.string.map { Data($0.utf8) } ?? body.data())
        }
    }
}

final class FakeSocket: FrameSocket, @unchecked Sendable {
    let owner: FakeHermes
    let index: Int
    private let lock = NSLock()
    private var buffer: [Result<String, SocketClosed>] = []
    private var waiter: CheckedContinuation<Result<String, SocketClosed>, Never>?
    private var closed = false

    init(owner: FakeHermes, index: Int) {
        self.owner = owner
        self.index = index
    }

    private func enqueue(_ item: Result<String, SocketClosed>) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: item)
        } else {
            buffer.append(item)
            lock.unlock()
        }
    }

    func deliver(_ frame: JSON) {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }
        enqueue(.success(frame.text))
    }

    func closeFromServer(_ c: SocketClosed) {
        lock.lock()
        let was = closed
        closed = true
        lock.unlock()
        guard !was else { return }
        enqueue(.failure(c))
    }

    func send(_ text: String) async throws {
        let isClosed = lock.withLock { closed }
        if isClosed { throw SocketClosed(code: 1006) }
        owner.clientSent(text, on: self)
    }

    func receive() async throws -> String {
        let item: Result<String, SocketClosed> = await withCheckedContinuation { c in
            lock.lock()
            if !buffer.isEmpty {
                let first = buffer.removeFirst()
                lock.unlock()
                c.resume(returning: first)
            } else {
                waiter = c
                lock.unlock()
            }
        }
        return try item.get()
    }

    func close(code: Int) {
        closeFromServer(SocketClosed(code: code))
    }
}

