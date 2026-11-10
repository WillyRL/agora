import AgoraCore
import SwiftUI

/// A kanban card and what it asks of you: its status, why it's blocked, its comments, and a box to
/// answer it. Agora handles a card but doesn't run the board (docs/adr/0002).
struct KanbanCardPanel: View {
    @Environment(AgoraCore.self) private var core
    let taskID: String
    /// The Bot whose chat this is (REST calls are scoped to a profile).
    let bot: String
    var boardHint: String? = nil
    /// Show the card's comments (the sheet does; the task chat shows only the newest).
    var allComments = false
    /// Called after Reload or an action, so the task's chat can reload too.
    var onChange: (() async -> Void)? = nil

    @State private var card: KanbanCard?
    @State private var error: String?
    @State private var busy = false
    @State private var reply = ""
    @State private var showCard: KanbanCardTarget?

    /// Under a task's chat the panel stays small: long text is cut short and the full card opens in a sheet.
    var compact: Bool { !allComments }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let card {
                waiting(card)
                comments(card)
                if !card.isFinished { composer(card) }
            } else if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error, card != nil {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: taskID) { await load() }
        .sheet(item: $showCard) { KanbanCardSheet(target: $0) }
    }

    var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.split.3x1").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("KANBAN").font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
            Text(taskID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if let card { Self.statusPill(card.status) }
            Spacer(minLength: 8)
            if compact, let card {
                Button("Show Card…") {
                    showCard = KanbanCardTarget(taskID: card.id, bot: bot, board: card.board, title: card.title)
                }
                .controlSize(.small)
                .help("The whole card: every comment, in full")
            }
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await run { _ in
                        await onChange?()
                        return nil
                    } }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Agora doesn't follow kanban cards live. Reload to see where this one is.")
            }
        }
    }

    @ViewBuilder
    func waiting(_ card: KanbanCard) -> some View {
        if card.isBlocked {
            callout(color: .orange, title: "Waiting for you", text: card.blockReason ?? "The card is blocked. Answer below, then send it back to work.")
        } else if card.isWaitingForReview {
            callout(color: .blue, title: "Ready for your review", text: card.summary ?? card.result ?? "The work is done and waits for you to accept it.")
        } else if card.isFinished, let done = card.summary ?? card.result {
            callout(color: .green, title: "Done", text: done)
        }
    }

    func callout(color: Color, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(color)
            if compact {
                Text(Self.preview(text)).font(.system(size: 12.5)).lineLimit(3).textSelection(.enabled)
            } else {
                MarkdownView(text: text).font(.system(size: 12.5)).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
    }

    @ViewBuilder
    func comments(_ card: KanbanCard) -> some View {
        let shown = compact ? Array(card.comments.suffix(1)) : card.comments
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if compact, card.comments.count > shown.count {
                    Text(card.comments.count - shown.count == 1 ? "1 earlier comment" : "\(card.comments.count - shown.count) earlier comments").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(shown) { c in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(author(c.author)).font(.system(size: 11.5, weight: .semibold))
                            if let date = c.date {
                                Text(date, format: .relative(presentation: .named)).font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                        }
                        if compact {
                            Text(Self.preview(c.body)).font(.system(size: 12.5)).lineLimit(2).foregroundStyle(.secondary)
                        } else {
                            MarkdownView(text: c.body).font(.system(size: 12.5)).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    func author(_ name: String) -> String {
        if name.hasPrefix("you") { return "You" }
        return core.bot(named: name)?.title ?? name
    }

    func composer(_ card: KanbanCard) -> some View {
        let empty = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .trailing, spacing: 8) {
            TextField(card.isBlocked ? "Answer the card…" : "Comment on the card…", text: $reply, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.contentBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            HStack(spacing: 8) {
                Text("The Bot reads comments the next time it works on the card.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if card.isWaitingForReview {
                    Button("Approve") {
                        Task { await run { try await core.approveKanbanCard($0, bot: bot) } }
                    }
                    .help("Accept the work: the card moves to Done")
                }
                if card.isBlocked {
                    Button(empty ? "Unblock" : "Comment & Unblock") {
                        let text = reply
                        Task { await run { c in
                            let commented = empty ? c : try await core.commentOnKanbanCard(c, bot: bot, text: text)
                            return try await core.unblockKanbanCard(commented, bot: bot)
                        } }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send the card back to work")
                } else {
                    Button("Comment") {
                        let text = reply
                        Task { await run { try await core.commentOnKanbanCard($0, bot: bot, text: text) } }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(empty)
                }
            }
            .disabled(busy)
        }
    }

    func load() async {
        busy = true
        defer { busy = false }
        do {
            card = try await core.kanbanCard(taskID, bot: bot, board: card?.board ?? boardHint)
            error = nil
        } catch {
            self.error = "Couldn't read the card: \(error.localizedDescription)"
        }
    }

    /// Runs an action on the card, then shows the card as Hermes has it now.
    func run(_ action: (KanbanCard) async throws -> KanbanCard?) async {
        guard let current = card else { return await load() }
        busy = true
        do {
            if let updated = try await action(current) {
                card = updated
                reply = ""
                busy = false
                await onChange?()
            } else {
                busy = false
                await load()
            }
            error = nil
        } catch {
            busy = false
            self.error = error.localizedDescription
        }
    }

    /// Markdown flattened to a line of plain text, for a short preview.
    static func preview(_ markdown: String) -> String {
        markdown.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("|") && !$0.hasPrefix("```") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*- ")) }
            .joined(separator: " · ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    static func statusPill(_ status: String) -> some View {
        let (label, color): (String, Color) = switch status {
        case "running": ("Working", .accentColor)
        case "ready": ("Up next", .secondary)
        case "todo", "triage": ("To do", .secondary)
        case "scheduled": ("Scheduled", .secondary)
        case "blocked": ("Blocked", .orange)
        case "review": ("Ready for review", .blue)
        case "done": ("Done", .green)
        case "archived": ("Archived", .secondary)
        default: (status.capitalized, .secondary)
        }
        return Text(label).pill(color)
    }
}

/// A kanban card in a sheet, opened from a card's news in a Bot Chat.
struct KanbanCardSheet: View {
    let target: KanbanCardTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !target.title.isEmpty {
                HStack {
                    Text(target.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(16)
                Divider()
            }
            ScrollView {
                KanbanCardPanel(taskID: target.taskID, bot: target.bot, boardHint: target.board, allComments: true).padding(16)
            }
        }
        .frame(minWidth: 520, idealWidth: 680, maxWidth: 1000, minHeight: 420, idealHeight: 640, maxHeight: 1000)
    }
}

struct KanbanCardTarget: Identifiable {
    var taskID: String
    var bot: String
    var board: String?
    var title: String
    var id: String { taskID }
}
