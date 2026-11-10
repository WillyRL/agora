import AgoraCore
import AppKit
import SwiftUI

/// First launch: one screen that gets you to your Bots. No tour.
struct SetupView: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    @State private var useLocal = AgoraCore.localHermesInstalled
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 30)
            RoundedRectangle(cornerRadius: 18)
                .fill(Theme.accent)
                .frame(width: 72, height: 72)
                .overlay(Text("A").font(.system(size: 36, weight: .semibold)).foregroundStyle(.white))
                .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 6)
            VStack(spacing: 6) {
                Text("Welcome to Agora").font(.system(size: 28, weight: .bold))
                Text("A quiet window onto your Bots. Their thinking, tools and memory stay in Hermes.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                ChoiceCard(selected: useLocal, title: "On this Mac", subtitle: AgoraCore.localHermesInstalled ? "Found Hermes at ~/.hermes" : "Hermes isn't installed on this Mac") {
                    useLocal = true
                }
                .disabled(!AgoraCore.localHermesInstalled)
                ChoiceCard(selected: !useLocal, title: "On another machine", subtitle: "`hermes serve` on another machine. Nothing Hermes-related needed here.") {
                    useLocal = false
                }
                if !useLocal {
                    RemoteConnectionForm { app.showSetup = false }
                        .padding(.top, 4)
                }
            }
            .frame(width: 460)
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
            if useLocal {
                Button {
                    working = true
                    Task {
                        await core.addLocalConnection()
                        working = false
                        if core.status == .connected {
                            app.showSetup = false
                            await core.watchBotChats()
                        } else if case .offline(let m) = core.status {
                            error = m
                        }
                    }
                } label: {
                    Text(working ? "Connecting…" : "Connect").frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(working)
                .keyboardShortcut(.defaultAction)
            }
            Spacer(minLength: 30)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
        .onAppear { if app.setupStartsRemote || !AgoraCore.localHermesInstalled { useLocal = false } }
    }
}

struct ChoiceCard: View {
    let selected: Bool
    let title: String
    let subtitle: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Add a Remote Connection: URL, then a pasted token or browser sign-in (whichever the server offers).
struct RemoteConnectionForm: View {
    @Environment(AgoraCore.self) private var core
    let onDone: () -> Void
    @State private var name = ""
    @State private var urlText = ""
    @State private var token = ""
    @State private var status: RemoteAccess.Status?
    @State private var busy = false
    @State private var error: String?
    /// Cloudflare Access stands in front of this address: its login page, while open.
    @State private var accessLogin: AccessLoginTarget?
    @State private var behindAccess: URL?

    var url: URL? {
        var s = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TailnetGatewaysList(busy: busy, onConnect: pick, onUse: use)
            TextField("Name (e.g. Home Mac mini)", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                TextField("https://hermes.example.com", text: $urlText).textFieldStyle(.roundedBorder).onSubmit(check)
                Button("Check", action: check).disabled(url == nil || busy)
            }
            if let status {
                Text("Hermes \(status.version ?? "?") · \(status.authRequired ? "login required" : "no login gate")")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                if status.supportsBrowserSignIn {
                    Button {
                        signIn()
                    } label: {
                        Label("Sign in with browser", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                }
                if status.acceptsToken {
                    HStack {
                        SecureField("Or paste a session token", text: $token).textFieldStyle(.roundedBorder)
                        Button("Connect") { connectWithToken() }.disabled(token.isEmpty || busy)
                    }
                }
                if !status.supportsBrowserSignIn && !status.acceptsToken {
                    Text("This Hermes offers no login Agora can use.").font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            if let behindAccess, status == nil {
                Text("\(behindAccess.host ?? "This address") is behind Cloudflare Access. Log in there first, then sign in to Hermes.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    accessLogin = AccessLoginTarget(origin: behindAccess)
                } label: {
                    Label("Log in to Cloudflare Access", systemImage: "lock.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
        }
        .sheet(item: $accessLogin) { target in
            let origin = target.origin
            AccessLoginSheet(origin: origin) { token in
                core.saveAccessToken(token, for: origin)
                accessLogin = nil
                check()
            } onCancel: {
                accessLogin = nil
            }
        }
    }

    /// A Hermes found on the tailnet: fill the form and, when it offers browser sign-in, start it right away.
    func pick(_ gateway: TailnetGateway) {
        name = gateway.deviceName
        urlText = gateway.url.absoluteString
        status = gateway.status
        error = nil
        if gateway.status.supportsBrowserSignIn { signIn() }
    }

    func use(_ id: UUID) {
        busy = true
        Task {
            await core.switchConnection(to: id)
            busy = false
            finish()
        }
    }

    func check() {
        guard let url else { return }
        busy = true
        error = nil
        status = nil
        behindAccess = nil
        Task {
            defer { busy = false }
            do {
                status = try await core.probeRemote(url)
            } catch HermesError.accessLoginRequired(let origin) {
                behindAccess = origin
                accessLogin = AccessLoginTarget(origin: origin)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func connectWithToken() {
        guard let url else { return }
        busy = true
        Task {
            await core.addRemoteConnection(name: name, url: url, token: token)
            busy = false
            finish()
        }
    }

    func signIn() {
        guard let url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await core.addRemoteConnection(name: name, url: url, receiver: NetworkLoopbackReceiver()) { authorize in
                    Task { @MainActor in NSWorkspace.shared.open(authorize) }
                }
                finish()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func finish() {
        if core.status == .connected {
            Task { await core.watchBotChats() }
            onDone()
        } else {
            switch core.status {
            case .offline(let m), .needsSignIn(let m), .configurationError(let m): error = m
            case .needsAccessLogin(let origin): behindAccess = origin
            default: break
            }
        }
    }
}

/// Hermes found on the machines of your tailnet. Scans when shown; one click connects.
struct TailnetGatewaysList: View {
    @Environment(AgoraCore.self) private var core
    let busy: Bool
    let onConnect: (TailnetGateway) -> Void
    let onUse: (UUID) -> Void

    var body: some View {
        if core.tailnet.tailscaleInstalled {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("On your tailnet").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if core.tailnet.scanning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            Task { await core.scanTailnet() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Look again")
                    }
                }
                if let problem = core.tailnet.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(.secondary)
                } else if core.tailnet.gateways.isEmpty {
                    Text(core.tailnet.scanning ? "Looking for Hermes on your other machines…" : "No Hermes found on your other machines. On one of them, run `hermes serve --host <its Tailscale IP>`, then look again.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(core.tailnet.gateways) { gateway in
                    row(gateway)
                }
                Text("Or enter an address").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
            }
            .task { await core.scanTailnet() }
        }
    }

    func row(_ g: TailnetGateway) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.deviceName).font(.system(size: 13, weight: .medium))
                Text("\(g.url.host ?? g.url.absoluteString) · Hermes \(g.status.version ?? "?")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let saved = g.savedConnectionID {
                if saved == core.registry.activeID {
                    Text("Active").font(.system(size: 11)).foregroundStyle(Theme.accent)
                } else {
                    Button("Use") { onUse(saved) }.disabled(busy)
                }
            } else if !g.isSupported {
                Text("Needs Hermes 0.23+").font(.system(size: 11)).foregroundStyle(.orange)
                    .help("Update Hermes on \(g.deviceName) and restart `hermes serve`.")
            } else {
                Button("Connect") { onConnect(g) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }
}

/// Shown when a Remote login expired and couldn't be refreshed.
struct SignInAgainSheet: View {
    @Environment(AgoraCore.self) private var core
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in again").font(.system(size: 17, weight: .semibold))
            if case .needsSignIn(let message) = core.status { Text(message).foregroundStyle(.secondary) }
            if core.activeLoginMethod == "token" {
                SecureField("New session token", text: $token).textFieldStyle(.roundedBorder)
                Button("Connect") { Task { await core.updateToken(token) } }.buttonStyle(.borderedProminent).disabled(token.isEmpty)
            } else {
                Button {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            try await core.signInAgain(receiver: NetworkLoopbackReceiver()) { url in
                                Task { @MainActor in NSWorkspace.shared.open(url) }
                            }
                        } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Label("Sign in with browser", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                DisclosureGroup("Use a session token instead") {
                    HStack {
                        SecureField("Session token", text: $token).textFieldStyle(.roundedBorder)
                        Button("Connect") { Task { await core.updateToken(token) } }.disabled(token.isEmpty)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
            HStack {
                Spacer()
                Button("Not now") { Task { await core.stop() } }
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionsSettings().tabItem { Label("Connections", systemImage: "network") }
            MCPSettings().tabItem { Label("MCP Servers", systemImage: "puzzlepiece.extension") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 600, height: 480)
    }
}

struct ConnectionsSettings: View {
    @Environment(AgoraCore.self) private var core
    @Environment(AppModel.self) private var app
    @State private var adding = false
    @State private var renaming: SavedConnection?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(core.registry.connections) { c in
                    HStack {
                        Image(systemName: c.isLocal ? "desktopcomputer" : "server.rack")
                        VStack(alignment: .leading) {
                            Text(c.name)
                            Text(c.remoteURL?.absoluteString ?? "Hermes on this Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if c.id == core.registry.activeID {
                            Text("Active").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        } else {
                            Button("Use") {
                                Task {
                                    await core.switchConnection(to: c.id)
                                    app.destination = .today
                                    if core.status == .connected { await core.watchBotChats() }
                                }
                            }
                        }
                        Menu {
                            Button("Rename…") {
                                newName = c.name
                                renaming = c
                            }
                            Button("Remove", role: .destructive) { Task { await core.removeConnection(c.id) } }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            HStack {
                Button("Add Remote…") { adding = true }
                if !core.registry.connections.contains(where: \.isLocal), AgoraCore.localHermesInstalled {
                    Button("Add This Mac") { Task { await core.addLocalConnection() } }
                }
            }
        }
        .padding(20)
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a Remote Connection").font(.headline)
                RemoteConnectionForm { adding = false }
                HStack {
                    Spacer()
                    Button("Close") { adding = false }
                }
            }
            .padding(24)
            .frame(width: 460)
        }
        .alert("Rename Connection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let r = renaming { core.renameConnection(r.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(AgoraCore.self) private var core
    @State private var hotkey = HotkeyChoice.saved
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var error: String?

    var body: some View {
        @Bindable var app = app
        Form {
            Picker("Appearance", selection: $app.appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Quick Ask hotkey", selection: $hotkey) {
                ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: hotkey) { _, value in
                HotkeyChoice.saved = value
                app.hotkey.register(value)
            }
            Toggle("Open Agora at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, value in
                    do { try LoginItem.set(value) } catch {
                        self.error = "Couldn't change the login item: \(error.localizedDescription)"
                        openAtLogin = LoginItem.isEnabled
                    }
                }
            Text("Closing the window keeps Agora running in the Dock so notifications and Quick Ask keep working. ⌘Q quits.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            if core.installsAgoraSkill {
                Toggle("Teach my Bots about Agora", isOn: Binding(get: { core.teachBots == true }, set: { core.setTeachBots($0) }))
                Text(TeachBots.explanation + " Turning this off leaves what's already there; turn the skill off in Skills.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                if core.teachBots == true && !core.allBots.isEmpty {
                    Text(TeachBots.openChats).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    RefreshPromptsCommand()
                }
            }
            UpdateSettings(updater: app.updater)
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
    }
}

struct NotificationSettings: View {
    @Environment(AgoraCore.self) private var core
    var body: some View {
        Form {
            Section("Notify me about Routine results and messages from other Bots") {
                if core.allBots.isEmpty { Text("Connect to see your Bots.").foregroundStyle(.secondary) }
                ForEach(core.allBots) { bot in
                    Toggle(isOn: Binding(get: { !core.isMuted(bot.name) }, set: { core.setMuted(bot.name, !$0) })) {
                        HStack {
                            BotAvatar(bot: bot, size: 18)
                            Text(bot.title)
                        }
                    }
                }
            }
            Text("Approvals always notify you when Agora isn't in front, so a Bot is never stuck waiting.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Settings → General: automatic update checks (release builds only).
struct UpdateSettings: View {
    let updater: AppUpdater
    @State private var automatic = false

    var body: some View {
        if updater.isAvailable {
            Toggle("Check for updates automatically", isOn: $automatic)
                .onAppear { automatic = updater.checksAutomatically }
                .onChange(of: automatic) { _, on in updater.checksAutomatically = on }
            HStack {
                Button("Check Now") { updater.checkForUpdates() }
                if let last = updater.lastChecked {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            if AppFlavor.current == .nightly {
                Text("This is Agora Nightly: built every night from the latest code. It updates to new nightly builds and keeps its own settings, separate from Agora.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        } else {
            Text(AppFlavor.current == .dev
                ? "This is Agora Dev, built from source: it keeps its own settings and doesn't update itself. Rebuild to update it."
                : "This copy doesn't update itself. Install a release from GitHub to get updates in the app.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}
