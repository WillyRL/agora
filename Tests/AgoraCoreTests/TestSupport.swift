import Foundation

@testable import AgoraCore

@MainActor
enum TestCore {
    /// An Agora Core whose active Connection is the local Hermes, played by `fake`.
    static func make(
        _ fake: FakeHermes, notifier: RecordingNotifier = RecordingNotifier(), store: InMemoryKeyValueStore = InMemoryKeyValueStore(),
        credentials: InMemoryCredentialStore = InMemoryCredentialStore(), remote: URL? = nil,
        accessTokens: AccessTokenStore = InMemoryAccessTokenStore()
    ) -> AgoraCore {
        let env = AgoraEnvironment(
            sockets: fake, http: fake, control: fake, starter: fake, credentials: credentials, notifier: notifier,
            store: store, connectionOptions: .immediate, tailnet: fake, accessTokens: accessTokens)
        let registry = ConnectionRegistry(store: store)
        if let remote {
            let saved = registry.add(name: "Home Server", kind: .remote(remote))
            registry.activate(saved.id)
        } else if registry.connections.isEmpty {
            let saved = registry.add(name: "This Mac", kind: .local)
            registry.activate(saved.id)
        }
        return AgoraCore(registry: registry, environment: env)
    }
}

/// Polls until `condition` holds (state updates arrive asynchronously from the socket).
@MainActor
func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
