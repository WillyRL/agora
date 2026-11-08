import Foundation

/// Something a Bot is waiting on you for: an approval, a clarifying question, or a secret.
public struct PendingPrompt: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Permission to run something. `choices` ⊆ `once`, `session`, `always`, `deny`.
        case approval(command: String, description: String, choices: [String])
        /// A question, optionally with choices.
        case clarify(question: String, choices: [String], multiSelect: Bool)
        /// Several questions at once (batch clarify). Answers are keyed by question id.
        case clarifyBatch(questions: [Question])
        /// A secret value (API key, token …) for an environment variable.
        case secret(prompt: String, envVar: String)
        /// The sudo password for a command.
        case sudo(command: String)
    }

    public struct Question: Sendable, Equatable, Identifiable {
        public var id: String
        public var question: String
        public var choices: [String]
        public var multiSelect: Bool
    }

    /// `prompt_id` for approval/clarify events, or the server request id (`srq-…`).
    public var id: String
    public var bot: String
    public var sessionID: String
    public var kind: Kind
    /// Answered through `approval.respond`/`clarify.respond` (event prompts) or a JSON-RPC response (server requests).
    public var isServerRequest: Bool
    public var generation: Int

    /// True for prompts whose answer must never be shown or stored (secrets and passwords).
    public var isSecret: Bool {
        switch kind {
        case .secret, .sudo: return true
        default: return false
        }
    }
}
