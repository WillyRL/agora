import Foundation
import Testing

@testable import AgoraCore

@MainActor
@Suite struct TailnetTests {
    @Test func findsHermesOnTheOnlineMachinesOfYourTailnet() async throws {
        let fake = try FakeHermes(named: "tailnet")
        let core = TestCore.make(fake)

        await core.scanTailnet()

        #expect(core.tailnet.problem == nil)
        #expect(!core.tailnet.scanning)
        // One entry per machine, sorted by name. HTTPS through Tailscale Serve wins over plain :9119.
        #expect(core.tailnet.gateways.map(\.deviceName) == ["homelab", "Old iMac", "Studio Mac mini"])
        #expect(core.tailnet.gateways.map(\.url.absoluteString) == [
            "http://homelab.tail1234.ts.net:9119", "http://old-imac.tail1234.ts.net:9119", "https://studio-mac-mini.tail1234.ts.net",
        ])
        let studio = try #require(core.tailnet.gateways.last)
        #expect(studio.status.supportsBrowserSignIn)
        #expect(studio.isSupported)
        #expect(core.tailnet.gateways.first { $0.deviceName == "Old iMac" }?.isSupported == false)

        // This Mac, offline machines, phones and nodes shared in from other tailnets are never probed.
        let probed = Set(fake.httpRequests.compactMap(\.url.host))
        #expect(probed == ["studio-mac-mini.tail1234.ts.net", "homelab.tail1234.ts.net", "nas.tail1234.ts.net", "old-imac.tail1234.ts.net"])
    }

    @Test func aMachineYouAlreadySavedIsMarked() async throws {
        let fake = try FakeHermes(named: "tailnet")
        let core = TestCore.make(fake)
        let saved = core.registry.add(name: "Homelab", kind: .remote(URL(string: "http://homelab.tail1234.ts.net:9119/")!))

        await core.scanTailnet()

        #expect(core.tailnet.gateways.first { $0.deviceName == "homelab" }?.savedConnectionID == saved.id)
        #expect(core.tailnet.gateways.first { $0.deviceName == "Studio Mac mini" }?.savedConnectionID == nil)
    }

    @Test func saysSoWhenTailscaleIsOffOrMissing() async throws {
        let stopped = try FakeHermes(fixture: Fixtures.load("tailnet").setting("tailscale", ["BackendState": "Stopped", "Peer": .null]))
        let core = TestCore.make(stopped)
        await core.scanTailnet()
        #expect(core.tailnet.problem == "Tailscale is turned off on this Mac.")
        #expect(core.tailnet.gateways.isEmpty)
        #expect(stopped.httpRequests.isEmpty)

        let missing = try FakeHermes(named: "remote-token")
        let core2 = TestCore.make(missing)
        await core2.scanTailnet()
        #expect(core2.tailnet.problem == "Tailscale isn't installed on this Mac.")
    }

    @Test func connectingToAFoundMachineSignsInThroughTheBrowserAndNamesItAfterTheMachine() async throws {
        let fake = try FakeHermes(named: "remote-signin")
        let credentials = InMemoryCredentialStore()
        let core = TestCore.make(fake, credentials: credentials)
        let gateway = TailnetGateway(
            deviceName: "Studio Mac mini", url: URL(string: "https://hermes.example.com")!,
            status: .init(version: "0.23.0", authRequired: true, authProviders: ["basic"], authFlows: ["native_pkce"]))
        let receiver = FakeLoopback()

        let saved = try await core.connect(to: gateway, receiver: receiver) { url in
            receiver.remember(state: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? "")
        }

        #expect(saved.name == "Studio Mac mini")
        #expect(core.registry.activeID == saved.id)
        #expect(core.status == .connected)
    }
}
