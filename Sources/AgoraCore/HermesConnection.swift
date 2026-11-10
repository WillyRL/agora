import Foundation

public enum ConnectionStatus: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    /// Unreachable; Agora keeps retrying in the background.
    case offline(String)
    /// A Remote login expired and couldn't be refreshed.
    case needsSignIn(String)
    /// The Hermes we reach can't be used as configured (4403, Host check …). No retry.
    case configurationError(String)
    /// Cloudflare Access stands in front of the Remote Hermes; log in at this origin.
    case needsAccessLogin(URL)

    public var isConnected: Bool { self == .connected }
}

/// A server notification (`method: "event"`).
public struct GatewayEvent: Sendable, Equatable {
    public var type: String
    public var sessionID: String?
    public var payload: JSON
    public var seq: Int?
    public var executionGeneration: Int?
    public var replayed: Bool

    public init(type: String, sessionID: String? = nil, payload: JSON = .null, seq: Int? = nil, executionGeneration: Int? = nil, replayed: Bool = false) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
        self.seq = seq
        self.executionGeneration = executionGeneration
        self.replayed = replayed
    }
}

/// A question Hermes asks Agora (JSON-RPC request from server to client: sudo, secret, clarify, …).
public struct ServerRequest: Sendable, Equatable {
    public var id: String
    public var method: String
    public var params: JSON
    public var replayed: Bool
}

public struct GatewayReady: Sendable, Equatable {
    public var heartbeat: Bool
    public var replayEpoch: String?
    public var sessionAuthority: Bool
    /// What `client.capabilities` said this server may ask Agora.
    public var serverRequests: [String]
    public var isReconnect: Bool
    /// The Hermes version from the login step (`/api/status` or the local identity), if known.
    public var serverVersion: String? = nil
}

public enum HermesSignal: Sendable, Equatable {
    case status(ConnectionStatus)
    case ready(GatewayReady)
    case event(GatewayEvent)
    case request(ServerRequest)
}

/// The one module at the Agora ↔ Hermes line. It hides transport, login, access tickets,
/// reconnection and replay. The app sees typed RPC calls, REST calls, and one ordered stream
/// of signals (status, events, server requests).
public actor HermesConnection {
    public struct Options: Sendable {
        /// Waits between reconnect attempts (heartbeats and timeouts always use the real clock).
        public var sleep: @Sendable (Duration) async throws -> Void
        public var now: @Sendable () -> Date
        public var random: @Sendable (Double) -> Double
        public var heartbeatInterval: Duration
        public var heartbeatDeadline: TimeInterval
        public var handshakeTimeout: Duration
        public var callTimeout: Duration

        public init(
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            now: @escaping @Sendable () -> Date = Date.init,
            random: @escaping @Sendable (Double) -> Double = { Double.random(in: 0..<max($0, 0.001)) },
            heartbeatInterval: Duration = .seconds(15),
            heartbeatDeadline: TimeInterval = 45,
            handshakeTimeout: Duration = .seconds(15),
            callTimeout: Duration = .seconds(120)
        ) {
            self.sleep = sleep
            self.now = now
            self.random = random
            self.heartbeatInterval = heartbeatInterval
            self.heartbeatDeadline = heartbeatDeadline
            self.handshakeTimeout = handshakeTimeout
            self.callTimeout = callTimeout
        }

        /// For tests: no waiting between reconnect attempts, no heartbeat.
        public static var immediate: Options {
            Options(sleep: { _ in await Task.yield() }, random: { _ in 0 }, heartbeatInterval: .seconds(3600))
        }
    }

    public nonisolated let signals: AsyncStream<HermesSignal>
    private let continuation: AsyncStream<HermesSignal>.Continuation

    private let access: AccessProvider
    private let sockets: SocketFactory
    private let http: HTTPClient
    private let options: Options

    public private(set) var status: ConnectionStatus = .idle
    public private(set) var serverInfo = ServerInfo()
    public private(set) var ready: GatewayReady?

    private var socket: FrameSocket?
    /// Frames go out through one writer per socket, so they reach Hermes in the order they were sent.
    private var outbox: AsyncStream<String>.Continuation?
    private var writerTask: Task<Void, Never>?
    private var socketGeneration = 0
    private var readerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var openedAt: Date?
    private var lastInbound = Date()
    private var closedByUser = false
    private var reconnectAttempt = 0

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]

    // Replay bookkeeping (per session).
    private var processEpoch: String?
    private var watermarks: [String: Int] = [:]
    private var sessionEpochs: [String: String] = [:]
    private var sessionProfiles: [String: String] = [:]
    private var parked: [String: [GatewayEvent]] = [:]

    public init(access: AccessProvider, sockets: SocketFactory, http: HTTPClient, options: Options = Options()) {
        self.access = access
        self.sockets = sockets
        self.http = http
        self.options = options
        (signals, continuation) = AsyncStream.makeStream(of: HermesSignal.self)
    }

    // MARK: Lifecycle

    /// Connects once. Throws if Hermes can't be reached; after a successful connect, drops are
    /// repaired in the background.
    public func connect() async throws {
        closedByUser = false
        setStatus(.connecting)
        do {
            try await dial(isReconnect: false)
        } catch {
            setStatus(Self.status(for: error))
            throw error
        }
    }

    public func disconnect() {
        closedByUser = true
        reconnectTask?.cancel()
        reconnectTask = nil
        tearDownSocket(code: 1000)
        failPending(HermesError.notConnected)
        setStatus(.idle)
    }

    /// Ends the signal stream. Call when the Connection is thrown away.
    public func shutdown() {
        disconnect()
        continuation.finish()
    }

    /// Tells the connection which profile a session belongs to, so replay after a reconnect
    /// can address it.
    public func track(session: String, profile: String) {
        sessionProfiles[session] = profile
    }

    public func untrack(session: String) {
        sessionProfiles[session] = nil
        watermarks[session] = nil
        sessionEpochs[session] = nil
    }

    /// Sets the replay cursor from a snapshot (`session.resume` / `session.create`).
    public func setCursor(session: String, lastSequence: Int?, epoch: String?) {
        if let lastSequence { watermarks[session] = max(watermarks[session] ?? 0, lastSequence) }
        if let epoch {
            if let old = sessionEpochs[session], old != epoch { watermarks[session] = lastSequence ?? 0 }
            sessionEpochs[session] = epoch
        }
    }

    /// Reconnect right away (e.g. after the Mac wakes up).
    public func reconnectNow() {
        guard !closedByUser else { return }
        switch status {
        case .connected, .connecting: return
        default:
            // A running loop keeps going (cancelling it mid-dial could leave two sockets); it just retries sooner.
            reconnectAttempt = 0
            if reconnectTask == nil { startReconnectLoop() }
        }
    }

    // MARK: RPC

    public func call(_ method: String, _ params: JSON = [:], timeout: Duration? = nil) async throws -> JSON {
        guard let outbox, status == .connected || method == "client.capabilities" else { throw HermesError.notConnected }
        let (method, params) = ready?.sessionAuthority == false ? LegacyDialect.translate(method, params) : (method, params)
        let id = nextID
        nextID += 1
        let frame: JSON = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let limit = timeout ?? options.callTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            if Task.isCancelled { return }
            await self?.expire(id: id, method: method)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            if case .terminated = outbox.yield(frame.text) { fail(id: id, error: HermesError.connectionLost) }
        }
    }

    public func respond(to request: String, result: JSON) async {
        outbox?.yield(JSON.object(["jsonrpc": "2.0", "id": .string(request), "result": result]).text)
    }

    public func respondError(to request: String, code: Int = -32601, message: String = "Method not supported by Agora") async {
        outbox?.yield(
            JSON.object(["jsonrpc": "2.0", "id": .string(request), "error": ["code": .number(Double(code)), "message": .string(message)]]).text)
    }

    // MARK: REST

    /// A REST call under `/api/*`, scoped to `profile`. Adds `?profile=` unless `scopeQuery` is false.
    public func rest(
        _ method: String, _ path: String, profile: String, query: [String: String] = [:], body: JSON? = nil,
        purpose: RESTPurpose = .http, scopeQuery: Bool = true
    ) async throws -> JSON {
        try await restResponse(method, path, profile: profile, query: query, body: body, purpose: purpose, scopeQuery: scopeQuery, accept: "application/json").json
    }

    /// A REST call whose answer is a file, not JSON: returns the raw bytes.
    public func restData(_ path: String, profile: String, query: [String: String] = [:]) async throws -> Data {
        try await restResponse("GET", path, profile: profile, query: query, body: nil, purpose: .http, scopeQuery: true, accept: "*/*").body
    }

    private func restResponse(
        _ method: String, _ path: String, profile: String, query: [String: String], body: JSON?,
        purpose: RESTPurpose, scopeQuery: Bool, accept: String
    ) async throws -> HTTPResponse {
        for attempt in 0..<2 {
            let (base, headers) = try await access.restAccess(profile: profile, purpose: purpose)
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
            comps.path = basePath + path
            var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            if scopeQuery, query["profile"] == nil { items.append(URLQueryItem(name: "profile", value: profile)) }
            comps.queryItems = items.isEmpty ? nil : items
            var allHeaders = headers
            if body != nil { allHeaders["Content-Type"] = "application/json" }
            allHeaders["Accept"] = accept
            let request = HTTPRequest(method: method, url: comps.url!, headers: allHeaders, body: body?.data())
            let response = try await http.send(request)
            if (200..<300).contains(response.status) { return response }
            if response.status == 401, attempt == 0, try await access.recoverFromUnauthorized() { continue }
            if response.status == 401 { throw HermesError.signInRequired("Hermes no longer accepts Agora's login.") }
            let detail = response.json["detail"].string ?? response.json["error"].string ?? String(decoding: response.body.prefix(200), as: UTF8.self)
            throw HermesError.http(status: response.status, detail: detail)
        }
        throw HermesError.signInRequired("Hermes no longer accepts Agora's login.")
    }

    // MARK: Dial + handshake

    private func dial(isReconnect: Bool) async throws {
        serverInfo = try await access.prepare()
        let dial = try await access.webSocketDial()
        let socket: FrameSocket
        do {
            socket = try await sockets.open(dial)
        } catch let closed as SocketClosed {
            throw Self.error(forClose: closed)
        }
        // First frame must be gateway.ready.
        let payload: JSON
        do {
            let first = try await withTimeout(options.handshakeTimeout) { try await socket.receive() }
            let frame = try JSON(text: first)
            guard frame["method"].string == "event", frame["params"]["type"].string == "gateway.ready" else {
                throw HermesError.protocolViolation("expected gateway.ready, got \(frame["method"].string ?? "a response")")
            }
            payload = frame["params"]["payload"]
        } catch let closed as SocketClosed {
            throw Self.error(forClose: closed)
        } catch {
            socket.close(code: 1002)
            throw error
        }

        tearDownSocket(code: 1000)  // never two sockets at once
        socketGeneration += 1
        self.socket = socket
        startWriter(socket)
        openedAt = options.now()
        lastInbound = options.now()
        startReader(socket, generation: socketGeneration)

        // Advertise that Agora answers server requests; without this Hermes withdraws every approval.
        var serverRequests: [String] = []
        do {
            let caps = try await call("client.capabilities", ["server_requests": true], timeout: .seconds(15))
            serverRequests = caps["server_requests"].array?.compactMap(\.string) ?? []
        } catch let e as HermesError where e.isMethodNotFound {
            serverRequests = []
        } catch {
            tearDownSocket(code: 1011)
            failPending(HermesError.connectionLost)
            throw error
        }

        let epoch = payload["replay_epoch"].string
        if let processEpoch, let epoch, processEpoch != epoch {
            // Hermes restarted: sequence numbers without a per-session epoch are meaningless now.
            for sid in watermarks.keys where sessionEpochs[sid] == nil { watermarks[sid] = nil }
        }
        processEpoch = epoch

        let readyInfo = GatewayReady(
            heartbeat: payload["heartbeat"].bool ?? false, replayEpoch: epoch,
            sessionAuthority: payload["session_authority"].bool ?? false, serverRequests: serverRequests,
            isReconnect: isReconnect, serverVersion: serverInfo.version)
        ready = readyInfo
        setStatus(.connected)
        if readyInfo.heartbeat { startHeartbeat(generation: socketGeneration) }
        if isReconnect { await replayAll() }
        continuation.yield(.ready(readyInfo))
    }

    private func startWriter(_ socket: FrameSocket) {
        let (stream, cont) = AsyncStream.makeStream(of: String.self)
        outbox = cont
        writerTask = Task {
            for await text in stream {
                do { try await socket.send(text) } catch { return }  // the reader notices the close
            }
        }
    }

    private func startReader(_ socket: FrameSocket, generation: Int) {
        readerTask?.cancel()
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await socket.receive()
                    await self?.handle(text: text, generation: generation)
                } catch {
                    let closed = error as? SocketClosed ?? SocketClosed(code: 1006, reason: "\(error)")
                    await self?.socketDidClose(closed, generation: generation)
                    return
                }
            }
        }
    }

    private func startHeartbeat(generation: Int) {
        heartbeatTask?.cancel()
        let interval = options.heartbeatInterval
        heartbeatTask = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                n += 1
                if await !self.heartbeat(n: n, generation: generation) { return }
            }
        }
    }

    private func heartbeat(n: Int, generation: Int) async -> Bool {
        guard generation == socketGeneration, let socket else { return false }
        if options.now().timeIntervalSince(lastInbound) > options.heartbeatDeadline {
            socket.close(code: 4000)
            await socketDidClose(SocketClosed(code: 1006, reason: "heartbeat timeout"), generation: generation)
            return false
        }
        outbox?.yield(JSON.object(["jsonrpc": "2.0", "id": .string("heartbeat-\(n)"), "method": "gateway.ping", "params": [:]]).text)
        return true
    }

    // MARK: Inbound frames

    private func handle(text: String, generation: Int) async {
        guard generation == socketGeneration else { return }
        lastInbound = options.now()
        guard let frame = try? JSON(text: text) else { return }
        if let method = frame["method"].string {
            if method == "event" {
                receive(event: Self.event(from: frame["params"]))
            } else if let id = frame["id"].string {
                continuation.yield(.request(ServerRequest(id: id, method: method, params: frame["params"], replayed: false)))
            }
            return
        }
        // A response to one of our calls.
        let id: Int?
        switch frame["id"] {
        case .number(let n): id = Int(n)
        case .string(let s): id = Int(s)  // our ids are numbers; "heartbeat-N" replies are not ours to resolve
        default: id = nil
        }
        guard let id, let cont = pending.removeValue(forKey: id) else { return }
        if frame["error"].object != nil {
            let e = frame["error"]
            cont.resume(
                throwing: HermesError.rpc(
                    code: e["code"].int ?? 0, message: e["message"].string ?? "error",
                    reason: e["data"]["reason"].string, data: e["data"]))
        } else {
            let result = frame["result"]
            redeliverOpenRequests(in: result)
            cont.resume(returning: result)
        }
    }

    static func event(from params: JSON) -> GatewayEvent {
        GatewayEvent(
            type: params["type"].string ?? "", sessionID: params["session_id"].string, payload: params["payload"],
            seq: params["seq"].int, executionGeneration: params["execution_generation"].int ?? params["payload"]["execution_generation"].int)
    }

    private func receive(event: GatewayEvent) {
        if let sid = event.sessionID, event.seq != nil, parked[sid] != nil {
            parked[sid]?.append(event)
            return
        }
        dispatchIfNewer(event)
    }

    private func dispatchIfNewer(_ event: GatewayEvent) {
        if let sid = event.sessionID, let seq = event.seq {
            if let mark = watermarks[sid], seq <= mark { return }
            watermarks[sid] = seq
        }
        continuation.yield(.event(event))
    }

    private func redeliverOpenRequests(in result: JSON) {
        for r in result["open_requests"].array ?? [] {
            guard let id = r["id"].string, let method = r["method"].string else { continue }
            continuation.yield(.request(ServerRequest(id: id, method: method, params: r["params"], replayed: true)))
        }
    }

    // MARK: Replay after reconnect

    private func replayAll() async {
        let sids = Array(watermarks.keys)
        for sid in sids { parked[sid] = [] }
        await withTaskGroup(of: Void.self) { group in
            for sid in sids {
                group.addTask { await self.replay(session: sid) }
            }
        }
    }

    private func replay(session sid: String) async {
        defer {
            let held = parked.removeValue(forKey: sid) ?? []
            for e in held { dispatchIfNewer(e) }
        }
        guard let mark = watermarks[sid] else { return }
        var params: [String: JSON] = ["session_id": .string(sid), "last_sequence": .number(Double(mark))]
        if let epoch = sessionEpochs[sid] { params["replay_epoch"] = .string(epoch) }
        if let profile = sessionProfiles[sid] { params["profile"] = .string(profile) }
        do {
            let r = try await call("session.events.since", .object(params), timeout: .seconds(10))
            let epoch = r["replay_epoch"].string ?? r["epoch"].string
            let epochChanged = epoch != nil && sessionEpochs[sid] != nil && epoch != sessionEpochs[sid]
            if r["snapshot_required"].bool == true || r["truncated"].bool == true || epochChanged {
                watermarks[sid] = nil
                continuation.yield(.event(GatewayEvent(type: "session.replay_gap", sessionID: sid, payload: ["latest_seq": r["latest_seq"]])))
                return
            }
            for e in r["events"].array ?? [] {
                var ev = Self.event(from: e)
                ev.replayed = true
                dispatchIfNewer(ev)
            }
        } catch let e as HermesError where e.rpcReason == "not_found" {
            untrack(session: sid)
        } catch {
            // Replay is best-effort; the app re-resumes open sessions after `.ready`.
        }
    }

    // MARK: Closing + reconnecting

    private func socketDidClose(_ closed: SocketClosed, generation: Int) async {
        guard generation == socketGeneration else { return }
        let wasStable = openedAt.map { options.now().timeIntervalSince($0) >= 5 } ?? false
        tearDownSocket(code: nil)
        failPending(HermesError.connectionLost)
        guard !closedByUser else { return }
        if closed.code == 4403 {
            setStatus(.configurationError(Self.configurationMessage(closed)))
            return
        }
        if wasStable { reconnectAttempt = 0 }
        startReconnectLoop()
    }

    private func startReconnectLoop() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    private func reconnectLoop() async {
        defer { reconnectTask = nil }
        while !Task.isCancelled, !closedByUser {
            let attempt = reconnectAttempt
            reconnectAttempt += 1
            setStatus(.reconnecting(attempt: attempt + 1))
            let ceilingMs = min(15_000.0, 300.0 * pow(2.0, Double(min(attempt, 32))))
            try? await options.sleep(.milliseconds(Int(options.random(ceilingMs))))
            if Task.isCancelled || closedByUser { return }
            do {
                try await dial(isReconnect: true)
                return
            } catch {
                switch Self.status(for: error) {
                case .needsSignIn(let m):
                    setStatus(.needsSignIn(m))
                    return
                case .configurationError(let m):
                    setStatus(.configurationError(m))
                    return
                case .needsAccessLogin(let url):
                    setStatus(.needsAccessLogin(url))
                    return
                default:
                    if attempt >= 6 { setStatus(.offline(error.localizedDescription)) }
                    continue
                }
            }
        }
    }

    private func tearDownSocket(code: Int?) {
        readerTask?.cancel()
        readerTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        outbox?.finish()
        outbox = nil
        writerTask = nil
        if let code { socket?.close(code: code) }
        socket = nil
        socketGeneration += 1
        openedAt = nil
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, c) in waiting { c.resume(throwing: error) }
    }

    private func fail(id: Int, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func expire(id: Int, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: HermesError.timeout(method))
    }

    private func setStatus(_ s: ConnectionStatus) {
        guard s != status else { return }
        status = s
        continuation.yield(.status(s))
    }

    // MARK: Error mapping

    static func error(forClose closed: SocketClosed) -> HermesError {
        switch closed.code {
        case 4403: return .configuration(configurationMessage(closed))
        default: return .connectionLost  // 4401 included: the ticket expired or was used; mint a new one and redial
        }
    }

    static func configurationMessage(_ closed: SocketClosed) -> String {
        let reason = closed.reason.isEmpty ? "" : " (\(closed.reason))"
        return "Hermes refused the connection\(reason). Check the Connection's address and login settings in Hermes."
    }

    static func status(for error: Error) -> ConnectionStatus {
        switch error {
        case HermesError.signInRequired(let m): return .needsSignIn(m)
        case HermesError.accessLoginRequired(let url): return .needsAccessLogin(url)
        case HermesError.configuration(let m): return .configurationError(m)
        default: return .offline((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}

/// Runs `body`, failing with `HermesError.timeout` if it takes longer than `limit`.
func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw HermesError.timeout("handshake")
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
