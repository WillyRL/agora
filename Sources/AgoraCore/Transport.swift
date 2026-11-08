import Foundation

// The edges Agora talks through. Real implementations live in `SystemTransport.swift`;
// tests swap in `FakeHermes`, which replays recorded protocol conversations.

/// How to open the gateway WebSocket.
public struct WebSocketDial: Sendable, Equatable {
    public var url: URL
    public var protocols: [String]
    public var headers: [String: String]

    public init(url: URL, protocols: [String] = [], headers: [String: String] = [:]) {
        self.url = url
        self.protocols = protocols
        self.headers = headers
    }
}

/// An open WebSocket carrying JSON-RPC text frames.
public protocol FrameSocket: Sendable {
    func send(_ text: String) async throws
    /// Next text frame. Throws `SocketClosed` when the peer closes.
    func receive() async throws -> String
    func close(code: Int)
}

public struct SocketClosed: Error, Sendable, Equatable {
    public var code: Int
    public var reason: String
    public init(code: Int, reason: String = "") {
        self.code = code
        self.reason = reason
    }
}

public protocol SocketFactory: Sendable {
    func open(_ dial: WebSocketDial) async throws -> FrameSocket
}

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    public var bodyJSON: JSON? { body.flatMap { try? JSON(data: $0) } }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
    public var json: JSON { (try? JSON(data: body)) ?? .null }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// The local gateway's control socket (`~/.hermes/gateway.sock`): one JSON line in, one JSON line out.
public protocol ControlSocket: Sendable {
    func request(_ message: JSON) async throws -> JSON
}

/// Runs `hermes gateway ensure --json` and returns its one line of JSON output.
public protocol GatewayStarter: Sendable {
    func ensure() async throws -> JSON
}
