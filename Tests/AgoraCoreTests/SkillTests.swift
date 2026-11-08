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
