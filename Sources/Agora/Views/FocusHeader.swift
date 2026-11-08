import AgoraCore
import SwiftUI

/// Focus mode's header: a row of Bots with the current one in the middle, its name and purpose,
/// and tabs for its Bot Chat and newest Side Chats. ← → (or the chevrons) move between Bots.
struct FocusHeader: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    let bot: Bot

    static let slot: CGFloat = 76
    static let railWidth: CGFloat = 380
    /// Side Chat tabs next to the Bot Chat (the open one is always added).
    static let sideTabs = 3

    var index: Int { core.bots.firstIndex { $0.name == bot.name } ?? 0 }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                chevron("chevron.left") { app.switchBot(-1) }
                rail
                chevron("chevron.right") { app.switchBot(1) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bot.title).font(.system(size: 16, weight: .bold))
                if !bot.description.isEmpty {
                    Text(bot.description).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: 560)
            HStack(spacing: 10) {
                tabs
                Text("← → to switch").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 12)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) { corner.padding(.top, 12).padding(.trailing, 18) }
        .background(Theme.contentBackground)
        .task(id: bot.name) { await core.loadSideChats(for: bot.name) }
    }

    // MARK: Bots

    var rail: some View {
        HStack(spacing: 0) {
            ForEach(Array(core.bots.enumerated()), id: \.element.id) { i, b in
                bubble(b, distance: abs(i - index))
                    .frame(width: Self.slot, height: 78)
                    .contentShape(Rectangle())
                    .onTapGesture { app.destination = .bot(b.name) }
                    .help(b.title)
            }
        }
        .offset(x: Self.railWidth / 2 - (CGFloat(index) * Self.slot + Self.slot / 2))
        .frame(width: Self.railWidth, height: 78, alignment: .leading)
        .clipped()
        .mask(
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22), .init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                startPoint: .leading, endPoint: .trailing)
        )
        .animation(.spring(response: 0.5, dampingFraction: 0.72), value: index)
    }

    func bubble(_ b: Bot, distance d: Int) -> some View {
        let current = d == 0
        let size: CGFloat = current ? 58 : d == 1 ? 40 : 30
        let pending = core.pendingPrompts.contains { $0.bot == b.name }
        return BotAvatar(bot: b, size: size)
            .overlay {
                if current {
                    Circle().stroke(Theme.contentBackground, lineWidth: 3).padding(-1.5)
                    Circle().stroke(b.color.swiftUI, lineWidth: 2).padding(-4)
                }
            }
            .shadow(color: current ? .black.opacity(0.18) : .clear, radius: 11, y: 8)
            .overlay(alignment: .topTrailing) {
                if !current, pending || core.isUnread(b.name) {
                    Circle().fill(pending ? Color.orange : Theme.accent).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Theme.contentBackground, lineWidth: 2))
                        .offset(x: 1, y: -1)
                }
            }
            .opacity(current ? 1 : d == 1 ? 0.6 : 0.35)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: d)
    }

    func chevron(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(HoverCircleStyle())
        .disabled(core.bots.count < 2)
    }

    // MARK: Chats

    var openSession: String? { app.destination.sessionID }

    /// The newest few Side Chats, plus the open one if it's older.
    var sideChats: [SideChatSummary] {
        let all = core.sideChats[bot.name] ?? []
        var shown = Array(all.prefix(Self.sideTabs))
        if let open = openSession, !shown.contains(where: { $0.id == open }), let current = all.first(where: { $0.id == open }) {
            shown.append(current)
        }
        return shown
    }

    var tabs: some View {
        HStack(spacing: 3) {
            tab("Bot Chat", selected: openSession == nil) { app.destination = .bot(bot.name) }
            ForEach(sideChats) { side in
                tab(side.title.isEmpty ? "New Side Chat" : side.title, selected: openSession == side.id) {
                    app.destination = .sideChat(bot: bot.name, session: side.id)
                }
            }
            Button {
                Task { await app.newSideChat(bot: bot.name, carryContext: false) }
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Side Chat")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }

    func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 150)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? Theme.cardBackground : .clear)
                        .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 1.5, y: 1))
                .foregroundStyle(selected ? .primary : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Corner

    var corner: some View {
        HStack(spacing: 6) {
            if let c = conversation { ChatActions(bot: bot, conversation: c) }
            Button {
                app.showRoutines.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .tint(app.showRoutines ? Theme.accent : nil)
            .help("Show \(bot.title)'s Routines")
            Button("Exit Focus") { app.setFocus(false) }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .help("Exit Focus (esc)")
        }
    }

    var conversation: Conversation? {
        if let open = openSession { return core.conversation(open) }
        return core.botChatIDs[bot.name].flatMap { core.conversation($0) }
    }
}

/// A round, borderless button that lights up under the pointer.
struct HoverCircleStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? .primary : .secondary)
            .background(Circle().fill(Color.primary.opacity(hovering || configuration.isPressed ? 0.06 : 0)))
            .onHover { hovering = $0 }
    }
}
