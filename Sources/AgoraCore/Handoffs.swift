import Foundation

/// Work passed between Bots, read out of what Hermes stores: messages one Bot sends another
/// (`message_agent`) and kanban task updates. Hermes marks neither with structured data a client can
/// read; both are recognised by the fixed text Hermes writes (tools/bot_mode_dm.py, locales/en.yaml).

/// A message from another Bot, split into what the sender wrote and the extras `message_agent` adds.
public struct Handoff: Sendable, Equatable {
    public var message: String
    /// The sender doesn't wait for an answer (`[no reply needed]`).
    public var noReply: Bool
    public var constraints: String?
    /// What the sender needs back.
    public var replyNeeded: String?

    static let noReplyMarker = "[no reply needed]"

    /// `body` is the text after "Message from 🤖 Name (@handle): ".
    public init(body: String) {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        noReply = text.hasPrefix(Self.noReplyMarker)
        if noReply { text = String(text.dropFirst(Self.noReplyMarker.count)).trimmingCharacters(in: .whitespaces) }
        // message_agent puts the typed fields last, each on its own labelled line.
        var lines = text.components(separatedBy: "\n")
        var constraints: String?
        var replyNeeded: String?
        while let last = lines.last {
            if last.hasPrefix("Constraints: ") { constraints = String(last.dropFirst("Constraints: ".count)) }
            else if last.hasPrefix("Reply needed: ") { replyNeeded = String(last.dropFirst("Reply needed: ".count)) }
            else { break }
            lines.removeLast()
        }
        self.constraints = constraints
        self.replyNeeded = replyNeeded
        message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A `message_agent` call in the sending Bot's chat.
public struct OutgoingHandoff: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case sending
        case delivered
        /// Hermes couldn't confirm it arrived.
        case unconfirmed
        case cancelled
        case failed(String)
    }

    /// Who it went to, as the Bot named them (a Bot name or handle).
    public var to: String
    public var message: Handoff
    public var status: Status

    public init?(_ tool: ToolActivity) {
        guard tool.name == "message_agent", let args = try? JSON(text: tool.arguments) else { return nil }
        to = (args["target"].string ?? args["to"].string ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        var body = args["message"].string ?? ""
        if args["expects_reply"].bool == false { body = Handoff.noReplyMarker + " " + body }
        message = Handoff(body: body)
        if let c = args["constraints"].nonEmptyString { message.constraints = c }
        if let e = args["expecting"].nonEmptyString { message.replyNeeded = e }
        let cancelling = args["cancel"].nonEmptyString != nil
        let result = (try? JSON(text: tool.result)) ?? .null
        if tool.state == .running {
            status = .sending
        } else if let error = result["error"].nonEmptyString {
            status = .failed(Self.firstSentence(error))
        } else if tool.state == .failed {
            status = .failed(Self.firstSentence(tool.result))
        } else if cancelling {
            status = .cancelled
        } else if result["status"].string == "ambiguous" {
            status = .unconfirmed
        } else {
            status = .delivered
        }
    }

    static func firstSentence(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        if let end = line.range(of: ". ") { return String(line[..<end.lowerBound]) + "." }
        return line
    }
}

/// A kanban task update Hermes posts to the chat that created the task ("[kanban] Task t_… completed.").
public struct KanbanUpdate: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case done, review, changesRequested, blocked, retrying, failed, other
    }

    public var taskID: String
    public var status: Status
    /// Hermes's own words for it ("completed", "blocked; needs attention" …).
    public var statusText: String
    public var title: String
    /// The Bot assigned to the task.
    public var assignee: String
    public var board: String
    public var result: String?
    public var reviewFeedback: String?

    static var head: Regex<(Substring, Substring, Substring)> { /^\[kanban\] Task (\S+) (.+?)\.\s*$/ }

    public init?(text: String) {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, let m = first.firstMatch(of: Self.head) else { return nil }
        taskID = String(m.1)
        statusText = String(m.2)
        status = Self.status(statusText)
        var title = "", assignee = "", board = ""
        var result: String?, feedback: String?
        for line in lines.dropFirst() {
            // The rest is guidance for the Bot, not news for you.
            if line.hasPrefix("This is an automatic task-status notification") || line.hasPrefix("Inspect the existing card") { break }
            if line.hasPrefix("Title: ") { title = String(line.dropFirst(7)) }
            else if line.hasPrefix("Assignee: ") { assignee = String(line.dropFirst(10)).trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) }
            else if line.hasPrefix("Board: ") { board = String(line.dropFirst(7)) }
            else if line.hasPrefix("Result: ") { result = String(line.dropFirst(8)) }
            else if line.hasPrefix("Review feedback: ") { feedback = String(line.dropFirst(17)) }
        }
        self.title = title
        self.assignee = assignee
        self.board = board
        self.result = result
        reviewFeedback = feedback
    }

    /// The first status wins when Hermes joins several ("completed, blocked; needs attention").
    static func status(_ text: String) -> Status {
        let first = text.components(separatedBy: ", ").first ?? text
        if first.hasPrefix("completed") { return .done }
        if first.hasPrefix("handed off for review") { return .review }
        if first.hasPrefix("review requested changes") { return .changesRequested }
        if first.hasPrefix("blocked") || first.hasPrefix("routed to triage") { return .blocked }
        if first.hasPrefix("crashed") || first.hasPrefix("timed out") { return .retrying }
        if first.hasPrefix("gave up") { return .failed }
        return .other
    }
}

/// A `kanban_*` tool call in words ("Created card “Cut the promo” for @video-editor").
public struct KanbanAction: Sendable, Equatable {
    public var symbol: String
    public var title: String
    public var detail: String

    public init?(_ tool: ToolActivity) {
        guard tool.name.hasPrefix("kanban_") else { return nil }
        let args = (try? JSON(text: tool.arguments)) ?? .null
        let result = (try? JSON(text: tool.result)) ?? .null
        let card = args["task_id"].nonEmptyString ?? result["task_id"].nonEmptyString
        let named = args["title"].nonEmptyString.map { "“\($0)”" }
        let assignee = args["assignee"].nonEmptyString.map { " for @\($0)" } ?? ""
        switch tool.name {
        case "kanban_create": (symbol, title) = ("plus.rectangle.on.rectangle", "Created card \(named ?? card ?? "")\(assignee)")
        case "kanban_complete": (symbol, title) = ("checkmark.rectangle", "Completed card")
        case "kanban_block": (symbol, title) = ("pause.rectangle", "Blocked card")
        case "kanban_unblock": (symbol, title) = ("play.rectangle", "Unblocked card")
        case "kanban_request_review": (symbol, title) = ("eye", "Asked for a review")
        case "kanban_request_changes": (symbol, title) = ("arrow.uturn.backward.square", "Requested changes")
        case "kanban_comment": (symbol, title) = ("text.bubble", "Commented on card")
        case "kanban_link": (symbol, title) = ("link", "Linked cards")
        case "kanban_show": (symbol, title) = ("rectangle.portrait", "Looked at card")
        case "kanban_list": (symbol, title) = ("rectangle.split.3x1", "Checked the board")
        case "kanban_heartbeat": (symbol, title) = ("waveform.path.ecg", "Still working")
        case "kanban_attach", "kanban_attach_url": (symbol, title) = ("paperclip", "Attached to card")
        case "kanban_attachments": (symbol, title) = ("paperclip", "Looked at attachments")
        default: (symbol, title) = ("rectangle.on.rectangle", tool.name.replacingOccurrences(of: "_", with: " "))
        }
        detail = tool.name == "kanban_create" ? (result["task_id"].string ?? "") : (card ?? "")
    }
}

/// The brief Hermes's kanban dispatcher opens a card's chat with (hermes_cli/kanban_db_context.py):
/// optional preloaded skills, then "# Kanban task t_…: title", the card's fields and sections, and
/// last "work kanban task t_…" (gateway/session_kanban.py). Live, only that last line arrives.
public struct KanbanBrief: Sendable, Equatable {
    public var taskID: String
    public var title: String
    /// "Assignee", "Workspace", "Max runtime" … in the order Hermes wrote them.
    public var fields: [Field]
    /// The card's sections (## Body, ## Attachments, ## Prior attempts …) as Markdown.
    public var details: String

    public struct Field: Sendable, Equatable {
        public var name: String
        public var value: String
    }

    static var work: Regex<(Substring, Substring)> { /(?m)^work kanban task (\S+)\s*\z/ }
    static var header: Regex<(Substring, Substring, Substring)> { /(?m)^# Kanban task (\S+): (.+)$/ }

    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let w = trimmed.firstMatch(of: Self.work) else { return nil }
        taskID = String(w.1)
        guard let h = trimmed.firstMatch(of: Self.header) else {
            guard trimmed == String(w.0) else { return nil }
            title = ""; fields = []; details = ""
            return
        }
        title = String(h.2)
        let rest = trimmed[h.range.upperBound..<w.range.lowerBound]
        var fields: [Field] = []
        var detailLines: [Substring] = []
        var inDetails = false
        for line in rest.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") { inDetails = true }
            if inDetails { detailLines.append(line); continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { fields.append(Field(name: String(line[..<colon]), value: value)) }
        }
        self.fields = fields
        details = detailLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func field(_ name: String) -> String? { fields.first { $0.name == name }?.value }
}
