import Foundation
import Testing

@testable import AgoraCore

@MainActor
struct SkillTests {
    @Test func aBotsSkillsAreListedByCategoryWithWhereTheyCameFrom() async throws {
        let fake = try FakeHermes(named: "skills")
        let core = TestCore.make(fake)
        await core.start()

        let skills = try await core.skills(bot: "coder")

        #expect(skills.map(\.name) == ["arxiv", "plan", "market-data"])
        #expect(skills.map(\.origin) == [.bundled, .local, .hub])
        #expect(skills.first { $0.name == "market-data" }?.enabled == false)
        #expect(fake.unexpected.isEmpty)
    }

    @Test func turningASkillOnTouchesThatBotOnly() async throws {
        let fake = try FakeHermes(named: "skills")
        let core = TestCore.make(fake)
        await core.start()

        try await core.setSkill("market-data", enabled: true, bot: "coder")

        #expect(fake.unexpected.isEmpty)
    }

    @Test func aNewSkillIsWrittenAsASkillFileForThatBot() async throws {
        let fake = try FakeHermes(named: "skills")
        let core = TestCore.make(fake)
        await core.start()
        let name = Skill.slug("Silver Weekly!")
        #expect(name == "silver-weekly")

        let doc = Skill.document(name: name, description: "Weekly silver chart, \"before\" the reopen", instructions: "  Pull SI=F daily bars.\n\n")
        try await core.createSkill(name, content: doc, category: "trading", bot: "coder")

        #expect(try await core.skillContent("plan", bot: "coder").hasPrefix("---"))
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aHubSkillIsFoundAndInstalledForOneBot() async throws {
        let fake = try FakeHermes(named: "skills")
        let core = TestCore.make(fake)
        await core.start()

        let hits = try await core.searchSkillHub("powerpoint", bot: "coder")
        try await core.installSkill(hits[0], bot: "coder")

        #expect(hits.map(\.name) == ["pptx-author", "powerpoint"])
        #expect(hits.map(\.installed) == [false, true])
        #expect(hits[0].trust == "builtin")
        #expect(fake.sent("skills.manage").last?["params"]["query"] == "official/finance/pptx-author")
        #expect(fake.sent("skills.manage").last?["params"]["profile"] == "coder")
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aSkillHermesRefusesToInstallSaysWhy() async throws {
        let fake = try FakeHermes(named: "skills")
        let core = TestCore.make(fake)
        await core.start()

        await #expect {
            try await core.installSkill(
                HubSkill(name: "sketchy", description: "", identifier: "skills-sh/someone/sketchy", source: "skills-sh", trust: "community", installed: false),
                bot: "coder")
        } throws: { error in
            error.localizedDescription.contains("scan verdict DANGEROUS")
        }
    }

    @Test func aHubSkillCanBeUninstalledFromOneBot() async throws {
        let fake = try FakeHermes(named: "skills")
        let core = TestCore.make(fake)
        core.uninstallPollInterval = .milliseconds(1)
        await core.start()
        _ = try await core.skills(bot: "coder")  // uses the first listing

        try await core.uninstallSkill("market-data", bot: "coder")

        #expect(fake.unexpected.isEmpty)
    }
}

@MainActor
struct AgoraSkillTests {
    @Test func everyBotGetsTheAgoraSkillAndOnlyAgorasOwnOlderCopiesAreReplaced() async throws {
        let fake = try FakeHermes(named: "agora-skill")
        let core = TestCore.make(fake)
        core.installsAgoraSkill = true
        core.teachBots = true
        await core.start()

        func writes(_ method: String) -> [JSON] {
            fake.httpRequests.filter { $0.method == method && $0.url.path.hasPrefix("/api/skills") }.compactMap(\.bodyJSON)
        }
        #expect(await eventually { writes("POST").count == 4 && writes("PUT").count == 1 })
        try await Task.sleep(for: .milliseconds(50))  // nothing more arrives

        #expect(Set(writes("POST").compactMap { $0["profile"].string }) == ["default", "business-team", "chart-technical-analysts", "finance-assistant"])
        #expect(writes("POST").allSatisfy { $0["content"].string == AgoraSkill.document })
        #expect(writes("PUT").map { $0["profile"].string } == ["coder"])
        #expect(writes("PUT").first?["content"].string == AgoraSkill.document)
        #expect(fake.unexpected.isEmpty)
    }

    @Test func botsAreTaughtOnlyAfterYouSayYes() async throws {
        let fake = try FakeHermes(named: "agora-skill")
        let core = TestCore.make(fake)
        core.installsAgoraSkill = true
        await core.start()
        try await Task.sleep(for: .milliseconds(50))

        #expect(core.shouldAskToTeachBots)
        #expect(fake.httpRequests.isEmpty)

        core.setTeachBots(true)
        #expect(!core.shouldAskToTeachBots)
        #expect(await eventually { fake.httpRequests.filter { $0.method == "POST" && $0.url.path == "/api/skills" }.count == 4 })
    }

    @Test func notNowTeachesNothingAndDoesntAskAgain() async throws {
        let fake = try FakeHermes(named: "agora-skill")
        let core = TestCore.make(fake)
        core.installsAgoraSkill = true
        await core.start()
        core.setTeachBots(false)
        try await Task.sleep(for: .milliseconds(50))

        #expect(!core.shouldAskToTeachBots)
        #expect(fake.httpRequests.isEmpty)
    }

    @Test func theSkillIsOffUnlessTheAppTurnsItOn() async throws {
        let fake = try FakeHermes(named: "agora-skill")
        let core = TestCore.make(fake)
        await core.start()
        try await Task.sleep(for: .milliseconds(50))

        #expect(fake.httpRequests.isEmpty)
    }

    @Test func theSkillDeclaresItsVersionAndAuthor() {
        #expect(AgoraSkill.installedVersion(AgoraSkill.document) == AgoraSkill.version)
        #expect(AgoraSkill.isOurs(AgoraSkill.document))
        #expect(!AgoraSkill.isOurs("---\nname: agora-chat\n---\nMine."))
    }

    /// Hermes refuses the whole skill otherwise (tools/skill_manager_tool.py).
    @Test func theDescriptionFitsHermessSkillIndex() throws {
        let line = try #require(AgoraSkill.document.split(separator: "\n").first { $0.hasPrefix("description: ") })
        let description = line.dropFirst("description: ".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        #expect(description.count <= AgoraSkill.maxDescription)
        #expect(description.hasSuffix("."))
    }
}

@MainActor
struct AgoraHintTests {
    @Test func everyBotGetsAgorasLineAndOnlyAgorasOwnOlderOnesAreReplaced() async throws {
        let fake = try FakeHermes(named: "agora-hint")
        let core = TestCore.make(fake)
        core.installsAgoraSkill = true
        core.teachBots = true
        await core.start()

        func puts() -> [JSON] {
            fake.httpRequests.filter { $0.method == "PUT" && $0.url.path == "/api/config" }.compactMap(\.bodyJSON)
        }
        func profiles() -> [String] {
            fake.httpRequests.filter { $0.method == "PUT" && $0.url.path == "/api/config" }
                .compactMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "profile" }?.value }
        }
        #expect(await eventually { puts().count == 4 })
        try await Task.sleep(for: .milliseconds(50))  // nothing more arrives

        #expect(Set(profiles()) == ["default", "business-team", "chart-technical-analysts", "coder"])
        // Only the one key: Hermes merges it into the rest of the Bot's config.
        #expect(puts().allSatisfy { $0 == ["config": ["platform_hints": ["gui": AgoraHint.entry]]] })
        #expect(fake.unexpected.isEmpty)
    }

    @Test func theLineStaysOneParagraph() {
        #expect(!AgoraHint.text.contains("\n"))
        #expect(AgoraHint.text.contains("MEDIA:/absolute/path"))
    }
}

struct RefreshCommandTests {
    @Test func oneLinePerBotWithOddNamesQuoted() {
        #expect(AgoraHint.refreshCommand(bots: ["default", "video_editor-2", "it's mine"]) == """
            hermes -p default sessions refresh-prompts
            hermes -p video_editor-2 sessions refresh-prompts
            hermes -p 'it'\\''s mine' sessions refresh-prompts
            """)
    }
}
