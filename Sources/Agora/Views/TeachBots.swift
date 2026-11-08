import AgoraCore
import AppKit
import SwiftUI

/// What "Teach my Bots about Agora" does, in the sheet and in Settings.
enum TeachBots {
    static let explanation = "Bots don't know they're in Agora, so they say they can't attach files. Agora can add an agora-chat skill and a line to each Bot's system prompt on your Hermes host, so Bots know they can show files, images and charts here."
    static let openChats = "New chats know right away. Chats already under way keep their old instructions until you run this once on your Hermes host:"
}

/// Asks once whether Agora may teach your Bots about itself, then shows how to update open chats.
struct TeachBotsSheet: View {
    @Environment(AgoraCore.self) private var core
    @Binding var taught: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if taught {
                Text("Your Bots know about Agora").font(.system(size: 17, weight: .semibold))
                Text(TeachBots.openChats).foregroundStyle(.secondary)
                RefreshPromptsCommand()
                HStack {
                    Spacer()
                    Button("Done") { taught = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Teach your Bots about Agora?").font(.system(size: 17, weight: .semibold))
                Text(TeachBots.explanation).foregroundStyle(.secondary)
                Text("You can change this in Settings.").foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Not Now") { core.setTeachBots(false) }.keyboardShortcut(.cancelAction)
                    Button("Teach Them") {
                        taught = true
                        core.setTeachBots(true)
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 460)
    }
}

/// The command that refreshes every Bot's open chats, with a Copy button.
struct RefreshPromptsCommand: View {
    @Environment(AgoraCore.self) private var core
    @State private var copied = false

    var body: some View {
        let command = AgoraHint.refreshCommand(bots: core.allBots.map(\.name))
        HStack(alignment: .top) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command + "\n", forType: .string)
                copied = true
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
