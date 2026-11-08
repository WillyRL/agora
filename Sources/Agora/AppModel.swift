import AgoraCore
import AppKit
import Foundation
import Observation
import SwiftUI

/// Where the main window is.
enum Destination: Hashable {
    case today
    case bot(String)
    case sideChat(bot: String, session: String)
    case allBots
    case newBot
    case editBot(String)

    var sessionID: String? {
        if case .sideChat(_, let s) = self { return s }
        return nil
    }

    var isChat: Bool {
        switch self {
        case .bot, .sideChat: return true
        default: return false
        }
    }

    var bot: String? {
        switch self {
        case .bot(let b), .sideChat(let b, _), .editBot(let b): return b
        default: return nil
        }
    }
}

/// App-level state: builds Agora Core with the real system pieces and holds UI navigation.
@MainActor
@Observable
final class AppModel {
    let core: AgoraCore
    let notifier = UserNotificationsNotifier()
    let updater = AppUpdater()
    var destination: Destination = .today {
        didSet {
            // Opening a Side Chat always shows its Bot's list.
            if case .sideChat(let bot, _) = destination { collapsedBots.remove(bot) }
            // Focus only exists in a chat.
            if focusMode, !destination.isChat { setFocus(false) }
            syncViewing()
        }
    }
    /// Focus: the sidebar hides, the window narrows, and a row of Bots sits above the chat.
    private(set) var focusMode = false
    private var frameBeforeFocus: NSRect?
    /// Bots whose Side Chat list was folded away by clicking the Bot again.
    var collapsedBots: Set<String> = []
    var showRoutines = false
    var composerFocus = 0
    var showSetup = false
    /// The setup screen opens on "On another machine" (snapshots).
    var setupStartsRemote = false
    var appearance = AppearanceChoice.saved {
        didSet {
            AppearanceChoice.saved = appearance
            appearance.apply()
        }
    }
    var quickAsk: QuickAskController!
    var hotkey: GlobalHotkey!
    /// Opens the main window (set by the SwiftUI scene).
    var openMainWindow: (() -> Void)?

    /// Flips between Light and Dark (from System, to the opposite of what's showing).
    func toggleAppearance() {
        appearance = AppearanceChoice.isDark ? .light : .dark
    }

    init() {
        let store: KeyValueStore
        let env: AgoraEnvironment
        if ProcessInfo.processInfo.environment["AGORA_DEMO"] != nil {
            // A made-up Hermes with made-up Bots, for screenshots and trying Agora out.
            env = DemoHermes.environment(notifier: notifier)
            store = env.store
            let registry = ConnectionRegistry(store: store)
            registry.activate(registry.add(name: "Demo Mac", kind: .local).id)
        } else {
            store = UserDefaultsStore()
            env = AgoraEnvironment(
                sockets: URLSessionSockets(), http: URLSessionHTTP(), control: UnixControlSocket(), starter: ProcessGatewayStarter(),
                credentials: KeychainCredentialStore(), notifier: notifier, store: store, tailnet: TailscaleCLI())
        }
        let registry = ConnectionRegistry(store: store)
        core = AgoraCore(registry: registry, environment: env)
        showSetup = registry.connections.isEmpty
        quickAsk = QuickAskController(app: self)
        hotkey = GlobalHotkey { [weak self] in self?.quickAsk.toggle() }
        notifier.onAction = { [weak self] action in self?.handle(action) }
    }

    func launch() async {
        if DebugSnapshot.prefix == nil {
            notifier.requestAuthorization()
            hotkey.register(HotkeyChoice.saved)
        }
        guard !showSetup else { return }
        await connect()
    }

    /// Connects the active Connection and starts watching every Bot Chat for activity.
    func connect() async {
        await core.start()
        if case .needsSignIn = core.status { return }
        if core.status == .connected {
            await core.watchBotChats()
        }
    }

    func focusComposer() { composerFocus += 1 }

    func newSideChat(bot: String, carryContext: Bool) async {
        do {
            let side = try await core.newSideChat(for: bot, carryContext: carryContext)
            destination = .sideChat(bot: bot, session: side.storedSessionID)
        } catch {
            core.notice = "Couldn't start a Side Chat: \(error.localizedDescription)"
        }
    }

    /// Shows a chat in the main window (from Quick Ask or a notification).
    func show(bot: String, session: String?) {
        if let session, let c = core.conversation(session), !c.isBotChat {
            destination = .sideChat(bot: bot, session: c.storedSessionID)
        } else {
            destination = .bot(bot)
        }
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Turns Focus on or off. Turning it on outside a chat opens the most recent Bot's chat.
    func setFocus(_ on: Bool) {
        guard on != focusMode else { return }
        if on, !destination.isChat {
            guard let bot = core.defaultQuickAskBot else { return }
            destination = .bot(bot.name)
        }
        focusMode = on
        resizeWindow(forFocus: on)
        composerFocus += 1
    }

    /// The previous (-1) or next (+1) Bot's chat, wrapping around.
    func switchBot(_ step: Int) {
        let bots = core.bots
        guard !bots.isEmpty else { return }
        let i = bots.firstIndex { $0.name == destination.bot } ?? 0
        destination = .bot(bots[(i + step + bots.count) % bots.count].name)
    }

    /// Narrows the window to 980 pt around its centre for Focus, and gives the old size back after.
    private func resizeWindow(forFocus on: Bool) {
        guard let window = NSApp.windows.first(where: { $0.title == "Agora" && $0.isVisible }),
            !window.styleMask.contains(.fullScreen)
        else { return }
        var frame = window.frame
        if on {
            guard frame.width > 1000 else { return }
            frameBeforeFocus = frame
            frame.origin.x += (frame.width - 980) / 2
            frame.size.width = 980
        } else {
            guard let before = frameBeforeFocus else { return }
            frameBeforeFocus = nil
            frame.origin.x -= (before.width - frame.width) / 2
            frame.size.width = before.width
        }
        window.setFrame(frame, display: true, animate: true)
    }

    func syncViewing() {
        switch destination {
        case .bot(let b): core.setViewing(bot: b, session: nil)
        case .sideChat(let b, let s): core.setViewing(bot: b, session: s)
        default: core.setViewing(bot: nil, session: nil)
        }
    }

    func handle(_ action: NotificationAction) {
        switch action {
        case .open(let bot, let session):
            show(bot: bot, session: session)
        case .answer(let promptID, let choice):
            Task { await core.answerFromNotification(promptID: promptID, choice: choice) }
        }
    }
}
