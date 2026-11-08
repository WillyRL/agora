import Foundation

// Real transports: URLSession WebSockets and HTTP, the gateway's Unix control socket,
// and `hermes gateway ensure`.

public final class URLSessionSockets: SocketFactory {
    let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    public func open(_ dial: WebSocketDial) async throws -> FrameSocket {
        var request = URLRequest(url: dial.url)
        for (k, v) in dial.headers { request.setValue(v, forHTTPHeaderField: k) }
        if !dial.protocols.isEmpty {
            request.setValue(dial.protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        return URLSessionSocket(task: task)
    }
}

final class URLSessionSocket: FrameSocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let s): return s
            case .data(let d): return String(decoding: d, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            let code = task.closeCode.rawValue
            let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? error.localizedDescription
            throw SocketClosed(code: code == 0 ? 1006 : code, reason: reason)
        }
    }

    func close(code: Int) {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    }
}

public final class URLSessionHTTP: HTTPClient {
    let session: URLSession

    public init(timeout: TimeInterval = 60) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: r)
        return HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }
}

/// `~/.hermes/gateway.sock`: one newline-terminated JSON request, one reply, then the server closes.
public struct UnixControlSocket: ControlSocket {
    public let hermesHome: URL

    public init(hermesHome: URL = UnixControlSocket.defaultHermesHome) {
        self.hermesHome = hermesHome
    }

    public static var defaultHermesHome: URL {
        if let env = ProcessInfo.processInfo.environment["HERMES_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".hermes")
    }

    /// The socket path, following `gateway.sock.path` when the socket lives elsewhere.
    public var socketPath: String? {
        let direct = hermesHome.appending(path: "gateway.sock").path
        if Self.isOwnedSocket(direct) { return direct }
        if let pointer = try? String(contentsOf: hermesHome.appending(path: "gateway.sock.path"), encoding: .utf8) {
            let path = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasSuffix("/control.sock"), Self.isOwnedSocket(path) { return path }
        }
        return nil
    }

    /// Hermes is installed here if its home directory exists.
    public var hermesInstalled: Bool {
        FileManager.default.fileExists(atPath: hermesHome.path)
    }

    /// Only talk to a socket that is ours and private (a cheap guard against a planted socket).
    static func isOwnedSocket(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK && st.st_uid == getuid() && (st.st_mode & 0o077) == 0
    }

    public func request(_ message: JSON) async throws -> JSON {
        guard let path = socketPath else { throw HermesError.hermesUnavailable("Hermes isn't running on this Mac.") }
        let line = message.text + "\n"
        return try await Task.detached { try Self.exchange(path: path, line: line) }.value
    }

    static func exchange(path: String, line: String) throws -> JSON {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HermesError.hermesUnavailable("socket() failed") }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw HermesError.hermesUnavailable("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else { throw HermesError.hermesUnavailable("Hermes isn't running on this Mac.") }
        let out = Array(line.utf8)
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, out.count - sent) }
            guard n > 0 else { throw HermesError.hermesUnavailable("Couldn't talk to Hermes.") }
            sent += n
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count < 1_048_576 {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(UInt8(ascii: "\n")) { break }
        }
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) ?? (data.isEmpty ? nil : data.endIndex) else {
            throw HermesError.hermesUnavailable("Hermes closed the control socket without answering.")
        }
        return try JSON(data: data[data.startIndex..<newline])
    }
}

/// Starts the local Hermes service with the official idempotent starter, `hermes gateway ensure --json`.
public struct ProcessGatewayStarter: GatewayStarter {
    public let hermesHome: URL
    public init(hermesHome: URL = UnixControlSocket.defaultHermesHome) {
        self.hermesHome = hermesHome
    }

    public static func hermesExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".local/bin/hermes"), URL(fileURLWithPath: "/opt/homebrew/bin/hermes"),
            URL(fileURLWithPath: "/usr/local/bin/hermes"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func ensure() async throws -> JSON {
        guard let exe = Self.hermesExecutable() else {
            throw HermesError.hermesUnavailable("Couldn't find the `hermes` command on this Mac.")
        }
        let home = hermesHome
        return try await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = ["gateway", "ensure", "--json", "--timeout", "60"]
            var env = ProcessInfo.processInfo.environment
            env["HERMES_HOME"] = home.path
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            guard let json = try? JSON(text: line) else {
                throw HermesError.hermesUnavailable("`hermes gateway ensure` gave no answer (exit \(p.terminationStatus)).")
            }
            return json
        }.value
    }
}

/// Reads the tailnet with the Tailscale command line (`tailscale status --json`).
public struct TailscaleCLI: TailnetSource {
    public init() {}

    /// The app's own binary first: it always matches the running Tailscale.
    public static func executable() -> URL? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
        ]
        return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func status() async throws -> JSON {
        guard let exe = Self.executable() else { throw TailnetUnavailable.notInstalled }
        return try await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = ["status", "--json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let json = try? JSON(data: data) else {
                throw HermesError.hermesUnavailable("Tailscale didn't answer. Is it running?")
            }
            return json
        }.value
    }
}
