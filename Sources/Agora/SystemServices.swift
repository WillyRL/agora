import AgoraCore
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

// MARK: - Notifications

enum NotificationAction {
    case open(bot: String, session: String)
    case answer(promptID: String, choice: String)
}

/// macOS notifications with approval buttons. Clicking one opens the chat.
final class UserNotificationsNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onAction: (@MainActor (NotificationAction) -> Void)?
    private var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current() }

    static let approvalCategory = "agora.approval"
    static let messageCategory = "agora.message"

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: "once", title: "Allow once"),
            UNNotificationAction(identifier: "session", title: "This session"),
            UNNotificationAction(identifier: "always", title: "Always"),
            UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
        ]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: actions, intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.messageCategory, actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ n: AgoraNotification) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.userInfo = ["bot": n.bot, "session": n.sessionID, "prompt": n.id]
        content.threadIdentifier = n.bot
        if n.kind == .approval {
            content.categoryIdentifier = Self.approvalCategory
            content.sound = .default
        } else {
            content.categoryIdentifier = Self.messageCategory
        }
        center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
    }

    func remove(id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
        center?.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let bot = info["bot"] as? String ?? ""
        let session = info["session"] as? String ?? ""
        let prompt = info["prompt"] as? String ?? ""
        let action: NotificationAction
        switch response.actionIdentifier {
        case "once", "session", "always", "deny": action = .answer(promptID: prompt, choice: response.actionIdentifier)
        default: action = .open(bot: bot, session: session)
        }
        await MainActor.run { onAction?(action) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - Global hotkey

/// The Quick Ask hotkey choices offered in Settings.
enum HotkeyChoice: String, CaseIterable, Identifiable {
    case optionSpace, controlSpace, optionCommandSpace, shiftCommandSpace, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .controlSpace: return "⌃ Space"
        case .optionCommandSpace: return "⌥⌘ Space"
        case .shiftCommandSpace: return "⇧⌘ Space"
        case .off: return "Off"
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .controlSpace: return UInt32(controlKey)
        case .optionCommandSpace: return UInt32(optionKey | cmdKey)
        case .shiftCommandSpace: return UInt32(shiftKey | cmdKey)
        case .off: return 0
        }
    }

    static var saved: HotkeyChoice {
        // Only one copy should own ⌥Space: Nightly and Dev start with the hotkey off.
        get { HotkeyChoice(rawValue: UserDefaults.standard.string(forKey: "agora.hotkey") ?? "") ?? (AppFlavor.current == .stable ? .optionSpace : .off) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "agora.hotkey") }
    }
}

/// A system-wide hotkey (Carbon RegisterEventHotKey; needs no accessibility permission).
@MainActor
final class GlobalHotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var current: GlobalHotkey?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register(_ choice: HotkeyChoice) {
        unregister()
        guard choice != .off else { return }
        GlobalHotkey.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotkey.current?.action() } }
                return noErr
            }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4147_5241), id: 1)  // "AGRA"
        RegisterEventHotKey(UInt32(kVK_Space), choice.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}

// MARK: - Open at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Light, Dark, or follow macOS. Applied app-wide, so every window (Quick Ask, Settings) follows.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    static var saved: AppearanceChoice {
        get { UserDefaults.standard.string(forKey: "appearance").flatMap(AppearanceChoice.init(rawValue:)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appearance") }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Whether the app is showing dark right now (for `.system`, what macOS is set to).
    @MainActor static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
