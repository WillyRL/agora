import Foundation
import Testing

@testable import AgoraCore

@MainActor
struct RosterTests {
    @Test func localConnectionListsEveryVisibleBot() async throws {
        let fake = try FakeHermes(named: "local-roster")
        let core = TestCore.make(fake)

        await core.start()

        #expect(core.status == .connected)
        #expect(
            core.bots.map(\.title) == [
                "Hermes", "Business Team", "Chart Technical Analysts", "Coder", "Devops", "Finance Assistant",
            ])
        #expect(fake.unexpected.isEmpty)
    }

    @Test func handshakeAdvertisesServerRequestsAfterReady() async throws {
        let fake = try FakeHermes(named: "local-roster")
        let core = TestCore.make(fake)

        await core.start()

        let caps = fake.sent("client.capabilities")
        #expect(caps.first?["params"]["server_requests"] == true)
        #expect(fake.dials.first?.protocols.first == "hermes-gateway-v1")
        #expect(fake.dials.first?.url.absoluteString == "ws://127.0.0.1:56904/api/ws")
        #expect(core.serverCapabilities.contains("approval"))
    }

    @Test func botsShowTheOfficialAppsLook() async throws {
        let fake = try FakeHermes(named: "local-roster")
        let core = TestCore.make(fake)

        await core.start()

        let hermes = try #require(core.bots.first { $0.name == "default" })
        #expect(hermes.color == BotColor(hex: "#8b5cf6"))
        #expect(hermes.shape == "squircle")
        // No picked colour: the same deterministic hue the official app derives from the name.
        let coder = try #require(core.bots.first { $0.name == "coder" })
        #expect(coder.color == BotColor.derived(from: "coder"))
        #expect(coder.description.hasPrefix("This agent profile dedicated to Coding"))
        #expect(core.bots.contains { $0.name == "reviewer" } == false)
    }
}
