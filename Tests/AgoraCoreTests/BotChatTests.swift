import Foundation
import Testing

@testable import AgoraCore

@MainActor
struct BotChatTests {
    @Test func openingABotWithoutABotChatCreatesOneTitledBotChat() async throws {
        let fake = try FakeHermes(named: "botchat-create")
        let core = TestCore.make(fake)
        await core.start()

        let chat = try await core.openBotChat(for: "coder")

        #expect(chat.title == "Bot Chat")
        #expect(chat.isBotChat)
        #expect(chat.items.isEmpty)
        let create = try #require(fake.sent("session.create").first)
        #expect(create["params"]["title"] == "Bot Chat")
        #expect(create["params"]["hidden"] == true)
        #expect(fake.unexpected.isEmpty)
    }

    @Test func typingReloadMcpReloadsTheChatsToolsInsteadOfMessagingTheBot() async throws {
        let fake = try FakeHermes(named: "botchat-create")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")

        await core.send("/reload-mcp", to: chat)

        #expect(fake.sent("prompt.submit").isEmpty)
        let reload = try #require(fake.sent("reload.mcp").last)
        #expect(reload["params"] == ["session_id": .string(chat.sessionID), "confirm": true])
    }

    @Test func openingABotChatShowsItsHistory() async throws {
        let fake = try FakeHermes(named: "botchat-history")
        let core = TestCore.make(fake)
        core.historyPageSize = 4
        await core.start()

        let chat = try await core.openBotChat(for: "default")

        #expect(fake.sent("session.create").isEmpty)
        #expect(chat.items.map(\.text).first == "how much is my mac mini storage left")
        let tool = try #require(chat.items.compactMap(\.tool).first)
        #expect(tool.name == "terminal")
        #expect(tool.context == "df -h /System/Volumes/Data | tail -1")
        #expect(tool.result.contains("33Gi"))
        #expect(chat.items.last?.kind == .assistant)
        #expect(chat.items.last?.text == "The Mac mini has **33 GB free** out of 228 GB.")
        #expect(chat.hasMoreHistory)
    }

    @Test func scrollingBackLoadsOlderMessagesIncludingRoutineResultsAndOtherBots() async throws {
        let fake = try FakeHermes(named: "botchat-history")
        let core = TestCore.make(fake)
        core.historyPageSize = 4
        await core.start()
        let chat = try await core.openBotChat(for: "default")

        await core.loadOlderHistory(chat)

        #expect(chat.items.first?.kind == .botMessage(from: "orchestrator"))
        #expect(chat.items.first?.text == "Context check: do you remember the investment dashboard?")
        #expect(chat.items[1].kind == .routineResult)
        #expect(chat.items[1].text == "Background Process Finished: df -k /")
        #expect(chat.items[2].text == "how much is my mac mini storage left")
        #expect(chat.hasMoreHistory == false)
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aReplyStreamsInAndTheFinishedMessageReplacesIt() async throws {
        let fake = try FakeHermes(named: "botchat-stream")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")

        await core.send("What's on my calendar?", to: chat)

        #expect(await eventually { chat.liveText == "You have two meet" })
        #expect(chat.isRunning)
        #expect(chat.items.first?.kind == .user)
        #expect(chat.items.first?.pending == false)

        // A re-sent chunk (same offset) is not shown twice.
        fake.pushEvent("message.delta", session: "sess-coder-chat", seq: 5, generation: 1, payload: ["text": "meetings", "turn_id": "t1", "segment": 0, "offset": 13])
        #expect(await eventually { chat.liveText == "You have two meetings" })

        fake.pushEvent(
            "message.complete", session: "sess-coder-chat", seq: 6, generation: 1,
            payload: ["text": "You have two meetings today.", "status": "complete"])
        #expect(await eventually { !chat.isRunning })
        #expect(chat.liveText.isEmpty)
        #expect(chat.items.map(\.text) == ["What's on my calendar?", "You have two meetings today."])
        #expect(chat.items.allSatisfy { !$0.streaming })
    }

    @Test func aMessageToAChatHermesUnloadedReopensTheChatAndSendsAgain() async throws {
        let fake = try FakeHermes(named: "session-gone")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")
        #expect(chat.sessionID == "live-1")

        let sent = await core.send("Draw me the latest SILVER chart", to: chat)

        #expect(sent)
        #expect(chat.sessionID == "live-2")
        #expect(core.conversation("live-2") === chat)
        #expect(try await core.openBotChat(for: "coder") === chat)
        #expect(chat.items.map(\.text) == ["Is silver stretched?", "Silver into the reopen: stretched.", "Draw me the latest SILVER chart"])
        #expect(chat.items.allSatisfy { !$0.failed })
        #expect(fake.sent("prompt.submit").count == 2)
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aBotChatCannotBeRenamed() async throws {
        let fake = try FakeHermes(named: "botchat-create")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")

        await core.rename(chat, to: "Something else")

        #expect(chat.title == "Bot Chat")
        #expect(fake.sent("session.mutate").isEmpty)
    }
}
