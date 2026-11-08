import Foundation
import Synchronization

// Records a real conversation with Hermes so it can be replayed by the fake Hermes in tests.
// Wrap the real transports with these, run a scenario, then call `FixtureRecorder.fixture()`.
//
// Fixture format (also read by the test target's FakeHermes):
// {
//   "description": "...",
//   "control": [ {"expect": {"verb": "identify"}, "reply": {...}} ],
//   "http":    [ {"expect": {"method": "GET", "path": "/api/status", "query": {...}}, "reply": {"status": 200, "body": {...}}} ],
//   "connections": [
//     { "onOpen": [<server frame>...],
//       "exchanges": [ {"expect": {"method": "...", "params": {...}}, "result": ... | "error": {...}, "then": [<frame> | {"close": 4401}]},
//                      {"expect": {"response_to": "srq-1"}, "then": [...]} ] }
//   ]
// }

public final class FixtureRecorder: Sendable {
    private struct State {
        var control: [JSON] = []
        var http: [JSON] = []
        var connections: [[(outbound: Bool, frame: JSON)]] = []
    }
    private let state = Mutex(State())
    public let description: String

    public init(description: String) {
        self.description = description
    }

    func recordControl(request: JSON, reply: JSON) {
        let verb = request["verb"].string ?? ""
        state.withLock { $0.control.append(["expect": ["verb": .string(verb)], "reply": Self.redact(reply)]) }
    }

    func recordHTTP(_ request: HTTPRequest, _ response: HTTPResponse) {
        let comps = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        var query: [String: JSON] = [:]
        for item in comps?.queryItems ?? [] where item.name != "ticket" { query[item.name] = .string(item.value ?? "") }
        var expect: [String: JSON] = ["method": .string(request.method), "path": .string(comps?.path ?? "")]
        if !query.isEmpty { expect["query"] = .object(query) }
        let body = (try? JSON(data: response.body)) ?? .string(String(decoding: response.body, as: UTF8.self))
        state.withLock {
            $0.http.append(["expect": .object(expect), "reply": ["status": .number(Double(response.status)), "body": Self.redact(body)]])
        }
    }

    func openConnection() -> Int {
        state.withLock {
            $0.connections.append([])
            return $0.connections.count - 1
        }
    }

    func recordFrame(connection: Int, outbound: Bool, text: String) {
        guard let frame = try? JSON(text: text) else { return }
        if frame["method"].string == "gateway.ping" || frame["id"].string?.hasPrefix("heartbeat-") == true { return }
        state.withLock { $0.connections[connection].append((outbound, frame)) }
    }

    /// The recorded conversation as a fixture.
    public func fixture() -> JSON {
        state.withLock { s in
            let connections: [JSON] = s.connections.map { Self.connectionFixture($0) }
            return [
                "description": .string(description), "control": .array(s.control), "http": .array(s.http),
                "connections": .array(connections),
            ]
        }
    }

    private static func connectionFixture(_ frames: [(outbound: Bool, frame: JSON)]) -> JSON {
        var onOpen: [JSON] = []
        var exchanges: [[String: JSON]] = []
        var responses: [String: JSON] = [:]  // id text → response frame
        for (outbound, frame) in frames where !outbound && frame["method"].isNull {
            responses[frame["id"].text] = frame
        }
        var current: Int? = nil
        for (outbound, frame) in frames {
            if outbound {
                if let method = frame["method"].string {
                    var ex: [String: JSON] = ["expect": ["method": .string(method), "params": redact(frame["params"])], "then": []]
                    if let resp = responses[frame["id"].text] {
                        if resp["error"].object != nil { ex["error"] = resp["error"] } else { ex["result"] = redact(resp["result"]) }
                    }
                    exchanges.append(ex)
                } else if let id = frame["id"].string {
                    exchanges.append(["expect": ["response_to": .string(id), "result": frame["result"]], "then": []])
                }
                current = exchanges.count - 1
            } else if frame["method"].isNull {
                continue  // a response, already attached to its request
            } else if let c = current {
                if case .array(var then) = exchanges[c]["then"] ?? .array([]) {
                    then.append(redact(frame))
                    exchanges[c]["then"] = .array(then)
                }
            } else {
                onOpen.append(redact(frame))
            }
        }
        return ["onOpen": .array(onOpen), "exchanges": .array(exchanges.map { JSON.object($0) })]
    }

    /// Removes secrets (tickets, tokens) from recorded data.
    static func redact(_ j: JSON) -> JSON {
        switch j {
        case .object(let o):
            var out: [String: JSON] = [:]
            for (k, v) in o {
                if ["ticket", "access_token", "refresh_token", "token", "value"].contains(k), v.string != nil {
                    out[k] = "REDACTED"
                } else {
                    out[k] = redact(v)
                }
            }
            return .object(out)
        case .array(let a): return .array(a.map(redact))
        default: return j
        }
    }
}

public struct RecordingControlSocket: ControlSocket {
    let inner: ControlSocket
    let recorder: FixtureRecorder
    public init(_ inner: ControlSocket, recorder: FixtureRecorder) {
        self.inner = inner
        self.recorder = recorder
    }
    public func request(_ message: JSON) async throws -> JSON {
        let reply = try await inner.request(message)
        recorder.recordControl(request: message, reply: reply)
        return reply
    }
}

public struct RecordingHTTPClient: HTTPClient {
    let inner: HTTPClient
    let recorder: FixtureRecorder
    public init(_ inner: HTTPClient, recorder: FixtureRecorder) {
        self.inner = inner
        self.recorder = recorder
    }
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await inner.send(request)
        recorder.recordHTTP(request, response)
        return response
    }
}

public struct RecordingSocketFactory: SocketFactory {
    let inner: SocketFactory
    let recorder: FixtureRecorder
    public init(_ inner: SocketFactory, recorder: FixtureRecorder) {
        self.inner = inner
        self.recorder = recorder
    }
    public func open(_ dial: WebSocketDial) async throws -> FrameSocket {
        let socket = try await inner.open(dial)
        return RecordingSocket(inner: socket, recorder: recorder, index: recorder.openConnection())
    }
}

struct RecordingSocket: FrameSocket {
    let inner: FrameSocket
    let recorder: FixtureRecorder
    let index: Int
    func send(_ text: String) async throws {
        recorder.recordFrame(connection: index, outbound: true, text: text)
        try await inner.send(text)
    }
    func receive() async throws -> String {
        let text = try await inner.receive()
        recorder.recordFrame(connection: index, outbound: false, text: text)
        return text
    }
    func close(code: Int) { inner.close(code: code) }
}
