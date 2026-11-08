import AgoraCore
import AppKit
import SwiftUI

/// The floating Quick Ask panel, opened from any app with the global hotkey.
@MainActor
final class QuickAskController {
    private weak var app: AppModel?
    private var panel: QuickAskPanel?

    init(app: AppModel) {
        self.app = app
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard let app else { return }
        if panel == nil {
            let p = QuickAskPanel(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 120), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.standardWindowButton(.closeButton)?.isHidden = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .clear
            p.isOpaque = false
            let host = NSHostingView(
                rootView: QuickAskView(onClose: { [weak self] in self?.close() }, onOpenChat: { [weak self] bot in
                    self?.close()
                    self?.app?.show(bot: bot, session: nil)
                })
                .environment(app.core)
                .environment(app))
            host.sizingOptions = [.preferredContentSize]
            p.contentView = host
            panel = p
        }
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - 310, y: frame.maxY - frame.height * 0.18))
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .quickAskOpened, object: nil)
    }

    func close() {
        panel?.orderOut(nil)
    }
}

extension Notification.Name {
    static let quickAskOpened = Notification.Name("agora.quickAskOpened")
}

final class QuickAskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct QuickAskView: View {
    @Environment(AgoraCore.self) private var core
    let onClose: () -> Void
    let onOpenChat: (String) -> Void

    @State private var text = ""
    @State private var conversation: Conversation?
    @State private var askedBot: String?
    @State private var replyAnchor = 0
    @State private var error: String?
    @FocusState private var focused: Bool

    var target: Bot? { core.quickAskTarget(for: text).bot ?? askedBot.flatMap { core.bot(named: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let bot = target {
                    BotAvatar(bot: bot, size: 26)
                }
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19))
                    .focused($focused)
                    .onSubmit(ask)
                if conversation?.isRunning == true {
                    ProgressView().controlSize(.small)
                }
                Text("⏎").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if let conversation, let reply = reply(in: conversation) {
                Divider()
                ScrollView {
                    MarkdownView(text: reply).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let conversation, let bot = core.bot(named: conversation.bot) {
                ForEach(conversation.prompts) { prompt in
                    PromptCard(prompt: prompt, bot: bot).padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 6) {
                ForEach(core.bots.prefix(6)) { bot in
                    Button {
                        text = "@\(bot.name) " + core.quickAskTarget(for: text).question
                        focused = true
                    } label: {
                        HStack(spacing: 4) {
                            BotAvatar(bot: bot, size: 14)
                            Text(bot.title).font(.system(size: 11)).lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(target?.name == bot.name ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let bot = conversation?.bot ?? target?.name {
                    Button("Open in Bot Chat ⌘↩") { onOpenChat(bot) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .keyboardShortcut(.return, modifiers: .command)
                }
                Text("esc").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline))
        .onExitCommand(perform: onClose)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .quickAskOpened)) { _ in
            focused = true
            error = nil
        }
    }

    var placeholder: String {
        if let bot = target { return "Ask \(bot.title)…  (@name to switch)" }
        return "Connect to Hermes first"
    }

    /// The answer to the question asked from this panel: the live reply, then the finished one.
    func reply(in c: Conversation) -> String? {
        let after = c.items.dropFirst(replyAnchor)
        let text = after.filter { $0.kind == .assistant }.map(\.text).joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    func ask() {
        let question = text
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        error = nil
        Task {
            do {
                let (bot, _) = core.quickAskTarget(for: question)
                if let bot { askedBot = bot.name }
                let chat = try await core.openBotChat(for: bot?.name ?? "")
                replyAnchor = chat.items.count
                conversation = chat
                text = ""
                try await core.quickAsk(question)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
