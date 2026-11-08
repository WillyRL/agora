import Foundation
import Synchronization
import Testing

@testable import AgoraCore

@MainActor
struct MCPTests {
    func started() async throws -> (FakeHermes, AgoraCore) {
        let fake = try FakeHermes(named: "mcp")
        let core = TestCore.make(fake)
        await core.start()
        return (fake, core)
    }

    @Test func theLibraryListsTheMainProfilesServers() async throws {
        let (_, core) = try await started()

        let servers = try await core.mcpServers()

        #expect(servers.map(\.name) == ["garmin", "linear", "kanban", "acme easypanel"])
        #expect(servers[0].address == "/Users/me/.hermes/garmin/run.sh")
        #expect(!servers[0].isRemote)
        #expect(servers[1].isRemote && servers[1].auth == .oauth && !servers[1].enabled)
        #expect(servers[2].plugin == "kanban")
        // A key carried in the URL is never shown.
        #expect(servers[1].address == "https://mcp.linear.app/mcp?apiKey=•••")
    }

    @Test func serversCanBeSwitchedOnTestedAddedAndRemoved() async throws {
        let (fake, core) = try await started()

        try await core.setMCPServer("linear", enabled: true)
        let good = try await core.testMCPServer("garmin")
        let bad = try await core.testMCPServer("tavily")
        try await core.addMCPServer(NewMCPServer(name: "tavily", url: "https://mcp.tavily.com/mcp", auth: .header, token: "tvly-secret"))
        await #expect(throws: HermesError.self) { try await core.addMCPServer(NewMCPServer(name: "garmin", command: "run.sh")) }
        try await core.removeMCPServer("tavily")

        #expect(good.ok && good.tools.map(\.name) == ["get_activities", "get_sleep"])
        #expect(!bad.ok && bad.error == "401 Unauthorized")
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aCommandIsSplitIntoProgramAndArguments() async throws {
        let (fake, core) = try await started()

        try? await core.addMCPServer(NewMCPServer(name: "files", command: "npx -y @mcp/files /tmp"))

        let body = try #require(fake.httpRequests.last?.bodyJSON)
        #expect(body["command"] == "npx")
        #expect(body["args"] == ["-y", "@mcp/files", "/tmp"])
    }

    @Test func signingInOpensTheBrowserAndWaitsForApproval() async throws {
        let (fake, core) = try await started()
        let opened = Mutex<[URL]>([])

        try await core.signInMCPServer("linear", poll: .milliseconds(5)) { url in opened.withLock { $0.append(url) } }

        #expect(opened.withLock { $0 } == [URL(string: "https://linear.app/oauth/authorize?state=x")!])
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aBotGetsOnlyTheServersPickedForIt() async throws {
        let (fake, core) = try await started()

        let current = try await core.mcpServers(bot: "coder")
        try await core.setMCPServers(bot: "coder", enabled: ["linear"])

        #expect(current.map(\.name) == ["garmin"] && !current[0].enabled)
        let sent = try #require(fake.sent("profiles.configure").last)
        #expect(sent["params"]["enabled_mcp_servers"] == ["linear"])
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aNameWithASpaceIsSentEncodedOnce() async throws {
        let (fake, core) = try await started()

        let result = try await core.testMCPServer("acme easypanel")

        #expect(result.ok)
        #expect(fake.httpRequests.last?.url.absoluteString.contains("/api/mcp/servers/acme%20easypanel/test") == true)
        #expect(fake.unexpected.isEmpty)
    }

    @Test func editingReplacesTheServerAndKeepsItOff() async throws {
        let (fake, core) = try await started()
        let servers = try await core.mcpServers()
        let linear = try #require(servers.first { $0.name == "linear" })
        #expect(linear.draft.url == "https://mcp.linear.app/mcp?apiKey=lin-secret")  // the form gets the real URL

        var draft = linear.draft
        draft.url = "https://mcp.linear.app/sse"
        try await core.editMCPServer(linear, to: draft)

        let calls = fake.httpRequests.suffix(3).map { "\($0.method) \($0.url.path)" }
        #expect(calls == ["DELETE /api/mcp/servers/linear", "POST /api/mcp/servers", "PUT /api/mcp/servers/linear/enabled"])
        #expect(fake.unexpected.isEmpty)
    }

    @Test func editingAServerWithSettingsAgoraCantSeeIsRefused() async throws {
        let (fake, core) = try await started()
        let garmin = try #require(try await core.mcpServers().first { $0.name == "garmin" })

        await #expect(throws: HermesError.self) { try await core.editMCPServer(garmin, to: garmin.draft) }
        #expect(!fake.httpRequests.contains { $0.method == "DELETE" })
    }

    @Test func aTokenServerIsAddedToTheBotWithItsTokenThenSwitchedOn() async throws {
        let (fake, core) = try await started()
        var s = try await core.mcpSelection(bot: "coder")
        #expect(s.names == ["garmin", "linear", "acme easypanel"])  // plugin servers aren't offered
        #expect(s.needsToken("acme easypanel") && !s.needsToken("garmin") && !s.needsToken("linear"))

        s.picked = ["garmin", "acme easypanel"]
        await #expect(throws: HermesError.self) { try await core.applyMCPSelection(s, bot: "coder") }  // no token yet
        s.tokens["acme easypanel"] = "ep-token"
        try await core.applyMCPSelection(s, bot: "coder")

        let add = try #require(fake.httpRequests.last { $0.method == "POST" && $0.url.path == "/api/mcp/servers" })
        #expect(add.url.query?.contains("profile=coder") == true)
        #expect(fake.sent("profiles.configure").last?["params"]["enabled_mcp_servers"] == ["acme easypanel", "garmin"])
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aTokenTypedOnceIsRememberedUntilTheServerIsRemoved() async throws {
        let (_, core) = try await started()

        try await core.addMCPServer(NewMCPServer(name: "tavily", url: "https://mcp.tavily.com/mcp", auth: .header, token: "tvly-secret"))
        #expect(core.rememberedMCPToken(for: "tavily") == "tvly-secret")

        try await core.removeMCPServer("tavily")
        #expect(core.rememberedMCPToken(for: "tavily") == nil)
    }

    @Test func aServerGoesToSeveralBotsWithTheRememberedToken() async throws {
        let (fake, core) = try await started()
        core.rememberMCPToken("ep-token", for: "acme easypanel")
        let acme = try #require(try await core.mcpServers().first { $0.name == "acme easypanel" })

        try await core.addMCPServer(acme, toBots: ["coder"])

        let add = try #require(fake.httpRequests.last { $0.method == "POST" && $0.url.path == "/api/mcp/servers" })
        #expect(add.bodyJSON?["bearer_token"] == "ep-token")
        #expect(fake.sent("profiles.configure").last?["params"]["enabled_mcp_servers"] == ["acme easypanel"])
        #expect(fake.unexpected.isEmpty)
    }

    @Test func theBotEditorDoesntAskForARememberedToken() async throws {
        let (_, core) = try await started()
        core.rememberMCPToken("ep-token", for: "acme easypanel")

        let s = try await core.mcpSelection(bot: "coder")

        #expect(s.needsToken("acme easypanel") && s.tokens["acme easypanel"] == "ep-token")
    }

    @Test func aBotsToolGroupsListTheOnesItCanUseFirst() async throws {
        let (_, core) = try await started()

        let sets = try await core.toolsets(bot: "devops")

        #expect(sets.map(\.name) == ["terminal", "web", "browser"])
        #expect(sets[1].label == "Web search" && !sets[1].configured && sets[1].tools == ["web_search", "web_extract"])
    }
}
