import CryptoKit
import Foundation

/// A file a Bot hands over in its reply. Bots write `MEDIA:/path/to/file` (some write `ATTACH:`) on its own line for any
/// file, or `::preview{file="page.html"}` for an HTML page shown live in the chat (Hermes teaches
/// both to Bots talking to a desktop app). The file stays on the Hermes host; Agora fetches it.
public struct FileAttachment: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable { case image, html, text, other }

    public var path: String
    /// Shown live in the message (`::preview`), not as a card.
    public var inline: Bool
    public var id: String { "\(inline ? "preview" : "media"):\(path)" }

    public init(path: String, inline: Bool) {
        self.path = path
        self.inline = inline
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var fileExtension: String { (path as NSString).pathExtension.lowercased() }

    public var kind: Kind {
        switch fileExtension {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg": return .image
        case "html", "htm": return .html
        case "md", "markdown", "txt", "text", "csv", "tsv", "json", "log", "yaml", "yml", "xml", "toml": return .text
        default: return .other
        }
    }
}

/// A Bot message split into text and the files it hands over, in order.
public enum MessagePart: Sendable, Hashable {
    case text(String)
    case file(FileAttachment)

    /// Splits out `MEDIA:` / `ATTACH:` and `::preview{…}` lines (each alone on its line, outside code blocks).
    public static func split(_ text: String) -> [MessagePart] {
        guard text.contains("MEDIA:") || text.contains("ATTACH:") || text.contains("::preview") else { return [.text(text)] }
        var parts: [MessagePart] = []
        var buffer: [Substring] = []
        var inCode = false
        func flush() {
            let t = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append(.text(t)) }
            buffer.removeAll()
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle() }
            if !inCode, let file = attachment(in: trimmed) {
                flush()
                parts.append(.file(file))
            } else {
                buffer.append(line)
            }
        }
        flush()
        return parts
    }

    static func attachment(in line: String) -> FileAttachment? {
        var line = line
        if line.hasPrefix("`"), line.hasSuffix("`"), line.count > 2 { line = String(line.dropFirst().dropLast()) }
        // Hermes's own apps use MEDIA:; Bots following other instructions (or their own skills) write ATTACH:.
        if let prefix = ["MEDIA:", "ATTACH:"].first(where: { line.hasPrefix($0) }) {
            let path = clean(String(line.dropFirst(prefix.count)))
            // Bots give absolute paths; anything else is prose that happens to start with "MEDIA:".
            return path.hasPrefix("/") || path.hasPrefix("~") ? FileAttachment(path: path, inline: false) : nil
        }
        if line.hasPrefix("::preview{"), line.hasSuffix("}"),
            let m = line.firstMatch(of: /(?:file|path)\s*=\s*(?:"([^"]+)"|'([^']+)')/)
        {
            let path = String(m.1 ?? m.2 ?? "")
            return path.isEmpty ? nil : FileAttachment(path: path, inline: true)
        }
        return nil
    }

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>"))
    }
}

extension AgoraCore {
    /// A file on the Hermes host, as bytes. Works the same for Local and Remote Connections.
    public func fileData(_ path: String, in c: Conversation) async throws -> Data {
        let connection = try requireConnection()
        return try await connection.restData("/api/fs/download", profile: c.bot, query: ["path": path, "session_id": c.storedSessionID])
    }

    /// Downloads a file from the Hermes host into Agora's cache (fresh each time, since Bots rewrite
    /// files) and returns the local copy, for opening, Quick Look or saving.
    public func localCopy(of path: String, in c: Conversation) async throws -> URL {
        let data = try await fileData(path, in: c)
        let folder = Self.filesCache.appending(path: Self.cacheKey(c.bot + ":" + path), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: (path as NSString).lastPathComponent)
        try data.write(to: url, options: .atomic)
        return url
    }

    static var filesCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Agora/Files", directoryHint: .isDirectory)
    }

    static func cacheKey(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
