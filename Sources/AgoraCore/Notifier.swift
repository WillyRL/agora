import Foundation
import Synchronization

public struct AgoraNotification: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case routineResult, botMessage, approval, question
    }

    public var id: String
    public var kind: Kind
    public var bot: String
    public var title: String
    public var body: String
    public var sessionID: String
    /// For approvals: the choices the notification's buttons offer (`once`, `session`, `always`, `deny`).
    public var choices: [String]

    public init(id: String, kind: Kind, bot: String, title: String, body: String, sessionID: String, choices: [String] = []) {
        self.id = id
        self.kind = kind
        self.bot = bot
        self.title = title
        self.body = body
        self.sessionID = sessionID
        self.choices = choices
    }
}

/// macOS notifications. The app uses `UserNotificationsNotifier`; tests use `RecordingNotifier`.
public protocol Notifier: Sendable {
    func post(_ notification: AgoraNotification)
    func remove(id: String)
}

public final class RecordingNotifier: Notifier {
    private let state = Mutex<[AgoraNotification]>([])
    private let removed = Mutex<[String]>([])
    public init() {}
    public func post(_ notification: AgoraNotification) { state.withLock { $0.append(notification) } }
    public func remove(id: String) { removed.withLock { $0.append(id) } }
    public var posted: [AgoraNotification] { state.withLock { $0 } }
    public var removedIDs: [String] { removed.withLock { $0 } }
}
