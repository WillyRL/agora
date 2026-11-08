import Foundation

/// The few things the Bot editor changes. Tools and skills stay in Hermes; MCP servers are in MCP.swift.
public struct BotDraft: Sendable, Equatable {
    public var name: String
    public var title: String
    public var description: String
    public var persona: String
    public var model: String
    public var provider: String
    /// `#rrggbb`, or nil for the name's own colour.
    public var color: String?
    public var avatarPNG: Data?

    public init(
        name: String = "", title: String = "", description: String = "", persona: String = "", model: String = "", provider: String = "",
        color: String? = nil, avatarPNG: Data? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.persona = persona
        self.model = model
        self.provider = provider
        self.color = color
        self.avatarPNG = avatarPNG
    }
}

/// A model you can pick for a Bot.
public struct ModelChoice: Sendable, Hashable, Identifiable {
    public var provider: String
    public var providerName: String
    public var model: String
    public var id: String { "\(provider):\(model)" }
}

extension AgoraCore {
    /// Turns a typed name into a Hermes profile id (lowercase ASCII, dashes).
    public static func profileName(from typed: String) -> String {
        let folded = typed.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var out = ""
        for ch in folded {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        return String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(64))
    }

    /// The editor's starting point for an existing Bot (reads its persona from SOUL.md).
    public func draft(for bot: Bot) async -> BotDraft {
        var d = BotDraft(
            name: bot.name, title: bot.title, description: bot.description, model: bot.model, provider: bot.provider,
            color: bot.meta["color"].string)
        if let connection, let soul = try? await connection.rest("GET", "/api/profiles/\(bot.name)/soul", profile: bot.name, scopeQuery: false) {
            d.persona = soul["content"].string ?? ""
        }
        return d
    }

    /// Models on offer (the profile's providers that are signed in).
    public func modelChoices(for bot: String = "default") async -> [ModelChoice] {
        guard let connection else { return [] }
        guard let r = try? await connection.rest("GET", "/api/model/options", profile: bot, query: ["explicit_only": "1"]) else { return [] }
        var out: [ModelChoice] = []
        for p in r["providers"].array ?? [] where p["authenticated"].bool != false && p["source"].string != "virtual" {
            let slug = p["slug"].string ?? ""
            let name = p["name"].string ?? slug
            for m in (p["models"].array ?? []).compactMap(\.string).prefix(25) { out.append(ModelChoice(provider: slug, providerName: name, model: m)) }
        }
        return out
    }

    // MARK: Create

    /// Creates a Bot: a new Hermes profile with its persona, description, model, and the official
    /// app's look (title, colour, avatar).
    @discardableResult
    public func createBot(_ d: BotDraft) async throws -> Bot {
        let connection = try requireConnection()
        let name = d.name.isEmpty ? Self.profileName(from: d.title) : Self.profileName(from: d.name)
        guard !name.isEmpty else { throw HermesError.protocolViolation("Give the Bot a name.") }
        var params: [String: JSON] = ["name": .string(name)]
        if !d.description.isEmpty { params["description"] = .string(d.description) }
        if !d.persona.isEmpty { params["soul"] = .string(d.persona) }
        if !d.model.isEmpty {
            params["model"] = .string(d.model)
            if !d.provider.isEmpty { params["provider"] = .string(d.provider) }
        }
        let created = try await connection.call("profiles.create", .object(params), timeout: .seconds(180))
        guard created["ok"].bool != false else { throw HermesError.protocolViolation("Hermes didn't create the Bot.") }
        var meta: [String: JSON] = ["title": .string(d.title), "shape": "circle", "imageKind": d.avatarPNG == nil ? "shape" : "photo", "created": .number((Date().timeIntervalSince1970 * 1000).rounded()), "custom": true]
        if let color = d.color { meta["color"] = .string(color) }
        try await writeLook(bot: name, meta: .object(meta), expectedRevision: 0)
        if let png = d.avatarPNG { try await setAvatar(bot: name, png: png) }
        try await loadRoster()
        guard let bot = bot(named: name) else { throw HermesError.protocolViolation("The new Bot didn't appear.") }
        return bot
    }

    // MARK: Persona

    /// Drafts a persona (SOUL.md) from the Bot's name and purpose. Text already in the persona is
    /// treated as notes to keep and build on. Hermes writes it with its quick background model,
    /// billed to `bot` (a new Bot doesn't exist yet, so it uses the default Bot).
    public func draftPersona(name: String, purpose: String, current: String, bot: String?) async throws -> String {
        let connection = try requireConnection()
        var input = "Bot name: \(name.trimmingCharacters(in: .whitespacesAndNewlines))\nPurpose: \(purpose.trimmingCharacters(in: .whitespacesAndNewlines))"
        let notes = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { input += "\n\nCurrent persona or notes (keep what they ask for):\n\(notes)" }
        let r = try await connection.call(
            "llm.oneshot",
            ["profile": .string(bot ?? "default"), "instructions": .string(Self.personaInstructions), "input": .string(input),
             "max_tokens": 2000, "temperature": 0.7],
            timeout: .seconds(90))
        let text = (r["text"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw HermesError.protocolViolation("Hermes returned an empty persona. Try again.") }
        return text
    }

    static let personaInstructions = """
        You write SOUL.md files for Hermes Bots. A SOUL.md is the persona a Bot reads at the start of every \
        conversation: who it is and how it behaves. It is not a task list and not documentation.

        Write the persona for the Bot described by the user. Use Markdown with a few short sections, addressed \
        to the Bot as "you", 150 to 300 words in total:
        - Who you are: one or two sentences on the role and what the Bot is for.
        - How you work: the approach, what it checks before acting, when it asks the user first.
        - How you talk: tone, length of replies, format.
        - What you avoid.

        Be specific to this Bot's purpose; skip generic virtues like "helpful" or "friendly". If current \
        persona text or notes are given, keep every concrete instruction in them and build on them. Reply \
        with the SOUL.md content only, no preamble and no code fence.
        """

    // MARK: Edit

    /// Saves changes to a Bot. Its look is merged into the official app's metadata so keys Agora
    /// doesn't know are kept.
    public func saveBot(_ d: BotDraft) async throws {
        let connection = try requireConnection()
        guard let current = bot(named: d.name) else { throw HermesError.protocolViolation("Unknown Bot \(d.name)") }
        var params: [String: JSON] = ["name": .string(d.name)]
        if d.description != current.description { params["description"] = .string(d.description) }
        if !d.persona.isEmpty { params["soul"] = .string(d.persona) }
        if !d.model.isEmpty, d.model != current.model || d.provider != current.provider {
            params["model"] = .string(d.model)
            params["provider"] = .string(d.provider.isEmpty ? current.provider : d.provider)
            params["confirm_expensive_model"] = true
        }
        if params.count > 1 {
            let r = try await connection.call("profiles.configure", .object(params))
            if r["confirm_required"].bool == true {
                throw HermesError.protocolViolation(r["confirm_message"].string ?? "Hermes wants confirmation for that model.")
            }
        }
        var patch: [String: JSON] = ["title": .string(d.title)]
        patch["color"] = d.color.map(JSON.string) ?? .null
        if d.avatarPNG != nil { patch["imageKind"] = "photo" }
        try await mergeLook(bot: d.name, patch: patch)
        if let png = d.avatarPNG { try await setAvatar(bot: d.name, png: png) }
        try await loadRoster()
    }

    /// Read-modify-write of `ui_meta.hermes-bots`, retrying if another app changed it meanwhile.
    func mergeLook(bot name: String, patch: [String: JSON]) async throws {
        let connection = try requireConnection()
        for _ in 0..<3 {
            let fresh = try await connection.call("profiles.list", ["include_sessions": false])
            guard let row = fresh["profiles"].array?.first(where: { $0["name"].string == name }) else { throw HermesError.protocolViolation("Unknown Bot \(name)") }
            var meta = row["ui_meta"]["hermes-bots"].object ?? [:]
            for key in ["chat", "image", "pet"] { meta[key] = nil }
            for (k, v) in patch { meta[k] = v }
            let revision = row["ui_meta_revisions"]["hermes-bots"].int ?? 0
            if try await writeLook(bot: name, meta: .object(meta), expectedRevision: revision, throwOnConflict: false) { return }
        }
        throw HermesError.protocolViolation("The Bot was changed somewhere else while saving. Try again.")
    }

    @discardableResult
    func writeLook(bot name: String, meta: JSON, expectedRevision: Int, throwOnConflict: Bool = true) async throws -> Bool {
        let connection = try requireConnection()
        let r = try await connection.call(
            "profiles.configure",
            ["name": .string(name), "ui_meta": ["hermes-bots": meta], "ui_meta_expected_revisions": ["hermes-bots": .number(Double(expectedRevision))]])
        if r["applied"]["ui_meta"].bool == true { return true }
        if throwOnConflict { throw HermesError.protocolViolation("Couldn't save the Bot's look.") }
        return false
    }

    func setAvatar(bot name: String, png: Data) async throws {
        let connection = try requireConnection()
        _ = try await connection.call(
            "profiles.set_asset", ["name": .string(name), "asset": "avatar", "data": .string("data:image/png;base64,\(png.base64EncodedString())")])
        avatars[name] = png
    }

    /// The Bot's avatar image, if it has one.
    public func avatar(for bot: Bot) async -> Data? {
        guard bot.hasAvatar, bot.meta["imageKind"].string == "photo" else { return nil }
        if let cached = avatars[bot.name] { return cached }
        guard let connection, let r = try? await connection.call("profiles.get_asset", ["name": .string(bot.name), "asset": "avatar"]),
            r["found"].bool == true, let data = ChatImage.dataURL(r["data"].string ?? "").decodedData
        else { return nil }
        avatars[bot.name] = data
        return data
    }

    // MARK: Delete

    /// Deletes a Bot (its Hermes profile, with its memory and chats). The primary Bot can't be deleted.
    public func deleteBot(_ name: String) async throws {
        guard name != "default" else { throw HermesError.protocolViolation("The main Hermes Bot can't be deleted.") }
        let connection = try requireConnection()
        _ = try await connection.rest("DELETE", "/api/profiles/\(name)", profile: name, purpose: .profileRegistry, scopeQuery: false)
        allBots.removeAll { $0.name == name }
        bots.removeAll { $0.name == name }
        if let sid = botChatIDs.removeValue(forKey: name) { conversations[sid] = nil }
        sideChats[name] = nil
        routines[name] = nil
    }
}
