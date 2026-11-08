import Foundation
import Testing

@testable import AgoraCore

@MainActor
struct FileTests {
    @Test func aReplyIsSplitIntoTextAndTheFilesTheBotHandsOver() {
        let text = """
            Here's the silver chart.

            ::preview{file="/Users/me/charts/silver_2026-11-07.html"}

            **Summary** and the deck:
            MEDIA:/Users/me/decks/silver.pptx
            `MEDIA:/tmp/chart.png`
            ```
            MEDIA:/not/a/file.txt
            ```
            """
        let parts = MessagePart.split(text)

        #expect(parts.count == 6)
        #expect(parts[0] == .text("Here's the silver chart."))
        #expect(parts[1] == .file(FileAttachment(path: "/Users/me/charts/silver_2026-11-07.html", inline: true)))
        #expect(parts[2] == .text("**Summary** and the deck:"))
        #expect(parts[3] == .file(FileAttachment(path: "/Users/me/decks/silver.pptx", inline: false)))
        #expect(parts[4] == .file(FileAttachment(path: "/tmp/chart.png", inline: false)))
        guard case .text(let code) = parts[5] else { Issue.record("expected the code block as text"); return }
        #expect(code.contains("MEDIA:/not/a/file.txt"))
    }

    @Test func filesAreSortedByWhatTheyAre() {
        #expect(FileAttachment(path: "/a/chart.PNG", inline: false).kind == .image)
        #expect(FileAttachment(path: "/a/page.html", inline: true).kind == .html)
        #expect(FileAttachment(path: "/a/deck.pptx", inline: false).kind == .other)
        #expect(FileAttachment(path: "/a/deck.pptx", inline: false).name == "deck.pptx")
    }

    @Test func plainTextIsLeftAlone() {
        #expect(MessagePart.split("No files here.") == [.text("No files here.")])
        #expect(MessagePart.split("Use MEDIA: lines to send files.") == [.text("Use MEDIA: lines to send files.")])
        #expect(MessagePart.split("MEDIA: lines send files.") == [.text("MEDIA: lines send files.")])
    }

    @Test func aFileIsFetchedFromTheHermesHostUnderTheSavedSession() async throws {
        let fake = try FakeHermes(named: "session-gone")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")

        let data = try await core.fileData("/Users/me/charts/silver.html", in: chat)

        #expect(String(decoding: data, as: UTF8.self).contains("<body>chart</body>"))
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aFileIsStoredInTheChatsWorkspaceAndNamedInTheMessage() async throws {
        let fake = try FakeHermes(named: "send-file")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")
        let csv = ImageAttachment(data: Data("date,price\n2026-11-06,51.94\n".utf8), filename: "my trades.csv")
        let png = ImageAttachment(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]), filename: "chart.png")
        #expect(!csv.isImage)
        #expect(png.isImage)

        let sent = await core.send("What's my average entry?", images: [csv, png], to: chat)

        #expect(sent)
        let mine = try #require(chat.items.last)
        #expect(mine.text == "What's my average entry?")
        #expect(mine.images.count == 1)
        #expect(mine.files == ["/Users/me/.hermes/profiles/coder/workspace/attachments/my_trades.csv"])
        #expect(fake.unexpected.isEmpty)
    }

    @Test func aSentFileShowsAsAFileInHistoryNotAsText() {
        let rows: [JSON] = [
            ["id": 1, "role": "user", "content": "@file:attachments/my_trades.csv\n@file:\"attachments/Q3 report.pdf\"\n\nWhat's my average entry?", "timestamp": 1793908083.59]
        ]
        let item = try? #require(Conversation.items(from: rows).first)
        #expect(item?.text == "What's my average entry?")
        #expect(item?.files == ["attachments/my_trades.csv", "attachments/Q3 report.pdf"])
    }

    @Test func aFileThatIsTooBigIsNotSent() async throws {
        let fake = try FakeHermes(named: "send-file")
        let core = TestCore.make(fake)
        await core.start()
        let chat = try await core.openBotChat(for: "coder")
        let huge = ImageAttachment(data: Data(count: ImageAttachment.maxBytes + 1), filename: "huge.zip")

        let sent = await core.send("here", images: [huge], to: chat)

        #expect(!sent)
        #expect(core.notice?.contains("too big") == true)
        #expect(fake.sent("file.attach").isEmpty)
    }
}
