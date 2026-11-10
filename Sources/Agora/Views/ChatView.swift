import AgoraCore
import SwiftUI

/// A Bot's Bot Chat or one of its Side Chats.
struct ChatView: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    let bot: Bot
    /// nil = the Bot Chat.
    let sessionID: String?

    @State private var conversation: Conversation?
    @State private var loadError: String?
    @State private var draft = ""
    @State private var images: [ImageAttachment] = []
    @State private var loadAttempt = 0

    var body: some View {
        VStack(spacing: 0) {
            if !app.focusMode {
                ChatHeader(bot: bot, conversation: conversation)
                Divider()
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let conversation {
                        // A fresh scroll view per chat, so one chat's scroll offset never carries over to the next.
                        MessageList(conversation: conversation, bot: bot).id(conversation.id)
                        if conversation.isKanbanTask {
                            KanbanTaskFooter(conversation: conversation)
                        } else {
                            BottomArea(conversation: conversation, bot: bot, draft: $draft, images: $images)
                        }
                    } else if let loadError {
                        ContentUnavailableView {
                            Label("Couldn't open the chat", systemImage: "exclamationmark.bubble")
                        } description: {
                            Text(loadError)
                        } actions: {
                            Button("Try Again") { loadAttempt += 1 }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                if app.showRoutines {
                    Divider()
                    RoutinesPanel(bot: bot).frame(width: 290)
                }
            }
        }
        .task(id: "\(bot.name)|\(sessionID ?? "")|\(loadAttempt)|\(core.status == .connected)") {
            await load()
        }
    }

    func load() async {
        guard core.status == .connected else { return }
        loadError = nil
        do {
            if let sessionID {
                let title = core.sideChats[bot.name]?.first { $0.id == sessionID }?.title ?? ""
                conversation = try await core.openConversation(bot: bot.name, sessionID: sessionID, title: title)
            } else {
                conversation = try await core.openBotChat(for: bot.name)
            }
            core.markSeen(bot: bot.name)
            app.focusComposer()
        } catch {
            conversation = nil
            loadError = Self.explain(error)
        }
    }
}

extension ChatView {
    /// Hermes's reasons, in words.
    static func explain(_ error: Error) -> String {
        if let e = error as? HermesError, e.rpcReason == "runtime_coordination_required" {
            return "This chat is open in another Hermes process right now, for example Agora on another Mac that connects through hermes serve. Close it there (or wait until its reply finishes), then try again."
        }
        return error.localizedDescription
    }
}

struct ChatHeader: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    let bot: Bot
    let conversation: Conversation?

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(bot: bot, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.map { $0.isBotChat ? bot.title : $0.title.isEmpty ? "Side Chat" : $0.title } ?? bot.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let conversation {
                ChatActions(bot: bot, conversation: conversation)
            }
            Button {
                app.setFocus(true)
            } label: {
                Label("Focus", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Focus (⌘⇧F)")
            .buttonStyle(.bordered)
            Button {
                app.showRoutines.toggle()
            } label: {
                Label("Routines", systemImage: "clock.arrow.circlepath")
            }
            .help("Show \(bot.title)'s Routines")
            .buttonStyle(.bordered)
            .tint(app.showRoutines ? Theme.accent : nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    var subtitle: String {
        guard let conversation else { return bot.description }
        if conversation.isBotChat { return bot.description.isEmpty ? "Bot Chat" : bot.description }
        if conversation.isKanbanTask { return "Kanban task for \(bot.title)" }
        return "Side Chat with \(bot.title)"
    }
}

/// New Side Chat, condense, and Side Chat housekeeping.
struct ChatActions: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    let bot: Bot
    let conversation: Conversation
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false

    var body: some View {
        Menu {
            Button("New Side Chat") { Task { await app.newSideChat(bot: bot.name, carryContext: false) } }
            Button("New Side Chat with Context") { Task { await app.newSideChat(bot: bot.name, carryContext: true) } }
            Button("Reload MCP Tools") { Task { await core.reloadToolsNow(conversation) } }
            Divider()
            if conversation.isBotChat {
                Button("Condense Bot Chat") { Task { await core.condense(conversation) } }
                    .disabled(conversation.isRunning)
            } else {
                Button("Rename…") {
                    newTitle = conversation.title
                    renaming = true
                }
                Button("Archive") { Task { await core.archive(conversation); app.destination = .bot(bot.name) } }
                Button("Delete…", role: .destructive) { confirmDelete = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Chat actions")
        .alert("Rename Side Chat", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") { Task { await core.rename(conversation, to: newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this Side Chat?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    await core.delete(conversation)
                    app.destination = .bot(bot.name)
                }
            }
        } message: {
            Text("Its messages are removed from Hermes. This can't be undone.")
        }
    }
}

struct MessageList: View {
    @Environment(AgoraCore.self) private var core
    let conversation: Conversation
    let bot: Bot
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if conversation.hasMoreHistory {
                    Button {
                        Task { await core.loadOlderHistory(conversation) }
                    } label: {
                        if conversation.loadingHistory { ProgressView().controlSize(.small) } else { Text("Load earlier messages") }
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                    .onAppear { Task { await core.loadOlderHistory(conversation) } }
                }
                if !conversation.isBotChat, conversation.items.isEmpty {
                    Text("Side Chat · \(bot.title) keeps its persona, skills and memory here")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                ForEach(ChatRow.group(conversation.items)) { row in
                    switch row {
                    case .item(let item):
                        ChatItemView(item: item, bot: bot, conversation: conversation).id(item.id)
                    case .tools(let id, let tools):
                        ToolGroupRow(tools: tools).id(id)
                    }
                }
                if conversation.isRunning, conversation.liveText.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(conversation.statusLine ?? "\(bot.title) is thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 40)
                } else if let status = conversation.statusLine {
                    Text(status).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 40)
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        .task {
            // The lazy stack guesses row heights and charts size themselves late, so the first
            // bottom offset can land past the content and show a blank chat. Settle at the bottom again.
            for delay in [0.05, 0.3] {
                try? await Task.sleep(for: .seconds(delay))
                position.scrollTo(edge: .bottom)
            }
        }
    }
}

/// In place of the message box under a kanban card's worker chat. Only the board may run the chat,
/// so you answer the card instead: comment, unblock or approve it.
struct KanbanTaskFooter: View {
    @Environment(AgoraCore.self) private var core
    let conversation: Conversation
    @State private var reloading = false

    /// The card's id, from the brief that opens its chat.
    var taskID: String? {
        for item in conversation.items {
            if case .kanbanBrief(let brief) = item.kind { return brief.taskID }
        }
        return nil
    }

    var body: some View {
        Group {
            if let taskID {
                VStack(alignment: .leading, spacing: 8) {
                    KanbanCardPanel(taskID: taskID, bot: conversation.bot) {
                        await core.reloadKanbanTask(conversation)
                    }
                    Text("Only the kanban board can run this chat, so you answer the card instead.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            } else {
                readOnlyNote
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    /// When the chat doesn't say which card it's for.
    var readOnlyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "rectangle.split.3x1").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("A kanban task's chat").font(.system(size: 12.5, weight: .semibold))
                Text("The kanban board runs this chat, so you can read it here but not reply. To change the task, ask Hermes.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                reloading = true
                Task {
                    await core.reloadKanbanTask(conversation)
                    reloading = false
                }
            } label: {
                if reloading { ProgressView().controlSize(.small) } else { Label("Reload", systemImage: "arrow.clockwise") }
            }
            .disabled(reloading)
            .help("Agora doesn't follow this chat live. Reload to see where the task is.")
        }
    }
}

struct BottomArea: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    let conversation: Conversation
    let bot: Bot
    @Binding var draft: String
    @Binding var images: [ImageAttachment]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(conversation.prompts) { prompt in
                PromptCard(prompt: prompt, bot: bot)
            }
            Composer(
                text: $draft, images: $images, placeholder: conversation.isRunning ? "Steer \(bot.title)…" : "Message \(bot.title)",
                isRunning: conversation.isRunning, focusToken: app.composerFocus,
                onSend: send, onStop: { Task { await core.stop(conversation) } },
                onArrowWhenEmpty: app.focusMode ? { step in app.switchBot(step) } : nil)
            HStack {
                Text(bot.model.isEmpty ? "Default model" : bot.model)
                Spacer()
                if conversation.isRunning { Text("Sending now steers \(bot.title)") }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    func send() {
        let text = draft
        let attached = images
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attached.isEmpty else { return }
        draft = ""
        images = []
        Task { await core.send(text, images: attached, to: conversation) }
    }
}

/// What the message list shows: single items, or a run of tool calls folded into one row.
enum ChatRow: Identifiable {
    case item(ChatItem)
    case tools(id: String, [ToolActivity])

    var id: String {
        switch self {
        case .item(let i): return i.id
        case .tools(let id, _): return id
        }
    }

    /// Folds runs of more than three finished tool calls so a busy turn stays readable.
    static func group(_ items: [ChatItem]) -> [ChatRow] {
        var out: [ChatRow] = []
        var run: [ChatItem] = []
        func flush() {
            if run.count > 3, run.allSatisfy({ $0.tool?.state != .running }) {
                out.append(.tools(id: "group-\(run[0].id)", run.compactMap(\.tool)))
            } else {
                out += run.map(ChatRow.item)
            }
            run = []
        }
        for item in items {
            if item.tool != nil { run.append(item) } else {
                flush()
                out.append(.item(item))
            }
        }
        flush()
        return out
    }
}

struct ToolGroupRow: View {
    let tools: [ToolActivity]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tools.contains { $0.state == .failed } ? "exclamationmark.circle" : "wrench.and.screwdriver")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Used \(tools.count) tools").font(.system(size: 12, weight: .medium))
                    Text(names).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    ToolRow(tool: tool).padding(.leading, 14)
                }
            }
        }
        .padding(.leading, 40)
    }

    var names: String {
        var seen: [String] = []
        for t in tools where !seen.contains(t.name) { seen.append(t.name) }
        return seen.prefix(4).joined(separator: ", ")
    }
}
