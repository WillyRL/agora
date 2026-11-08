import Foundation
import Testing

@testable import AgoraCore

@MainActor
struct ApprovalTests {
    func chatWithApproval() async throws -> (FakeHermes, AgoraCore, Conversation) {
        let fake = try FakeHermes(named: "approvals")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")
        await core.send("Clean the build folder", to: chat)
        #expect(await eventually { !chat.prompts.isEmpty })
        return (fake, core, chat)
    }

    @Test func anApprovalRequestShowsACardWithTheCommand() async throws {
        let (_, core, chat) = try await chatWithApproval()
        defer { withExtendedLifetime(core) {} }

        let card = try #require(chat.prompts.first)
        #expect(card.kind == .approval(command: "rm -rf build", description: "recursive delete", choices: ["once", "deny", "session", "always"]))
    }

    @Test func approvingSendsTheChoiceAndClosesTheCard() async throws {
        let (fake, core, chat) = try await chatWithApproval()

        await core.answer(try #require(chat.prompts.first), choice: "once")

        let respond = try #require(fake.sent("approval.respond").first)
        #expect(respond["params"]["choice"] == "once")
        #expect(respond["params"]["execution_generation"] == 2)
        #expect(await eventually { chat.prompts.isEmpty })
    }

    @Test func denyingSendsDeny() async throws {
        let (fake, core, chat) = try await chatWithApproval()

        await core.answer(try #require(chat.prompts.first), choice: "deny")

        #expect(fake.sent("approval.respond").first?["params"]["choice"] == "deny")
        #expect(chat.prompts.isEmpty)
    }

    @Test func aWithdrawnApprovalDisappears() async throws {
        let (fake, core, chat) = try await chatWithApproval()
        defer { withExtendedLifetime(core) {} }

        fake.pushEvent("approval.settled", session: "sess-coder-chat", seq: 3, generation: 2, payload: ["prompt_id": "ap_1", "execution_generation": 2])

        #expect(await eventually { chat.prompts.isEmpty })
        #expect(fake.sent("approval.respond").isEmpty)
    }
}

@MainActor
struct QuestionTests {
    func chatWithQuestions() async throws -> (FakeHermes, AgoraCore, Conversation) {
        let fake = try FakeHermes(named: "questions")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")
        await core.send("Set up the weather integration", to: chat)
        #expect(await eventually { chat.prompts.count == 3 })
        return (fake, core, chat)
    }

    @Test func aClarifyingQuestionShowsACardAndSendsTheAnswer() async throws {
        let (fake, core, chat) = try await chatWithQuestions()

        let question = try #require(chat.prompts.first { if case .clarify = $0.kind { true } else { false } })
        #expect(question.kind == .clarify(question: "Which city should I use?", choices: ["Jakarta", "Bandung"], multiSelect: false))

        await core.answer(question, text: "Bandung")

        #expect(fake.sent("clarify.respond").first?["params"]["answer"] == "Bandung")
        #expect(!chat.prompts.contains { $0.id == question.id })
    }

    @Test func aSecretIsSentButNeverShownOrKept() async throws {
        let (fake, core, chat) = try await chatWithQuestions()

        let secret = try #require(chat.prompts.first { $0.isSecret && $0.id == "srq-2" })
        #expect(secret.kind == .secret(prompt: "Paste your OpenWeather API key", envVar: "OPENWEATHER_KEY"))

        await core.answer(secret, text: "sk-test-123")

        #expect(await eventually { fake.responses.contains { $0["id"] == "srq-2" && $0["result"]["value"] == "sk-test-123" } })
        #expect(!chat.prompts.contains { $0.id == "srq-2" })
        #expect(!chat.items.contains { $0.text.contains("sk-test-123") })
    }

    @Test func unsupportedRequestsGetMethodNotFoundSoTheBotIsntLeftWaiting() async throws {
        let (fake, core, chat) = try await chatWithQuestions()
        defer { withExtendedLifetime(core) {} }

        #expect(await eventually { fake.responses.contains { $0["id"] == "srq-3" } })
        let reply = try #require(fake.responses.first { $0["id"] == "srq-3" })
        #expect(reply["error"]["code"] == -32601)
        #expect(!chat.prompts.contains { $0.id == "srq-3" })
    }

    @Test func aWithdrawnSudoPromptDisappears() async throws {
        let (fake, core, chat) = try await chatWithQuestions()
        defer { withExtendedLifetime(core) {} }
        #expect(chat.prompts.contains { $0.kind == .sudo(command: "brew services restart redis") })

        fake.pushEvent("request.cancel", session: "sess-coder-chat", payload: ["id": "srq-4", "method": "sudo", "reason": "timeout"])

        #expect(await eventually { !chat.prompts.contains { $0.id == "srq-4" } })
    }
}
