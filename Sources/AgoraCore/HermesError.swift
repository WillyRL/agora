import Foundation

public enum HermesError: Error, Sendable, Equatable, LocalizedError {
    /// The server answered a JSON-RPC call with an error.
    case rpc(code: Int, message: String, reason: String?, data: JSON)
    /// A REST call came back with a non-2xx status.
    case http(status: Int, detail: String)
    /// The socket dropped while a call was waiting.
    case connectionLost
    /// Not connected yet, or offline.
    case notConnected
    /// The Hermes we reach can't be used as configured (close code 4403, Host check, …). Retrying won't help.
    case configuration(String)
    /// Remote login expired and couldn't be refreshed: the user must sign in again.
    case signInRequired(String)
    /// Hermes isn't running locally and couldn't be started.
    case hermesUnavailable(String)
    /// Something in the protocol didn't look the way Agora expects.
    case protocolViolation(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .rpc(_, let message, let reason, _): return reason.map { "\(message) (\($0))" } ?? message
        case .http(let status, let detail): return "HTTP \(status): \(detail)"
        case .connectionLost: return "The connection to Hermes dropped."
        case .notConnected: return "Not connected to Hermes."
        case .configuration(let m): return m
        case .signInRequired(let m): return m
        case .hermesUnavailable(let m): return m
        case .protocolViolation(let m): return "Unexpected reply from Hermes: \(m)"
        case .timeout(let m): return "Timed out: \(m)"
        }
    }

    /// JSON-RPC "method not found": the server predates this feature.
    public var isMethodNotFound: Bool {
        if case .rpc(let code, _, _, _) = self { return code == -32601 }
        return false
    }

    /// Hermes no longer holds this live session (it unloaded an idle chat, or dropped it after a
    /// disconnect). The saved session is fine: resume it by its saved id.
    public var isSessionGone: Bool {
        if case .rpc(let code, _, _, _) = self { return code == 4001 }
        return false
    }

    public var rpcReason: String? {
        if case .rpc(_, _, let reason, _) = self { return reason }
        return nil
    }
}

/// Errors from a view going away (a cancelled task or request) aren't worth telling anyone about.
func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let u = error as? URLError, u.code == .cancelled { return true }
    return (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
}
