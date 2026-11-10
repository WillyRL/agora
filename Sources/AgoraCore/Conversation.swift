import Foundation
import Observation

/// An image in a message: bytes Agora has, a data URL from history, or a file path on the Hermes host
/// (fetched through REST when shown, so it works for Remote Connections too).
public enum ChatImage: Sendable, Hashable {
    case data(Data, mime: String)
    case dataURL(String)
    case hostPath(String)
    case remote(URL)

    var decodedData: Data? {
        switch self {
        case .data(let d, _): return d
        case .dataURL(let s):
            guard let comma = s.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(s[s.index(after: comma)...]))
        default: return nil
        }
    }
}

/// One tool call, shown as a compact row ("web_search…") that expands to details.
public struct ToolActivity: Sendable, Equatable {
    public enum State: Sendable, Equatable { case running, done, failed }
    public var id: String
    public var name: String
    /// Short preview of what it's doing (a command, a query …).
    public var context: String
    /// The full arguments, pretty-printed.
    public var arguments: String
    public var result: String
    public var progress: String?
    public var duration: Double?
    public var state: State
}

public struct ChatItem: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case user
        case assistant
        /// A message another Bot sent this Bot.
        case botMessage(from: String)
        /// A Routine's result or another background completion.
        case routineResult
        /// News about a kanban task this chat created (done, blocked, ready for review …).
        case kanbanUpdate(KanbanUpdate)
        /// The task a kanban card gave this Bot: the brief that starts a card's chat.
        case kanbanBrief(KanbanBrief)
        case tool(ToolActivity)
        /// Something Agora or Hermes wants you to know (an error, "interrupted" …).
        case notice
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var images: [ChatImage]
    /// Files sent with a message (paths on the Hermes host, or just names while it's sending).
    public var files: [String]
    public var date: Date?
    /// A message being streamed in right now.
    public var streaming: Bool
    /// A message Agora sent that Hermes hasn't confirmed yet.
    public var pending: Bool
    public var failed: Bool

    public init(
        id: String, kind: Kind, text: String, images: [ChatImage] = [], files: [String] = [], date: Date? = nil, streaming: Bool = false,
        pending: Bool = false, failed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.images = images
        self.files = files
        self.date = date
        self.streaming = streaming
        self.pending = pending
        self.failed = failed
    }

    public var tool: ToolActivity? {
        if case .tool(let t) = kind { return t }
        return nil
    }
}

/// One conversation with a Bot: its Bot Chat or a Side Chat.
@MainActor
@Observable
public final class Conversation: Identifiable {
    public nonisolated let bot: String
    /// The live session id: WebSocket calls and events use it.
    public internal(set) var sessionID: String
    /// The saved session id (Hermes' session store): REST and the Side Chat list use it. A remote
    /// `hermes serve` resumes a saved session under a new live id; locally the two are usually the same.
    public internal(set) var storedSessionID: String
    public internal(set) var title: String
    public var isBotChat: Bool { title == AgoraCore.botChatTitle }
    /// A kanban card's worker chat, opened read-only: Hermes lets only the board run it.
    public internal(set) var isKanbanTask = false
    public internal(set) var items: [ChatItem] = []
    public internal(set) var isRunning = false
    /// More (older) history can be loaded.
    public internal(set) var hasMoreHistory = false
    public internal(set) var loadingHistory = false
    /// A short status line while the Bot works ("compacting…").
    public internal(set) var statusLine: String?
    /// Approvals, questions and secret prompts waiting for an answer.
    public internal(set) var prompts: [PendingPrompt] = []
    public internal(set) var startedAt: Date?

    var revision = 0
    var needsHistory = false
    /// The running turn was started by a message Agora sent.
    var awaitingOwnReply = false
    /// The running turn used a Routine (cron) tool, so the Routines list may have changed.
    var turnUsedRoutineTool = false
    /// The Bot that sent the message the current turn answers, if it was another Bot.
    var lastTurnFromBot: String?
    var generation = 0
    var historyOffset = 0
    var liveSegments: [String: Int] = [:]  // "turn:segment" → received UTF-16 length
    var liveItemID: String?
    var liveTurn: String?

    public nonisolated var id: String { sessionID_ }
    nonisolated let sessionID_: String

    init(bot: String, sessionID: String, title: String) {
        self.bot = bot
        self.sessionID = sessionID
        self.storedSessionID = sessionID
        self.sessionID_ = sessionID
        self.title = title
    }

    // MARK: Snapshot + history

    /// Whether `id` names this conversation (live or saved id).
    public func matches(_ id: String) -> Bool { id == sessionID || id == storedSessionID }

    func apply(snapshot s: JSON) {
        if let stored = s["session_key"].nonEmptyString ?? s["stored_session_id"].nonEmptyString { storedSessionID = stored }
        revision = s["revision"].int ?? revision
        generation = s["execution_generation"].int ?? generation
        isRunning = s["running"].bool ?? false
        if let t = s["info"]["title"].string, !t.isEmpty, title != AgoraCore.botChatTitle { title = t }
        if let started = s["info"]["started_at"].double { startedAt = Date(timeIntervalSince1970: started) }
    }

    /// Replaces history with the newest page (rows in time order).
    func setHistory(rows: [JSON], pageSize: Int) {
        let parsed = Conversation.items(from: rows)
        // Keep what's still in flight: unconfirmed messages, and the live reply while the Bot is working.
        let live = items.filter { $0.pending || ($0.streaming && isRunning) }
        let storedUserTexts = Set(parsed.filter { $0.kind == .user }.suffix(5).map(\.text))
        items = parsed + live.filter { l in !parsed.contains { $0.id == l.id } && !(l.kind == .user && storedUserTexts.contains(l.text)) }
        if !isRunning { liveItemID = nil; liveSegments.removeAll() }
        historyOffset = rows.count
        hasMoreHistory = rows.count >= pageSize
    }

    func prependHistory(rows: [JSON], pageSize: Int) {
        let older = Conversation.items(from: rows).filter { o in !items.contains { $0.id == o.id } }
        items = older + items
        historyOffset += rows.count
        hasMoreHistory = rows.count >= pageSize
    }

    // MARK: Parsing stored rows

    static let botMessagePattern = /^Message from 🤖 (.+?) \(@([^)]+)\):\s*/
    static let legacyBotMessagePattern = /^\[Message from agent '([^']+)'\]\s*/
    static let routineKinds: Set<String> = ["process_complete", "async_delegation_complete", "internal_notification"]

    /// Turns stored OpenAI-format rows (REST or snapshot) into what the chat shows.
    static func items(from rows: [JSON]) -> [ChatItem] {
        var out: [ChatItem] = []
        var toolIndex: [String: Int] = [:]
        for row in rows {
            let role = row["role"].string ?? ""
            let kind = row["display_kind"].string
            let meta = metadata(row["display_metadata"])
            if kind == "hidden" || meta["model_only"].bool == true { continue }
            let id = (row["id"].int ?? row["row_id"].int).map { "row-\($0)" } ?? row["message_uid"].string ?? UUID().uuidString
            let date = row["timestamp"].double.map { Date(timeIntervalSince1970: $0) }
            let (text, images) = content(row["content"])
            switch role {
            case "user":
                if let update = KanbanUpdate(text: text) {
                    out.append(ChatItem(id: id, kind: .kanbanUpdate(update), text: text, date: date))
                    continue
                }
                if let brief = KanbanBrief(text: text) {
                    out.append(ChatItem(id: id, kind: .kanbanBrief(brief), text: text, date: date))
                    continue
                }
                // Before the routine check: the gateway stores another Bot's message as an internal notification too.
                if let m = text.firstMatch(of: botMessagePattern) {
                    out.append(ChatItem(id: id, kind: .botMessage(from: String(m.1)), text: String(text[m.range.upperBound...]), images: images, date: date))
                    continue
                }
                if let k = kind, routineKinds.contains(k) {
                    let shown = meta["display_text"].nonEmptyString ?? text
                    out.append(ChatItem(id: id, kind: .routineResult, text: routineText(full: text, shown: shown), date: date))
                    continue
                }
                if text.hasPrefix("[System:") { continue }
                if let m = text.firstMatch(of: botMessagePattern) {
                    out.append(ChatItem(id: id, kind: .botMessage(from: String(m.1)), text: String(text[m.range.upperBound...]), images: images, date: date))
                } else if let m = text.firstMatch(of: legacyBotMessagePattern) {
                    out.append(ChatItem(id: id, kind: .botMessage(from: String(m.1)), text: String(text[m.range.upperBound...]), images: images, date: date))
                } else {
                    let (caption, pathImages, files) = splitAttachmentLines(text)
                    if kind == "failed_turn" { continue }
                    out.append(ChatItem(id: id, kind: .user, text: caption, images: images + pathImages, files: files, date: date))
                }
            case "assistant":
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty {
                    out.append(ChatItem(id: id, kind: .assistant, text: text, images: images, date: date))
                }
                for call in row["tool_calls"].array ?? [] {
                    let callID = call["id"].string ?? call["call_id"].string ?? UUID().uuidString
                    let name = toolName(call["function"]["name"].string ?? "tool")
                    let args = call["function"]["arguments"].string ?? ""
                    let activity = ToolActivity(
                        id: callID, name: name, context: toolContext(arguments: args), arguments: prettyJSON(args), result: "", progress: nil,
                        duration: nil, state: .done)
                    toolIndex[callID] = out.count
                    out.append(ChatItem(id: "tool-\(callID)", kind: .tool(activity), text: "", date: date))
                }
            case "tool":
                guard let callID = row["tool_call_id"].string, let i = toolIndex[callID], var t = out[i].tool else { continue }
                t.result = text
                if isErrorResult(text) { t.state = .failed }
                out[i].kind = .tool(t)
            default:
                continue
            }
        }
        return out
    }

    /// Some stored tool names are encoded as `_tool_<base64>`; show the real name.
    static func toolName(_ raw: String) -> String {
        guard raw.hasPrefix("_tool_") else { return raw }
        var b64 = String(raw.dropFirst(6)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty else { return raw }
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    static func metadata(_ j: JSON) -> JSON {
        if let s = j.string, let parsed = try? JSON(text: s) { return parsed }
        return j
    }

    static func content(_ c: JSON) -> (String, [ChatImage]) {
        if let s = c.string { return (s, []) }
        var text: [String] = []
        var images: [ChatImage] = []
        for part in c.array ?? [] {
            switch part["type"].string {
            case "text", "input_text": text.append(part["text"].string ?? "")
            case "image_url", "input_image":
                let url = part["image_url"]["url"].string ?? part["image_url"].string ?? ""
                if url.hasPrefix("data:") { images.append(.dataURL(url)) } else if let u = URL(string: url), u.scheme?.hasPrefix("http") == true {
                    images.append(.remote(u))
                }
            default: continue
            }
        }
        let joined = text.joined(separator: "\n").replacingOccurrences(of: "[screenshot]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (joined, images)
    }

    /// `@image:<path>` and `@file:<path>` lines mark images and files attached to a user message.
    static func splitAttachmentLines(_ text: String) -> (String, [ChatImage], [String]) {
        guard text.contains("@image:") || text.contains("@file:") else { return (text, [], []) }
        var kept: [Substring] = []
        var images: [ChatImage] = []
        var files: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@image:") {
                images.append(.hostPath(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("@file:") {
                // Hermes quotes a path with spaces in `, " or '.
                let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                let path = value.count > 1 && ["`", "\"", "'"].contains(value.first!) && value.last == value.first ? String(value.dropFirst().dropLast()) : value
                if !path.isEmpty { files.append(path) }
            } else {
                kept.append(line)
            }
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), images, files)
    }

    static func routineText(full: String, shown: String) -> String {
        if let r = full.range(of: "--- JOB OUTPUT ---") ?? full.range(of: "--- RESULT ---") {
            let body = full[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return body }
        }
        return shown
    }

    static func toolContext(arguments: String) -> String {
        guard let args = try? JSON(text: arguments), let o = args.object else { return String(arguments.prefix(80)) }
        for key in ["command", "query", "url", "path", "code", "prompt", "text", "name"] {
            if let v = o[key]?.string { return String(v.split(separator: "\n").first ?? "").prefix(80).description }
        }
        return String((o.values.first?.string ?? "").prefix(80))
    }

    static func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return text }
        return String(decoding: pretty, as: UTF8.self)
    }

    static func isErrorResult(_ text: String) -> Bool {
        guard let j = try? JSON(text: text) else { return false }
        if let e = j["error"].string, !e.isEmpty { return true }
        return j["status"].string == "error"
    }

    // MARK: Live events

    /// Applies one event for this session. Returns true when it changed what a notification cares about.
    func apply(event e: GatewayEvent) {
        if let g = e.executionGeneration, g < generation, e.type.hasPrefix("message.") || e.type.hasPrefix("tool.") { return }
        let p = e.payload
        switch e.type {
        case "session.info":
            if let t = p["title"].nonEmptyString, !isBotChat, t != AgoraCore.botChatTitle { title = t }
            if let r = p["revision"].int { revision = r }
            if let g = p["execution_generation"].int { generation = max(generation, g) }
            if let running = p["running"].bool {
                isRunning = running
                if !running { finishLive(status: nil) }
            }
        case "session.updated", "session.title":
            if let r = p["revision"].int { revision = r }
            if let t = p["title"].nonEmptyString, !isBotChat, t != AgoraCore.botChatTitle { title = t }
        case "message.start":
            isRunning = true
            liveTurn = p["turn_id"].string
            if let g = e.executionGeneration { generation = max(generation, g) }
            lastTurnFromBot = nil
            // A turn Hermes started itself (a Routine result, a message from another Bot …) shows its prompt.
            if let shown = p["display_text"].nonEmptyString ?? p["text"].nonEmptyString, p["display_kind"].string != "hidden" {
                let id = "start-\(p["turn_id"].string ?? UUID().uuidString)"
                if !items.contains(where: { $0.id == id }) {
                    if let update = KanbanUpdate(text: p["text"].nonEmptyString ?? shown) {
                        items.append(ChatItem(id: id, kind: .kanbanUpdate(update), text: shown, date: Date()))
                    } else if let brief = KanbanBrief(text: p["text"].nonEmptyString ?? shown) {
                        items.append(ChatItem(id: id, kind: .kanbanBrief(brief), text: shown, date: Date()))
                    } else if let m = shown.firstMatch(of: Conversation.botMessagePattern) {
                        lastTurnFromBot = String(m.1)
                        items.append(ChatItem(id: id, kind: .botMessage(from: String(m.1)), text: String(shown[m.range.upperBound...]), date: Date()))
                    } else if let k = p["display_kind"].string, Conversation.routineKinds.contains(k) || p["notification_category"].string != nil {
                        items.append(ChatItem(id: id, kind: .routineResult, text: Conversation.routineText(full: shown, shown: shown), date: Date()))
                    }
                }
            }
        case "message.delta":
            isRunning = true
            guard let text = p["text"].string else {
                liveItemID = nil  // segment boundary
                return
            }
            appendDelta(text, turn: p["turn_id"].string ?? liveTurn ?? "turn", segment: p["segment"].int ?? 0, offset: p["offset"].int)
        case "message.interim":
            if p["already_streamed"].bool != true, let text = p["text"].string {
                appendDelta(text, turn: p["turn_id"].string ?? liveTurn ?? "turn", segment: p["segment"].int ?? 0, offset: nil)
            }
            liveItemID = nil
        case "tool.generating":
            statusLine = "\(p["name"].string ?? "tool")…"
        case "tool.start":
            liveItemID = nil
            statusLine = nil
            if (p["name"].string ?? p["tool_name"].string ?? "").contains("cron") { turnUsedRoutineTool = true }
            let id = p["tool_id"].string ?? p["tool_call_id"].string ?? UUID().uuidString
            let args = p["args"].isNull ? "" : Conversation.prettyJSON(p["args"].text)
            let activity = ToolActivity(
                id: id, name: Conversation.toolName(p["name"].string ?? p["tool_name"].string ?? "tool"), context: p["context"].string ?? "", arguments: args,
                result: "", progress: nil, duration: nil, state: .running)
            if !items.contains(where: { $0.id == "tool-\(id)" }) {
                items.append(ChatItem(id: "tool-\(id)", kind: .tool(activity), text: "", date: Date(), streaming: true))
            }
        case "tool.progress":
            updateTool(p["tool_id"].string) { t in
                if let m = p["message"].string { t.progress = m } else if let pct = p["percent"].double { t.progress = "\(Int(pct))%" }
            }
        case "tool.complete":
            updateTool(p["tool_id"].string) { t in
                t.state = p["is_error"].bool == true ? .failed : .done
                t.result = p["summary"].string ?? p["result_text"].string ?? (p["result"].isNull ? "" : p["result"].text)
                t.duration = p["duration_s"].double
                t.progress = nil
            }
            if let path = p["image_path"].nonEmptyString {
                items.append(ChatItem(id: "img-\(path)", kind: .assistant, text: "", images: [.hostPath(path)], date: Date()))
            }
        case "message.complete":
            let text = p["text"].string ?? p["content"].string ?? ""
            let status = p["status"].string ?? p["outcome"].string
            if !text.isEmpty {
                if let id = liveItemID, let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].text = text
                } else if !items.contains(where: { $0.kind == .assistant && $0.streaming && $0.text == text }) {
                    items.append(ChatItem(id: "reply-\(UUID().uuidString)", kind: .assistant, text: text, date: Date(), streaming: true))
                }
            }
            if status == "error" || status == "failed" {
                let message = p["error"].string ?? p["failure_reason"].string ?? "The Bot ran into an error."
                items.append(ChatItem(id: "notice-\(UUID().uuidString)", kind: .notice, text: message, date: Date()))
            } else if status == "interrupted" || status == "cancelled" {
                items.append(ChatItem(id: "notice-\(UUID().uuidString)", kind: .notice, text: "Stopped.", date: Date()))
            }
            finishLive(status: status)
            isRunning = false
        case "status.update":
            let kind = p["kind"].string
            if kind == "compacting" { statusLine = p["text"].string ?? "Condensing…" } else if kind == "status" || kind == "lifecycle" {
                statusLine = p["text"].nonEmptyString
            }
        case "error":
            items.append(ChatItem(id: "notice-\(UUID().uuidString)", kind: .notice, text: p["message"].string ?? "Error", date: Date()))
        default:
            break
        }
    }

    private func appendDelta(_ text: String, turn: String, segment: Int, offset: Int?) {
        let key = "\(turn):\(segment)"
        var chunk = text
        let received = liveSegments[key] ?? 0
        if let offset, offset < received {
            let overlap = received - offset
            let units = Array(text.utf16)
            guard overlap < units.count else { return }
            chunk = String(decoding: units[overlap...], as: UTF16.self)
        }
        liveSegments[key] = received + chunk.utf16.count
        let itemID = "live-\(key)"
        if let i = items.firstIndex(where: { $0.id == itemID }) {
            items[i].text += chunk
        } else {
            items.append(ChatItem(id: itemID, kind: .assistant, text: chunk, date: Date(), streaming: true))
        }
        liveItemID = itemID
        statusLine = nil
    }

    private func updateTool(_ id: String?, _ change: (inout ToolActivity) -> Void) {
        guard let id, let i = items.firstIndex(where: { $0.id == "tool-\(id)" }), var t = items[i].tool else { return }
        change(&t)
        items[i].kind = .tool(t)
        if t.state != .running { items[i].streaming = false }
    }

    private func finishLive(status: String?) {
        for i in items.indices where items[i].streaming {
            items[i].streaming = false
            if var t = items[i].tool, t.state == .running {
                t.state = status == "error" ? .failed : .done
                items[i].kind = .tool(t)
            }
        }
        liveItemID = nil
        liveTurn = nil
        liveSegments.removeAll()
        statusLine = nil
    }

    /// The streaming reply text so far (empty when idle).
    public var liveText: String {
        items.last(where: { $0.streaming && $0.kind == .assistant })?.text ?? ""
    }
}
