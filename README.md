<p align="center"><img src="assets/icon.svg" width="88" height="88" alt=""></p>

<h1 align="center">Agora</h1>

<p align="center"><b>A native macOS desktop for your <a href="https://github.com/NousResearch/hermes-agent">Hermes</a> Bots.</b><br>
Light and clean from day one, and it doesn't make you run Hermes on the same Mac.</p>

<p align="center">
  <img src="docs/screenshots/chat-light.png" width="49%" alt="A chat with a Bot in light mode: a live chart, key levels and the tools the Bot used">
  <img src="docs/screenshots/chat-dark.png" width="49%" alt="The same chat in dark mode">
</p>

I have been using the Hermes for quite a while, the one thing that I don't like about them is their **Hermes Desktop** It's too bloated, I'm using hermes mainly for my assistant, doing repetitive works, not for coding, I'll straight up using the official harness like claude code, therefore I don't need my hermes desktop to have terminal, file explorer, and other features. I only need to chat with my hermes agents and done something for me on background while I'm doing other stuffs, so I made Agora, and I'm quite happy with the result, and I believed someone must have the same problem with me, hope you like it.  

Agora is a small SwiftUI app for talking to the Bots you run in Hermes. Hermes does the thinking, tools, memory and schedules; Agora is the window onto it. Run Hermes on a Mac mini, a home server or a VPS, and use Agora from your laptop. Or run both on one Mac.

## What it does

- **One ongoing chat per Bot**, plus **Side Chats** for separate topics (optionally starting from a summary of the main chat).
- **Replies stream in** with formatted text, tables, code, the tools the Bot used, and images.
- **Files both ways.** Send PDFs, spreadsheets, CSVs and images; get back live HTML charts and widgets right in the message (themed to light or dark mode), images, and cards for anything else (Open, Quick Look, Save).
- **Approvals and questions inline**, or from a notification, when a Bot wants to run something or needs an answer.
- **Remote first.** Connect to `hermes serve` on another machine with a token or browser sign-in, and Agora finds Hermes on your **Tailscale** tailnet for you. It reconnects by itself and picks up where it left off.
- **Manage your Bots.** Create and edit them (purpose, persona, model), see their tools, choose their **MCP servers**, and install or write **skills** for one Bot at a time.
- **Routines.** See, pause, resume, run or delete a Bot's scheduled jobs.
- **Quick Ask** from any app with ⌥Space, **Focus** mode, and a light/dark switch (⇧⌘L).

<p align="center">
  <img src="docs/screenshots/today-light.png" width="49%" alt="Today: what each Bot has been up to">
  <img src="docs/screenshots/today-dark.png" width="49%" alt="Today in dark mode">
</p>

**Focus** puts one Bot at a time in front of you, with nothing else around it. Switch Bots with ← and →, and move between its chats with the tabs.

<p align="center">
  <img src="docs/screenshots/focus-light.png" width="49%" alt="Focus mode in light mode: one Bot, its chats as tabs, and a Bot switcher on top">
  <img src="docs/screenshots/focus-dark.png" width="49%" alt="Focus mode in dark mode">
</p>

## Requirements

- macOS 15 or later.
- Hermes **v0.23 or later**, on this Mac or another machine you can reach.

## Download

Agora is in **beta**: get the newest **Agora-<version>.dmg** from [Releases](https://github.com/WillyRL/agora/releases), open it and drag Agora into Applications. It runs natively on Apple Silicon and Intel. The builds aren't notarized by Apple yet, so the first time you open Agora, go to **System Settings → Privacy & Security** and click **Open Anyway**.

Agora updates itself (**Agora → Check for Updates…**), so a beta moves on to the full release when it's out. See what's new in each version in the [changelog](CHANGELOG.md). Want the newest changes every day? **[Agora Nightly](https://github.com/WillyRL/agora/releases/tag/nightly)** is built every night from `main`. It's a separate app, so it installs next to Agora with its own settings, and updates itself to each new nightly.

## Build it yourself

Needs Xcode 26 or later (Swift 6.2). It takes about a minute:

```sh
git clone https://github.com/WillyRL/agora.git
cd agora
scripts/build-app.sh stable
open build/Agora.app
```

On first launch, choose **On this Mac** if Hermes runs here, or **On another machine** to connect to a remote one.

**Tired of the password prompt after every rebuild?** Run `scripts/make-signing-cert.sh` once. Builds then keep the same signature, so macOS stops asking; click **Always Allow** the next time it does.

### Try it without Hermes

```sh
AGORA_DEMO=1 build/Agora.app/Contents/MacOS/Agora
```

Opens Agora against a made-up Hermes with six example Bots (the screenshots above). Nothing is saved and nothing leaves the app.

## Hermes on another machine

On the machine that runs your Bots, serve Hermes where Agora can reach it. Sign-in is always required off loopback; `basic` username/password is fine on a tailnet:

```sh
hermes serve --host "$(tailscale ip -4)" --port 9119
```

In Agora, choose **On another machine** (or Settings → Connections → Add Remote…). Agora reads `tailscale status`, asks each online machine for Hermes on `https://<machine>.<tailnet>.ts.net` (Tailscale Serve) and `http://<machine>:9119`, and lists what it finds. **Connect** names the Connection after the machine and opens browser sign-in. You can also add any URL by hand and paste a session token.

## MCP servers

Settings → MCP Servers manages the servers in the main Hermes profile: switch them on or off, test the connection (and see their tools), add one by URL or command, sign in to OAuth servers in the browser, or remove one. Tokens you type are kept in the Keychain so you enter them once. Each Bot's Configure page picks which servers that Bot uses, and **Add to Bots…** adds one to several Bots at once.

## Skills

Each Bot has its own skills (its profile's `skills/` folder in Hermes). In **Configure <Bot> → Skills** you can turn a skill on or off for that Bot, view or edit its SKILL.md, write a new one (**New Skill…**), or search the skills hub and install one for that Bot only (**Get from Hub…**). Changes apply right away, and the Bot's open chats reload their skills.

The first time you connect, Agora asks to **teach your Bots about Agora** (you can change your answer in Settings → General). If you say yes, it adds one skill to every Bot: **agora-chat**, which tells the Bot how to show files, images and live charts in an Agora chat. Without it, Bots assume a plain terminal and say they can't attach files. Turn it off in Skills if you don't want it; Agora won't turn it back on. If you edit it, your edits stay until a new Agora version updates it.

It also adds one line to each Bot's system prompt saying it's in Agora and can attach files (`platform_hints.gui` in the Bot's `config.yaml`). Replace it with your own text and Agora leaves it alone. A chat already under way keeps the prompt it started with until you run `hermes -p <bot> sessions refresh-prompts` on the Hermes host. Agora shows the command for all your Bots, with a Copy button, after you say yes and in Settings → General.

## Contributing

Issues and pull requests are welcome. Build with `swift build` and test with `swift test` (no Hermes needed); [CONTRIBUTING.md](CONTRIBUTING.md) has the details.

## License

[MIT](LICENSE). Agora is an independent project and isn't affiliated with Nous Research or the Hermes project.
