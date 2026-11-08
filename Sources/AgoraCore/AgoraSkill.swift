import Foundation
import os

/// The `agora-chat` skill: what an Agora chat can show (files, images, live HTML), written into every Bot so
/// it knows. Hermes only teaches this to its own desktop app's chats; Agora's chats get no such
/// instructions, so without the skill a Bot assumes a plain terminal and says it can't attach files.
public enum AgoraSkill {
    public static let name = "agora-chat"
    /// Raise this when `document` changes: Bots with an older copy get the new one on their next connect.
    public static let version = 1

    /// Hermes refuses a description longer than this (its skill index is one short line per skill).
    static let maxDescription = 60

    /// Hidden from messaging chats (Telegram, Discord…), where none of this renders.
    public static let document = """
        ---
        name: agora-chat
        description: "Attach files and charts in Agora: write MEDIA:/path lines."
        version: \(version)
        author: Agora
        license: MIT
        metadata:
          hermes:
            tags: [Agora, files, attachments, charts]
            session_platforms: [gui, desktop]
        ---

        # Showing things in Agora

        Agora installs and updates this skill. Edits are kept until Agora ships a newer version.

        You are chatting in Agora, a native macOS chat app for Hermes. It is a graphical chat, not a terminal:
        Markdown renders (headings, lists, tables, code blocks, links), and files you name the right way appear
        in the chat. If your platform instructions say you are in a CLI, TUI or messaging app, they win; ignore
        this skill there.

        ## When to Use

        Whenever you hand the user a file (image, GIF, video, PDF, deck, report), show a chart or table you
        built, or are asked to "attach", "send" or "show" something.

        ## Files

        Put each file on its own line, with nothing else on the line and an absolute path:

        ```
        MEDIA:/Users/me/projects/launch/demo.gif
        ```

        - Images (png, jpg, gif, webp, heic, svg…) show inline.
        - Text files (md, txt, csv, json, log, yaml…) get a card with a View button.
        - Anything else (pdf, mp4, pptx, zip…) gets a card with Open, Quick Look and Save a Copy.
        - The file stays on the Hermes host; Agora fetches it, so it works when the user is on another Mac.
        - `MEDIA:` inside a code block is shown as code, not attached. Use that when you mean the literal text.

        Never tell the user the chat can't show attachments, and don't open files on the host to show them.
        Attach them.

        ## Live HTML (charts, tables, small widgets)

        Write one self-contained HTML file (inline CSS and JS) and put this alone on its own line:

        ```
        ::preview{file="/absolute/path/chart.html"}
        ```

        It renders in the message, sized to its content (up to 1200 pt tall). Agora themes it to match light
        or dark mode: use `var(--foreground)`, `var(--muted-foreground)`, `var(--accent)`, `var(--border)` and
        `var(--card)` for colour, and don't set your own background, font or page margins.

        A widget can talk back: `data-hermes-send="prompt"` on a clickable element, or
        `window.hermes.send("prompt")`, sends that prompt to you as the user's next message (500 characters
        at most, one per second). Answer it by updating the widget's file and previewing it again.

        To hand over an HTML file as a download instead, use `MEDIA:` rather than `::preview`.
        """

    /// Agora wrote it (a skill of the user's own by the same name is left alone).
    static func isOurs(_ content: String) -> Bool {
        content.split(separator: "\n").prefix(20).contains { $0.trimmingCharacters(in: .whitespaces) == "author: Agora" }
    }

    static let log = Logger(subsystem: "io.github.willyrl.agora", category: "agora-skill")

    /// The version an installed copy declares (0 when it has none).
    static func installedVersion(_ content: String) -> Int {
        for line in content.split(separator: "\n").prefix(20) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "version" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) ?? 0
            }
        }
        return 0
    }
}

/// Agora's line in each Bot's system prompt (`platform_hints.gui` in its config.yaml). Hermes has
/// such a line for its own desktop app but none for `gui`, Agora's chats, so a Bot there assumes a
/// terminal and never opens the agora-chat skill. Unlike a skill, this is in every chat from its
/// first turn. A chat already under way keeps the prompt it started with until
/// `hermes sessions refresh-prompts`.
public enum AgoraHint {
    /// Raise this when `text` changes: Bots with an older one get the new one on their next connect.
    public static let version = 1
    static let platform = "gui"

    public static let text = """
        You are chatting in Agora, a native macOS chat app for Hermes: a graphical chat, not a terminal. \
        Markdown renders (headings, lists, tables, code blocks, links). To attach a file, put \
        MEDIA:/absolute/path/to/file alone on its own line: images show inline, and any other file (video, \
        PDF, deck, text) gets a card the user can open, preview or save, even from another Mac. Never say \
        this chat can't show attachments. For a chart or small widget, write a self-contained HTML file and \
        put ::preview{file="/absolute/path/chart.html"} alone on its own line. The agora-chat skill has the details.
        """

    /// The shell lines that make chats already under way rebuild their system prompt (one per Bot, so
    /// the new line reaches all of them). Hermes keeps a chat's prompt until then; no API asks for it.
    public static func refreshCommand(bots: [String]) -> String {
        bots.map { "hermes -p \(shellWord($0)) sessions refresh-prompts" }.joined(separator: "\n")
    }

    static func shellWord(_ s: String) -> String {
        let plain = !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return plain ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What Agora writes: Hermes reads `replace` and ignores `agora_version`, which marks it as Agora's.
    static var entry: JSON { ["replace": .string(text), "agora_version": .number(Double(version))] }

    /// Agora should write its hint over `current` (the Bot's saved `platform_hints.gui`): there is
    /// none, or there's an older one Agora wrote. Anything the user wrote is left alone.
    static func shouldWrite(over current: JSON) -> Bool {
        switch current {
        case .null: return true
        case .object(let o): return o["agora_version"].map { ($0.int ?? 0) < version } ?? false
        default: return false
        }
    }
}

extension AgoraCore {
    /// You agreed to let Agora teach your Bots about itself: the `agora-chat` skill and Agora's line in
    /// each Bot's system prompt, both written into the Bot's files on the Hermes host. `nil` until
    /// you've been asked (`shouldAskToTeachBots`). One answer for every Connection on this Mac.
    public var teachBots: Bool? {
        get { access(keyPath: \.teachBots); return env.store.decode(Bool.self, "teachBots") }
        set { withMutation(keyPath: \.teachBots) { env.store.encode(newValue, "teachBots") } }
    }

    /// Time to ask: connected, with Bots, and never asked.
    public var shouldAskToTeachBots: Bool {
        installsAgoraSkill && teachBots == nil && status == .connected && !allBots.isEmpty
    }

    /// Answers the question (or flips the Settings switch). Yes teaches every Bot now. No leaves
    /// alone what's already there: the skill can be turned off in Skills.
    public func setTeachBots(_ on: Bool) {
        teachBots = on
        if on { teachUncheckedBots() }
    }

    /// Teaches each Bot not yet taught on this Connection, if you agreed.
    func teachUncheckedBots() {
        guard installsAgoraSkill, teachBots == true else { return }
        let unchecked = allBots.map(\.name).filter { !agoraSkillChecked.contains($0) }
        agoraSkillChecked.formUnion(unchecked)
        if !unchecked.isEmpty { Task { for bot in unchecked { await installAgoraHint(bot: bot); await installAgoraSkill(bot: bot) } } }
    }

    /// Puts Agora's line in a Bot's system prompt, unless the user has their own (see `AgoraHint`).
    func installAgoraHint(bot: String) async {
        do {
            let connection = try requireConnection()
            let config = try await connection.rest("GET", "/api/config", profile: bot, query: ["include_defaults": "false"])
            guard AgoraHint.shouldWrite(over: config["platform_hints"][AgoraHint.platform]) else { return }
            // Hermes merges this into the saved config, so nothing else changes.
            _ = try await connection.rest("PUT", "/api/config", profile: bot,
                body: ["config": ["platform_hints": .object([AgoraHint.platform: AgoraHint.entry])]])
        } catch {
            AgoraSkill.log.error("agora hint for \(bot, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Gives a Bot the current `agora-chat` skill. A Bot without it gets it; one with an older copy
    /// that Agora wrote gets the new one. Turning it off sticks (that only changes Hermes's skill config).
    /// Best effort: a Hermes without the skills API just doesn't get it.
    func installAgoraSkill(bot: String) async {
        do {
            let installed = try await skills(bot: bot)
            if !installed.contains(where: { $0.name == AgoraSkill.name }) {
                try await createSkill(AgoraSkill.name, content: AgoraSkill.document, category: nil, bot: bot)
            } else {
                let content = try await skillContent(AgoraSkill.name, bot: bot)
                if AgoraSkill.isOurs(content), AgoraSkill.installedVersion(content) < AgoraSkill.version {
                    try await saveSkill(AgoraSkill.name, content: AgoraSkill.document, bot: bot)
                }
            }
        } catch {
            AgoraSkill.log.error("agora-chat skill for \(bot, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
