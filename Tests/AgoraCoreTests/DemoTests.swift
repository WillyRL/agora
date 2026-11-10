import Foundation
import Testing

@testable import AgoraCore

@MainActor
struct DemoTests {
    @Test func theDemoHermesShowsItsBotsAndAChartChat() async throws {
        let env = DemoHermes.environment(notifier: RecordingNotifier())
        let registry = ConnectionRegistry(store: env.store)
        registry.activate(registry.add(name: "Demo Mac", kind: .local).id)
        let core = AgoraCore(registry: registry, environment: env)
        await core.start()

        #expect(await eventually { core.bots.count == 6 })
        let chat = try await core.openBotChat(for: "markets")
        #expect(chat.items.first?.text == "Chart gold for this week and give me the key levels.")
        #expect(chat.items.last?.text.contains("::preview{file=") == true)
        #expect(String(decoding: try await core.fileData("/Users/demo/charts/gold-week.html", in: chat), as: UTF8.self).contains("<svg"))
    }
}

@MainActor
struct KanbanTaskChatTests {
    @Test func aKanbanWorkersChatIsMarkedAndOpensReadOnlyWithItsCard() async throws {
        let env = DemoHermes.environment(notifier: RecordingNotifier())
        let registry = ConnectionRegistry(store: env.store)
        registry.activate(registry.add(name: "Demo Mac", kind: .local).id)
        let core = AgoraCore(registry: registry, environment: env)
        await core.start()
        await core.loadSideChats(for: "research")

        let sides = try #require(core.sideChats["research"])
        #expect(sides.filter(\.isKanbanTask).map(\.id) == ["side-kanban-evals"])

        let task = try await core.openConversation(bot: "research", sessionID: "side-kanban-evals", title: "Five papers on long-context evals")
        #expect(task.isKanbanTask)
        guard case .kanbanBrief(let brief) = task.items.first?.kind else {
            Issue.record("expected the task's card first, got \(String(describing: task.items.first?.kind))")
            return
        }
        #expect(brief.taskID == "t_5c21e0b7")

        let ordinary = try await core.openConversation(bot: "research", sessionID: "side-papers", title: "Long-context evals")
        #expect(!ordinary.isKanbanTask)
    }

    @Test func youCanAnswerABlockedCardAndSendItBackToWork() async throws {
        let env = DemoHermes.environment(notifier: RecordingNotifier())
        let registry = ConnectionRegistry(store: env.store)
        registry.activate(registry.add(name: "Demo Mac", kind: .local).id)
        let core = AgoraCore(registry: registry, environment: env)
        await core.start()

        let card = try await core.kanbanCard("t_5c21e0b7", bot: "research")
        #expect(card.isBlocked)
        #expect(card.blockReason?.contains("preprints") == true)
        #expect(card.comments.first?.body == "Skip anything before 2024.")

        let answered = try await core.commentOnKanbanCard(card, bot: "research", text: "  Preprints are fine.  ")
        #expect(answered.comments.last?.body == "Preprints are fine.")
        #expect(answered.comments.last?.author == "you (Agora)")
        let unblocked = try await core.unblockKanbanCard(answered, bot: "research")
        #expect(unblocked.status == "ready")
        #expect(!unblocked.isBlocked)
    }

    @Test func aCardOnAnotherBoardIsFoundAndAMissingOneSaysSo() async throws {
        let env = DemoHermes.environment(notifier: RecordingNotifier())
        let registry = ConnectionRegistry(store: env.store)
        registry.activate(registry.add(name: "Demo Mac", kind: .local).id)
        let core = AgoraCore(registry: registry, environment: env)
        await core.start()

        let done = try await core.kanbanCard("t_3906c4a2", bot: "default")
        #expect(done.board == "launch")
        #expect(done.isFinished)
        #expect(done.summary?.contains("1,240") == true)
        await #expect(throws: HermesError.self) { try await core.kanbanCard("t_nope", bot: "default") }
    }
}
