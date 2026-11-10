import SwiftUI

/// How to make Hermes on another machine reachable and keep it running, folded under the Remote
/// connection form. The gateway does both: its web listener (`webapp.*`) serves what Agora needs,
/// and `hermes gateway install` runs it in the background.
struct ServeGuide: View {
    /// Open in snapshots, so the guide can be checked.
    @State private var open = ProcessInfo.processInfo.environment["AGORA_SNAPSHOT"] != nil

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run these on the machine with your Bots. The Hermes gateway serves Agora and keeps running in the background.")
                    .foregroundStyle(.secondary)
                step(1, "Give Hermes a login") {
                    Text("Hermes won't take connections from other machines without one. You'll use it in **Sign in with browser**.")
                    CommandBox(command: "hermes config set dashboard.basic_auth.username me\nhermes config set dashboard.basic_auth.password 'a long password'")
                }
                step(2, "Let it take connections") {
                    Text("On a **Tailscale** tailnet or your home network:")
                    CommandBox(command: "hermes config set webapp.enabled true\nhermes config set webapp.host 0.0.0.0")
                    Text("Behind a **Cloudflare Tunnel**, keep it local, give it the tunnel's address, and point the tunnel at `http://localhost:9120`:")
                    CommandBox(command: "hermes config set webapp.enabled true\nhermes config set webapp.public_url https://hermes.example.com")
                }
                step(3, "Keep it running") {
                    Text("This runs the gateway in the background and starts it when you log in. If it's already installed, use `hermes gateway restart` instead.")
                    CommandBox(command: "hermes gateway install")
                    Text("`hermes gateway status` shows whether it's running.").foregroundStyle(.secondary)
                }
                step(4, "Connect") {
                    Text("Agora finds it on your tailnet above. Or type its address, like `http://<machine name>:9120` or your tunnel's, press **Check**, then **Sign in with browser**.")
                }
                Text("Prefer a token to a password? Put `HERMES_DASHBOARD_SESSION_TOKEN=<token>` in `~/.hermes/.env` and run `hermes serve --host <address>` instead of the gateway, then paste the token here. `hermes serve` stops when you close its terminal.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .padding(.top, 8)
        } label: {
            Label("How to set up Hermes on the other machine", systemImage: "terminal")
                .font(.system(size: 12, weight: .medium))
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { open.toggle() } }
        }
    }

    func step(_ n: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accent.opacity(0.15)))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                content().fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A shell command with a Copy button.
struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(command)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command + "\n", forType: .string)
                copied = true
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
    }
}
