import AgoraCore
import AppKit
import SwiftUI

/// Settings → MCP Servers: the main Hermes profile's servers, which every Bot picks from.
struct MCPSettings: View {
    @Environment(AgoraCore.self) private var core
    @State private var servers: [MCPServer] = []
    @State private var loading = false
    @State private var error: String?
    @State private var busy: Set<String> = []
    @State private var results: [String: MCPTestResult] = [:]
    @State private var adding = false
    @State private var editing: MCPServer?
    @State private var givingToBots: MCPServer?
    /// Debug snapshots only: test this server once the list loads.
    var autoTest: String?
    @State private var removing: MCPServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MCP servers give your Bots extra tools. Pick which ones each Bot uses in its Configure page.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            if core.status != .connected {
                Spacer()
                Text("Connect to Hermes to manage MCP servers.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(servers) { s in row(s) }
                    if servers.isEmpty, !loading {
                        Text("No MCP servers yet.").foregroundStyle(.secondary)
                    }
                }
                .overlay { if loading && servers.isEmpty { ProgressView() } }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                HStack {
                    Button("Add Server…") { adding = true }
                    Spacer()
                    Text("Changes apply to new chats.").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
            }
        }
        .padding(20)
        .task(id: "\(core.registry.activeID?.uuidString ?? "")-\(core.status == .connected)") {
            await load()
            if let autoTest, servers.contains(where: { $0.name == autoTest }) { test(autoTest) }
        }
        .sheet(isPresented: $adding) {
            AddMCPServerSheet(editing: nil, existing: Set(servers.map(\.name))) { added in
                adding = false
                Task {
                    await load()
                    if let added, added.auth == .oauth { await signIn(added.name) }
                }
            }
        }
        .sheet(item: $givingToBots) { server in
            AddToBotsSheet(server: server) { givingToBots = nil }
        }
        .sheet(item: $editing) { old in
            AddMCPServerSheet(editing: old, existing: []) { saved in
                editing = nil
                Task {
                    results[old.name] = nil
                    await load()
                    // A new login or address needs a fresh sign-in.
                    if let saved, saved.auth == .oauth, old.auth != .oauth || saved.url != old.url { await signIn(old.name) }
                }
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let s = removing { run(s.name) { try await core.removeMCPServer(s.name) } }
            }
        } message: {
            Text("Bots that copied it keep their own copy until you switch it off in their Configure page.")
        }
    }

    @ViewBuilder func row(_ s: MCPServer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: s.isRemote ? "globe" : "terminal").foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(s.name).font(.system(size: 13, weight: .medium))
                        if let plugin = s.plugin { Badge("from \(plugin)") }
                        if s.auth == .oauth { Badge("sign-in") }
                        if s.auth == .header { Badge("token") }
                    }
                    Text(s.address).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if busy.contains(s.name) { ProgressView().controlSize(.small) }
                Toggle("", isOn: Binding(get: { s.enabled }, set: { on in run(s.name) { try await core.setMCPServer(s.name, enabled: on) } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(s.plugin != nil || busy.contains(s.name))
                    .help(s.plugin != nil ? "Provided by a Hermes plugin" : (s.enabled ? "On" : "Off"))
                Menu {
                    Button("Test Connection") { test(s.name) }
                    if s.auth == .oauth, s.plugin == nil { Button("Sign In…") { Task { await signIn(s.name) } } }
                    if s.plugin == nil {
                        Button("Add to Bots…") { givingToBots = s }
                        Button("Edit…") { editing = s }
                        Divider()
                        Button("Remove…", role: .destructive) { removing = s }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(busy.contains(s.name))
            }
            if let r = results[s.name] { TestResultLine(result: r).padding(.leading, 28) }
        }
        .padding(.vertical, 3)
    }

    func load() async {
        guard core.status == .connected else { return }
        loading = true
        defer { loading = false }
        do {
            servers = try await core.mcpServers()
            error = nil
        } catch {
            self.error = "Couldn't load MCP servers: \(error.localizedDescription)"
        }
    }

    func test(_ name: String) {
        busy.insert(name)
        results[name] = nil
        Task {
            defer { busy.remove(name) }
            do { results[name] = try await core.testMCPServer(name) } catch { results[name] = MCPTestResult(ok: false, error: error.localizedDescription, tools: []) }
        }
    }

    func signIn(_ name: String) async {
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            try await core.signInMCPServer(name) { url in Task { @MainActor in NSWorkspace.shared.open(url) } }
            error = nil
            results[name] = try? await core.testMCPServer(name)
        } catch {
            self.error = "\(name): \(error.localizedDescription)"
        }
    }

    func run(_ name: String, _ work: @escaping () async throws -> Void) {
        busy.insert(name)
        Task {
            defer { busy.remove(name) }
            do {
                try await work()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await load()
        }
    }
}

struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct TestResultLine: View {
    let result: MCPTestResult
    var body: some View {
        if result.ok {
            let names = result.tools.map(\.name)
            let shown = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", …" : "")
            Label("Connected · \(names.count) tool\(names.count == 1 ? "" : "s")\(names.isEmpty ? "" : ": \(shown)")", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.green).lineLimit(2)
                .help(result.tools.map { "\($0.name) — \($0.description)" }.joined(separator: "\n"))
        } else {
            Label(result.error ?? "Couldn't connect.", systemImage: "xmark.octagon.fill")
                .font(.system(size: 11)).foregroundStyle(.red).lineLimit(3)
        }
    }
}

/// Adds a server, or edits one when `editing` is set (its name stays; Hermes re-adds it under the same name).
struct AddMCPServerSheet: View {
    @Environment(AgoraCore.self) private var core
    let editing: MCPServer?
    let existing: Set<String>
    /// Called with the saved server, or nil when cancelled.
    let done: (NewMCPServer?) -> Void

    @State private var draft = NewMCPServer()
    @State private var isURL = true
    @State private var saving = false
    @State private var error: String?

    init(editing: MCPServer?, existing: Set<String>, done: @escaping (NewMCPServer?) -> Void, initialName: String = "") {
        self.editing = editing
        self.existing = existing
        self.done = done
        _draft = State(initialValue: editing?.draft ?? NewMCPServer(name: initialName))
        _isURL = State(initialValue: editing.map { !$0.url.isEmpty } ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "Add an MCP Server" : "Edit \(editing!.name)").font(.headline)
            if let editing, !editing.hiddenSettings.isEmpty {
                Text("This server has \(editing.hiddenSettings.joined(separator: " and ")) that Agora can't see, so it can't be edited here. Use `hermes mcp` on the Mac running Hermes.")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            // Plain left-aligned boxes: a grouped Form right-aligns its fields, which hides a trailing space while typing.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    label("Name")
                    if editing == nil {
                        TextField("", text: $draft.name, prompt: Text("linear")).textFieldStyle(.roundedBorder)
                    } else {
                        Text(draft.name)
                    }
                }
                GridRow {
                    label("Kind")
                    Picker("", selection: $isURL) {
                        Text("URL").tag(true)
                        Text("Command").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if isURL {
                    GridRow {
                        label("URL")
                        TextField("", text: $draft.url, prompt: Text("https://mcp.example.com/mcp")).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        label("Login")
                        Picker("", selection: $draft.auth) {
                            Text("None").tag(MCPServer.Auth.none)
                            Text("Sign in with browser").tag(MCPServer.Auth.oauth)
                            Text("Token").tag(MCPServer.Auth.header)
                        }
                        .labelsHidden().fixedSize()
                    }
                    if draft.auth == .header {
                        GridRow {
                            label("Token")
                            SecureField("", text: $draft.token, prompt: Text(editing?.auth == .header ? "Enter it again — Hermes never shows it" : ""))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                } else {
                    GridRow {
                        label("Command")
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("", text: $draft.command, prompt: Text("npx -y @modelcontextprotocol/server-filesystem ~/Documents")).textFieldStyle(.roundedBorder)
                            Text("Runs on the Mac where Hermes is. Keys the server needs go in that profile's .env.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(saveTitle, action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || editing?.hiddenSettings.isEmpty == false || (isURL && draft.auth == .header && draft.token.isEmpty) || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || (isURL ? draft.url : draft.command).trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    var saveTitle: String {
        let signIn = isURL && draft.auth == .oauth && (editing == nil || editing!.auth != .oauth || editing!.url != draft.url)
        if editing == nil { return signIn ? "Add and Sign In" : "Add" }
        return signIn ? "Save and Sign In" : "Save"
    }

    func add() {
        var s = draft
        if isURL { s.command = "" } else { s.url = ""; s.auth = .none; s.token = "" }
        if s.auth != .header { s.token = "" }
        if let editing {
            saving = true
            Task {
                defer { saving = false }
                do {
                    try await core.editMCPServer(editing, to: s)
                    done(s)
                } catch {
                    self.error = error.localizedDescription
                }
            }
            return
        }
        guard !existing.contains(s.name.trimmingCharacters(in: .whitespaces)) else {
            error = "There's already a server called \(s.name)."
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await core.addMCPServer(s)
                done(s)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The Bot editor's "MCP servers" section: which library servers this Bot may use.
struct BotMCPPicker: View {
    @Environment(AgoraCore.self) private var core
    let bot: String?
    @Binding var selection: BotMCPSelection

    @State private var loaded = false
    @State private var error: String?
    /// The token server being switched on, waiting for its token.
    @State private var askingToken: String?
    @State private var token = ""

    var body: some View {
        Field("MCP servers") {
            if !loaded {
                ProgressView().controlSize(.small)
            } else if selection.names.isEmpty {
                Text("No MCP servers in Hermes yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(selection.names, id: \.self) { name in
                        HStack(spacing: 8) {
                        Toggle(name, isOn: Binding(get: { selection.picked.contains(name) }, set: { on in
                            if on {
                                if selection.needsToken(name), selection.tokens[name] == nil {
                                    token = ""
                                    askingToken = name
                                } else {
                                    selection.picked.insert(name)
                                }
                            } else {
                                selection.picked.remove(name)
                            }
                        }))
                        .toggleStyle(.checkbox)
                            // Its tools, from the Bot's own copy (only once the Bot has it).
                            if let bot, selection.own.contains(where: { $0.name == name }) {
                                MCPToolsLink(server: name, bot: bot)
                            }
                        }
                    }
                }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack(spacing: 4) {
                Text("Saving reloads the Bot's open chats. Add servers or sign in to them in").font(.system(size: 11)).foregroundStyle(.tertiary)
                SettingsLink { Text("Settings → MCP Servers").font(.system(size: 11)) }.buttonStyle(.link)
            }
        }
        .alert("Token for \(askingToken ?? "")", isPresented: Binding(get: { askingToken != nil }, set: { if !$0 { askingToken = nil } })) {
            SecureField("Token", text: $token)
            Button("Add") {
                if let name = askingToken, !token.isEmpty {
                    selection.tokens[name] = token
                    selection.picked.insert(name)
                }
                askingToken = nil
            }
            Button("Cancel", role: .cancel) { askingToken = nil }
        } message: {
            Text("This server logs in with a token, and Hermes never hands a saved one back. Enter it once: Agora keeps it in your Keychain for your other Bots.")
        }
        .task {
            guard !loaded else { return }
            defer { loaded = true }
            do {
                selection = try await core.mcpSelection(bot: bot)
            } catch {
                self.error = "Couldn't load MCP servers: \(error.localizedDescription)"
            }
        }
    }
}

/// Gives one library server to several Bots, typing a token server's token once.
struct AddToBotsSheet: View {
    @Environment(AgoraCore.self) private var core
    let server: MCPServer
    let done: () -> Void

    @State private var already: Set<String> = []
    @State private var chosen: Set<String> = []
    @State private var token = ""
    @State private var remembered = false
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var bots: [Bot] { core.allBots.filter { $0.name != AgoraCore.mcpLibraryProfile } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add \(server.name) to Bots").font(.headline)
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(bots) { bot in
                        let has = already.contains(bot.name)
                        Toggle(isOn: Binding(get: { has || chosen.contains(bot.name) }, set: { on in
                            if on { chosen.insert(bot.name) } else { chosen.remove(bot.name) }
                        })) {
                            HStack(spacing: 6) {
                                BotAvatar(bot: bot, size: 18)
                                Text(bot.title)
                                if has { Text("already on").font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(has)
                    }
                }
                if server.auth == .header {
                    if remembered {
                        Label("Uses the token Agora saved for \(server.name).", systemImage: "key.fill")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        SecureField("Token", text: $token)
                        Text("Typed once: Agora keeps it in your Keychain for the next Bot, and each Bot gets its own copy in Hermes.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || chosen.isEmpty || (server.auth == .header && !remembered && token.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 420)
        .task {
            remembered = core.rememberedMCPToken(for: server.name) != nil
            for bot in bots {
                if let own = try? await core.mcpServers(bot: bot.name), own.contains(where: { $0.name == server.name && $0.enabled }) {
                    already.insert(bot.name)
                }
            }
            loading = false
        }
    }

    func add() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await core.addMCPServer(server, toBots: Array(chosen), token: token)
                done()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// "Show tools" next to an MCP server: connects with the Bot's copy and lists what it offers.
struct MCPToolsLink: View {
    @Environment(AgoraCore.self) private var core
    let server: String
    let bot: String
    @State private var result: MCPTestResult?
    @State private var loading = false
    @State private var showing = false

    var body: some View {
        Button(loading ? "Connecting…" : "Show tools") {
            if result != nil { showing = true; return }
            loading = true
            Task {
                defer { loading = false }
                do { result = try await core.testMCPServer(server, bot: bot) } catch {
                    result = MCPTestResult(ok: false, error: error.localizedDescription)
                }
                showing = true
            }
        }
        .buttonStyle(.link).font(.system(size: 11)).disabled(loading)
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            if let result { ToolListPopover(title: server, result: result) }
        }
    }
}

struct ToolListPopover: View {
    let title: String
    let result: MCPTestResult
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if result.ok {
                Text("\(result.tools.count) tool\(result.tools.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.tools) { t in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.name).font(.system(size: 12, design: .monospaced))
                                if !t.description.isEmpty {
                                    Text(t.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            } else {
                TestResultLine(result: result)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// The Bot editor's "Tools" section: the Bot's Hermes tool groups, read-only.
struct BotToolsSection: View {
    @Environment(AgoraCore.self) private var core
    let bot: String
    @State private var sets: [Toolset]?
    @State private var error: String?
    @State private var showOff = false

    var body: some View {
        Field("Tools") {
            if let sets {
                let on = sets.filter(\.enabled)
                let off = sets.filter { !$0.enabled }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(on) { ToolsetRow(set: $0) }
                    if !off.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showOff.toggle() }
                        } label: {
                            Label("\(off.count) off", systemImage: showOff ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).padding(.top, 6)
                        if showOff { ForEach(off) { ToolsetRow(set: $0) } }
                    }
                }
            } else if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            do { sets = try await core.toolsets(bot: bot) } catch { self.error = "Couldn't load tools: \(error.localizedDescription)" }
        }
    }
}

struct ToolsetRow: View {
    let set: Toolset
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: set.enabled ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11)).foregroundStyle(set.enabled ? (set.configured ? Color.green : .orange) : .secondary)
                    Text(set.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(set.enabled ? .primary : .secondary)
                    if set.enabled && !set.configured { Badge("needs keys") }
                    Text(set.description).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !set.tools.isEmpty {
                        Text("\(set.tools.count)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(set.description)
            if expanded, !set.tools.isEmpty {
                Text(set.tools.joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.leading, 17)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}
