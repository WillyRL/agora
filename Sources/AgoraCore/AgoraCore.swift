import Foundation
import Observation

/// Everything Agora Core needs from the outside world. The app passes the real system
/// pieces; tests pass a fake Hermes and in-memory stand-ins.
public struct AgoraEnvironment: Sendable {
    public var sockets: SocketFactory
    public var http: HTTPClient
    public var control: ControlSocket
    public var starter: GatewayStarter?
    public var credentials: CredentialStore
    public var notifier: Notifier
    public var store: KeyValueStore
    public var connectionOptions: HermesConnection.Options
    /// Reads your tailnet to find Hermes on your other machines (nil: no Tailscale).
    public var tailnet: TailnetSource?
    /// Cloudflare Access logins, for Hermes behind a Cloudflare Tunnel.
    public var accessTokens: AccessTokenStore
    /// `http` without the Cloudflare Access gate, to read Cloudflare's own answers.
    let directHTTP: HTTPClient

    public init(
        sockets: SocketFactory, http: HTTPClient, control: ControlSocket, starter: GatewayStarter?, credentials: CredentialStore,
        notifier: Notifier, store: KeyValueStore, connectionOptions: HermesConnection.Options = .init(), tailnet: TailnetSource? = nil,
        accessTokens: AccessTokenStore = InMemoryAccessTokenStore()
    ) {
        self.tailnet = tailnet
        self.accessTokens = accessTokens
        self.sockets = AccessGatedSockets(inner: sockets, tokens: accessTokens)
        self.http = AccessGatedHTTP(inner: http, tokens: accessTokens)
        self.directHTTP = http
        self.control = control
        self.starter = starter
        self.credentials = credentials
        self.notifier = notifier
        self.store = store
        self.connectionOptions = connectionOptions
    }
}

/// The app layer: observable state the SwiftUI views read, built on the Hermes Connection.
@MainActor
@Observable
public final class AgoraCore {
    public struct Features: Sendable, Equatable {
        /// The canonical session protocol (Hermes v0.23+). Without it chats can't open.
        public var sessionAuthority = true
        /// Hermes can ask Agora for approvals, answers and secrets.
        public var serverRequests = true
        /// Follow-ups can steer a running task (otherwise they're sent as new messages).
        public var steer = true
        /// Routines can be managed (cron REST).
        public var routines = true
    }

    public let registry: ConnectionRegistry
    let env: AgoraEnvironment

    public internal(set) var status: ConnectionStatus = .idle
    /// Visible Bots on the active Connection, in Hermes' order.
    public internal(set) var bots: [Bot] = []
    /// Every Bot, including hidden ones.
    public internal(set) var allBots: [Bot] = []
    /// Server requests this Hermes may send Agora (from `client.capabilities`).
    public internal(set) var serverCapabilities: [String] = []
    public internal(set) var hermesVersion: String?
    /// What the connected Hermes supports. Features it lacks are hidden or explained, never broken.
    public internal(set) var features = Features()
    /// A problem worth telling the user about (failed action, unsupported feature …).
    public var notice: String?
    /// Agora may teach Bots about itself here (see `teachBots`). The app turns it on; the demo and
    /// tests that script every request leave it off.
    public var installsAgoraSkill = false
    /// Bots checked for the `agora-chat` skill on this Connection.
    var agoraSkillChecked: Set<String> = []
    /// Hermes found on your tailnet (see `scanTailnet`).
    public internal(set) var tailnet = TailnetScan()

    /// Open conversations by session id.
    public internal(set) var conversations: [String: Conversation] = [:]
    /// Each Bot's Bot Chat session id, once opened.
    public internal(set) var botChatIDs: [String: String] = [:]
    /// The Bot you talked to most recently (Quick Ask's default).
    public internal(set) var lastUsedBot: String? {
        get { access(keyPath: \.lastUsedBot); return env.store.decode(String.self, "lastUsedBot") }
        set { withMutation(keyPath: \.lastUsedBot) { env.store.encode(newValue, "lastUsedBot") } }
    }
    /// Each Bot's Routines.
    public internal(set) var routines: [String: [Routine]] = [:]
    /// Bots with activity you haven't seen.
    public internal(set) var unread: Set<String> = []
    /// Whether Agora is the frontmost app (notifications are skipped for the chat you're looking at).
    public var appIsActive = true
    /// The chat on screen.
    public internal(set) var viewing: (bot: String, session: String?)?
    /// Bots whose notifications are muted (remembered).
    public internal(set) var mutedBots: Set<String> {
        get { access(keyPath: \.mutedBots); return Set(env.store.decode([String].self, "mutedBots") ?? []) }
        set { withMutation(keyPath: \.mutedBots) { env.store.encode(newValue.sorted(), "mutedBots") } }
    }
    @ObservationIgnored var avatars: [String: Data] = [:]
    /// Each Bot's Side Chats, newest first.
    public internal(set) var sideChats: [String: [SideChatSummary]] = [:]
    var historyPageSize = 120
    @ObservationIgnored var sideAnswers: [String: String] = [:]
    @ObservationIgnored var sideAnswerWaiters: [String: CheckedContinuation<String, Error>] = [:]
    @ObservationIgnored var imageCache: [ChatImage: Data] = [:]
    /// Files of messages that didn't send, kept for Retry (by the message's local id).
    @ObservationIgnored var uninstallPollInterval: Duration = .seconds(1)
    @ObservationIgnored var unsentAttachments: [String: [ImageAttachment]] = [:]

    var connection: HermesConnection?
    @ObservationIgnored var startToken = UUID()
    private var signalTask: Task<Void, Never>?

    public init(registry: ConnectionRegistry, environment: AgoraEnvironment) {
        self.registry = registry
        self.env = environment
    }

    // MARK: Lifecycle

    /// Connects to the active Connection and loads its Bots.
    public func start() async {
        await stop()
        let token = UUID()
        startToken = token
        guard let saved = registry.active else {
            status = .idle
            return
        }
        let connection = HermesConnection(access: makeAccess(for: saved), sockets: env.sockets, http: env.http, options: env.connectionOptions)
        self.connection = connection
        signalTask = Task { [weak self] in
            for await signal in connection.signals {
                guard let self else { return }
                await self.handle(signal, from: connection)
            }
        }
        do {
            try await connection.connect()
            guard startToken == token else { return }  // a newer start (Connection switch) took over
            status = await connection.status
            hermesVersion = await connection.serverInfo.version
            serverCapabilities = await connection.ready?.serverRequests ?? []
            if let ready = await connection.ready { adopt(ready: ready) }
            try await loadRoster()
        } catch {
            guard startToken == token else { return }
            status = await connection.status
            if status == .connected { notice = error.localizedDescription }
        }
    }

    public func stop() async {
        signalTask?.cancel()
        signalTask = nil
        if let connection { await connection.shutdown() }
        connection = nil
        resetConnectionState()
        status = .idle
    }

    /// Reconnects right away (after the Mac wakes up, for example).
    public func reconnectNow() async {
        await connection?.reconnectNow()
    }

    /// Switches the active Connection and shows that machine's Bots.
    public func switchConnection(to id: UUID) async {
        guard id != registry.activeID else { return }
        registry.activate(id)
        await start()
    }

    func makeAccess(for saved: SavedConnection) -> AccessProvider {
        switch saved.kind {
        case .local: return LocalAccess(control: env.control, starter: env.starter)
        case .remote(let url): return RemoteAccess(baseURL: url, http: env.http, credentials: env.credentials)
        }
    }

    func requireConnection() throws -> HermesConnection {
        guard let connection else { throw HermesError.notConnected }
        return connection
    }

    /// Clears everything that belongs to the previous Connection.
    func resetConnectionState() {
        bots = []
        allBots = []
        agoraSkillChecked = []
        conversations = [:]
        botChatIDs = [:]
        sideChats = [:]
        sideAnswers = [:]
        let waiters = sideAnswerWaiters
        sideAnswerWaiters = [:]
        for (_, w) in waiters { w.resume(throwing: HermesError.notConnected) }
        routines = [:]
        unread = []
        avatars = [:]
        serverCapabilities = []
        hermesVersion = nil
        features = Features()
    }

    // MARK: Signals

    private func handle(_ signal: HermesSignal, from source: HermesConnection) async {
        guard source === connection else { return }
        switch signal {
        case .status(let s):
            status = s
        case .ready(let ready):
            serverCapabilities = ready.serverRequests
            adopt(ready: ready)
            if ready.isReconnect { await didReconnect() }
        case .event(let event):
            handle(event: event)
        case .request(let request):
            await handle(request: request)
        }
    }

    func adopt(ready: GatewayReady) {
        features.sessionAuthority = ready.sessionAuthority
        features.serverRequests = !ready.serverRequests.isEmpty
        // The older dialect (a standalone `hermes serve`) can't steer: follow-ups go as new messages.
        if !ready.sessionAuthority { features.steer = false }
        // A standalone `hermes serve` (how remote Connections usually reach Hermes) never sends
        // `session_authority`, even on a current Hermes, so trust the version when Hermes reports one.
        let tooOld = ready.serverVersion.map { !TailnetGateway.version($0, atLeast: [0, 23]) } ?? !ready.sessionAuthority
        if tooOld {
            notice = "This Hermes is older than Agora expects (it needs Hermes v0.23 or later). Chats may not open; update Hermes with `hermes update`."
        }
    }

    func didReconnect() async {
        try? await loadRoster()
        for c in conversations.values { await refresh(c) }
    }

    func handle(event: GatewayEvent) {
        route(event: event)
    }


    // MARK: Roster

    public func loadRoster() async throws {
        let connection = try requireConnection()
        let result = try await connection.call("profiles.list", [:])
        let rows = result["profiles"].array ?? []
        let previous = Dictionary(allBots.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        allBots = rows.map(Bot.init(row:)).filter { !$0.name.isEmpty }.map { fresh in
            // Keep a live preview that's newer than the roster's.
            guard let old = previous[fresh.name], let oldActive = old.lastActive, oldActive > (fresh.lastActive ?? .distantPast) else { return fresh }
            var merged = fresh
            merged.lastPreview = old.lastPreview
            merged.lastActive = old.lastActive
            return merged
        }
        bots = allBots.filter { !$0.hidden }
        restoreUnread()
        teachUncheckedBots()
    }

    public func bot(named name: String) -> Bot? {
        allBots.first { $0.name == name }
    }
}
