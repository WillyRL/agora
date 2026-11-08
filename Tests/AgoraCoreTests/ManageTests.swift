import Foundation
import Testing

@testable import AgoraCore

@MainActor
struct RoutineTests {
    @Test func aBotsRoutinesShowScheduleNextRunAndLastResult() async throws {
        let fake = try FakeHermes(named: "routines")
        let core = TestCore.make(fake)
        await core.start()

        await core.loadRoutines(for: "coder")

        let list = try #require(core.routines["coder"])
        #expect(list.map(\.title) == ["Morning brief", "Inbox sweep"])
        #expect(list[0].schedule == "every weekday at 07:00")
        #expect(list[0].nextRun != nil)
        #expect(list[0].lastStatus == "ok")
        #expect(list[1].lastError == "IMAP timeout")
    }

    @Test func routinesCanBePausedResumedRunAndDeleted() async throws {
        let fake = try FakeHermes(named: "routines")
        let core = TestCore.make(fake)
        await core.start()
        await core.loadRoutines(for: "coder")
        let brief = try #require(core.routines["coder"]?.first)

        await core.pause(brief)
        #expect(core.routines["coder"]?.first?.paused == true)

        await core.resume(try #require(core.routines["coder"]?.first))
        #expect(core.routines["coder"]?.first?.paused == false)

        let sweep = try #require(core.routines["coder"]?.last)
        await core.runNow(sweep)
        #expect(core.routines["coder"]?.last?.lastStatus == "ok")

        await core.delete(sweep)
        #expect(core.routines["coder"]?.map(\.title) == ["Morning brief"])
        #expect(fake.httpRequests.contains { $0.method == "DELETE" && $0.url.path == "/api/cron/jobs/b2" })
    }

    @Test func askingTheBotForARoutineUpdatesThePanel() async throws {
        let fake = try FakeHermes(named: "routines")
        let core = TestCore.make(fake)
        await core.start()
        await core.loadRoutines(for: "coder")
        let chat = try await core.openBotChat(for: "coder")

        await core.send("Nudge me to walk at 3pm on weekdays", to: chat)

        #expect(await eventually { core.routines["coder"]?.count == 3 })
        #expect(core.routines["coder"]?.last?.title == "Afternoon walk nudge")
    }
}

@MainActor
struct ActivityTests {
    func watching(_ notifier: RecordingNotifier = RecordingNotifier(), store: InMemoryKeyValueStore = InMemoryKeyValueStore()) async throws -> (FakeHermes, AgoraCore) {
        let fake = try FakeHermes(named: "activity")
        let core = TestCore.make(fake, notifier: notifier, store: store)
        await core.start()
        await core.watchBotChats()
        return (fake, core)
    }

    @Test func aRoutineResultNotifiesAndMarksTheBotUnread() async throws {
        let notifier = RecordingNotifier()
        let (fake, core) = try await watching(notifier)
        core.markSeen(bot: "coder")

        fake.pushEvent("message.start", session: "sess-coder-chat", seq: 1, generation: 2,
            payload: ["turn_id": "rt1", "display_kind": "process_complete", "display_text": "Morning brief finished"])
        fake.pushEvent("message.complete", session: "sess-coder-chat", seq: 2, generation: 2,
            payload: ["text": "3 meetings today. **Dentist** at 11:00.", "status": "complete"])

        #expect(await eventually { core.isUnread("coder") })
        let note = try #require(notifier.posted.first)
        #expect(note.kind == .routineResult)
        #expect(note.bot == "coder")
        #expect(note.body == "3 meetings today. Dentist at 11:00.")
        #expect(core.bot(named: "coder")?.lastPreview == "3 meetings today. Dentist at 11:00.")
    }

    @Test func anotherBotsMessageNotifies() async throws {
        let notifier = RecordingNotifier()
        let (fake, core) = try await watching(notifier)
        defer { withExtendedLifetime(core) {} }

        fake.pushEvent("message.start", session: "sess-fin-chat", seq: 1, generation: 2,
            payload: ["turn_id": "b1", "text": "Message from 🤖 coder (@coder): Can you check the invoice total?"])
        fake.pushEvent("message.complete", session: "sess-fin-chat", seq: 2, generation: 2, payload: ["text": "It's $412.", "status": "complete"])

        #expect(await eventually { notifier.posted.first?.kind == .botMessage })
    }

    @Test func aMutedBotDoesntNotifyButStillShowsUnread() async throws {
        let notifier = RecordingNotifier()
        let store = InMemoryKeyValueStore()
        let (fake, core) = try await watching(notifier, store: store)
        core.setMuted("coder", true)
        core.markSeen(bot: "coder")

        fake.pushEvent("message.complete", session: "sess-coder-chat", seq: 2, generation: 2, payload: ["text": "Inbox sweep done.", "status": "complete"])

        #expect(await eventually { core.isUnread("coder") })
        #expect(notifier.posted.isEmpty)
        // The mute is remembered.
        let again = TestCore.make(try FakeHermes(named: "local-roster"), store: store)
        #expect(again.isMuted("coder"))
    }

    @Test func theChatYoureLookingAtDoesntNotifyOrGoUnread() async throws {
        let notifier = RecordingNotifier()
        let (fake, core) = try await watching(notifier)
        core.setViewing(bot: "coder", session: nil)

        fake.pushEvent("message.complete", session: "sess-coder-chat", seq: 2, generation: 2, payload: ["text": "Done.", "status": "complete"])

        try await Task.sleep(for: .milliseconds(50))
        #expect(!core.isUnread("coder"))
        #expect(notifier.posted.isEmpty)
    }

    @Test func activitySinceYouLastLookedShowsUnreadAfterLaunch() async throws {
        let fake = try FakeHermes(named: "activity")
        let core = TestCore.make(fake)

        await core.start()

        #expect(core.isUnread("coder"))
        #expect(core.bot(named: "coder")?.lastPreview == "Earlier reply")
        core.markSeen(bot: "coder")
        #expect(!core.isUnread("coder"))
    }

    @Test func approvalsNotifyWithButtonsWhenAgoraIsInTheBackground() async throws {
        let notifier = RecordingNotifier()
        let (fake, core) = try await watching(notifier)
        core.appIsActive = false

        fake.pushEvent("approval.request", session: "sess-coder-chat", seq: 3, generation: 2,
            payload: ["kind": "approval", "prompt_id": "ap_9", "execution_generation": 2, "command": "git push", "description": "push to origin", "choices": ["once", "deny", "session", "always"]])

        #expect(await eventually { notifier.posted.contains { $0.kind == .approval } })
        let note = try #require(notifier.posted.first { $0.kind == .approval })
        #expect(note.choices == ["once", "deny", "session", "always"])

        await core.answerFromNotification(promptID: note.id, choice: "session")

        #expect(fake.sent("approval.respond").first?["params"]["choice"] == "session")
        #expect(core.pendingPrompts.isEmpty)
    }
}

@MainActor
struct QuickAskTests {
    @Test func quickAskDefaultsToTheMostRecentBotAndAtNameSwitches() async throws {
        let fake = try FakeHermes(named: "local-roster")
        let core = TestCore.make(fake)
        await core.start()

        #expect(core.quickAskTarget(for: "hello").bot?.name == "default")
        core.lastUsedBot = "coder"
        #expect(core.quickAskTarget(for: "what's next?").bot?.name == "coder")
        let target = core.quickAskTarget(for: "@finance how much did I spend?")
        #expect(target.bot?.name == "finance-assistant")
        #expect(target.question == "how much did I spend?")
        #expect(core.quickAskTarget(for: "@FinanceAssistant hi").bot?.name == "finance-assistant")
    }

    @Test func aQuickAskIsSavedInThatBotsBotChat() async throws {
        let fake = try FakeHermes(named: "botchat-stream")
        let core = TestCore.make(fake)
        await core.start()

        let chat = try #require(try await core.quickAsk("@coder What's on my calendar?"))

        #expect(chat.isBotChat)
        #expect(chat.bot == "coder")
        #expect(fake.sent("prompt.submit").first?["params"]["session_id"] == "sess-coder-chat")
        #expect(await eventually { chat.liveText == "You have two meet" })
        #expect(core.lastUsedBot == "coder")
    }
}

@MainActor
struct BotEditorTests {
    @Test func creatingABotSetsItsPersonaModelAndLook() async throws {
        let fake = try FakeHermes(named: "bot-editor")
        let core = TestCore.make(fake)
        await core.start()

        let bot = try await core.createBot(
            BotDraft(title: "Travel", description: "Trips, bookings & itineraries", persona: "Organised and a little adventurous.", model: "claude-opus-5-5", provider: "anthropic", color: "#f97316"))

        #expect(bot.name == "travel")
        #expect(bot.title == "Travel")
        #expect(bot.color == BotColor(hex: "#f97316"))
        let look = try #require(fake.sent("profiles.configure").first)
        #expect(look["params"]["ui_meta"]["hermes-bots"]["title"] == "Travel")
        #expect(look["params"]["ui_meta"]["hermes-bots"]["color"] == "#f97316")
    }

    @Test func editingABotKeepsMetadataItDoesntKnow() async throws {
        let fake = try FakeHermes(named: "bot-editor")
        let core = TestCore.make(fake)
        await core.start()
        let finance = try #require(core.bot(named: "finance-assistant"))
        var draft = await core.draft(for: finance)
        #expect(draft.persona == "You manage my money.")

        draft.title = "Ledger"
        draft.description = "Money, budgets and the budget app"
        draft.color = "#22c55e"
        try await core.saveBot(draft)

        let write = try #require(fake.sent("profiles.configure").last)
        let meta = write["params"]["ui_meta"]["hermes-bots"]
        #expect(meta["title"] == "Ledger")
        #expect(meta["color"] == "#22c55e")
        // Keys written by the official app survive.
        #expect(meta["sectionId"] == "money")
        #expect(meta["pinned"] == true)
        #expect(meta["created"] == 1788539709939)
        #expect(write["params"]["ui_meta_expected_revisions"]["hermes-bots"] == 1)
        #expect(fake.unexpected.isEmpty)
    }

    @Test func deletingABotRemovesIt() async throws {
        let fake = try FakeHermes(named: "bot-editor")
        let core = TestCore.make(fake)
        await core.start()

        try await core.deleteBot("devops")

        #expect(core.bot(named: "devops") == nil)
        #expect(fake.httpRequests.contains { $0.method == "DELETE" && $0.url.path == "/api/profiles/devops" })
        await #expect(throws: HermesError.self) { try await core.deleteBot("default") }
    }
}

@MainActor
struct RemoteTests {
    let server = URL(string: "https://hermes.example.com")!

    @Test func addingARemoteServerShowsWhichLoginsItAccepts() async throws {
        let fake = try FakeHermes(named: "remote-token")
        let core = TestCore.make(fake)

        let status = try await core.probeRemote(server)

        #expect(status.supportsBrowserSignIn)
        #expect(status.acceptsToken)
        #expect(status.version == "0.23.0")
    }

    @Test func aCurrentHermesBehindHermesServeIsNotCalledOld() async throws {
        let fake = try FakeHermes(named: "remote-serve")
        let core = TestCore.make(fake)

        await core.addRemoteConnection(name: "Mac mini", url: server, token: "tok-123")

        #expect(core.status == .connected)
        #expect(core.notice == nil)

        // Its session.create knows `idempotency_key`, not the gateway's `request_id`.
        _ = try? await core.newSideChat(for: "coder")
        let create = try #require(fake.sent("session.create").last)
        #expect(create["params"]["idempotency_key"].string != nil)
        #expect(create["params"]["request_id"].isNull)
        #expect(!core.features.steer)  // it can't steer; follow-ups go as new messages

        let chat = try await core.openBotChat(for: "coder")
        await core.send("hello", to: chat)
        let submit = try #require(fake.sent("prompt.submit").last)
        #expect(submit["params"].object.map { Set($0.keys) } == ["session_id", "profile", "text"])
    }

    @Test func aTokenConnectionListsBotsAndOpensBotChatScopedByProfile() async throws {
        let fake = try FakeHermes(named: "remote-token")
        let credentials = InMemoryCredentialStore()
        let core = TestCore.make(fake, credentials: credentials)

        await core.addRemoteConnection(name: "Home Server", url: server, token: "tok-123")

        #expect(core.status == .connected)
        #expect(core.bots.count == 6)
        #expect(credentials.load(for: "https://hermes.example.com") == .token("tok-123"))
        let dial = try #require(fake.dials.first)
        #expect(dial.url.absoluteString == "wss://hermes.example.com/api/ws")
        #expect(dial.protocols.contains("hermes-gateway-ticket.wsticket-1"))
        let ticket = try #require(fake.httpRequests.first { $0.url.path == "/api/auth/ws-ticket" })
        #expect(ticket.headers["Authorization"] == "Bearer tok-123")

        let chat = try await core.openBotChat(for: "coder")
        #expect(chat.items.first?.text == "Hello from the home server.")
        let history = try #require(fake.httpRequests.first { $0.url.path.hasSuffix("/messages") })
        #expect(history.url.query?.contains("profile=coder") == true)
        #expect(fake.unexpected.isEmpty)
    }

    @Test func connectionsCanBeSavedSwitchedRenamedAndRemoved() async throws {
        let fake = try FakeHermes(named: "remote-token")
        let credentials = InMemoryCredentialStore()
        let core = TestCore.make(fake, credentials: credentials)
        let local = try #require(core.registry.active)

        let remote = await core.addRemoteConnection(name: "Home Server", url: server, token: "tok-123")
        #expect(core.registry.connections.count == 2)
        #expect(core.registry.activeID == remote.id)

        core.renameConnection(remote.id, to: "VPS")
        #expect(core.registry.connections.last?.name == "VPS")

        await core.removeConnection(remote.id)
        #expect(core.registry.connections.map(\.id) == [local.id])
        #expect(core.registry.activeID == local.id)
        #expect(credentials.load(for: "https://hermes.example.com") == nil)
    }

    @Test func browserSignInSwapsTheCodeAndRefreshesAnExpiredToken() async throws {
        let fake = try FakeHermes(named: "remote-signin")
        let credentials = InMemoryCredentialStore()
        let core = TestCore.make(fake, credentials: credentials)
        let receiver = FakeLoopback()
        let opened = OpenedURL()

        try await core.addRemoteConnection(name: "Home", url: server, receiver: receiver) { url in
            opened.set(url)
            receiver.remember(state: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? "")
        }

        let authorize = try #require(opened.value)
        let query = URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(authorize.path == "/auth/native/authorize")
        #expect(query.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(query.first { $0.name == "redirect_uri" }?.value == "http://127.0.0.1:53123/callback")
        let exchange = try #require(fake.httpRequests.first { $0.url.path == "/auth/native/token" })
        #expect(exchange.bodyJSON?["code_verifier"].string?.count == 43)
        // The first access token had already expired: it was refreshed before minting the WebSocket ticket.
        #expect(credentials.load(for: "https://hermes.example.com") == .oauth(access: "access-2", refresh: "refresh-2", expiresAt: 4102444800, provider: "basic"))
        #expect(fake.httpRequests.first { $0.url.path == "/api/auth/ws-ticket" }?.headers["Authorization"] == "Bearer access-2")
        #expect(core.status == .connected)
    }

    @Test func aLoginThatCantBeRefreshedAsksToSignInAgain() async throws {
        let fake = try FakeHermes(named: "remote-expired")
        let credentials = InMemoryCredentialStore()
        credentials.save(.oauth(access: "old", refresh: "stale", expiresAt: 1000, provider: "basic"), for: "https://hermes.example.com")
        let core = TestCore.make(fake, credentials: credentials, remote: server)

        await core.start()

        guard case .needsSignIn = core.status else {
            Issue.record("expected needsSignIn, got \(core.status)")
            return
        }
        #expect(credentials.load(for: "https://hermes.example.com") == nil)
    }
}

final class FakeLoopback: LoopbackReceiver, @unchecked Sendable {
    private let lock = NSLock()
    private var state: String?
    func start() async throws -> URL { URL(string: "http://127.0.0.1:53123/callback")! }
    func callback() async throws -> URL {
        // The browser comes back with the state Agora sent.
        URL(string: "http://127.0.0.1:53123/callback?code=gw-code-1&state=\(lock.withLock { state } ?? "")")!
    }
    func stop() {}
    func remember(state: String) { lock.withLock { self.state = state } }
}

final class OpenedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    var value: URL? { lock.withLock { url } }
    func set(_ u: URL) { lock.withLock { url = u } }
}

@MainActor
struct PersonaTests {
    @Test func aPersonaIsDraftedFromTheNameAndPurposeKeepingWhatsAlreadyThere() async throws {
        let fake = try FakeHermes(named: "persona")
        let core = TestCore.make(fake)
        await core.start()

        let persona = try await core.draftPersona(name: "Coder ", purpose: "Writes and reviews code", current: "Always run the tests.", bot: "coder")

        #expect(persona == "## Who you are\nYou are Coder.")
        let sent = try #require(fake.sent("llm.oneshot").first?["params"])
        #expect(sent["input"].string == "Bot name: Coder\nPurpose: Writes and reviews code\n\nCurrent persona or notes (keep what they ask for):\nAlways run the tests.")
        #expect(sent["instructions"].string?.contains("SOUL.md") == true)
        #expect(sent["session_id"] == .null)  // stateless: no chat is touched
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aNewBotsPersonaIsWrittenUnderTheDefaultBotAndAnEmptyAnswerIsAnError() async throws {
        let fake = try FakeHermes(named: "persona")
        let core = TestCore.make(fake)
        await core.start()
        _ = try await core.draftPersona(name: "Coder", purpose: "", current: "", bot: "coder")  // uses the first reply

        await #expect(throws: HermesError.self) {
            try await core.draftPersona(name: "Video Editor", purpose: "Promo videos", current: "", bot: nil)
        }
        #expect(fake.sent("llm.oneshot").last?["params"]["profile"] == "default")
        #expect(fake.sent("llm.oneshot").last?["params"]["input"].string?.contains("Current persona") == false)
    }
}
