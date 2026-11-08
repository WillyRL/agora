import Foundation

/// A colour as the official app stores it (`#rrggbb` or `hsl(h s% l%)`), resolved to RGB.
public struct BotColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The official app's violet, used for the primary Bot and as a last resort.
    public static let primary = BotColor(hex: "#8b5cf6")!

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s.prefix(6), radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    public init(hue: Double, saturation: Double, lightness: Double) {
        let h = hue.truncatingRemainder(dividingBy: 360) / 360
        let s = saturation, l = lightness
        func f(_ n: Double) -> Double {
            let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
            let a = s * min(l, 1 - l)
            return l - a * max(-1, min(k - 3, 9 - k, 1))
        }
        self.init(red: f(0), green: f(8), blue: f(4))
    }

    /// Parses what `ui_meta.hermes-bots.color` may hold.
    public init?(css: String) {
        let s = css.trimmingCharacters(in: .whitespaces).lowercased()
        if let hex = BotColor(hex: s) {
            self = hex
            return
        }
        if s.hasPrefix("hsl") {
            let numbers = s.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
            guard numbers.count >= 3 else { return nil }
            self.init(hue: numbers[0], saturation: numbers[1] / 100, lightness: numbers[2] / 100)
            return
        }
        if let named = Self.named[s] {
            self = named
            return
        }
        return nil
    }

    static let named: [String: BotColor] = [
        "red": BotColor(hex: "#ef4444")!, "orange": BotColor(hex: "#f97316")!, "amber": BotColor(hex: "#f59e0b")!,
        "yellow": BotColor(hex: "#eab308")!, "green": BotColor(hex: "#22c55e")!, "teal": BotColor(hex: "#14b8a6")!,
        "blue": BotColor(hex: "#3b82f6")!, "indigo": BotColor(hex: "#6366f1")!, "violet": BotColor(hex: "#8b5cf6")!,
        "purple": BotColor(hex: "#a855f7")!, "pink": BotColor(hex: "#ec4899")!, "gray": BotColor(hex: "#6b7280")!,
    ]

    /// The deterministic hue the official app gives a profile with no picked colour.
    public static func derived(from name: String) -> BotColor {
        let key = name.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key != "default" else { return .primary }
        var hash: UInt32 = 0
        for unit in key.utf16 { hash = hash &* 31 &+ UInt32(unit) }
        return BotColor(hue: Double(hash % 360), saturation: 0.68, lightness: 0.58)
    }

    public var hex: String {
        func c(_ v: Double) -> String { String(format: "%02x", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#\(c(red))\(c(green))\(c(blue))"
    }

    /// True when white text reads better than black on this colour.
    public var isDark: Bool { 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.6 }
}

/// A personal assistant with its own purpose. In Hermes terms, one Bot is one profile.
public struct Bot: Sendable, Identifiable, Equatable {
    /// The profile name (Hermes' id for the Bot).
    public var name: String
    public var title: String
    public var description: String
    public var model: String
    public var provider: String
    public var color: BotColor
    public var shape: String?
    public var hasAvatar: Bool
    public var hidden: Bool
    public var isDefault: Bool
    /// The official app's `ui_meta.hermes-bots` object, kept whole so edits never drop keys Agora doesn't know.
    public var meta: JSON
    public var metaRevision: Int
    /// The Bot Chat Hermes knows about, if any (`canonical_session`).
    public var botChatID: String?
    public var botChatTipID: String?
    public var lastPreview: String?
    public var lastActive: Date?

    public var id: String { name }
    public var initial: String { String(title.first ?? "?").uppercased() }

    init(row p: JSON) {
        name = p["name"].string ?? ""
        let meta = p["ui_meta"]["hermes-bots"]
        self.meta = meta
        metaRevision = p["ui_meta_revisions"]["hermes-bots"].int ?? 0
        title = Bot.displayName(name: name, metaTitle: meta["title"].string, displayName: p["display_name"].string ?? p["bot_title"].string)
        description = p["description"].string ?? ""
        model = p["model"].string ?? ""
        provider = p["provider"].string ?? ""
        if name == "default", meta["custom"].bool != true, meta["color"].string == nil {
            color = .primary
        } else {
            color = meta["color"].string.flatMap(BotColor.init(css:)) ?? .derived(from: name)
        }
        shape = meta["shape"].string
        hasAvatar = p["has_avatar"].bool ?? false
        hidden = meta["hidden"].bool ?? false
        isDefault = p["is_default"].bool ?? (name == "default")
        let chat = p["canonical_session"]
        botChatID = chat["id"].string
        botChatTipID = chat["resolved_id"].string
        if let preview = chat["preview"].nonEmptyString {
            lastPreview = plainText(preview)
            lastActive = chat["last_active"].double.map { Date(timeIntervalSince1970: $0) }
        } else {
            lastPreview = nil
            lastActive = nil
        }
    }

    /// The same naming rules as the official app: a Bot Mode title wins, then the profile's
    /// display name, then "Hermes" for the primary profile, else the name in title case.
    static func displayName(name: String, metaTitle: String?, displayName: String?) -> String {
        if let t = metaTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        if let d = displayName?.trimmingCharacters(in: .whitespaces), !d.isEmpty { return d }
        if name.lowercased() == "default" { return "Hermes" }
        let raw = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return raw.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// One line of plain text from Markdown, for previews and notifications.
func plainText(_ markdown: String) -> String {
    var s = markdown.replacing(/```[\s\S]*?```/, with: " ")
    s = s.replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
    s = s.replacing(/[*_`#>]+/, with: "")
    s = s.replacing(/\s+/, with: " ")
    return String(s.trimmingCharacters(in: .whitespaces).prefix(240))
}
