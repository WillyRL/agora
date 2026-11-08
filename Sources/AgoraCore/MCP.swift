import Foundation

/// An MCP server configured in a Hermes profile. The main profile ("default") holds the library
/// every Bot draws from; each Bot keeps its own copy with its own on/off switches.
public struct MCPServer: Sendable, Equatable, Identifiable {
    public enum Auth: String, Sendable { case none, oauth, header }

    public var name: String
    /// A URL (`https://…`) or the command that starts it.
    public var address: String
    public var isRemote: Bool
    public var auth: Auth
    public var enabled: Bool
    /// Set when a Hermes plugin provides the server; such servers can't be changed here.
    public var plugin: String?
    /// The full URL (may carry a key) or command line, for editing. Show `address` instead.
    public var url: String
    public var command: String
    /// Settings Agora can't see or carry over (stdio env values come back hidden; a tool filter),
    /// which an edit would lose.
    public var hiddenSettings: [String]
    public var id: String { name }

    init(_ j: JSON) {
        name = j["name"].string ?? ""
        isRemote = j["url"].string != nil || j["transport"].string == "http"
        address = j["url"].string.map(Self.hidingSecrets) ?? ([j["command"].string ?? ""] + (j["args"].array ?? []).compactMap(\.string)).joined(separator: " ")
        auth = Auth(rawValue: j["auth"].string ?? "") ?? .none
        enabled = j["enabled"].bool ?? true
        plugin = j["source"].string == "plugin" ? (j["plugin"].string ?? "a plugin") : nil
        url = j["url"].string ?? ""
        command = j["url"].string == nil ? ([j["command"].string ?? ""] + (j["args"].array ?? []).compactMap(\.string)).joined(separator: " ") : ""
        var hidden: [String] = []
        if !(j["env"].object ?? [:]).isEmpty { hidden.append("environment variables") }
        if j["tools"].array != nil { hidden.append("a tool selection") }
        hiddenSettings = hidden
    }

    /// The Add/Edit form filled in from this server (the token is never read back).
    public var draft: NewMCPServer {
        NewMCPServer(name: name, url: url, command: command, auth: auth)
    }

    /// Some servers take their API key in the URL (`?apiKey=…`); never show those values.
    static func hidingSecrets(_ url: String) -> String {
        guard var comps = URLComponents(string: url) else { return url }
        let names = comps.queryItems?.map(\.name) ?? []
        comps.query = nil
        comps.fragment = nil
        if comps.password != nil { comps.password = "x" }
        var out = comps.string ?? url
        if comps.password != nil { out = out.replacingOccurrences(of: ":x@", with: ":•••@") }
        if !names.isEmpty { out += "?" + names.map { "\($0)=•••" }.joined(separator: "&") }
        return out
    }
}

/// What "Add server" sends. Exactly one of `url` or `command`.
public struct NewMCPServer: Sendable, Equatable {
    public var name = ""
    public var url = ""
    public var command = ""
    public var auth: MCPServer.Auth = .none
    /// Only for `.header` auth. Hermes stores it in the profile's `.env`; it is never read back.
    public var token = ""

    public init(name: String = "", url: String = "", command: String = "", auth: MCPServer.Auth = .none, token: String = "") {
        self.name = name
        self.url = url
        self.command = command
        self.auth = auth
        self.token = token
    }
}

/// The result of connecting to a server and listing its tools.
public struct MCPTestResult: Sendable, Equatable {
    public struct Tool: Sendable, Equatable, Identifiable {
        public var name: String
        public var description: String
        public var id: String { name }
    }
    public var ok: Bool
    public var error: String?
    public var tools: [Tool]

    public init(ok: Bool, error: String? = nil, tools: [Tool] = []) {
        self.ok = ok
        self.error = error
        self.tools = tools
    }
}

extension AgoraCore {
    /// The profile whose MCP servers are the library.
    public static let mcpLibraryProfile = "default"

    /// MCP servers configured for a Bot (the library when `bot` is the main profile).
    public func mcpServers(bot: String = mcpLibraryProfile) async throws -> [MCPServer] {
        let r = try await requireConnection().rest("GET", "/api/mcp/servers", profile: bot)
        return (r["servers"].array ?? []).map(MCPServer.init).filter { !$0.name.isEmpty }
    }

    public func setMCPServer(_ name: String, enabled: Bool, bot: String = mcpLibraryProfile) async throws {
        _ = try await requireConnection().rest("PUT", "/api/mcp/servers/\(name)/enabled", profile: bot, body: ["enabled": .bool(enabled)])
    }

    /// Connects to the server and lists its tools. A server that can't be reached is a result, not an error.
    public func testMCPServer(_ name: String, bot: String = mcpLibraryProfile) async throws -> MCPTestResult {
        let r = try await requireConnection().rest("POST", "/api/mcp/servers/\(name)/test", profile: bot)
        let tools = (r["tools"].array ?? []).map { MCPTestResult.Tool(name: $0["name"].string ?? "", description: $0["description"].string ?? "") }
        return MCPTestResult(ok: r["ok"].bool == true, error: r["error"].string, tools: tools)
    }

    public func addMCPServer(_ s: NewMCPServer, bot: String = mcpLibraryProfile) async throws {
        _ = try await requireConnection().rest("POST", "/api/mcp/servers", profile: bot, body: try Self.body(for: s))
        if s.auth == .header { rememberMCPToken(s.token, for: s.name) }
    }

    /// Changes a server's address or login. Hermes has no in-place update, so this removes the server and
    /// adds it back under the same name, keeping its on/off state. If Hermes refuses the new settings, the
    /// old ones are put back where possible.
    public func editMCPServer(_ old: MCPServer, to new: NewMCPServer, bot: String = mcpLibraryProfile) async throws {
        guard old.plugin == nil else { throw HermesError.protocolViolation("\(old.name) comes from a Hermes plugin and can't be changed here.") }
        guard old.hiddenSettings.isEmpty else {
            throw HermesError.protocolViolation(
                "\(old.name) has \(old.hiddenSettings.joined(separator: " and ")) that editing here would lose. Change it with `hermes mcp` instead.")
        }
        var new = new
        new.name = old.name
        let body = try Self.body(for: new)  // check before anything is removed
        let connection = try requireConnection()
        try await removeMCPServer(old.name, bot: bot)
        do {
            _ = try await connection.rest("POST", "/api/mcp/servers", profile: bot, body: body)
        } catch {
            if old.auth != .header, let back = try? Self.body(for: old.draft) {
                _ = try? await connection.rest("POST", "/api/mcp/servers", profile: bot, body: back)
                if !old.enabled { try? await setMCPServer(old.name, enabled: false, bot: bot) }
            }
            throw error
        }
        if !old.enabled { try await setMCPServer(old.name, enabled: false, bot: bot) }
        if new.auth == .header { rememberMCPToken(new.token, for: old.name) } else { rememberMCPToken(nil, for: old.name) }
    }

    static func body(for s: NewMCPServer) throws -> JSON {
        let name = s.name.trimmingCharacters(in: .whitespaces)
        let url = s.url.trimmingCharacters(in: .whitespaces)
        let command = s.command.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw HermesError.protocolViolation("Give the server a name.") }
        guard url.isEmpty != command.isEmpty else { throw HermesError.protocolViolation("Enter a URL or a command.") }
        var body: [String: JSON] = ["name": .string(name)]
        if !url.isEmpty {
            body["url"] = .string(url)
            if s.auth != .none { body["auth"] = .string(s.auth.rawValue) }
            if s.auth == .header {
                guard !s.token.isEmpty else { throw HermesError.protocolViolation("Enter the server's token.") }
                body["bearer_token"] = .string(s.token)
            }
        } else {
            // The command line splits on spaces; Hermes wants the program and its arguments apart.
            let parts = command.split(separator: " ").map(String.init)
            body["command"] = .string(parts[0])
            if parts.count > 1 { body["args"] = .array(parts.dropFirst().map(JSON.string)) }
        }
        return .object(body)
    }

    public func removeMCPServer(_ name: String, bot: String = mcpLibraryProfile) async throws {
        _ = try await requireConnection().rest("DELETE", "/api/mcp/servers/\(name)", profile: bot)
        if bot == Self.mcpLibraryProfile { rememberMCPToken(nil, for: name) }
    }

    // MARK: Remembered tokens

    /// A token server's token as last typed into Agora on this Connection, kept in the Keychain so
    /// giving the server to another Bot doesn't ask again (Hermes never hands a saved token back).
    public func rememberedMCPToken(for server: String) -> String? {
        guard let key = mcpTokenKey(server), case .token(let t) = env.credentials.load(for: key) else { return nil }
        return t
    }

    func rememberMCPToken(_ token: String?, for server: String) {
        guard let key = mcpTokenKey(server) else { return }
        env.credentials.save(token.flatMap { $0.isEmpty ? nil : RemoteCredential.token($0) }, for: key)
    }

    func mcpTokenKey(_ server: String) -> String? {
        registry.activeID.map { "mcp-token:\($0.uuidString):\(server)" }
    }

    /// Gives a library server to several Bots at once. A token server is added to each with `token`
    /// (or the remembered one); others are copied by Hermes. Bots keep their other servers, and their
    /// open chats reload.
    public func addMCPServer(_ server: MCPServer, toBots bots: [String], token: String? = nil) async throws {
        let token = (token?.isEmpty == false ? token : nil) ?? rememberedMCPToken(for: server.name)
        if server.auth == .header, token == nil { throw HermesError.protocolViolation("Enter the token for \(server.name).") }
        for bot in bots where bot != Self.mcpLibraryProfile {
            let own = try await mcpServers(bot: bot)
            if server.auth == .header, !own.contains(where: { $0.name == server.name }) {
                try await addMCPServer(NewMCPServer(name: server.name, url: server.url, auth: .header, token: token ?? ""), bot: bot)
            }
            let on = Set(own.filter { $0.enabled && $0.plugin == nil }.map(\.name)).union([server.name])
            try await setMCPServers(bot: bot, enabled: Array(on))
            for c in conversations.values where c.bot == bot { _ = try? await reloadTools(c) }
        }
        if let token, server.auth == .header { rememberMCPToken(token, for: server.name) }
    }

    /// Signs in to an OAuth server: opens the provider's page in the browser and waits (up to five
    /// minutes) for Hermes to receive the approval.
    public func signInMCPServer(
        _ name: String, bot: String = mcpLibraryProfile, poll: Duration = .seconds(1), openBrowser: @escaping @Sendable (URL) -> Void
    ) async throws {
        let connection = try requireConnection()
        var flow = try await connection.rest("POST", "/api/mcp/servers/\(name)/auth", profile: bot)
        guard let id = flow["flow_id"].string else { throw HermesError.protocolViolation("Hermes didn't start the sign-in.") }
        var opened = false
        let deadline = ContinuousClock.now + .seconds(300)
        while ContinuousClock.now < deadline {
            switch flow["status"].string {
            case "approved": return
            case "error": throw HermesError.protocolViolation(flow["error"].string ?? "Sign-in failed.")
            default: break
            }
            if !opened, let url = flow["authorization_url"].string.flatMap(URL.init(string:)) {
                opened = true
                openBrowser(url)
            }
            try await Task.sleep(for: poll)
            flow = try await connection.rest("GET", "/api/mcp/oauth/flows/\(id)", profile: bot, scopeQuery: false)
        }
        _ = try? await connection.rest("DELETE", "/api/mcp/oauth/flows/\(id)", profile: bot, scopeQuery: false)
        throw HermesError.protocolViolation("Sign-in timed out. Try again.")
    }

    /// Sets which library servers a Bot may use. Hermes copies servers the Bot doesn't have yet
    /// from the main profile and switches the rest off.
    public func setMCPServers(bot: String, enabled: [String]) async throws {
        let r = try await requireConnection().call(
            "profiles.configure", ["name": .string(bot), "enabled_mcp_servers": .array(enabled.sorted().map(JSON.string))])
        guard r["applied"]["mcp_servers"].bool == true else { throw HermesError.protocolViolation("Hermes didn't save the Bot's MCP servers.") }
    }
}

/// What the Bot editor's MCP section is choosing: the library, the Bot's own copies, and its picks.
public struct BotMCPSelection: Sendable, Equatable {
    public var library: [MCPServer] = []
    public var own: [MCPServer] = []
    public var picked: Set<String> = []
    public var original: Set<String> = []
    /// Tokens typed for token servers the Bot doesn't have yet (Hermes can't copy a token).
    public var tokens: [String: String] = [:]

    public init() {}

    public init(library: [MCPServer], own: [MCPServer]) {
        self.library = library
        self.own = own
        // Plugin servers follow their plugin, not these switches.
        let on = Set(own.filter { $0.enabled && $0.plugin == nil }.map(\.name))
        picked = on
        original = on
    }

    /// Library servers first, then any the Bot has on its own.
    public var names: [String] {
        var seen = Set<String>()
        return (library + own).filter { $0.plugin == nil }.map(\.name).filter { seen.insert($0).inserted }
    }

    /// A token server from the library that this Bot doesn't have yet: it needs its token typed again.
    public func needsToken(_ name: String) -> Bool {
        !own.contains { $0.name == name } && library.first { $0.name == name }?.auth == .header
    }

    public var changed: Bool { picked != original }
}

extension AgoraCore {
    /// The Bot editor's starting point for MCP servers.
    public func mcpSelection(bot: String?) async throws -> BotMCPSelection {
        let library = try await mcpServers()
        var own: [MCPServer] = []
        if let bot { own = try await mcpServers(bot: bot) }
        var selection = BotMCPSelection(library: library, own: own)
        for server in library where server.auth == .header {
            if let t = rememberedMCPToken(for: server.name) { selection.tokens[server.name] = t }
        }
        return selection
    }

    /// Saves a Bot's MCP picks: token servers it doesn't have yet are added to it with their token,
    /// Hermes copies the rest from the library, and the Bot's open chats reload their tools.
    public func applyMCPSelection(_ s: BotMCPSelection, bot: String) async throws {
        guard s.changed else { return }
        for name in s.picked.sorted() where s.needsToken(name) {
            guard let server = s.library.first(where: { $0.name == name }), let token = s.tokens[name], !token.isEmpty else {
                throw HermesError.protocolViolation("Enter the token for \(name).")
            }
            try await addMCPServer(NewMCPServer(name: name, url: server.url, auth: .header, token: token), bot: bot)
        }
        try await setMCPServers(bot: bot, enabled: Array(s.picked))
        for c in conversations.values where c.bot == bot { _ = try? await reloadTools(c) }
    }

    /// Reloads a chat's MCP tools so a change applies now rather than in its next chat. Hermes waits
    /// for a running reply to finish first. Returns Hermes's note, if it gave one.
    @discardableResult
    public func reloadTools(_ c: Conversation) async throws -> String? {
        let r = try await requireConnection().call("reload.mcp", ["session_id": .string(c.sessionID), "confirm": true], timeout: .seconds(60))
        return r["message"].string
    }
}
