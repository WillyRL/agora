import Foundation

extension AgoraCore {
    /// Server requests Agora answers itself. Everything else gets -32601 so the Bot fails fast.
    static let supportedServerRequests: Set<String> = ["approval", "clarify", "secret", "sudo"]

    // MARK: Incoming

    func applyPrompts(from snapshot: JSON, to c: Conversation) {
        let fromSnapshot = (snapshot["prompts"].array ?? []).compactMap { prompt(fromEvent: $0, bot: c.bot, session: c.sessionID) }
        let serverRequests = c.prompts.filter(\.isServerRequest)
        c.prompts = fromSnapshot + serverRequests.filter { r in !fromSnapshot.contains { $0.id == r.id } }
        promptsDidChange(c)
    }

    /// Approval/clarify events, their settlement, and withdrawn server requests.
    func handlePromptEvent(_ e: GatewayEvent, in c: Conversation) -> Bool {
        switch e.type {
        case "approval.request", "clarify.request":
            guard let p = prompt(fromEvent: e.payload, bot: c.bot, session: c.sessionID) else { return true }
            if !c.prompts.contains(where: { $0.id == p.id }) {
                c.prompts.append(p)
                promptsDidChange(c, added: p)
            }
            return true
        case "approval.settled", "clarify.settled":
            removePrompt(id: e.payload["prompt_id"].string, from: c)
            return true
        case "request.cancel":
            removePrompt(id: e.payload["id"].string, from: c)
            return true
        default:
            return false
        }
    }

    func prompt(fromEvent p: JSON, bot: String, session: String) -> PendingPrompt? {
        guard let id = p["prompt_id"].string else { return nil }
        let generation = p["execution_generation"].int ?? 0
        switch p["kind"].string {
        case "approval":
            let kind = PendingPrompt.Kind.approval(
                command: p["command"].string ?? "", description: p["description"].string ?? "",
                choices: p["choices"].array?.compactMap(\.string) ?? ["once", "deny"])
            return PendingPrompt(id: id, bot: bot, sessionID: session, kind: kind, isServerRequest: false, generation: generation)
        case "clarify":
            let kind = PendingPrompt.Kind.clarify(
                question: p["question"].string ?? "", choices: p["choices"].array?.compactMap(\.string) ?? [],
                multiSelect: p["multi_select"].bool ?? false)
            return PendingPrompt(id: id, bot: bot, sessionID: session, kind: kind, isServerRequest: false, generation: generation)
        default:
            return nil
        }
    }

    func handle(request r: ServerRequest) async {
        guard Self.supportedServerRequests.contains(r.method) else {
            await connection?.respondError(to: r.id)
            return
        }
        let sid = r.params["session_id"].string ?? ""
        guard let c = conversations[sid] else {
            // A session Agora hasn't opened (e.g. a Side Chat in the background): open it so the card can show.
            if let bot = await botOwning(session: sid), let c = try? await openConversation(bot: bot, sessionID: sid, title: "") {
                add(request: r, to: c)
            } else {
                await connection?.respondError(to: r.id, code: -32603, message: "Agora has no window for this session")
            }
            return
        }
        add(request: r, to: c)
    }

    private func add(request r: ServerRequest, to c: Conversation) {
        let p = r.params
        let kind: PendingPrompt.Kind
        switch r.method {
        case "secret":
            kind = .secret(prompt: p["prompt"].string ?? "Enter a secret", envVar: p["env_var"].string ?? "")
        case "sudo":
            kind = .sudo(command: p["command"].string ?? "")
        case "approval":
            kind = .approval(
                command: p["command"].string ?? "", description: p["description"].string ?? "",
                choices: p["choices"].array?.compactMap(\.string) ?? ["once", "session", "always", "deny"])
        case "clarify":
            let questions = (p["questions"].array ?? []).map {
                PendingPrompt.Question(
                    id: $0["qid"].string ?? $0["id"].string ?? UUID().uuidString, question: $0["question"].string ?? "",
                    choices: $0["choices"].array?.compactMap(\.string) ?? [], multiSelect: $0["multi_select"].bool ?? false)
            }
            if questions.isEmpty, let q = p["question"].string {
                kind = .clarify(question: q, choices: p["choices"].array?.compactMap(\.string) ?? [], multiSelect: false)
            } else {
                kind = .clarifyBatch(questions: questions)
            }
        default:
            return
        }
        guard !c.prompts.contains(where: { $0.id == r.id }) else { return }
        let prompt = PendingPrompt(id: r.id, bot: c.bot, sessionID: c.sessionID, kind: kind, isServerRequest: true, generation: c.generation)
        c.prompts.append(prompt)
        promptsDidChange(c, added: prompt)
    }

    private func removePrompt(id: String?, from c: Conversation) {
        guard let id, let i = c.prompts.firstIndex(where: { $0.id == id }) else { return }
        c.prompts.remove(at: i)
        env.notifier.remove(id: id)
        promptsDidChange(c)
    }

    // MARK: Answering

    /// Answers an approval: `once`, `session`, `always` or `deny`.
    public func answer(_ p: PendingPrompt, choice: String) async {
        guard let connection, let c = conversations[p.sessionID] else { return }
        removePrompt(id: p.id, from: c)
        if p.isServerRequest {
            await connection.respond(to: p.id, result: ["choice": .string(choice)])
            return
        }
        do {
            _ = try await connection.call(
                "approval.respond",
                [
                    "session_id": .string(p.sessionID), "profile": .string(p.bot), "execution_generation": .number(Double(p.generation)),
                    "prompt_id": .string(p.id), "choice": .string(choice),
                ], timeout: .seconds(300))
        } catch {
            if !isCancellation(error) { notice = "Couldn't send your answer: \(error.localizedDescription)" }
        }
    }

    /// Answers a clarifying question, a secret or a sudo password. Secret values go straight to Hermes;
    /// Agora never shows, logs or stores them.
    public func answer(_ p: PendingPrompt, text: String) async {
        guard let connection, let c = conversations[p.sessionID] else { return }
        removePrompt(id: p.id, from: c)
        switch p.kind {
        case .secret, .sudo:
            await connection.respond(to: p.id, result: ["value": .string(text)])
        case .clarify:
            if p.isServerRequest {
                await connection.respond(to: p.id, result: ["answers": ["answer": .string(text)]])
                return
            }
            do {
                _ = try await connection.call(
                    "clarify.respond",
                    [
                        "session_id": .string(p.sessionID), "profile": .string(p.bot), "execution_generation": .number(Double(p.generation)),
                        "prompt_id": .string(p.id), "answer": .string(text),
                    ])
            } catch {
                if !isCancellation(error) { notice = "Couldn't send your answer: \(error.localizedDescription)" }
            }
        case .clarifyBatch(let questions):
            var answers: [String: JSON] = [:]
            for q in questions { answers[q.id] = .string(text) }
            await connection.respond(to: p.id, result: ["answers": .object(answers)])
        case .approval:
            await answer(p, choice: text)
        }
    }

    /// Answers several questions at once (batch clarify). A `nil` answer skips that question.
    public func answer(_ p: PendingPrompt, answers: [String: String?]) async {
        guard let connection, let c = conversations[p.sessionID] else { return }
        removePrompt(id: p.id, from: c)
        var out: [String: JSON] = [:]
        for (k, v) in answers { out[k] = v.map(JSON.string) ?? .null }
        await connection.respond(to: p.id, result: ["answers": .object(out), "outcome": "submitted"])
    }

    /// Declines a prompt without answering.
    public func dismiss(_ p: PendingPrompt) async {
        switch p.kind {
        case .approval: await answer(p, choice: "deny")
        case .clarifyBatch:
            guard let connection, let c = conversations[p.sessionID] else { return }
            removePrompt(id: p.id, from: c)
            await connection.respond(to: p.id, result: [:])
        default: await answer(p, text: "")
        }
    }

    /// Finds which Bot a session belongs to (for prompts from sessions Agora hasn't opened).
    func botOwning(session sid: String) async -> String? {
        if let c = conversations[sid] { return c.bot }
        if let hit = sideChats.values.joined().first(where: { $0.id == sid }) { return hit.bot }
        // Not in any loaded list: look through each Bot's Side Chats.
        for bot in bots where sideChats[bot.name] == nil {
            await loadSideChats(for: bot.name)
            if sideChats[bot.name]?.contains(where: { $0.id == sid }) == true { return bot.name }
        }
        return nil
    }

    /// Every prompt waiting on you, across open conversations.
    public var pendingPrompts: [PendingPrompt] {
        conversations.values.flatMap(\.prompts)
    }
}
