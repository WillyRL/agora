import Foundation
import Testing

@testable import AgoraCore

@MainActor
struct ReconnectTests {
    @Test func aReplyThatWasStreamingContinuesAfterReconnecting() async throws {
        let fake = try FakeHermes(named: "reconnect-streaming")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")
        await core.send("Tell me a story", to: chat)
        #expect(await eventually { chat.liveText == "Hello " })
        let ticketsBefore = fake.ticketsMinted

        fake.drop(code: 1006)

        #expect(await eventually { fake.dials.count == 2 && core.status == .connected })
        #expect(fake.ticketsMinted > ticketsBefore)
        #expect(await eventually { chat.liveText == "Hello world" })
        // The sudo prompt that was waiting comes back from open_requests.
        #expect(await eventually { chat.prompts.contains { $0.id == "srq-9" } })
        #expect(chat.isRunning)
        // The sent message isn't shown twice after the history reload.
        #expect(chat.items.filter { $0.kind == .user }.count == 1)
        #expect(fake.unexpected.isEmpty)
    }

    @Test func anExpiredTicketGetsANewTicketAndAnotherDial() async throws {
        let fake = try FakeHermes(named: "reconnect-ticket")
        let core = TestCore.make(fake)
        await core.start()

        fake.drop(code: 1006)

        #expect(await eventually { fake.dials.count == 3 && core.status == .connected })
        #expect(fake.ticketsMinted == 3)
        #expect(core.bots.count == 6)
    }

    @Test func hermesRestartingMidChatRereadsTheChat() async throws {
        let fake = try FakeHermes(named: "reconnect-restart")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")
        await core.send("Tell me a story", to: chat)
        #expect(await eventually { chat.liveText == "Hello " })

        fake.drop(code: 1012, reason: "service restart")

        #expect(await eventually { chat.items.last?.text == "Hello world, the end." })
        #expect(chat.isRunning == false)
        #expect(chat.items.map(\.text) == ["Tell me a story", "Hello world, the end."])
    }

    @Test func aRefusedConnectionShowsAConfigurationErrorAndStopsRetrying() async throws {
        let fake = try FakeHermes(named: "reconnect-config-error")
        let core = TestCore.make(fake)
        await core.start()

        fake.drop(code: 4403, reason: "host_mismatch")

        #expect(await eventually { if case .configurationError = core.status { true } else { false } })
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.dials.count == 1)
    }

    @Test func aLocalHermesThatIsntRunningIsStartedOnce() async throws {
        let fake = try FakeHermes(named: "local-not-running")
        let core = TestCore.make(fake)

        await core.start()

        #expect(fake.ensureCalls == 1)
        #expect(core.status == .connected)
        #expect(core.bots.count == 6)
    }

    @Test func statusShowsReconnectingWhileTheConnectionIsDown() async throws {
        let fake = try FakeHermes(named: "reconnect-stalled")
        let core = TestCore.make(fake)
        await core.start()
        #expect(core.status == .connected)

        fake.drop(code: 1006)

        #expect(await eventually { if case .reconnecting = core.status { true } else { false } })
    }
}

@MainActor
struct CapabilityTests {
    @Test func anOlderHermesStillListsBotsButExplainsWhatsMissing() async throws {
        let fake = try FakeHermes(named: "old-hermes")
        let core = TestCore.make(fake)

        await core.start()

        #expect(core.status == .connected)
        #expect(core.bots.count == 6)
        #expect(core.features.sessionAuthority == false)
        #expect(core.notice?.contains("older") == true)
    }

    @Test func steeringFallsBackToANewMessageWhenHermesCantSteer() async throws {
        let fake = try FakeHermes(named: "steer-unsupported")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")
        await core.send("Write a poem", to: chat)
        #expect(await eventually { chat.isRunning })

        await core.send("Shorter please", to: chat)

        #expect(fake.sent("prompt.submit").count == 2)
        #expect(core.features.steer == false)
        #expect(fake.unexpected.isEmpty)
    }
}
