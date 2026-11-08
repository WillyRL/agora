import Foundation

/// A Side Chat in the sidebar list.
public struct SideChatSummary: Sendable, Identifiable, Equatable {
    public var id: String
    public var bot: String
    public var title: String
    public var lastActive: Date?
    public var preview: String?
}

extension AgoraCore {
    static let handoffQuestion = """
        I'm starting a separate Side Chat with you to go deeper on something from this conversation. \
        Write a short handoff summary (at most 6 sentences) of the recent context I'd need there: \
        what we were discussing, decisions made, and open questions. Write it to yourself, plainly, no preamble.
        """

    // MARK: Listing

    /// Loads a Bot's Side Chats, newest first. Bot Chats, archived chats (including ones Hermes
    /// archived for being unused) and Routine runs are left out.
    public func loadSideChats(for bot: String) async {
        guard let connection else { return }
        do {
            let r = try await connection.rest(
                "GET", "/api/sessions", profile: bot,
                query: ["limit": "50", "archived": "exclude", "order": "recent", "exclude_sources": "cron", "min_messages": "0"])
            let rows = (r["sessions"].array ?? []).filter { row in
                let title = row["title"].string ?? ""
                if title == Self.botChatTitle { return false }
                if row["archived"].bool == true || (row["auto_archived"].int ?? 0) != 0 { return false }
                if row["hidden"].bool == true { return false }
                if row["source"].string == "cron" { return false }
                return row["id"].string != nil
            }
            sideChats[bot] = rows.map { row in
                SideChatSummary(
                    id: row["id"].string!, bot: bot, title: row["title"].nonEmptyString ?? "",
                    lastActive: (row["last_active"].double ?? row["started_at"].double).map { Date(timeIntervalSince1970: $0) },
                    preview: row["preview"].string)
            }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        } catch {
            if !isCancellation(error) { notice = "Couldn't load Side Chats: \(error.localizedDescription)" }
        }
    }

    // MARK: Creating

    /// Starts a Side Chat with a Bot. With `carryContext`, the Bot first writes a short handoff summary of
    /// its recent Bot Chat (as a side question, so the Bot Chat itself is left unchanged); the summary
    /// becomes the Side Chat's first message.
    @discardableResult
    public func newSideChat(for bot: String, carryContext: Bool = false) async throws -> Conversation {
        let connection = try requireConnection()
        var summary: String?
        if carryContext {
            summary = try await handoffSummary(for: bot)
        }
        let snapshot = try await connection.call(
            "session.create", sessionCreateParams(["source": "gui", "profile": .string(bot)]))
        let side = try await adopt(snapshot: snapshot, bot: bot, title: "")  // Hermes titles it after the first message
        var list = sideChats[bot] ?? []
        list.removeAll { side.matches($0.id) }
        list.insert(SideChatSummary(id: side.storedSessionID, bot: bot, title: side.title, lastActive: Date(), preview: nil), at: 0)
        sideChats[bot] = list
        if let summary, !summary.isEmpty {
            await send("Context carried over from our Bot Chat:\n\n\(summary)", to: side)
        }
        return side
    }

    /// Asks the Bot (over its Bot Chat's context, without adding to it) for a handoff summary.
    func handoffSummary(for bot: String) async throws -> String {
        let connection = try requireConnection()
        let chat = try await openBotChat(for: bot)
        do {
            let r = try await connection.call(
                "prompt.btw", ["session_id": .string(chat.sessionID), "profile": .string(bot), "text": .string(Self.handoffQuestion)])
            guard let task = r["task_id"].string else { throw HermesError.protocolViolation("prompt.btw returned no task") }
            let text = try await waitForSideAnswer(task: task)
            if text.hasPrefix("error:") { throw HermesError.protocolViolation(text) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let e as HermesError where e.isMethodNotFound {
            // Older Hermes: summarise the recent transcript with a one-shot completion instead.
            let transcript = chat.items.suffix(30).compactMap { item -> String? in
                switch item.kind {
                case .user: return "User: \(item.text)"
                case .assistant: return "\(bot): \(item.text)"
                case .botMessage(let from): return "\(from): \(item.text)"
                default: return nil
                }
            }.joined(separator: "\n")
            let r = try await connection.call(
                "llm.oneshot",
                ["profile": .string(bot), "session_id": .string(chat.sessionID), "instructions": .string(Self.handoffQuestion), "input": .string(transcript)])
            return (r["text"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func waitForSideAnswer(task: String) async throws -> String {
        if let ready = sideAnswers.removeValue(forKey: task) { return ready }
        return try await withCheckedThrowingContinuation { cont in
            sideAnswerWaiters[task] = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                self?.sideAnswerWaiters.removeValue(forKey: task)?.resume(throwing: HermesError.timeout("handoff summary"))
            }
        }
    }

    /// Catches side-question answers (`btw.complete`). Returns true if the event was one.
    func handleSideAnswer(_ e: GatewayEvent) -> Bool {
        guard e.type == "btw.complete", let task = e.payload["task_id"].string else { return false }
        let text = e.payload["text"].string ?? ""
        if let waiter = sideAnswerWaiters.removeValue(forKey: task) {
            waiter.resume(returning: text)
        } else {
            sideAnswers[task] = text
        }
        return true
    }

    // MARK: Housekeeping

    /// Archives a Side Chat (a Bot Chat is never archived from Agora: archiving retires it).
    public func archive(_ c: Conversation) async {
        guard !c.isBotChat else { return }
        do {
            try await mutate(c, operation: "archive", payload: ["archived": true])
            forget(c)
        } catch {
            if !isCancellation(error) { notice = "Couldn't archive: \(error.localizedDescription)" }
        }
    }

    /// Deletes a Side Chat and its messages.
    public func delete(_ c: Conversation) async {
        guard !c.isBotChat else { return }
        do {
            try await mutate(c, operation: "delete", payload: [:], needsGeneration: true)
            forget(c)
        } catch {
            if !isCancellation(error) { notice = "Couldn't delete: \(error.localizedDescription)" }
        }
    }

    /// Archives a Side Chat straight from the list (it's opened without its messages first).
    /// Returns false (and sets `notice`) if it couldn't be.
    @discardableResult
    public func archiveSideChat(_ side: SideChatSummary) async -> Bool {
        guard let c = await sideChatConversation(side) else { return false }
        await archive(c)
        return sideChats[side.bot]?.contains(where: { $0.id == side.id }) != true
    }

    /// Brings an archived Side Chat back into the list.
    public func unarchiveSideChat(_ side: SideChatSummary) async {
        guard let c = await sideChatConversation(side) else { return }
        do {
            try await mutate(c, operation: "archive", payload: ["archived": false])
            var list = sideChats[side.bot] ?? []
            if !list.contains(where: { $0.id == side.id }) { list.append(side) }
            list.sort { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
            sideChats[side.bot] = list
        } catch {
            if !isCancellation(error) { notice = "Couldn't unarchive: \(error.localizedDescription)" }
        }
    }

    /// Deletes a Side Chat straight from the list.
    public func deleteSideChat(_ side: SideChatSummary) async {
        guard let c = await sideChatConversation(side) else { return }
        await delete(c)
    }

    func sideChatConversation(_ side: SideChatSummary) async -> Conversation? {
        do {
            return try await openConversation(bot: side.bot, sessionID: side.id, title: side.title)
        } catch {
            if !isCancellation(error) { notice = "Couldn't open that Side Chat: \(error.localizedDescription)" }
            return nil
        }
    }

    func forget(_ c: Conversation) {
        sideChats[c.bot]?.removeAll { c.matches($0.id) }
        conversations[c.sessionID] = nil
        let sid = c.sessionID
        Task { await connection?.untrack(session: sid) }
    }

    func sideChatsDidChange(bot: String) {
        for c in conversations.values where c.bot == bot && !c.isBotChat {
            if let i = sideChats[bot]?.firstIndex(where: { c.matches($0.id) }), !c.title.isEmpty {
                sideChats[bot]?[i].title = c.title
            }
        }
    }
}
