import AgoraCore
import SwiftUI

/// A message another Bot handed this one: what they asked, and what they need back.
struct IncomingHandoffCard: View {
    let handoff: Handoff
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageContent(text: handoff.message, conversation: conversation)
            HandoffFields(handoff: handoff)
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent.opacity(0.45)).frame(width: 3)
        }
    }
}

/// "Constraints", "Reply needed" and "No reply needed", under a handoff.
struct HandoffFields: View {
    let handoff: Handoff

    var body: some View {
        if handoff.constraints != nil || handoff.replyNeeded != nil || handoff.noReply {
            VStack(alignment: .leading, spacing: 4) {
                if let c = handoff.constraints { field("Constraints", c) }
                if let r = handoff.replyNeeded { field("Reply needed", r) }
                if handoff.noReply {
                    Label("No reply needed", systemImage: "bell.slash")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    func field(_ name: String, _ value: String) -> some View {
        (Text(name + "  ").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            + Text(value).font(.system(size: 12)))
            .textSelection(.enabled)
    }
}

/// This Bot handing work to another one (`message_agent`): who, what, and whether it got there.
struct OutgoingHandoffRow: View {
    @Environment(AgoraCore.self) private var core
    let handoff: OutgoingHandoff
    let tool: ToolActivity
    @State private var expanded = false

    var body: some View {
        let target = core.bot(named: handoff.to) ?? core.allBots.first { $0.title.caseInsensitiveCompare(handoff.to) == .orderedSame }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                Text("Handed off to").font(.system(size: 12)).foregroundStyle(.secondary)
                if let target { BotAvatar(bot: target, size: 16) }
                Text(target?.title ?? "@" + handoff.to).font(.system(size: 12, weight: .semibold))
                status
                Spacer(minLength: 0)
            }
            if !handoff.message.message.isEmpty {
                Text(handoff.message.message)
                    .font(.system(size: 12.5))
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                    .onTapGesture { expanded.toggle() }
            }
            HandoffFields(handoff: handoff.message)
            if case .failed(let why) = handoff.status {
                Text(why).font(.system(size: 11.5)).foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.15)))
    }

    @ViewBuilder var status: some View {
        switch handoff.status {
        case .sending: HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Sending…") }.pill(.secondary)
        case .delivered: Label("Delivered", systemImage: "checkmark").pill(.green)
        case .unconfirmed: Label("Not confirmed", systemImage: "questionmark").pill(.orange)
        case .cancelled: Label("Cancelled", systemImage: "xmark").pill(.secondary)
        case .failed: Label("Not delivered", systemImage: "exclamationmark.triangle.fill").pill(.red)
        }
    }
}

/// Hermes's news about a kanban task this chat created.
struct KanbanUpdateCard: View {
    @Environment(AgoraCore.self) private var core
    let update: KanbanUpdate
    let date: Date?
    /// The Bot whose chat shows the update.
    var bot: String = "default"
    @State private var open: KanbanCardTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.3x1").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("KANBAN").font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
                Text(update.taskID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                statusPill
                Spacer(minLength: 0)
                if let date {
                    Text(date, format: .dateTime.hour().minute()).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if !update.title.isEmpty {
                Text(update.title).font(.system(size: 13.5, weight: .semibold)).textSelection(.enabled)
            }
            HStack(spacing: 5) {
                if !update.assignee.isEmpty {
                    let bot = core.bot(named: update.assignee)
                    if let bot { BotAvatar(bot: bot, size: 16) }
                    Text(bot?.title ?? "@" + update.assignee).font(.system(size: 12))
                }
                if !update.board.isEmpty {
                    Text("· \(update.board) board").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let result = update.result {
                Text(result).font(.system(size: 12.5)).textSelection(.enabled)
            }
            if let feedback = update.reviewFeedback {
                (Text("Review  ").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) + Text(feedback).font(.system(size: 12.5)))
                    .textSelection(.enabled)
            }
            Button(update.status == .blocked || update.status == .review ? "Answer the Card…" : "Open Card…") {
                open = KanbanCardTarget(taskID: update.taskID, bot: bot, board: update.board.isEmpty ? nil : update.board, title: update.title)
            }
            .controlSize(.small)
            .help("See the card's status and comments, and comment, unblock or approve it")
        }
        .sheet(item: $open) { KanbanCardSheet(target: $0) }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(color).frame(width: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    var color: Color {
        switch update.status {
        case .done: .green
        case .review: .blue
        case .changesRequested, .blocked: .orange
        case .retrying: .yellow
        case .failed: .red
        case .other: .secondary
        }
    }

    var statusPill: some View {
        let label: String = switch update.status {
        case .done: "Done"
        case .review: "Ready for review"
        case .changesRequested: "Changes requested"
        case .blocked: "Blocked"
        case .retrying: "Retrying"
        case .failed: "Gave up"
        case .other: update.statusText.prefix(1).uppercased() + update.statusText.dropFirst()
        }
        return Text(label).pill(color)
    }
}

/// The task a kanban card gave this Bot, at the top of the card's chat. The full brief folds away.
struct KanbanBriefCard: View {
    let brief: KanbanBrief
    let bot: Bot
    let date: Date?
    @State private var expanded = false

    /// The fields worth a glance; the rest is in the brief.
    static let shown = ["Workspace", "Max runtime", "Branch"]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.3x1").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("KANBAN").font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
                Text(brief.taskID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Task for \(bot.title)").pill(Theme.accent)
                Spacer(minLength: 0)
                if let date {
                    Text(date, format: .dateTime.hour().minute()).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if !brief.title.isEmpty {
                Text(brief.title).font(.system(size: 13.5, weight: .semibold)).textSelection(.enabled)
            }
            ForEach(brief.fields.filter { Self.shown.contains($0.name) }, id: \.name) { field in
                (Text(field.name + "  ").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    + Text(field.value).font(.system(size: 12)))
                    .textSelection(.enabled)
            }
            if !brief.details.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(expanded ? "Hide brief" : "Show brief")
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded { MarkdownView(text: brief.details) }
            }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(Theme.accent).frame(width: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}

extension View {
    /// A small coloured status label.
    func pill(_ color: Color) -> some View {
        font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
