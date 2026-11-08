import Foundation
import Testing
@testable import AgoraCore

/// The text Hermes writes for Bot-to-Bot messages (tools/bot_mode_dm.py) and kanban wakes
/// (locales/en.yaml gateway.kanban.wake.*).
@MainActor
struct HandoffTests {
    @Test func aHandoffKeepsWhatTheSenderWroteAndLabelsTheRest() {
        let h = Handoff(body: "[no reply needed] Draft the post.\nTwo paragraphs.\n\nConstraints: Plain words\nReply needed: Markdown")
        #expect(h.noReply)
        #expect(h.message == "Draft the post.\nTwo paragraphs.")
        #expect(h.constraints == "Plain words")
        #expect(h.replyNeeded == "Markdown")
        #expect(Handoff(body: "Just this.") == Handoff(body: "Just this."))
        #expect(Handoff(body: "Just this.").constraints == nil)
    }

    @Test func anOutgoingHandoffSaysWhetherItArrived() {
        func tool(_ args: String, _ result: String, _ state: ToolActivity.State = .done) -> ToolActivity {
            ToolActivity(id: "1", name: "message_agent", context: "", arguments: args, result: result, progress: nil, duration: nil, state: state)
        }
        let sent = OutgoingHandoff(tool(#"{"target": "@writer", "message": "Hi", "expects_reply": false}"#, #"{"status": "queued"}"#))
        #expect(sent?.to == "writer")
        #expect(sent?.status == .delivered)
        #expect(sent?.message.noReply == true)
        let held = OutgoingHandoff(tool(#"{"target": "ops", "message": "Hi"}"#, #"{"error": "Held and not sent. Retry later.", "reason": "x"}"#))
        #expect(held?.status == .failed("Held and not sent."))
        #expect(OutgoingHandoff(tool(#"{"target": "ops", "message": "Hi"}"#, "", .running))?.status == .sending)
        #expect(OutgoingHandoff(ToolActivity(id: "2", name: "terminal", context: "", arguments: "{}", result: "", progress: nil, duration: nil, state: .done)) == nil)
    }

    @Test func aKanbanWakeBecomesAnUpdateWithoutTheBotsInstructions() throws {
        let text = """
            [kanban] Task t_3906c4a2 completed.
            Title: Cut the promo
            Assignee: @video-editor
            Board: launch

            Check the result or decide the next step.
            Result: Files in media/promo
            This is an automatic task-status notification, not a request to decompose the task again.
            """
        let u = try #require(KanbanUpdate(text: text))
        #expect(u.taskID == "t_3906c4a2")
        #expect(u.status == .done)
        #expect(u.title == "Cut the promo")
        #expect(u.assignee == "video-editor")
        #expect(u.board == "launch")
        #expect(u.result == "Files in media/promo")
        #expect(KanbanUpdate(text: "[kanban] Task t_1 handed off for review; the implementation is done.")?.status == .review)
        #expect(KanbanUpdate(text: "[kanban] Task t_1 gave up (retries exhausted), blocked; needs attention.")?.status == .failed)
        #expect(KanbanUpdate(text: "Hello [kanban] Task t_1 completed.") == nil)
    }

    @Test func storedKanbanWakesAndHandoffsGetTheirOwnKind() {
        let rows: [JSON] = [
            ["id": 1, "role": "user", "content": "[kanban] Task t_1 blocked; needs attention.\nTitle: X", "display_kind": "internal_notification", "timestamp": 1],
            ["id": 2, "role": "user", "content": "Message from 🤖 Hermes (@default): Do it", "timestamp": 2],
        ]
        let items = Conversation.items(from: rows)
        guard case .kanbanUpdate(let u) = items.first?.kind else { Issue.record("not a kanban update"); return }
        #expect(u.status == .blocked)
        #expect(items.last?.kind == .botMessage(from: "Hermes"))
    }

    @Test func kanbanToolsReadAsWords() {
        let create = ToolActivity(id: "1", name: "kanban_create", context: "", arguments: #"{"title": "Cut it", "assignee": "video-editor"}"#,
                                  result: #"{"ok": true, "task_id": "t_9"}"#, progress: nil, duration: nil, state: .done)
        #expect(KanbanAction(create)?.title == "Created card “Cut it” for @video-editor")
        #expect(KanbanAction(create)?.detail == "t_9")
    }
}

@MainActor
struct KanbanBriefTests {
    static let brief = """
        Some preloaded skill text.

        # Kanban task t_3906c4a2: Agora promo video

        Assignee: video-editor
        Status:   running
        Workspace: dir @ /Users/w/projects/agora-launch
        Max runtime: 10800s

        ## Body
        Promo video for Agora.

        ## Rules
        - Real footage only.

        work kanban task t_3906c4a2
        """

    @Test func theBriefBecomesACardWithItsFieldsAndSections() throws {
        let b = try #require(KanbanBrief(text: Self.brief))
        #expect(b.taskID == "t_3906c4a2")
        #expect(b.title == "Agora promo video")
        #expect(b.field("Status") == "running")
        #expect(b.field("Workspace") == "dir @ /Users/w/projects/agora-launch")
        #expect(b.details.hasPrefix("## Body\nPromo video for Agora."))
        #expect(b.details.hasSuffix("- Real footage only."))
        #expect(KanbanBrief(text: "work kanban task t_1")?.taskID == "t_1")
        #expect(KanbanBrief(text: "Please work kanban task t_1 now") == nil)
    }

    @Test func aBotsMessageStoredAsANotificationIsStillAHandoff() {
        let rows: [JSON] = [
            ["id": 1, "role": "user", "content": "Message from 🤖 hermes (@hermes): Brief you", "display_kind": "internal_notification", "timestamp": 1],
            ["id": 2, "role": "user", "content": .string(Self.brief), "timestamp": 2],
        ]
        let items = Conversation.items(from: rows)
        #expect(items.first?.kind == .botMessage(from: "hermes"))
        guard case .kanbanBrief = items.last?.kind else { Issue.record("not a brief"); return }
    }
}
