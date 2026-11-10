import Foundation
import Network

extension AgoraCore {
    /// Is Hermes installed on this Mac? (The setup screen pre-fills a Local Connection when it is.)
    public static var localHermesInstalled: Bool { UnixControlSocket().hermesInstalled }

    /// Asks a `hermes serve` which logins it accepts.
    public func probeRemote(_ url: URL) async throws -> RemoteAccess.Status {
        try await RemoteAccess.probe(baseURL: url, http: env.http)
    }

    /// Keeps the Cloudflare Access login for a Hermes behind a Cloudflare Tunnel (see `CloudflareAccess`).
    public func saveAccessToken(_ token: String, for url: URL) {
        guard let key = CloudflareAccess.key(for: url) else { return }
        env.accessTokens.save(token, for: key)
    }

    /// Logs in to Cloudflare Access in your browser and returns the app token (see `AccessBrowserLogin`).
    public func accessTokenFromBrowser(for origin: URL, openBrowser: @escaping @Sendable (URL) -> Void) async throws -> String {
        try await AccessBrowserLogin(origin: origin, http: env.directHTTP).run(openBrowser: openBrowser)
    }

    /// Adds a Local Connection (Hermes on this Mac) and makes it active.
    @discardableResult
    public func addLocalConnection(name: String = "This Mac") async -> SavedConnection {
        let saved = registry.connections.first(where: \.isLocal) ?? registry.add(name: name, kind: .local)
        registry.activate(saved.id)
        await start()
        return saved
    }

    /// Adds a Remote Connection with a pasted session token (kept in Keychain) and makes it active.
    @discardableResult
    public func addRemoteConnection(name: String, url: URL, token: String) async -> SavedConnection {
        env.credentials.save(.token(token.trimmingCharacters(in: .whitespacesAndNewlines)), for: RemoteAccess.credentialKey(for: url))
        return await addRemote(name: name, url: url)
    }

    /// Adds a Remote Connection by signing in through the browser (OAuth with PKCE), then makes it active.
    @discardableResult
    public func addRemoteConnection(
        name: String, url: URL, receiver: LoopbackReceiver, openBrowser: @escaping @Sendable (URL) -> Void
    ) async throws -> SavedConnection {
        try await BrowserSignIn(baseURL: url, http: env.http, credentials: env.credentials).run(receiver: receiver, openBrowser: openBrowser)
        return await addRemote(name: name, url: url)
    }

    /// Signs in again to the active Remote Connection after its login expired.
    public func signInAgain(receiver: LoopbackReceiver, openBrowser: @escaping @Sendable (URL) -> Void) async throws {
        guard let url = registry.active?.remoteURL else { return }
        try await BrowserSignIn(baseURL: url, http: env.http, credentials: env.credentials).run(receiver: receiver, openBrowser: openBrowser)
        await start()
    }

    /// Replaces the session token of the active Remote Connection.
    public func updateToken(_ token: String) async {
        guard let url = registry.active?.remoteURL else { return }
        env.credentials.save(.token(token.trimmingCharacters(in: .whitespacesAndNewlines)), for: RemoteAccess.credentialKey(for: url))
        await start()
    }

    private func addRemote(name: String, url: URL) async -> SavedConnection {
        let existing = registry.connections.first { $0.remoteURL.map(RemoteAccess.credentialKey(for:)) == RemoteAccess.credentialKey(for: url) }
        let saved = existing ?? registry.add(name: name.isEmpty ? (url.host ?? "Remote") : name, kind: .remote(url))
        registry.activate(saved.id)
        await start()
        return saved
    }

    public func renameConnection(_ id: UUID, to name: String) {
        registry.rename(id, to: name)
    }

    /// Removes a Connection and its Keychain entry. If it was active, switches to the next one.
    public func removeConnection(_ id: UUID) async {
        let wasActive = registry.activeID == id
        guard let removed = registry.remove(id) else { return }
        if let url = removed.remoteURL, !registry.connections.contains(where: { $0.remoteURL.map(RemoteAccess.credentialKey(for:)) == RemoteAccess.credentialKey(for: url) }) {
            env.credentials.save(nil, for: RemoteAccess.credentialKey(for: url))
        }
        if let url = removed.remoteURL, let key = CloudflareAccess.key(for: url),
            !registry.connections.contains(where: { $0.remoteURL.flatMap(CloudflareAccess.key(for:)) == key }) {
            env.accessTokens.save(nil, for: key)
        }
        if wasActive { await start() }
    }

    /// Whether the active Remote Connection uses a pasted token or browser sign-in.
    public var activeLoginMethod: String? {
        guard let url = registry.active?.remoteURL else { return nil }
        switch env.credentials.load(for: RemoteAccess.credentialKey(for: url)) {
        case .token: return "token"
        case .oauth: return "browser"
        case nil: return nil
        }
    }
}

/// Listens on `http://127.0.0.1:<port>/callback` for the browser to come back after sign-in.
public final class NetworkLoopbackReceiver: LoopbackReceiver, @unchecked Sendable {
    private let queue = DispatchQueue(label: "agora.loopback")
    private var listener: NWListener?
    private var waiter: CheckedContinuation<URL, Error>?
    private var received: URL?
    private let timeout: Duration

    public init(timeout: Duration = .seconds(300)) {
        self.timeout = timeout
    }

    public func start() async throws -> URL {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e):
                    once.done = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)/callback")!
    }

    public func callback() async throws -> URL {
        let timeout = self.timeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(.failure(HermesError.timeout("browser sign-in")))
        }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let received = self.received {
                    cont.resume(returning: received)
                } else {
                    self.waiter = cont
                }
            }
        }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.waiter?.resume(throwing: CancellationError())
            self.waiter = nil
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        queue.async {
            if case .success(let url) = result { self.received = url }
            guard let waiter = self.waiter else { return }
            self.waiter = nil
            waiter.resume(with: result)
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            let body = "<html><body style='font-family:-apple-system;padding:40px'><h2>Signed in to Agora</h2><p>You can close this window.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if parts.count >= 2, let url = URL(string: "http://127.0.0.1\(parts[1])"), url.query?.contains("code=") == true || url.query?.contains("error=") == true {
                self?.finish(.success(url))
            }
        }
    }
}

/// Guards a continuation that is resumed from a serial queue's callbacks.
private final class ResumeOnce: @unchecked Sendable {
    var done = false
}
