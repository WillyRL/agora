import Foundation

/// A standalone `hermes serve` (how remote Connections usually reach Hermes) answers on the older
/// session dialect even on a current Hermes: its `gateway.ready` has no `session_authority`, and it
/// rejects any field it doesn't know. Agora speaks the canonical dialect; this rewrites a call into
/// the older one. Fields map one-to-one where they exist and are dropped where the older dialect has
/// no equivalent (it checks no generations and stages images on the session itself).
enum LegacyDialect {
    static func translate(_ method: String, _ params: JSON) -> (String, JSON) {
        var p = params.object ?? [:]
        switch method {
        case "session.create":
            if let id = p.removeValue(forKey: "request_id") { p["idempotency_key"] = id }
        case "prompt.submit":
            // `attachments`: images uploaded with image.attach_bytes go with the next prompt anyway.
            p = p.filter { ["session_id", "profile", "text"].contains($0.key) }
        case "session.interrupt", "session.steer":
            p["execution_generation"] = nil
        case "session.events.since":
            if let mark = p.removeValue(forKey: "last_sequence") { p["last_seen"] = mark }
        case "approval.respond":
            p["execution_generation"] = nil
            if let id = p.removeValue(forKey: "prompt_id") { p["request_id"] = id }
        case "session.mutate":
            let session: [String: JSON] = ["session_id": p["session_id"] ?? .null, "profile": p["profile"] ?? .null]
            let payload = p["payload"]?.object ?? [:]
            switch p["operation"]?.string {
            case "rename": return ("session.title", .object(session.merging(["title": payload["title"] ?? .null]) { a, _ in a }))
            case "compress": return ("session.compress", .object(session))
            case "archive": return ("session.archive", .object(session.merging(["archived": payload["archived"] ?? true]) { a, _ in a }))
            case "delete": return ("session.delete", .object(session))
            default: break
            }
        default: break
        }
        return (method, .object(p))
    }
}
