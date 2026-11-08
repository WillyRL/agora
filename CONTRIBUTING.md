# Contributing to Agora

Thanks for helping. Issues and pull requests are welcome: keep changes small and focused, add or update a test when behaviour changes, and run `swift test` before opening a PR.

## Build and test

Needs macOS 15+ and Xcode 26+ (Swift 6.2).

```sh
swift build
swift test
scripts/build-app.sh && open "build/Agora Dev.app"
```

`build-app.sh` makes **Agora Dev** by default: its own app (`io.github.willyrl.agora.dev`, an orange DEV band on the icon) with its own settings and saved logins, so it never touches the Agora you use every day. It doesn't update itself, and its Quick Ask hotkey starts off. `scripts/build-app.sh stable` builds the regular **Agora** instead.

Tests drive Agora Core against a fake Hermes that replays protocol conversations from `Tests/AgoraCoreTests/Fixtures`, so they need no Hermes and no network.

**Password prompt after every rebuild?** macOS ties saved logins to the app's signature, and ad-hoc signed builds look like a new app every time. Run `scripts/make-signing-cert.sh` once per Mac: it creates a local signing certificate that `build-app.sh` then uses. On the next build macOS asks twice (once for `codesign`, once for Agora); enter your login password and click **Always Allow**.

## Day to day

- **Everyday app:** Agora (or Agora Nightly) from Releases. **Working on Agora:** Agora Dev from `build-app.sh`. The three install side by side.
- **Changes:** work on a branch and open a pull request, so the tests run on GitHub. Merge to `main` when green; that night's Agora Nightly picks it up.
- **Releases:** when Nightly has been fine for a while, tag a version (see `docs/releasing.md`).

## Recording fixtures

Record a new fixture from the Hermes on your Mac (read-only scenarios):

```sh
swift run agora-record roster /tmp/roster.json
swift run agora-record botchat /tmp/botchat.json <profile>
```

Recordings contain whatever your Hermes holds. **Check them for personal data before committing** (names, home paths, Bot personas, chat text, tokens) and replace it with neutral examples.

## Without Hermes, and screenshots

`AGORA_DEMO=1 "build/Agora Dev.app/Contents/MacOS/Agora"` runs Agora against a made-up Hermes (`Sources/AgoraCore/DemoHermes.swift`). With it, `AGORA_SNAPSHOT=/tmp/shot AGORA_SNAPSHOT_STEPS="appearance:light,size:1280x860,bot:markets,wait:3"` saves screenshots of the screens you list; the steps are in `Sources/Agora/DebugSnapshot.swift`. The README screenshots in `docs/screenshots` come from there.

## Where things are

| Path | What |
|---|---|
| `Sources/AgoraCore` | The Hermes Connection (transport, tickets, reconnect, replay) and Agora Core: Bots, chats, files, prompts, Side Chats, Routines, MCP, skills, the demo Hermes |
| `Sources/Agora` | The SwiftUI app: windows, Quick Ask panel, notifications, global hotkey, Settings, updates |
| `Sources/agora-record` | Records fixtures from a real Hermes |
| `Tests/AgoraCoreTests` | Recorded-conversation tests and the fake Hermes |
| `docs/` | Decisions (`adr/`), the Hermes protocol as Agora uses it (`protocol/`), the design reference (`design/`), releasing (`releasing.md`) |

Words used throughout the code and docs (Bot, Bot Chat, Side Chat, Routine, Connection…) are defined in `GLOSSARY.md`. Agora is a thin client: Hermes does the thinking, tools and memory (`docs/adr/0001`), so new features usually mean using more of Hermes's API, not reimplementing it.
