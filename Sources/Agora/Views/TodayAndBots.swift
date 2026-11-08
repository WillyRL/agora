import AgoraCore
import AppKit
import SwiftUI

/// Home: what's waiting for your OK, and the latest from your Bots.
struct TodayView: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Today")
            content
        }
    }

    var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .textCase(.uppercase)
                    Text(greeting).font(.system(size: 28, weight: .bold))
                    Text(summary).font(.system(size: 15)).foregroundStyle(.secondary)
                }

                if !core.pendingPrompts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Waiting for you")
                        ForEach(core.pendingPrompts) { prompt in
                            if let bot = core.bot(named: prompt.bot) {
                                WaitingRow(prompt: prompt, bot: bot)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("From your Bots")
                    if recent.isEmpty {
                        Text(core.status == .connected ? "Nothing new yet." : "Agora will show your Bots once Hermes is reachable.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    ForEach(recent) { bot in
                        Button {
                            app.destination = .bot(bot.name)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                BotAvatar(bot: bot, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(bot.title).font(.system(size: 13, weight: .semibold))
                                        if core.isUnread(bot.name) { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                                        Spacer()
                                        if let d = bot.lastActive { Text(RelativeTime.short(d)).font(.system(size: 11)).foregroundStyle(.tertiary) }
                                    }
                                    Text(bot.lastPreview ?? bot.description).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .noScrollEdgeEffect()
        .scrollContentBackground(.hidden)
        .background(Theme.contentBackground)
        .onAppear { core.setViewing(bot: nil, session: nil) }
    }

    var recent: [Bot] {
        core.bots.filter { $0.lastPreview != nil }.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "Good evening" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        let name = ProcessInfo.processInfo.environment["AGORA_DEMO"] != nil ? "Alex"  // demo screenshots show no real name
            : NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? "\(part)." : "\(part), \(name)."
    }

    var summary: String {
        let waiting = core.pendingPrompts.count
        let unread = core.unread.count
        var parts: [String] = []
        if waiting > 0 { parts.append(waiting == 1 ? "One thing is waiting for your OK" : "\(waiting) things are waiting for your OK") }
        if unread > 0 { parts.append(unread == 1 ? "one Bot has something new" : "\(unread) Bots have something new") }
        if parts.isEmpty { return core.status == .connected ? "All quiet. Your Bots are ready when you are." : "Connecting to Hermes…" }
        return parts.joined(separator: ", and ") + "."
    }
}

/// The thin bar at the top of a page (matches the chat header's height).
struct PageHeader: View {
    let title: String
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .frame(height: 50)
            .padding(.horizontal, 16)
            Divider()
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }
}

struct WaitingRow: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    let prompt: PendingPrompt
    let bot: Bot

    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(bot: bot, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 12, design: isApproval ? .monospaced : .default)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Review") { app.show(bot: prompt.bot, session: prompt.sessionID) }
            if isApproval {
                Button("Allow") { Task { await core.answer(prompt, choice: "once") } }.buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    var isApproval: Bool { if case .approval = prompt.kind { true } else { false } }

    var title: String {
        switch prompt.kind {
        case .approval(_, let description, _): return description.isEmpty ? "\(bot.title) wants to run a command" : description
        case .clarify(let q, _, _): return q
        case .clarifyBatch: return "\(bot.title) has questions"
        case .secret: return "\(bot.title) needs a secret"
        case .sudo: return "\(bot.title) needs your password"
        }
    }

    var detail: String {
        switch prompt.kind {
        case .approval(let command, _, _): return command
        case .sudo(let command): return command
        default: return bot.title
        }
    }
}

/// Every Bot as a card, plus making a new one.
struct AllBotsView: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "All Bots")
            content
        }
    }

    var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Each Bot has its own purpose, memory and Bot Chat.").foregroundStyle(.secondary)
                    Spacer()
                    Button("New Bot") { app.destination = .newBot }.buttonStyle(.borderedProminent).disabled(core.status != .connected)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    ForEach(core.allBots) { bot in
                        BotCard(bot: bot)
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(36)
            .frame(maxWidth: .infinity)
        }
        .noScrollEdgeEffect()
        .scrollContentBackground(.hidden)
        .background(Theme.contentBackground)
        .onAppear { core.setViewing(bot: nil, session: nil) }
    }
}

struct BotCard: View {
    @Environment(AppModel.self) private var app
    let bot: Bot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BotAvatar(bot: bot, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot.title).font(.system(size: 14, weight: .semibold))
                    Text(bot.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer()
                if bot.hidden { Text("Hidden").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Text(bot.description.isEmpty ? "No description yet." : bot.description)
                .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(3).frame(minHeight: 46, alignment: .top)
            Text(bot.model.isEmpty ? "Default model" : bot.model).font(.system(size: 11)).foregroundStyle(.tertiary)
            HStack {
                Button("Open Bot Chat") { app.destination = .bot(bot.name) }.buttonStyle(.borderedProminent).disabled(bot.hidden)
                Button("Configure") { app.destination = .editBot(bot.name) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }
}

/// The simple Bot editor: name, description, persona, model, avatar and colour. Nothing else.
struct BotEditorView: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    let existing: Bot?

    @State private var draft = BotDraft()
    @State private var models: [ModelChoice] = []
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var loaded = false
    @State private var mcp = BotMCPSelection()
    @State private var draftingPersona = false
    @State private var previousPersona: String?
    @State private var personaError: String?

    static let swatches = ["#8b5cf6", "#3b82f6", "#14b8a6", "#22c55e", "#eab308", "#f97316", "#ef4444", "#ec4899", "#6b7280"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existing == nil ? "New Bot" : "Configure \(existing!.title)").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Cancel") { app.destination = existing.map { .bot($0.name) } ?? .allBots }
                Button(existing == nil ? "Create" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 14) {
                        AvatarPicker(draft: $draft, name: draft.name.isEmpty ? draft.title : draft.name)
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Bot name", text: $draft.title).textFieldStyle(.plain).font(.system(size: 20, weight: .semibold))
                            if existing == nil {
                                Text("Hermes profile: \(AgoraCore.profileName(from: draft.title).isEmpty ? "…" : AgoraCore.profileName(from: draft.title))")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 6) {
                                ForEach(Self.swatches, id: \.self) { hex in
                                    Circle()
                                        .fill(BotColor(hex: hex)!.swiftUI)
                                        .frame(width: 18, height: 18)
                                        .overlay(Circle().stroke(Color.primary.opacity(draft.color == hex ? 0.7 : 0), lineWidth: 2).padding(-3))
                                        .onTapGesture { draft.color = hex }
                                }
                            }
                        }
                    }
                    Field("Purpose") {
                        // Grows with the text (purposes run long), up to six lines.
                        TextField("What is this Bot for?", text: $draft.description, axis: .vertical)
                            .lineLimit(2...6)
                            .textFieldStyle(.roundedBorder)
                    }
                    Field("Persona") {
                        TextEditor(text: $draft.persona)
                            .font(.system(size: 13))
                            .disabled(draftingPersona)
                            .frame(minHeight: 140, maxHeight: 300)  // long personas scroll inside, so the page stays short
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cardBackground))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(personaError ?? "How it should talk and think. Saved as the Bot's SOUL.md in Hermes.")
                                .font(.system(size: 11)).foregroundStyle(personaError == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
                            Spacer()
                            if let previousPersona, !draftingPersona {
                                Button("Undo") {
                                    draft.persona = previousPersona
                                    self.previousPersona = nil
                                }
                                .buttonStyle(.borderless)
                            }
                            Button(action: generatePersona) {
                                HStack(spacing: 5) {
                                    if draftingPersona { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                                    Text(draftingPersona ? "Writing…" : draft.persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Draft with AI" : "Rewrite with AI")
                                }
                            }
                            .controlSize(.small)
                            .disabled(draftingPersona || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                            .help("Hermes writes a persona from the name and purpose, keeping anything already in the box")
                        }
                    }
                    Field("Model") {
                        Picker("", selection: Binding(get: { "\(draft.provider):\(draft.model)" }, set: { v in
                            let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
                            draft.provider = parts.first ?? ""
                            draft.model = parts.count > 1 ? parts[1] : ""
                        })) {
                            Text("Hermes default").tag(":")
                            if !draft.model.isEmpty, !models.contains(where: { $0.model == draft.model && $0.provider == draft.provider }) {
                                Text(draft.model).tag("\(draft.provider):\(draft.model)")
                            }
                            ForEach(Dictionary(grouping: models, by: \.providerName).sorted { $0.key < $1.key }, id: \.key) { provider, choices in
                                Section(provider) {
                                    ForEach(choices) { m in Text(m.model).tag(m.id) }
                                }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    BotMCPPicker(bot: existing?.name, selection: $mcp)
                    if let existing {
                        BotToolsSection(bot: existing.name)
                        BotSkillsSection(bot: existing.name, botTitle: existing.title)
                    }
                    Text("Turn tool groups on or off in Hermes (`hermes tools`). Anything that sends, deletes or spends asks for your approval first.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
                    if let existing, existing.name != "default" {
                        Divider()
                        Button("Delete \(existing.title)…", role: .destructive) { confirmDelete = true }
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if let existing { draft = await core.draft(for: existing) }
            models = await core.modelChoices(for: existing?.name ?? "default")
            if DebugSnapshot.draftsPersona { generatePersona() }
        }
        .confirmationDialog("Delete \(existing?.title ?? "this Bot")?", isPresented: $confirmDelete) {
            Button("Delete Bot", role: .destructive) {
                Task {
                    do {
                        try await core.deleteBot(existing!.name)
                        app.destination = .allBots
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("Its Hermes profile, memory, chats and Routines are removed. This can't be undone.")
        }
        .onAppear { core.setViewing(bot: nil, session: nil) }
    }

    func generatePersona() {
        draftingPersona = true
        personaError = nil
        let before = draft.persona
        Task {
            defer { draftingPersona = false }
            do {
                let persona = try await core.draftPersona(name: draft.title, purpose: draft.description, current: before, bot: existing?.name)
                previousPersona = before
                draft.persona = persona
            } catch {
                personaError = "Couldn't write a persona: \(error.localizedDescription)"
            }
        }
    }

    func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                if existing == nil {
                    let bot = try await core.createBot(draft)
                    try await core.applyMCPSelection(mcp, bot: bot.name)
                    app.destination = .bot(bot.name)
                } else {
                    try await core.saveBot(draft)
                    try await core.applyMCPSelection(mcp, bot: draft.name)
                    app.destination = .bot(draft.name)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct Field<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

struct AvatarPicker: View {
    @Binding var draft: BotDraft
    let name: String

    var body: some View {
        Button(action: pick) {
            ZStack {
                if let data = draft.avatarPNG, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(Circle())
                } else {
                    let color = draft.color.flatMap(BotColor.init(hex:)) ?? .derived(from: name)
                    Circle().fill(color.swiftUI).frame(width: 64, height: 64)
                        .overlay(Text(String(name.first ?? "?").uppercased()).font(.system(size: 28, weight: .semibold)).foregroundStyle(.white))
                }
            }
        }
        .buttonStyle(.plain)
        .help("Choose an avatar image")
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic]
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
        let size = NSSize(width: 256, height: 256)
        let scaled = NSImage(size: size, flipped: false) { rect in
            img.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
        draft.avatarPNG = ImageAttachment.from(scaled)?.data
    }
}
