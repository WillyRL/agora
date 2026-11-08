import Foundation

/// A skill a Bot can use: a SKILL.md of instructions it loads when a task calls for it. Each Bot
/// has its own skills (its profile's `skills/` folder), so adding or turning one off touches that
/// Bot only.
public struct Skill: Sendable, Equatable, Identifiable {
    public enum Origin: String, Sendable {
        /// From the skills hub (`hermes skills install`).
        case hub
        /// Shipped with Hermes.
        case bundled
        /// From a shared folder outside the Bot (`skills.external_dirs`).
        case external
        /// Written by the Bot itself or by you.
        case local = "agent"
    }

    public var name: String
    public var description: String
    public var category: String
    public var enabled: Bool
    public var origin: Origin
    public var id: String { name }

    init(_ j: JSON) {
        name = j["name"].string ?? ""
        description = j["description"].string ?? ""
        category = j["category"].nonEmptyString ?? "other"
        enabled = j["enabled"].bool ?? true
        origin = Origin(rawValue: j["provenance"].string ?? "") ?? .local
    }

    /// A skill name Hermes accepts, made from whatever was typed ("Silver Weekly!" → "silver-weekly").
    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }

    /// A SKILL.md from the New Skill form.
    public static func document(name: String, description: String, instructions: String) -> String {
        let oneLine = description.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let quoted = "\"" + oneLine.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return "---\nname: \(name)\ndescription: \(quoted)\n---\n\n\(instructions.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }
}

/// A skill on the skills hub.
public struct HubSkill: Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    /// What to install: unique across sources, where names aren't ("official/finance/pptx-author").
    public var identifier: String
    /// Where it's from (official, skills.sh, github…) and how far Hermes trusts it (builtin, trusted, community).
    public var source: String
    public var trust: String
    /// This Bot has it already.
    public var installed: Bool
    public var id: String { identifier }
}

extension AgoraCore {
    /// A Bot's skills (on and off), by category then name.
    public func skills(bot: String) async throws -> [Skill] {
        let r = try await requireConnection().rest("GET", "/api/skills", profile: bot)
        return (r.array ?? []).map(Skill.init).filter { !$0.name.isEmpty }
            .sorted { ($0.category, $0.name) < ($1.category, $1.name) }
    }

    /// Turns a skill on or off for one Bot. Off keeps it on disk; the Bot just stops seeing it.
    public func setSkill(_ name: String, enabled: Bool, bot: String) async throws {
        _ = try await requireConnection().rest(
            "PUT", "/api/skills/toggle", profile: bot, body: ["name": .string(name), "enabled": .bool(enabled), "profile": .string(bot)])
        await reloadSkills(bot: bot)
    }

    /// The skill's SKILL.md.
    public func skillContent(_ name: String, bot: String) async throws -> String {
        try await requireConnection().rest("GET", "/api/skills/content", profile: bot, query: ["name": name])["content"].string ?? ""
    }

    public func saveSkill(_ name: String, content: String, bot: String) async throws {
        _ = try await requireConnection().rest(
            "PUT", "/api/skills/content", profile: bot, body: ["name": .string(name), "content": .string(content), "profile": .string(bot)])
        await reloadSkills(bot: bot)
    }

    /// Creates a skill for one Bot.
    public func createSkill(_ name: String, content: String, category: String?, bot: String) async throws {
        var body: [String: JSON] = ["name": .string(name), "content": .string(content), "profile": .string(bot)]
        if let category, !category.isEmpty { body["category"] = .string(category) }
        _ = try await requireConnection().rest("POST", "/api/skills", profile: bot, body: .object(body))
        await reloadSkills(bot: bot)
    }

    /// Searches the skills hub (shared by every Bot), marking what this Bot already has.
    public func searchSkillHub(_ query: String, bot: String) async throws -> [HubSkill] {
        let r = try await requireConnection().rest("GET", "/api/skills/hub/search", profile: bot, query: ["q": query, "limit": "30"])
        let installed = Set((r["installed"].object ?? [:]).keys)
        return (r["results"].array ?? []).compactMap { j in
            guard let name = j["name"].nonEmptyString, let id = j["identifier"].nonEmptyString else { return nil }
            let source = j["source"].string ?? ""
            // A ClawHub hit is listed by its bare slug but installed under clawhub/<slug>.
            let has = installed.contains(id) || (source == "clawhub" && installed.contains("clawhub/\(id)"))
            return HubSkill(
                name: name, description: j["description"].string ?? "", identifier: id, source: source,
                trust: j["trust_level"].string ?? "community", installed: has)
        }
    }

    /// Installs a hub skill for one Bot. Hermes scans it first and refuses one that fails the scan;
    /// the error then carries Hermes's reason.
    public func installSkill(_ skill: HubSkill, bot: String) async throws {
        _ = try await requireConnection().call(
            "skills.manage", ["action": "install", "query": .string(skill.identifier), "profile": .string(bot)], timeout: .seconds(180))
        await reloadSkills(bot: bot)
    }

    /// Removes a hub-installed skill from one Bot. Hermes does it in the background, so this waits
    /// (up to ~20 s) until the Bot's list no longer has it.
    public func uninstallSkill(_ name: String, bot: String) async throws {
        _ = try await requireConnection().rest("POST", "/api/skills/hub/uninstall", profile: bot, body: ["name": .string(name), "profile": .string(bot)])
        for _ in 0..<20 {
            try await Task.sleep(for: uninstallPollInterval)
            if try await !skills(bot: bot).contains(where: { $0.name == name }) { break }
        }
        await reloadSkills(bot: bot)
    }

    /// Lets the Bot's open chats see skill changes now (new chats always do).
    func reloadSkills(bot: String) async {
        guard let connection else { return }
        for c in conversations.values where c.bot == bot {
            _ = try? await connection.call("skills.reload", ["session_id": .string(c.sessionID), "profile": .string(bot)], timeout: .seconds(30))
        }
    }
}
