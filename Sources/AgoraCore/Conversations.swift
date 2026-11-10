import Foundation
import UniformTypeIdentifiers

/// A file to send with a message, as bytes (never a local file path, so it works for Remote
/// Connections too). Images go to the Bot as images; anything else (PDF, CSV, spreadsheets…) is
/// stored in the chat's workspace on the Hermes host, where the Bot can read it.
public struct ImageAttachment: Sendable, Equatable {
    public var data: Data
    public var filename: String
    public init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }

    /// Hermes takes PNG, JPEG, GIF and WebP as images; everything else goes as a file.
    public var isImage: Bool {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) || b.starts(with: [0xFF, 0xD8, 0xFF]) || b.starts(with: [0x47, 0x49, 0x46]) { return true }
        return b.count >= 12 && b[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50])
    }

    /// The largest file Agora sends (Hermes refuses bigger messages over the connection).
    public static let maxBytes = 50 * 1024 * 1024
}

extension AgoraCore {
    /// Hermes keys bot-to-bot messaging on this exact title. Agora creates Bot Chats with it and never renames them.
    public static let botChatTitle = "Bot Chat"

    // MARK: Opening

    /// Opens the Bot's Bot Chat, creating it if the Bot has none yet.
    @discardableResult
    public func openBotChat(for botName: String) async throws -> Conversation {
        let connection = try requireConnection()
        if let id = botChatIDs[botName], let open = conversations[id] {
            if open.needsHistory {
                try await loadNewestHistory(open)
                open.needsHistory = false
            }
            return open
        }
        let list = try await connection.call(
            "session.list", ["profile": .string(botName), "title": .string(Self.botChatTitle), "include_hidden": true, "limit": 200])
        // Only a session titled exactly "Bot Chat" is the Bot Chat (an older Hermes may ignore the title filter).
        let row = (list["sessions"].array ?? []).first { $0["title"].string == Self.botChatTitle || $0["root_title"].string == Self.botChatTitle }
        let snapshot: JSON
        if let row, let sid = row["resolved_id"].nonEmptyString ?? row["session_id"].string {
            snapshot = try await connection.call("session.resume", ["profile": .string(botName), "session_id": .string(sid), "omit_messages": true])
        } else if bot(named: botName)?.botChatID != nil {
            // Hermes says a Bot Chat exists but the lookup came back empty: creating one now would fork it.
            throw HermesError.protocolViolation("Couldn't find \(bot(named: botName)?.title ?? botName)'s Bot Chat. Try again.")
        } else {
            snapshot = try await connection.call(
                "session.create",
                sessionCreateParams(["source": "gui", "profile": .string(botName), "title": .string(Self.botChatTitle), "hidden": true]))
        }
        let conversation = try await adopt(snapshot: snapshot, bot: botName, title: Self.botChatTitle)
        botChatIDs[botName] = conversation.sessionID
        return conversation
    }

    static let reloadCommands: Set<String> = ["/reload-mcp", "/reload_mcp", "/mcp-reload", "/mcp_reload", "/reload-mcp now"]

    /// Reloads a chat's MCP tools and says how it went.
    public func reloadToolsNow(_ c: Conversation) async {
        do {
            let note = try await reloadTools(c)
            notice = note ?? (c.isRunning ? "MCP tools will reload when this reply finishes." : "Reloaded MCP tools for this chat.")
        } catch {
            if !isCancellation(error) { notice = "Couldn't reload MCP tools: \(error.localizedDescription)" }
        }
    }

    /// `session.create` params with a fresh retry key.
    func sessionCreateParams(_ params: [String: JSON]) -> JSON {
        var p = params
        p["request_id"] = .string(UUID().uuidString)  // `hermes serve` calls it idempotency_key (LegacyDialect)
        return .object(p)
    }

    /// Opens any session of a Bot (a Side Chat) by id.
    @discardableResult
    public func openConversation(bot botName: String, sessionID: String, title: String) async throws -> Conversation {
        if let open = conversation(sessionID) { return open }
        if sideChats[botName]?.first(where: { $0.id == sessionID })?.isKanbanTask == true {
            return try await openKanbanTask(bot: botName, sessionID: sessionID, title: title)
        }
        let connection = try requireConnection()
        let snapshot: JSON
        do {
            snapshot = try await connection.call("session.resume", ["profile": .string(botName), "session_id": .string(sessionID), "omit_messages": true])
        } catch let error as HermesError where error.localizedDescription.localizedCaseInsensitiveContains("kanban worker") {
            // Hermes refuses to resume a kanban worker's chat (only the board may run it). Read it instead.
            return try await openKanbanTask(bot: botName, sessionID: sessionID, title: title)
        }
        return try await adopt(snapshot: snapshot, bot: botName, title: title)
    }

    /// A kanban card's worker chat, read from Hermes's session store without resuming it:
    /// resuming would start a second writer the board can't see.
    func openKanbanTask(bot botName: String, sessionID: String, title: String) async throws -> Conversation {
        let conversation = Conversation(bot: botName, sessionID: sessionID, title: title)
        conversation.isKanbanTask = true
        try await loadNewestHistory(conversation)
        conversations[sessionID] = conversation
        return conversation
    }

    /// Reads a kanban task's chat again: Agora doesn't follow it live.
    public func reloadKanbanTask(_ c: Conversation) async {
        guard c.isKanbanTask else { return }
        do {
            try await loadNewestHistory(c)
        } catch {
            if !isCancellation(error) { notice = "Couldn't reload the task's chat: \(error.localizedDescription)" }
        }
    }

    /// An open conversation by its live or saved session id.
    public func conversation(_ id: String) -> Conversation? {
        conversations[id] ?? conversations.values.first { $0.storedSessionID == id || $0.id == id }
    }

    /// Registers a session snapshot (from create or resume) and loads its newest history.
    func adopt(snapshot: JSON, bot botName: String, title: String, loadHistory: Bool = true) async throws -> Conversation {
        let connection = try requireConnection()
        guard let sid = snapshot["session_id"].string else { throw HermesError.protocolViolation("session snapshot without session_id") }
        let conversation = conversations[sid] ?? Conversation(bot: botName, sessionID: sid, title: title)
        conversation.apply(snapshot: snapshot)
        conversations[sid] = conversation
        await connection.track(session: sid, profile: botName)
        await connection.setCursor(session: sid, lastSequence: snapshot["last_sequence"].int, epoch: snapshot["replay_epoch"].string)
        applyPrompts(from: snapshot, to: conversation)
        if (snapshot["message_count"].int ?? 1) > 0 {
            if loadHistory { try await loadNewestHistory(conversation) } else { conversation.needsHistory = true }
        }
        return conversation
    }

    // MARK: History

    func historyPage(_ c: Conversation, offset: Int) async throws -> [JSON] {
        let connection = try requireConnection()
        let r = try await connection.rest(
            "GET", "/api/sessions/\(c.storedSessionID)/messages", profile: c.bot,
            query: ["limit": "\(historyPageSize)", "order": "latest", "offset": "\(offset)", "include_compacted": "true"])
        return r["messages"].array ?? []
    }

    func loadNewestHistory(_ c: Conversation) async throws {
        c.loadingHistory = true
        defer { c.loadingHistory = false }
        c.setHistory(rows: try await historyPage(c, offset: 0), pageSize: historyPageSize)
    }

    /// Loads the next page of older messages.
    public func loadOlderHistory(_ c: Conversation) async {
        guard c.hasMoreHistory, !c.loadingHistory else { return }
        c.loadingHistory = true
        defer { c.loadingHistory = false }
        do {
            c.prependHistory(rows: try await historyPage(c, offset: c.historyOffset), pageSize: historyPageSize)
        } catch {
            if !isCancellation(error) { notice = error.localizedDescription }
        }
    }

    // MARK: Sending

    /// Sends a message. While the Bot is still working this steers the current task instead.
    /// Returns false (and sets `notice`) if the message couldn't be sent.
    @discardableResult
    public func send(_ text: String, images: [ImageAttachment] = [], to c: Conversation) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, let connection else { return false }
        // Hermes's own `/reload-mcp` (and the way people misremember it) runs here instead of reaching the Bot.
        if images.isEmpty, Self.reloadCommands.contains(trimmed.lowercased()) {
            await reloadToolsNow(c)
            return true
        }
        if c.isRunning, images.isEmpty, features.steer, await steer(trimmed, in: c) { return true }
        let submission = UUID().uuidString
        let localID = "local-\(submission)"
        if let big = images.first(where: { $0.data.count > ImageAttachment.maxBytes }) {
            notice = "\(big.filename) is too big to send (the limit is \(ImageAttachment.maxBytes / 1_048_576) MB)."
            return false
        }
        c.items.append(
            ChatItem(
                id: localID, kind: .user, text: trimmed,
                images: images.filter(\.isImage).map { .data($0.data, mime: Self.mime(for: $0.data)) },
                files: images.filter { !$0.isImage }.map(\.filename), date: Date(), pending: true))
        do {
            let staged: [String]
            do {
                staged = try await submit(trimmed, images: images, submission: submission, to: c, over: connection)
            } catch let e as HermesError where e.isSessionGone {
                // Hermes unloaded this chat while it sat idle: open it again and send once more.
                try await reopen(c)
                staged = try await submit(trimmed, images: images, submission: submission, to: c, over: connection)
            }
            if let i = c.items.firstIndex(where: { $0.id == localID }) {
                c.items[i].pending = false
                if !staged.isEmpty { c.items[i].files = staged }
            }
            c.isRunning = true
            c.awaitingOwnReply = true
            lastUsedBot = c.bot
            return true
        } catch {
            if let i = c.items.firstIndex(where: { $0.id == localID }) {
                c.items[i].pending = false
                c.items[i].failed = true
            }
            if !images.isEmpty { unsentAttachments[localID] = images }
            notice = "Couldn't send: \(error.localizedDescription)"
            return false
        }
    }

    /// Sends a message that didn't go through again, in its place.
    public func resend(_ item: ChatItem, in c: Conversation) async {
        guard item.failed, let i = c.items.firstIndex(where: { $0.id == item.id }) else { return }
        c.items.remove(at: i)
        let images = unsentAttachments.removeValue(forKey: item.id) ?? item.images.compactMap { image -> ImageAttachment? in
            guard case .data(let data, let mime) = image else { return nil }
            return ImageAttachment(data: data, filename: "image." + (mime.split(separator: "/").last.map(String.init) ?? "png"))
        }
        await send(item.text, images: images, to: c)
    }

    /// One `prompt.submit`, uploading attachments first: images go with the prompt, other files are
    /// stored in the chat's workspace and named at the top of the message as `@file:` refs (as
    /// Hermes's own app does). Returns the stored files' paths. The same `submission` id makes a retry safe.
    private func submit(_ trimmed: String, images: [ImageAttachment], submission: String, to c: Conversation, over connection: HermesConnection) async throws -> [String] {
        var refs: [String] = []
        var staged: [String] = []
        var attachments: [JSON] = []
        for file in images {
            if file.isImage {
                let r = try await connection.call(
                    "image.attach_bytes",
                    [
                        "session_id": .string(c.sessionID), "profile": .string(c.bot), "content_base64": .string(file.data.base64EncodedString()),
                        "filename": .string(file.filename),
                    ])
                guard let path = r["path"].string else { throw HermesError.protocolViolation("image upload returned no path") }
                attachments.append(["path": .string(path), "mime": .string(r["mime"].string ?? Self.mime(for: file.data))])
            } else {
                let r = try await connection.call(
                    "file.attach",
                    [
                        "session_id": .string(c.sessionID), "profile": .string(c.bot), "name": .string(file.filename),
                        "data_url": .string("data:\(Self.fileMime(file.filename));base64,\(file.data.base64EncodedString())"),
                    ])
                guard let ref = r["ref_text"].nonEmptyString else { throw HermesError.protocolViolation("file upload returned no reference") }
                refs.append(ref)
                staged.append(r["path"].nonEmptyString ?? r["ref_path"].string ?? file.filename)
            }
        }
        let text = (refs + [trimmed]).filter { !$0.isEmpty }.joined(separator: refs.isEmpty ? "" : "\n\n")
        var params: [String: JSON] = [
            "session_id": .string(c.sessionID), "profile": .string(c.bot), "text": .string(text), "submission_id": .string(submission),
        ]
        if !attachments.isEmpty { params["attachments"] = .array(attachments) }
        _ = try await connection.call("prompt.submit", .object(params))
        return staged
    }

    static func fileMime(_ name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Steers the running turn. Returns false if nothing was running, so the text should be sent as a new message.
    func steer(_ text: String, in c: Conversation) async -> Bool {
        guard let connection else { return false }
        do {
            let r = try await connection.call(
                "session.steer",
                ["session_id": .string(c.sessionID), "profile": .string(c.bot), "text": .string(text), "execution_generation": .number(Double(c.generation))])
            if r["status"].string == "rejected", r["delivered"].bool == false { return false }
            c.items.append(ChatItem(id: "steer-\(UUID().uuidString)", kind: .user, text: text, date: Date()))
            return true
        } catch let e as HermesError where e.isMethodNotFound {
            features.steer = false
            return false
        } catch let e as HermesError where ["stale_generation", "session_idle", "steer_unavailable"].contains(e.rpcReason ?? "") {
            return false
        } catch {
            if !isCancellation(error) { notice = "Couldn't steer: \(error.localizedDescription)" }
            return true
        }
    }

    static func mime(for data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if b.count >= 12, b[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
        return "image/png"
    }

    // MARK: Events

    func route(event: GatewayEvent) {
        if handleSideAnswer(event) { return }
        guard let sid = event.sessionID, let c = conversations[sid] else { return }
        if event.type == "session.replay_gap" {
            Task { await self.refresh(c) }
            return
        }
        if handlePromptEvent(event, in: c) { return }
        let oldTitle = c.title
        c.apply(event: event)
        if c.title != oldTitle { sideChatsDidChange(bot: c.bot) }
        conversationDidChange(c, event: event)
    }

    /// Re-reads a conversation after a reconnect or a replay gap.
    public func refresh(_ c: Conversation) async {
        do {
            try await reopen(c)
        } catch {
            if !isCancellation(error) { notice = error.localizedDescription }
        }
    }

    /// Resumes a conversation by its saved id and reloads its newest history. Hermes hands back the
    /// live session if it still holds one, or starts a new one (with a new live id) if it unloaded it.
    func reopen(_ c: Conversation) async throws {
        if c.isKanbanTask { return try await loadNewestHistory(c) }
        let connection = try requireConnection()
        let snapshot = try await connection.call(
            "session.resume", ["profile": .string(c.bot), "session_id": .string(c.storedSessionID), "omit_messages": true])
        if let sid = snapshot["session_id"].string, sid != c.sessionID {
            let old = c.sessionID
            await connection.untrack(session: old)
            conversations[old] = nil
            c.sessionID = sid
            conversations[sid] = c
            if botChatIDs[c.bot] == old { botChatIDs[c.bot] = sid }
            await connection.track(session: sid, profile: c.bot)
        }
        c.apply(snapshot: snapshot)
        await connection.setCursor(session: c.sessionID, lastSequence: snapshot["last_sequence"].int, epoch: snapshot["replay_epoch"].string)
        applyPrompts(from: snapshot, to: c)
        try await loadNewestHistory(c)
        c.needsHistory = false
    }
}

extension AgoraCore {
    // MARK: Session changes (session.mutate, revision-checked)

    /// Renames a Side Chat. A Bot Chat keeps its title: Hermes finds it by that exact title.
    public func rename(_ c: Conversation, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isBotChat, !trimmed.isEmpty, trimmed != AgoraCore.botChatTitle else { return }
        do {
            let r = try await mutate(c, operation: "rename", payload: ["title": .string(trimmed)])
            c.title = r["title"].string ?? trimmed
            sideChatsDidChange(bot: c.bot)
        } catch {
            if !isCancellation(error) { notice = "Couldn't rename: \(error.localizedDescription)" }
        }
    }

    /// Runs `session.mutate`, retrying once with the fresh revision if someone else changed the session first.
    @discardableResult
    func mutate(_ c: Conversation, operation: String, payload: JSON, needsGeneration: Bool = false) async throws -> JSON {
        let connection = try requireConnection()
        let requestID = UUID().uuidString
        for attempt in 0..<2 {
            var params: [String: JSON] = [
                "session_id": .string(c.sessionID), "profile": .string(c.bot), "request_id": .string(requestID),
                "expected_revision": .number(Double(c.revision)), "operation": .string(operation), "payload": payload,
            ]
            if needsGeneration { params["expected_generation"] = .number(Double(c.generation)) }
            do {
                let r = try await connection.call("session.mutate", .object(params))
                if let rev = r["revision"].int { c.revision = rev }
                return r
            } catch let e as HermesError where attempt == 0 && ["revision_conflict", "stale_generation"].contains(e.rpcReason ?? "") {
                if case .rpc(_, _, _, let data) = e {
                    if let rev = data["revision"].int { c.revision = rev }
                    if let gen = data["execution_generation"].int { c.generation = gen }
                }
                continue
            }
        }
        throw HermesError.protocolViolation("session changed twice while saving")
    }
}
