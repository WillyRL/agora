import Foundation

/// What Agora learns about the Hermes it reaches before opening the socket.
public struct ServerInfo: Sendable, Equatable {
    public var version: String?
    public var capabilities: [String]
    public init(version: String? = nil, capabilities: [String] = []) {
        self.version = version
        self.capabilities = capabilities
    }
}

/// Which REST permission a local ticket is minted for (remote ignores this).
public enum RESTPurpose: String, Sendable {
    case http = "native-http"
    case profileCreate = "native-profile-create"
    case profileRegistry = "native-profile-registry"
}

/// Gets Agora access to one Hermes: where it is, and fresh credentials for every
/// WebSocket dial and REST call. Local and Remote Connections differ only here.
public protocol AccessProvider: Sendable {
    func prepare() async throws -> ServerInfo
    func webSocketDial() async throws -> WebSocketDial
    /// Base URL and auth headers for one REST call aimed at `profile`.
    func restAccess(profile: String, purpose: RESTPurpose) async throws -> (base: URL, headers: [String: String])
    /// A REST call came back 401. Returns true if fresh credentials were obtained and the call may be retried.
    func recoverFromUnauthorized() async throws -> Bool
}

// MARK: - Local

/// Access to Hermes on this Mac through `~/.hermes/gateway.sock`.
public actor LocalAccess: AccessProvider {
    private let control: ControlSocket
    private let starter: GatewayStarter?
    private var identity: Identity?
    private var triedEnsure = false

    struct Identity {
        var apiOrigin: URL
        var instanceID: String
        var hermesHome: String
        var homes: [String: String]  // profile name → home path
        var version: String?
        var capabilities: [String]
    }

    public init(control: ControlSocket, starter: GatewayStarter? = nil) {
        self.control = control
        self.starter = starter
    }

    public func prepare() async throws -> ServerInfo {
        let id = try await identify()
        return ServerInfo(version: id.version, capabilities: id.capabilities)
    }

    public func webSocketDial() async throws -> WebSocketDial {
        let (ticket, id) = try await mintTicket(profileHome: nil, purpose: "interactive", hostScope: true)
        var comps = URLComponents(url: id.apiOrigin, resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.path = "/api/ws"
        return WebSocketDial(url: comps.url!, protocols: ["hermes-gateway-v1", "hermes-gateway-ticket.\(ticket)"])
    }

    public func restAccess(profile: String, purpose: RESTPurpose) async throws -> (base: URL, headers: [String: String]) {
        let id = try await currentIdentity()
        let home = Self.home(of: profile, in: id)
        let (ticket, fresh) = try await mintTicket(profileHome: home, purpose: purpose.rawValue, hostScope: false)
        return (fresh.apiOrigin, ["X-Hermes-Gateway-Ticket": ticket])
    }

    public func recoverFromUnauthorized() async throws -> Bool {
        identity = nil
        _ = try await identify()
        return true
    }

    // MARK: Internals

    private func currentIdentity() async throws -> Identity {
        if let identity { return identity }
        return try await identify()
    }

    private func identify() async throws -> Identity {
        let reply: JSON
        do {
            reply = try await control.request(["protocol": 1, "id": 1, "verb": "identify", "params": [:]])
        } catch {
            // No socket: Hermes isn't running. Start it once with the official idempotent starter.
            guard let starter, !triedEnsure else {
                throw HermesError.hermesUnavailable("Hermes isn't running on this Mac.")
            }
            triedEnsure = true
            let ensured = try await starter.ensure()
            guard ensured["state"].string == "ready" else {
                let state = ensured["state"].string ?? "unknown"
                let reason = ensured["reason_code"].string.map { " (\($0))" } ?? ""
                throw HermesError.hermesUnavailable("Couldn't start Hermes: \(state)\(reason).")
            }
            return try await identify()
        }
        guard reply["ok"].bool == true else {
            throw HermesError.hermesUnavailable(reply["error"].string ?? "Hermes refused to identify itself.")
        }
        let r = reply["result"]
        guard r["state"].string == "ready" else {
            throw HermesError.hermesUnavailable("Hermes is \(r["state"].string ?? "not ready").")
        }
        guard let originText = r["api_origin"].string, let origin = URL(string: originText),
            let host = origin.host, host == "127.0.0.1" || host == "::1"
        else { throw HermesError.protocolViolation("identify returned no loopback api_origin") }
        guard let instance = r["instance_id"].string, let home = r["hermes_home"].string else {
            throw HermesError.protocolViolation("identify is missing instance_id or hermes_home")
        }
        var homes: [String: String] = ["default": home]
        for p in r["served_profiles"].array ?? [] {
            guard let h = p["home"].string ?? p["profile_id"].string else { continue }
            homes[Self.profileName(home: h, hermesHome: home)] = h
        }
        let id = Identity(
            apiOrigin: origin, instanceID: instance, hermesHome: home, homes: homes,
            version: r["code_version"].string, capabilities: r["capabilities"].array?.compactMap(\.string) ?? [])
        identity = id
        triedEnsure = false
        return id
    }

    /// Mints a single-use ticket. Re-identifies once if the gateway restarted under us.
    private func mintTicket(profileHome: String?, purpose: String, hostScope: Bool) async throws -> (String, Identity) {
        var attempt = 0
        while true {
            let id = try await currentIdentity()
            var params: [String: JSON] = [
                "profile_id": .string(profileHome ?? id.hermesHome), "instance_id": .string(id.instanceID),
                "purpose": .string(purpose),
            ]
            if hostScope { params["scope"] = "host" }
            let reply = try await control.request(["protocol": 1, "id": 7, "verb": "session-ticket", "params": .object(params)])
            if reply["ok"].bool == true, let ticket = reply["result"]["ticket"].string {
                return (ticket, id)
            }
            let error = reply["error"].string ?? "ticket refused"
            if attempt == 0, error.contains("stale runtime instance") {
                attempt += 1
                identity = nil
                continue
            }
            throw HermesError.hermesUnavailable("Hermes refused access: \(error)")
        }
    }

    static func profileName(home: String, hermesHome: String) -> String {
        if home == hermesHome { return "default" }
        return URL(fileURLWithPath: home).lastPathComponent
    }

    static func home(of profile: String, in id: Identity) -> String {
        if let h = id.homes[profile] { return h }
        if profile == "default" { return id.hermesHome }
        return (id.hermesHome as NSString).appendingPathComponent("profiles/\(profile)")
    }
}

// MARK: - Remote

/// A Remote login, kept in the Credential Store.
public enum RemoteCredential: Sendable, Equatable, Codable {
    /// A pasted session token.
    case token(String)
    /// Tokens from the native browser sign-in.
    case oauth(access: String, refresh: String, expiresAt: Double, provider: String?)
}

public protocol CredentialStore: Sendable {
    func load(for key: String) -> RemoteCredential?
    func save(_ credential: RemoteCredential?, for key: String)
}

/// Access to `hermes serve` on another machine.
public actor RemoteAccess: AccessProvider {
    public let baseURL: URL
    private let http: HTTPClient
    private let credentials: CredentialStore
    private let now: @Sendable () -> Date
    private var authRequired = true
    private var refreshing: Task<RemoteCredential, Error>?

    public init(baseURL: URL, http: HTTPClient, credentials: CredentialStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.baseURL = baseURL
        self.http = http
        self.credentials = credentials
        self.now = now
    }

    var key: String { RemoteAccess.credentialKey(for: baseURL) }

    public static func credentialKey(for url: URL) -> String {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    public func prepare() async throws -> ServerInfo {
        let status = try await RemoteAccess.probe(baseURL: baseURL, http: http)
        authRequired = status.authRequired
        guard credentials.load(for: key) != nil else {
            throw HermesError.signInRequired("Sign in to \(baseURL.host ?? baseURL.absoluteString) to use its Bots.")
        }
        return ServerInfo(version: status.version, capabilities: status.authFlows)
    }

    public func webSocketDial() async throws -> WebSocketDial {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/api/ws"
        let credential = try await usableCredential()
        if !authRequired, case .token(let token) = credential {
            comps.queryItems = [URLQueryItem(name: "token", value: token)]
            return WebSocketDial(url: comps.url!)
        }
        let ticket = try await mintWebSocketTicket()
        return WebSocketDial(url: comps.url!, protocols: ["hermes-gateway-v1", "hermes-gateway-ticket.\(ticket)"])
    }

    public func restAccess(profile: String, purpose: RESTPurpose) async throws -> (base: URL, headers: [String: String]) {
        let credential = try await usableCredential()
        return (baseURL, ["Authorization": "Bearer \(credential.bearer)"])
    }

    public func recoverFromUnauthorized() async throws -> Bool {
        guard case .oauth = credentials.load(for: key) else {
            throw HermesError.signInRequired("The session token for \(baseURL.host ?? "this Hermes") was refused. Paste a new one.")
        }
        _ = try await refresh()
        return true
    }

    // MARK: Status probe

    public struct Status: Sendable, Equatable {
        public var version: String?
        public var authRequired: Bool
        public var authProviders: [String]
        public var authFlows: [String]
        public var supportsBrowserSignIn: Bool { authFlows.contains("native_pkce") }
        public var acceptsToken: Bool { !authRequired || authProviders.contains("session-token") }
    }

    public static func probe(baseURL: URL, http: HTTPClient) async throws -> Status {
        let url = baseURL.appending(path: "api/status")
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(method: "GET", url: url))
        } catch HermesError.accessLoginRequired(let origin) {
            throw HermesError.accessLoginRequired(origin)
        } catch {
            throw HermesError.hermesUnavailable("Couldn't reach \(baseURL.host ?? baseURL.absoluteString).")
        }
        guard response.status == 200 else {
            throw HermesError.hermesUnavailable("\(baseURL.host ?? "The remote Hermes") answered HTTP \(response.status). Is it running `hermes serve`?")
        }
        let j = response.json
        return Status(
            version: j["version"].string, authRequired: j["auth_required"].bool ?? false,
            authProviders: j["auth_providers"].array?.compactMap(\.string) ?? [],
            authFlows: j["auth_flows"].array?.compactMap(\.string) ?? [])
    }

    // MARK: Tokens

    private func usableCredential() async throws -> RemoteCredential {
        guard let credential = credentials.load(for: key) else {
            throw HermesError.signInRequired("Sign in to \(baseURL.host ?? "the remote Hermes") again.")
        }
        if case .oauth(_, _, let expiresAt, _) = credential, now().timeIntervalSince1970 >= expiresAt - 60 {
            return try await refresh()
        }
        return credential
    }

    private func refresh() async throws -> RemoteCredential {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.performRefresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> RemoteCredential {
        guard case .oauth(_, let refreshToken, _, let provider) = credentials.load(for: key) else {
            throw HermesError.signInRequired("Sign in again.")
        }
        var body: [String: JSON] = ["refresh_token": .string(refreshToken)]
        if let provider { body["provider"] = .string(provider) }
        let response = try await http.send(
            HTTPRequest(
                method: "POST", url: baseURL.appending(path: "auth/native/refresh"),
                headers: ["Content-Type": "application/json"], body: JSON.object(body).data()))
        switch response.status {
        case 200:
            let fresh = try BrowserSignIn.credential(from: response.json)
            credentials.save(fresh, for: key)
            return fresh
        case 401:
            credentials.save(nil, for: key)
            throw HermesError.signInRequired("Your login to \(baseURL.host ?? "the remote Hermes") expired. Sign in again.")
        default:
            throw HermesError.http(status: response.status, detail: response.json["detail"].string ?? "refresh failed")
        }
    }

    private func mintWebSocketTicket() async throws -> String {
        for attempt in 0..<2 {
            let credential = try await usableCredential()
            let response = try await http.send(
                HTTPRequest(
                    method: "POST", url: baseURL.appending(path: "api/auth/ws-ticket"),
                    headers: ["Authorization": "Bearer \(credential.bearer)"]))
            if response.status == 200, let ticket = response.json["ticket"].string { return ticket }
            if response.status == 401, attempt == 0, case .oauth = credential {
                _ = try await refresh()
                continue
            }
            if response.status == 401 || response.status == 403 {
                throw HermesError.signInRequired("\(baseURL.host ?? "The remote Hermes") no longer accepts your login. Sign in again.")
            }
            throw HermesError.http(status: response.status, detail: response.json["detail"].string ?? "ws-ticket failed")
        }
        throw HermesError.signInRequired("Sign in again.")
    }
}

extension RemoteCredential {
    var bearer: String {
        switch self {
        case .token(let t): return t
        case .oauth(let access, _, _, _): return access
        }
    }
}
