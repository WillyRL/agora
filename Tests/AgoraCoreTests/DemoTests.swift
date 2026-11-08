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
