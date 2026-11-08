import Foundation
import Testing

@testable import AgoraCore

let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

@MainActor
struct ToolActivityTests {
    @Test func toolActivityShowsAsCompactRowsThatFinish() async throws {
        let fake = try FakeHermes(named: "tools")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")

        await core.send("Find the weather and draw it", to: chat)

        #expect(await eventually { chat.items.compactMap(\.tool).first?.progress == "Reading 2 results" })
        var search = try #require(chat.items.compactMap(\.tool).first)
        #expect(search.name == "web_search")
        #expect(search.context == "weather Jakarta today")
        #expect(search.state == .running)
        #expect(search.arguments.contains("\"query\""))

        fake.pushEvent(
            "tool.complete", session: "sess-coder-chat", seq: 6, generation: 2,
            payload: ["tool_id": "call_ws", "name": "web_search", "duration_s": 1.2, "summary": "2 results", "is_error": false])
        fake.pushEvent(
            "tool.start", session: "sess-coder-chat", seq: 7, generation: 2,
            payload: ["tool_id": "call_img", "name": "image_generate", "context": "a sunny skyline"])
        fake.pushEvent(
            "tool.complete", session: "sess-coder-chat", seq: 8, generation: 2,
            payload: [
                "tool_id": "call_img", "name": "image_generate", "summary": "1 image",
                "image_path": "/Users/me/.hermes/profiles/coder/cache/images/gen_1.png",
            ])
        fake.pushEvent("message.complete", session: "sess-coder-chat", seq: 9, generation: 2, payload: ["text": "Here you go.", "status": "complete"])

        #expect(await eventually { !chat.isRunning })
        search = try #require(chat.items.compactMap(\.tool).first)
        #expect(search.state == .done)
        #expect(search.result == "2 results")
        #expect(search.duration == 1.2)
        #expect(chat.items.compactMap(\.tool).map(\.name) == ["web_search", "image_generate"])
        #expect(chat.items.last?.text == "Here you go.")

        // The image the Bot produced is shown inline, fetched as bytes through REST.
        let produced = try #require(chat.items.flatMap(\.images).first)
        #expect(produced == .hostPath("/Users/me/.hermes/profiles/coder/cache/images/gen_1.png"))
        let bytes = await core.imageData(produced, in: chat)
        #expect(bytes == tinyPNG)
    }

    @Test func attachedImagesAreUploadedAsBytesNotPaths() async throws {
        let fake = try FakeHermes(named: "tools")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")

        await core.send("Draw a cat", images: [ImageAttachment(data: tinyPNG, filename: "cat.png")], to: chat)

        let upload = try #require(fake.sent("image.attach_bytes").first)
        #expect(upload["params"]["content_base64"].string == tinyPNG.base64EncodedString())
        let submit = try #require(fake.sent("prompt.submit").first)
        #expect(submit["params"]["attachments"][0]["path"] == "/Users/me/.hermes/profiles/coder/cache/images/upload_ab12.png")
        #expect(chat.items.first?.images == [.data(tinyPNG, mime: "image/png")])
        #expect(fake.unexpected.isEmpty)
    }
}

@MainActor
struct ChatControlTests {
    @Test func sendingWhileTheBotWorksSteersInsteadOfQueueing() async throws {
        let fake = try FakeHermes(named: "controls")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")
        await core.send("Write a long essay", to: chat)
        #expect(await eventually { chat.liveText == "Once upon" })

        await core.send("Make it about cats", to: chat)

        #expect(fake.sent("prompt.submit").count == 1)
        #expect(fake.sent("session.steer").first?["params"]["execution_generation"] == 2)
        #expect(chat.items.contains { $0.kind == .user && $0.text == "Make it about cats" })
    }

    @Test func stopInterruptsTheReplyBeingGenerated() async throws {
        let fake = try FakeHermes(named: "controls")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")
        await core.send("Write a long essay", to: chat)
        #expect(await eventually { chat.isRunning && chat.liveText == "Once upon" })

        await core.stop(chat)

        #expect(await eventually { !chat.isRunning })
        #expect(fake.sent("session.interrupt").first?["params"]["execution_generation"] == 2)
        #expect(chat.items.contains { $0.kind == .assistant && $0.text == "Once upon a time" })
        #expect(chat.items.last?.kind == .notice)
    }

    @Test func condenseCompactsTheBotChatInsteadOfStartingOver() async throws {
        let fake = try FakeHermes(named: "controls")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")
        await core.send("Write a long essay", to: chat)
        #expect(await eventually { chat.liveText == "Once upon" })
        await core.stop(chat)
        #expect(await eventually { !chat.isRunning && chat.revision == 6 })

        await core.condense(chat)

        let compress = try #require(fake.sent("session.mutate").first)
        #expect(compress["params"]["operation"] == "compress")
        #expect(fake.sent("session.create").isEmpty)
        #expect(chat.items.map(\.text) == ["Earlier conversation condensed", "Once upon a time"])
        #expect(chat.title == "Bot Chat")
        #expect(fake.unexpected.isEmpty)
    }
}
