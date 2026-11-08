import Foundation

extension AgoraCore {
    /// Who a Quick Ask question goes to: `@name` at the start picks a Bot, otherwise the Bot you used
    /// most recently. Returns the Bot and the question without the `@name`.
    public func quickAskTarget(for text: String) -> (bot: Bot?, question: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") {
            let word = trimmed.dropFirst().prefix { !$0.isWhitespace }
            let rest = trimmed.dropFirst(word.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            if let bot = matchBot(String(word)) { return (bot, rest) }
        }
        return (defaultQuickAskBot, trimmed)
    }

    /// The Bot Quick Ask uses when you don't name one.
    public var defaultQuickAskBot: Bot? {
        if let name = lastUsedBot, let bot = bots.first(where: { $0.name == name }) { return bot }
        return bots.first
    }

    /// Bots whose name or title starts with `prefix` (for `@` completion).
    public func botsMatching(_ prefix: String) -> [Bot] {
        let p = Self.handle(prefix)
        return bots.filter { Self.handle($0.name).hasPrefix(p) || Self.handle($0.title).hasPrefix(p) }
    }

    func matchBot(_ word: String) -> Bot? {
        let w = Self.handle(word)
        guard !w.isEmpty else { return nil }
        return bots.first { Self.handle($0.name) == w || Self.handle($0.title) == w }
            ?? bots.first { Self.handle($0.name).hasPrefix(w) || Self.handle($0.title).hasPrefix(w) }
    }

    static func handle(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Asks a Bot from Quick Ask. The exchange happens in that Bot's Bot Chat, so it's saved there.
    @discardableResult
    public func quickAsk(_ text: String, images: [ImageAttachment] = []) async throws -> Conversation? {
        let (bot, question) = quickAskTarget(for: text)
        guard let bot, !question.isEmpty || !images.isEmpty else { return nil }
        let chat = try await openBotChat(for: bot.name)
        guard await send(question, images: images, to: chat) else {
            throw HermesError.protocolViolation(notice ?? "Couldn't send.")
        }
        return chat
    }
}
