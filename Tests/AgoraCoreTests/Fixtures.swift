import Foundation

@testable import AgoraCore

enum Fixtures {
    /// Loads a fixture. A fixture may name a `base` (e.g. the recorded connect + roster) and add to it:
    /// `exchanges` extend the base's first connection, `http`/`control` are added, `connections` are appended,
    /// and `profiles` patches rows of the recorded `profiles.list` result by name.
    static func load(_ name: String) throws -> JSON {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw HermesError.protocolViolation("missing fixture \(name)")
        }
        let own = try JSON(data: Data(contentsOf: url))
        guard let baseName = own["base"].string else { return own }
        var base = try load(baseName)
        var connections = base["connections"].array ?? []
        if var first = connections.first?.object {
            var exchanges = first["exchanges"]?.array ?? []
            if let patches = own["profiles"].object {
                exchanges = exchanges.map { ex in
                    guard ex["expect"]["method"].string == "profiles.list" else { return ex }
                    let rows = (ex["result"]["profiles"].array ?? []).map { row -> JSON in
                        guard let name = row["name"].string, let patch = patches[name]?.object else { return row }
                        var r = row.object ?? [:]
                        for (k, v) in patch { r[k] = v }
                        return .object(r)
                    }
                    return ex.setting("result", ex["result"].setting("profiles", .array(rows)))
                }
            }
            exchanges += own["exchanges"].array ?? []
            first["exchanges"] = .array(exchanges)
            if let extra = own["onOpenExtra"].array { first["onOpen"] = .array((first["onOpen"]?.array ?? []) + extra) }
            connections[0] = .object(first)
        }
        connections += own["connections"].array ?? []
        base = base.setting("connections", .array(connections))
        base = base.setting("http", .array((own["http"].array ?? []) + (base["http"].array ?? [])))
        base = base.setting("control", .array((base["control"].array ?? []) + (own["control"].array ?? [])))
        for key in ["ensure", "controlDown", "description", "tailscale"] where !own[key].isNull { base = base.setting(key, own[key]) }
        return base
    }
}
