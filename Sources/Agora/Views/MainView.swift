import AgoraCore
import SwiftUI

struct MainView: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    /// The sheet's second step, after you said yes: how to update chats already under way.
    @State private var teachFollowUp = false

    var body: some View {
        Group {
            if app.showSetup {
                SetupView()
            } else {
                HStack(spacing: 0) {
                    if !app.focusMode {
                        Sidebar().frame(width: 268)
                        Divider()
                    }
                    Detail()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.contentBackground)
                }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) { NoticeBanner() }
        .sheet(isPresented: Binding(get: { if case .needsSignIn = core.status { true } else { false } }, set: { _ in })) {
            SignInAgainSheet()
        }
        .sheet(item: Binding(get: { if case .needsAccessLogin(let url) = core.status { AccessLoginTarget(origin: url) } else { nil } }, set: { _ in })) { target in
            let origin = target.origin
            AccessLoginSheet(origin: origin) { token in
                core.saveAccessToken(token, for: origin)
                Task { await app.connect() }
            } onCancel: {
                Task { await core.stop() }
            }
        }
        .sheet(isPresented: Binding(get: { (core.shouldAskToTeachBots || teachFollowUp) && !app.showSetup }, set: { _ in })) {
            TeachBotsSheet(taught: $teachFollowUp)
        }
    }
}

struct Detail: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.destination {
        case .today:
            TodayView()
        case .bot(let name), .sideChat(let name, _):
            if let bot = core.bot(named: name) {
                VStack(spacing: 0) {
                    // Outside the chat's identity, so the Bot row slides when you switch Bots.
                    if app.focusMode {
                        FocusHeader(bot: bot)
                        Divider()
                    }
                    ChatView(bot: bot, sessionID: app.destination.sessionID).id(app.destination.sessionID ?? name)
                }
            } else {
                missing
            }
        case .allBots:
            AllBotsView()
        case .newBot:
            BotEditorView(existing: nil)
        case .editBot(let name):
            if let bot = core.bot(named: name) { BotEditorView(existing: bot).id(name) } else { missing }
        }
    }

    var missing: some View {
        ContentUnavailableView {
            Label(core.status == .connected ? "Bot not found" : "Not connected", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text(core.status == .connected ? "This Bot isn't on the active Connection." : "Agora will show your Bots once Hermes is reachable.")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 38)  // room for the window controls
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(selected: app.destination == .today) {
                        app.destination = .today
                    } content: {
                        CalendarBadge()
                        Text("Today").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if !core.pendingPrompts.isEmpty {
                            Text("\(core.pendingPrompts.count)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accent))
                        }
                    }
                    Text("BOTS")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    ForEach(core.bots) { bot in
                        BotSidebarEntry(bot: bot)
                    }
                    if core.bots.isEmpty, core.status == .connected {
                        Text("No Bots yet.").font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                    }
                }
                .padding(.horizontal, 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(selected: app.destination == .allBots) {
                    app.destination = .allBots
                } content: {
                    Image(systemName: "square.grid.2x2").frame(width: 22)
                    Text("All Bots").font(.system(size: 13))
                    Spacer()
                }
                SidebarRow(selected: false) {
                    app.quickAsk.open()
                } content: {
                    Image(systemName: "sparkle.magnifyingglass").frame(width: 22)
                    Text("Quick Ask").font(.system(size: 13))
                    Spacer()
                    Text(HotkeyChoice.saved.label).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 2) {
                    ConnectionSwitcher()
                    AppearanceButton()
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Theme.sidebarBackground)
    }
}

struct SidebarRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.14) : hovering ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
    }
}

struct CalendarBadge: View {
    var body: some View {
        VStack(spacing: 0) {
            Text(Date(), format: .dateTime.weekday(.abbreviated)).font(.system(size: 6.5, weight: .bold)).foregroundStyle(.red).textCase(.uppercase)
            Text(Date(), format: .dateTime.day()).font(.system(size: 11, weight: .semibold))
        }
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline))
    }
}

/// A Bot in the sidebar, with its Side Chats nested underneath while it's selected.
struct BotSidebarEntry: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    let bot: Bot

    /// Side Chats shown before "Show more", and how many more each click reveals.
    static let visibleSideChats = 5
    static let moreStep = 10

    @State private var limit = visibleSideChats
    @State private var deleting: SideChatSummary?
    /// The Side Chat just archived from here, offered back for a few seconds (there's no Archived list yet).
    @State private var justArchived: SideChatSummary?

    var isSelected: Bool { app.destination == .bot(bot.name) }
    var isOpen: Bool { app.destination.bot == bot.name }
    var isExpanded: Bool { isOpen && !app.collapsedBots.contains(bot.name) }

    /// The newest few, plus the open one if it's further down.
    var shownSideChats: [SideChatSummary] {
        let all = core.sideChats[bot.name] ?? []
        guard all.count > limit else { return all }
        var shown = Array(all.prefix(limit))
        if case .sideChat(_, let open) = app.destination, !shown.contains(where: { $0.id == open }),
            let current = all.first(where: { $0.id == open })
        {
            shown.append(current)
        }
        return shown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarRow(selected: isSelected) {
                if isSelected {
                    // Clicking the open Bot again folds or unfolds its Side Chats.
                    if app.collapsedBots.contains(bot.name) { app.collapsedBots.remove(bot.name) } else { app.collapsedBots.insert(bot.name) }
                } else {
                    app.destination = .bot(bot.name)
                }
            } content: {
                BotRow(bot: bot)
            }
            .contextMenu { BotContextMenu(bot: bot) }
            if isExpanded {
                ForEach(shownSideChats) { side in
                    SideChatSidebarRow(
                        side: side, selected: app.destination == .sideChat(bot: bot.name, session: side.id),
                        archive: { archive(side) }, delete: { deleting = side })
                }
                if let archived = justArchived {
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                        Text("Archived").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo") {
                            justArchived = nil
                            Task { await core.unarchiveSideChat(archived) }
                        }
                        .buttonStyle(.link).font(.system(size: 12))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .padding(.leading, 30)
                    .task(id: archived.id) {
                        try? await Task.sleep(for: .seconds(8))
                        if justArchived?.id == archived.id { justArchived = nil }
                    }
                }
                let total = core.sideChats[bot.name]?.count ?? 0
                if total > limit {
                    SidebarRow(selected: false) {
                        withAnimation(.easeInOut(duration: 0.15)) { limit += Self.moreStep }
                    } content: {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 14)
                        Text("Show more").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(total - shownSideChats.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 30)
                }
                if limit > Self.visibleSideChats {
                    SidebarRow(selected: false) {
                        withAnimation(.easeInOut(duration: 0.15)) { limit = Self.visibleSideChats }
                    } content: {
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 14)
                        Text("Show less").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.leading, 30)
                }
                SidebarRow(selected: false) {
                    Task { await app.newSideChat(bot: bot.name, carryContext: false) }
                } content: {
                    Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                    Text("New Side Chat").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 30)
            }
        }
        .task(id: isExpanded) {
            if isExpanded { await core.loadSideChats(for: bot.name) }
        }
        .onChange(of: isOpen) { _, open in if !open { limit = Self.visibleSideChats } }
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
        .animation(.easeInOut(duration: 0.15), value: core.sideChats[bot.name]?.map(\.id))
        .confirmationDialog(
            "Delete “\(deleting.map { $0.title.isEmpty ? "New Side Chat" : $0.title } ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let side = deleting {
                    leaveIfOpen(side)
                    Task { await core.deleteSideChat(side) }
                }
            }
        } message: {
            Text("Its messages are removed from Hermes. This can't be undone.")
        }
    }

    func archive(_ side: SideChatSummary) {
        leaveIfOpen(side)
        Task {
            if await core.archiveSideChat(side) { justArchived = side }
        }
    }

    /// Steps back to the Bot Chat if the Side Chat going away is the one on screen.
    func leaveIfOpen(_ side: SideChatSummary) {
        if app.destination == .sideChat(bot: bot.name, session: side.id) { app.destination = .bot(bot.name) }
    }
}

/// A Side Chat under its Bot: archive on hover, Archive/Delete on right-click.
struct SideChatSidebarRow: View {
    @Environment(AppModel.self) private var app
    let side: SideChatSummary
    let selected: Bool
    let archive: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        SidebarRow(selected: selected) {
            app.destination = .sideChat(bot: side.bot, session: side.id)
        } content: {
            Image(systemName: side.isKanbanTask ? "rectangle.split.3x1" : "bubble.left").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                .help(side.isKanbanTask ? "A kanban task: the board runs it" : "")
            Text(side.title.isEmpty ? "New Side Chat" : side.title).font(.system(size: 12)).lineLimit(1)
            Spacer()
            if hovering {
                Button(action: archive) {
                    Image(systemName: "archivebox").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Archive")
            } else if let d = side.lastActive {
                Text(RelativeTime.short(d)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { app.destination = .sideChat(bot: side.bot, session: side.id) }
            Divider()
            Button("Archive", action: archive)
            Button("Delete…", role: .destructive, action: delete)
        }
        .padding(.leading, 30)
    }
}

struct BotContextMenu: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    let bot: Bot
    var body: some View {
        Button("Open Bot Chat") { app.destination = .bot(bot.name) }
        Button("New Side Chat") { Task { await app.newSideChat(bot: bot.name, carryContext: false) } }
        Button("New Side Chat with Context") { Task { await app.newSideChat(bot: bot.name, carryContext: true) } }
        Divider()
        Button(core.isMuted(bot.name) ? "Unmute Notifications" : "Mute Notifications") { core.setMuted(bot.name, !core.isMuted(bot.name)) }
        Button("Configure \(bot.title)…") { app.destination = .editBot(bot.name) }
    }
}

struct BotRow: View {
    @Environment(AgoraCore.self) private var core
    let bot: Bot

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                BotAvatar(bot: bot, size: 30)
                if core.pendingPrompts.contains(where: { $0.bot == bot.name }) {
                    Circle().fill(Color.orange).frame(width: 9, height: 9).overlay(Circle().stroke(Theme.sidebarBackground, lineWidth: 1.5)).offset(x: 2, y: -2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(bot.title).font(.system(size: 13, weight: core.isUnread(bot.name) ? .bold : .semibold)).lineLimit(1)
                    if core.isMuted(bot.name) { Image(systemName: "bell.slash").font(.system(size: 9)).foregroundStyle(.tertiary) }
                    Spacer(minLength: 4)
                    if let d = bot.lastActive { Text(RelativeTime.short(d)).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                }
                HStack(spacing: 4) {
                    Text(bot.lastPreview ?? bot.description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if core.isUnread(bot.name) {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }
}

enum RelativeTime {
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if date > Date().addingTimeInterval(-6 * 86400) { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The connection status, and a menu to switch the active Connection.
struct ConnectionSwitcher: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            ForEach(core.registry.connections) { c in
                Button {
                    Task {
                        await core.switchConnection(to: c.id)
                        app.destination = .today
                        if core.status == .connected { await core.watchBotChats() }
                    }
                } label: {
                    if c.id == core.registry.activeID { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            Divider()
            if core.status != .connected {
                Button("Reconnect") { Task { await app.connect() } }
            }
            Button("Manage Connections…") { openSettings() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(detail)
    }

    var label: String {
        let name = core.registry.active?.name ?? "No Connection"
        switch core.status {
        case .connected: return "\(name) · connected"
        case .connecting: return "\(name) · connecting…"
        case .reconnecting: return "\(name) · reconnecting…"
        case .offline: return "\(name) · offline"
        case .needsSignIn, .needsAccessLogin: return "\(name) · sign in needed"
        case .configurationError: return "\(name) · can't connect"
        case .idle: return name
        }
    }

    var detail: String {
        switch core.status {
        case .offline(let m), .needsSignIn(let m), .configurationError(let m): return m
        case .needsAccessLogin(let url): return HermesError.accessLoginRequired(url).localizedDescription
        default: return core.hermesVersion.map { "Hermes \($0)" } ?? ""
        }
    }

    var color: Color {
        switch core.status {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        default: return .red
        }
    }
}

/// A short-lived banner for failures and explanations (core.notice).
struct NoticeBanner: View {
    @Environment(AgoraCore.self) private var core
    var body: some View {
        if let notice = core.notice {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                Text(notice).font(.system(size: 12.5)).lineLimit(3)
                Button {
                    core.notice = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
            .padding(.bottom, 80)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: notice) {
                try? await Task.sleep(for: .seconds(8))
                if core.notice == notice { core.notice = nil }
            }
        }
    }
}

/// Sun/moon button that flips Light and Dark.
struct AppearanceButton: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { app.toggleAppearance() } label: {
            Image(systemName: scheme == .dark ? "sun.max" : "moon")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(scheme == .dark ? "Switch to Light (⇧⌘L)" : "Switch to Dark (⇧⌘L)")
    }
}
