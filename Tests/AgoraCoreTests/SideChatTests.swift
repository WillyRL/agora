import Foundation
import Testing

@testable import AgoraCore

@MainActor
struct SideChatTests {
    @Test func aBotsSideChatsAreListedNewestFirstWithoutBotChatArchivedOrRoutineRuns() async throws {
        let fake = try FakeHermes(named: "sidechats")
        let core = TestCore.make(fake)
        await core.start()

        await core.loadSideChats(for: "coder")

        #expect(core.sideChats["coder"]?.map(\.title) == ["E-bike shortlist", "Lisbon trip"])
        let request = try #require(fake.httpRequests.first { $0.url.path == "/api/sessions" })
        #expect(request.url.query?.contains("exclude_sources=cron") == true)
    }

    @Test func aNewSideChatStartsBlankAndIsListedUnderItsBot() async throws {
        let fake = try FakeHermes(named: "sidechats")
        let core = TestCore.make(fake)
        await core.start()
        await core.loadSideChats(for: "coder")

        let side = try await core.newSideChat(for: "coder")

        #expect(side.isBotChat == false)
        #expect(side.items.isEmpty)
        #expect(core.sideChats["coder"]?.first?.id == "sess-side-1")
        let create = try #require(fake.sent("session.create").first)
        #expect(create["params"]["title"].isNull)
        #expect(create["params"]["hidden"].isNull)
    }

    @Test func aSideChatResumedUnderANewLiveIDStillLoadsItsHistoryAndStaysListed() async throws {
        let fake = try FakeHermes(named: "sidechat-live-id")
        let core = TestCore.make(fake)
        await core.start()
        await core.loadSideChats(for: "coder")

        let side = try await core.openConversation(bot: "coder", sessionID: "sess-old", title: "Lisbon trip")

        #expect(side.sessionID == "live-77")
        #expect(side.storedSessionID == "sess-old")
        #expect(side.items.first?.text == "Plan three days in Lisbon.")
        // Opening it again by its listed id finds the open conversation instead of resuming twice.
        let again = try await core.openConversation(bot: "coder", sessionID: "sess-old", title: "Lisbon trip")
        #expect(again === side)
        #expect(fake.sent("session.resume").count == 1)

        await core.archive(side)
        #expect(core.sideChats["coder"]?.contains { $0.id == "sess-old" } == false)
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aSideChatCanBeRenamedAndArchived() async throws {
        let fake = try FakeHermes(named: "sidechats")
        let core = TestCore.make(fake)
        await core.start()
        await core.loadSideChats(for: "coder")
        let side = try await core.newSideChat(for: "coder")

        await core.rename(side, to: "Trip planning")
        #expect(side.title == "Trip planning")
        #expect(core.sideChats["coder"]?.first?.title == "Trip planning")

        await core.archive(side)
        #expect(core.sideChats["coder"]?.contains { $0.id == "sess-side-1" } == false)
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aSideChatCanBeArchivedFromTheListAndBroughtBack() async throws {
        let fake = try FakeHermes(named: "sidechats")
        let core = TestCore.make(fake)
        await core.start()
        await core.loadSideChats(for: "coder")
        let row = try #require(core.sideChats["coder"]?.first { $0.id == "sess-new" })

        #expect(await core.archiveSideChat(row))
        #expect(core.sideChats["coder"]?.contains { $0.id == "sess-new" } == false)

        await core.unarchiveSideChat(row)
        #expect(core.sideChats["coder"]?.map(\.id) == ["sess-new", "sess-old"])
        #expect(fake.unexpected.isEmpty)
    }

    @Test func deletingASideChatRemovesIt() async throws {
        let fake = try FakeHermes(named: "sidechats")
        let core = TestCore.make(fake)
        await core.start()
        await core.loadSideChats(for: "coder")
        let side = try await core.openConversation(bot: "coder", sessionID: "sess-new", title: "E-bike shortlist")

        await core.delete(side)

        #expect(core.sideChats["coder"]?.map(\.title) == ["Lisbon trip"])
        #expect(core.conversations["sess-new"] == nil)
        #expect(fake.sent("session.mutate").first?["params"]["operation"] == "delete")
    }

    @Test func aBotChatIsNeverArchivedOrDeleted() async throws {
        let fake = try FakeHermes(named: "sidechats")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")

        await core.archive(chat)
        await core.delete(chat)

        #expect(fake.sent("session.mutate").isEmpty)
    }

    @Test func aSideChatWithContextStartsWithTheBotsHandoffSummary() async throws {
        let fake = try FakeHermes(named: "sidechat-context")
        let core = TestCore.make(fake)
        await core.start()
        let botChat = try await core.openBotChat(for: "coder")

        let side = try await core.newSideChat(for: "coder", carryContext: true)

        let summary = "We were comparing commuter e-bikes under $2,000; mid-drive motors win on hills."
        #expect(side.items.first?.text.contains(summary) == true)
        let submit = try #require(fake.sent("prompt.submit").first)
        #expect(submit["params"]["session_id"] == "sess-side-2")
        #expect(submit["params"]["text"].string?.contains(summary) == true)
        // The Bot Chat is left unchanged.
        #expect(botChat.items.isEmpty)
        #expect(fake.sent("prompt.submit").allSatisfy { $0["params"]["session_id"] != "sess-coder-chat" })
        #expect(fake.unexpected.isEmpty)
    }
}
