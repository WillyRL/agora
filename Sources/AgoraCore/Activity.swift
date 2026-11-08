import Foundation

extension AgoraCore {
    // MARK: Watching every Bot Chat

    /// Subscribes to every visible Bot's Bot Chat (without loading history) so Routine results,
    /// messages from other Bots and approvals arrive even for chats you haven't opened.
    public func watchBotChats() async {
        guard let connection else { return }
        for bot in bots where botChatIDs[bot.name] == nil {
            do {
                let list = try await connection.call(
                    "session.list", ["profile": .string(bot.name), "title": .string(Self.botChatTitle), "include_hidden": true, "limit": 200])
                guard let row = list["sessions"].array?.first, let sid = row["resolved_id"].nonEmptyString ?? row["session_id"].string else { continue }
                let snapshot = try await connection.call("session.resume", ["profile": .string(bot.name), "session_id": .string(sid), "omit_messages": true])
                let c = try await adopt(snapshot: snapshot, bot: bot.name, title: Self.botChatTitle, loadHistory: false)
                botChatIDs[bot.name] = c.sessionID
            } catch {
                continue  // that Bot just won't show live activity until opened
            }
        }
    }

    // MARK: Unread + seen

    /// The chat on screen right now (nil when the window is closed or another view shows).
    public func setViewing(bot: String?, session: String?) {
        viewing = bot.map { ($0, session) }
        if let bot { markSeen(bot: bot) }
    }

    public func markSeen(bot: String) {
        unread.remove(bot)
        var seen = lastSeen
        seen[bot] = Date().timeIntervalSince1970
        lastSeen = seen
    }

    public func isUnread(_ bot: String) -> Bool { unread.contains(bot) }

    /// Bots with activity newer than the last time you looked (survives restarts).
    func restoreUnread() {
        let seen = lastSeen
        for bot in allBots {
            guard let active = bot.lastActive?.timeIntervalSince1970 else { continue }
            if active > (seen[bot.name] ?? 0) + 1, viewing?.bot != bot.name { unread.insert(bot.name) }
        }
    }

    var lastSeen: [String: Double] {
        get { env.store.decode([String: Double].self, "lastSeen.\(connectionKey)") ?? [:] }
        set { env.store.encode(newValue, "lastSeen.\(connectionKey)") }
    }

    var connectionKey: String { registry.activeID?.uuidString ?? "none" }

    // MARK: Mute

    public func isMuted(_ bot: String) -> Bool { mutedBots.contains(bot) }

    public func setMuted(_ bot: String, _ muted: Bool) {
        var set = mutedBots
        if muted { set.insert(bot) } else { set.remove(bot) }
        mutedBots = set
    }

    // MARK: Reacting to activity

    func conversationDidChange(_ c: Conversation, event: GatewayEvent) {
        guard event.type == "message.complete" else { return }
        let ownTurn = c.awaitingOwnReply
        c.awaitingOwnReply = false
        let text = event.payload["text"].string ?? event.payload["content"].string ?? ""
        updatePreview(bot: c.bot, text: text)
        if c.turnUsedRoutineTool {
            c.turnUsedRoutineTool = false
            Task { await loadRoutines(for: c.bot) }
        }
        let isViewing = viewing?.bot == c.bot && (viewing?.session == nil ? c.isBotChat : viewing?.session.map(c.matches) == true)
        if !(isViewing && appIsActive) { unread.insert(c.bot) }
        guard !ownTurn, c.isBotChat, !text.isEmpty else { return }
        // A turn Agora didn't start: a Routine result or another Bot's message.
        guard !(isViewing && appIsActive), !isMuted(c.bot) else { return }
        let botTitle = bot(named: c.bot)?.title ?? c.bot
        let kind: AgoraNotification.Kind = c.lastTurnFromBot != nil ? .botMessage : .routineResult
        let title = kind == .botMessage ? "\(botTitle) ← \(c.lastTurnFromBot.flatMap { bot(named: $0)?.title ?? $0 } ?? "a Bot")" : botTitle
        env.notifier.post(
            AgoraNotification(id: "msg-\(c.sessionID)-\(UUID().uuidString.prefix(8))", kind: kind, bot: c.bot, title: title, body: Self.plain(text), sessionID: c.sessionID))
    }

    func promptsDidChange(_ c: Conversation, added: PendingPrompt? = nil) {
        guard let p = added, !appIsActive else { return }
        let botTitle = bot(named: c.bot)?.title ?? c.bot
        switch p.kind {
        case .approval(let command, let description, let choices):
            env.notifier.post(
                AgoraNotification(
                    id: p.id, kind: .approval, bot: c.bot, title: "\(botTitle) wants to run something",
                    body: description.isEmpty ? command : "\(description)\n\(command)", sessionID: c.sessionID, choices: choices))
        case .clarify(let question, _, _):
            env.notifier.post(AgoraNotification(id: p.id, kind: .question, bot: c.bot, title: "\(botTitle) has a question", body: question, sessionID: c.sessionID))
        case .clarifyBatch, .secret, .sudo:
            env.notifier.post(
                AgoraNotification(id: p.id, kind: .question, bot: c.bot, title: "\(botTitle) needs your input", body: "Open Agora to answer.", sessionID: c.sessionID))
        }
    }

    /// A button on an approval notification was pressed.
    public func answerFromNotification(promptID: String, choice: String) async {
        guard let p = pendingPrompts.first(where: { $0.id == promptID }) else { return }
        await answer(p, choice: choice)
    }

    func updatePreview(bot name: String, text: String) {
        guard !text.isEmpty else { return }
        let preview = Self.plain(text)
        for list in [\AgoraCore.allBots, \AgoraCore.bots] {
            if let i = self[keyPath: list].firstIndex(where: { $0.name == name }) {
                self[keyPath: list][i].lastPreview = preview
                self[keyPath: list][i].lastActive = Date()
            }
        }
    }

    /// One line of plain text for previews and notifications.
    static func plain(_ markdown: String) -> String { plainText(markdown) }
}
