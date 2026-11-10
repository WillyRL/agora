import Foundation

/// A card on Hermes's kanban board, as Agora shows it: what it is, where it stands and what was said
/// on it. Agora answers a card but doesn't run the board (docs/adr/0002).
public struct KanbanCard: Sendable, Equatable {
    public var id: String
    /// The board's slug, so later calls reach the same card.
    public var board: String?
    public var title: String
    /// triage, todo, scheduled, ready, running, blocked, review, done or archived.
    public var status: String
    public var assignee: String?
    public var body: String?
    /// The worker's latest hand-off note.
    public var summary: String?
    public var result: String?
    /// Why the card is blocked, when it is.
    public var blockReason: String?
    public var comments: [Comment]

    public struct Comment: Sendable, Equatable, Identifiable {
        public var id: Int
        public var author: String
        public var body: String
        public var date: Date?
    }

    public var isBlocked: Bool { status == "blocked" || status == "scheduled" }
    public var isWaitingForReview: Bool { status == "review" }
    public var isFinished: Bool { status == "done" || status == "archived" }

    init?(_ reply: JSON, board: String?) {
        let t = reply["task"]
        guard let id = t["id"].string else { return nil }
        self.id = id
        self.board = board
        title = t["title"].string ?? ""
        status = t["status"].string ?? "todo"
        assignee = t["assignee"].nonEmptyString
        body = t["body"].nonEmptyString
        summary = t["latest_summary"].nonEmptyString
        result = t["result"].nonEmptyString
        let blocked = (reply["events"].array ?? []).last { $0["kind"].string == "blocked" }
        blockReason = blocked?["payload"]["reason"].nonEmptyString
        comments = (reply["comments"].array ?? []).compactMap { c -> Comment? in
            guard let body = c["body"].nonEmptyString else { return nil }
            return Comment(
                id: c["id"].int ?? 0, author: c["author"].string ?? "", body: body,
                date: c["created_at"].double.map { Date(timeIntervalSince1970: $0) })
        }
    }
}

/// Who Agora signs your comments as. Workers see it as "comment from worker `you`".
let kanbanCommentAuthor = "you (Agora)"

extension AgoraCore {
    static let kanbanAPI = "/api/plugins/kanban"

    /// A card by id. `board` is a hint (a `[kanban]` update names it); the card may be on any board,
    /// so Agora tries the hint, then the current board, then the others.
    public func kanbanCard(_ id: String, bot: String, board hint: String? = nil) async throws -> KanbanCard {
        guard let connection else { throw HermesError.notConnected }
        let path = "\(Self.kanbanAPI)/tasks/\(id)"
        func fetch(_ board: String?) async throws -> KanbanCard? {
            do {
                let reply = try await connection.rest("GET", path, profile: bot, query: board.map { ["board": $0] } ?? [:])
                return KanbanCard(reply, board: board)
            } catch HermesError.http(status: 404, _) {
                return nil
            }
        }
        var tried: Set<String> = []
        for board in [hint?.lowercased(), nil] where tried.insert(board ?? "").inserted {
            if let board, board.isEmpty { continue }
            if let card = try await fetch(board) { return card }
        }
        let boards = (try? await connection.rest("GET", "\(Self.kanbanAPI)/boards", profile: bot)) ?? [:]
        for slug in (boards["boards"].array ?? []).compactMap({ $0["slug"].string }) where tried.insert(slug).inserted {
            if let card = try await fetch(slug) { return card }
        }
        throw HermesError.configuration("Hermes has no kanban card \(id). Its kanban plugin may be turned off.")
    }

    /// Adds a comment to the card. The worker reads it the next time it looks at the card.
    public func commentOnKanbanCard(_ card: KanbanCard, bot: String, text: String) async throws -> KanbanCard {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return card }
        try await kanbanWrite(card, bot: bot, "POST", "/comments", ["body": .string(body), "author": .string(kanbanCommentAuthor)])
        return try await kanbanCard(card.id, bot: bot, board: card.board)
    }

    /// Sends a blocked card back to work (the board's Unblock).
    public func unblockKanbanCard(_ card: KanbanCard, bot: String) async throws -> KanbanCard {
        try await kanbanWrite(card, bot: bot, "PATCH", "", ["status": "ready"])
        return try await kanbanCard(card.id, bot: bot, board: card.board)
    }

    /// Accepts a card waiting for review: it moves to done.
    public func approveKanbanCard(_ card: KanbanCard, bot: String) async throws -> KanbanCard {
        try await kanbanWrite(card, bot: bot, "PATCH", "", ["status": "done", "summary": "Approved in Agora"])
        return try await kanbanCard(card.id, bot: bot, board: card.board)
    }

    private func kanbanWrite(_ card: KanbanCard, bot: String, _ method: String, _ suffix: String, _ body: JSON) async throws {
        guard let connection else { throw HermesError.notConnected }
        _ = try await connection.rest(
            method, "\(Self.kanbanAPI)/tasks/\(card.id)\(suffix)", profile: bot,
            query: card.board.map { ["board": $0] } ?? [:], body: body)
    }
}
