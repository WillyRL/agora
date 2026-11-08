import Foundation

/// A group of Hermes tools a Bot can use (web, terminal, browser…), as `hermes tools` shows them.
public struct Toolset: Sendable, Equatable, Identifiable {
    public var name: String
    public var label: String
    public var description: String
    public var enabled: Bool
    /// False when it's on but missing the keys it needs, so its tools won't work yet.
    public var configured: Bool
    public var tools: [String]
    public var id: String { name }

    init(_ j: JSON) {
        name = j["name"].string ?? ""
        label = j["label"].nonEmptyString ?? name
        description = j["description"].string ?? ""
        enabled = j["enabled"].bool ?? false
        configured = j["configured"].bool ?? true
        tools = (j["tools"].array ?? []).compactMap(\.string)
    }
}

extension AgoraCore {
    /// A Bot's tool groups, the ones it can use first.
    public func toolsets(bot: String) async throws -> [Toolset] {
        let r = try await requireConnection().rest("GET", "/api/tools/toolsets", profile: bot)
        let all = (r.array ?? []).map(Toolset.init).filter { !$0.name.isEmpty }
        return all.filter(\.enabled) + all.filter { !$0.enabled }
    }
}
