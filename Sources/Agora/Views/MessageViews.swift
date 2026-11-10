import AgoraCore
import AppKit
import SwiftUI

/// One row in a chat.
struct ChatItemView: View {
    @Environment(AgoraCore.self) private var core
    let item: ChatItem
    let bot: Bot
    let conversation: Conversation

    var body: some View {
        switch item.kind {
        case .user:
            UserBubble(item: item, conversation: conversation)
        case .assistant:
            BotMessage(bot: bot, name: bot.title, date: item.date) {
                VStack(alignment: .leading, spacing: 8) {
                    if !item.text.isEmpty {
                        MessageContent(text: item.text, conversation: conversation)
                    }
                    ForEach(item.images, id: \.self) { image in
                        ChatImageView(image: image, conversation: conversation)
                    }
                }
            }
        case .botMessage(let from):
            // Hermes signs with the sender's display name; older messages with its Bot name.
            let sender = core.bot(named: from) ?? core.allBots.first { $0.title.caseInsensitiveCompare(from) == .orderedSame }
            BotMessage(bot: sender ?? bot, name: sender?.title ?? from, date: item.date, badge: "handed off to \(bot.title)") {
                IncomingHandoffCard(handoff: Handoff(body: item.text), conversation: conversation)
            }
        case .kanbanUpdate(let update):
            KanbanUpdateCard(update: update, date: item.date, bot: bot.name).padding(.leading, 40)
        case .kanbanBrief(let brief):
            KanbanBriefCard(brief: brief, bot: bot, date: item.date).padding(.leading, 40)
        case .routineResult:
            BotMessage(bot: bot, name: bot.title, date: item.date) {
                RoutineCard(text: item.text)
            }
        case .tool(let tool):
            if let handoff = OutgoingHandoff(tool) {
                OutgoingHandoffRow(handoff: handoff, tool: tool).padding(.leading, 40)
            } else {
                ToolRow(tool: tool, kanban: KanbanAction(tool)).padding(.leading, 40)
            }
        case .notice:
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text(item.text)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.leading, 40)
        }
    }
}

struct UserBubble: View {
    @Environment(AgoraCore.self) private var core
    let item: ChatItem
    let conversation: Conversation

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(item.images, id: \.self) { image in
                    ChatImageView(image: image, conversation: conversation, maxWidth: 260)
                }
                ForEach(item.files, id: \.self) { path in
                    if item.pending || item.failed {
                        FileChip(name: (path as NSString).lastPathComponent)
                    } else {
                        FileCard(file: FileAttachment(path: path, inline: false), conversation: conversation)
                    }
                }
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.accent.opacity(0.13)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.failed {
                    HStack(spacing: 8) {
                        Label("Not sent", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        Button("Retry") { Task { await core.resend(item, in: conversation) } }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                } else if item.pending {
                    Text("Sending…").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct BotMessage<Content: View>: View {
    let bot: Bot
    let name: String
    let date: Date?
    var badge: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BotAvatar(bot: bot, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    if let badge {
                        Text(badge).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                    if let date {
                        Text(date, format: .dateTime.hour().minute()).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                content
            }
            Spacer(minLength: 40)
        }
    }
}

struct RoutineCard: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ROUTINE").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent).tracking(0.6)
            MarkdownView(text: text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.18)))
    }
}

/// A compact tool row ("web_search · weather Jakarta today") that expands to its arguments and result.
struct ToolRow: View {
    let tool: ToolActivity
    /// A kanban tool, said in words instead of its name.
    var kanban: KanbanAction? = nil
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    stateIcon
                    if let kanban {
                        Image(systemName: kanban.symbol).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Text(kanban.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if !kanban.detail.isEmpty {
                            Text(kanban.detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(tool.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    if kanban == nil && !tool.context.isEmpty {
                        Text(tool.context).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if let progress = tool.progress {
                        Text(progress).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    if let d = tool.duration {
                        Text(String(format: "%.1fs", d)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !tool.arguments.isEmpty {
                        detail("Input", tool.arguments)
                    }
                    if !tool.result.isEmpty {
                        detail("Result", String(tool.result.prefix(4000)))
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder var stateIcon: some View {
        switch tool.state {
        case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green.opacity(0.8))
        case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red.opacity(0.8))
        }
    }

    func detail(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxHeight: 220)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        }
    }
}

/// An image in a message, loaded through Agora Core (bytes, data URL, or a path on the Hermes host).
struct ChatImageView: View {
    @Environment(AgoraCore.self) private var core
    let image: ChatImage
    let conversation: Conversation
    var maxWidth: CGFloat = 420
    @State private var loaded: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded {
                Image(nsImage: loaded)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: min(maxWidth, loaded.size.width), maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture(count: 2) { open(loaded) }
                    .contextMenu {
                        Button("Copy Image") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([loaded])
                        }
                        Button("Open in Preview") { open(loaded) }
                    }
            } else if failed {
                Label("Image unavailable", systemImage: "photo").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)).frame(width: 200, height: 140).overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: image) {
            if let data = await core.imageData(image, in: conversation), let ns = NSImage(data: data) {
                loaded = ns
            } else {
                failed = true
            }
        }
    }

    func open(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "agora-image-\(UUID().uuidString.prefix(8)).png")
        try? png.write(to: url)
        NSWorkspace.shared.open(url)
    }
}
