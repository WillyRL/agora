# Agora Glossary

**Agora**:
A native macOS app for talking with your personal Bots. It is only a client: every Bot's thinking, tools and memory live in Hermes, not in Agora.
_Avoid_: Hermes Desktop, the app (ambiguous)

**Hermes**:
The agent system (Hermes Agent by Nous Research) that runs the Bots. Agora connects to it but never reimplements it.
_Avoid_: backend, server

**Bot**:
A personal assistant with its own purpose and identity: name, persona, model, tools, skills, memory and conversation history. Each Bot is separate, and you choose which one to talk to, like picking a contact. In Hermes terms, one Bot is one profile.
_Avoid_: agent, profile (Hermes' word; use only when talking about Hermes internals), mode, persona

**Bot Chat**:
The single, never-ending main conversation with a Bot, like a messaging thread with a contact. When it gets long it is condensed rather than restarted. Other Bots' messages to this Bot arrive here.
_Avoid_: main session, default chat, thread

**Side Chat**:
A separate conversation with the same Bot, for a topic that shouldn't clutter its Bot Chat. It can start empty or carry over recent context from the Bot Chat. The Bot keeps its persona, skills and memory there.
_Avoid_: session, branch, fork, tab

**Routine**:
A task a Bot runs by itself on a schedule (for example "brief me on the markets every weekday at 7am"). Its results arrive in that Bot's Bot Chat.
_Avoid_: cron job, scheduled task, automation

**Connection**:
The Hermes that Agora talks to. It is either **Local** (Hermes running on this Mac) or **Remote** (Hermes running on another machine, with nothing Hermes-related needed on this Mac). You choose which one to use.
_Avoid_: gateway, backend, server

**Quick Ask**:
A small floating panel, opened with a global hotkey, for asking a Bot something without opening the main window.
_Avoid_: spotlight, launcher, popup

**Kanban Task**:
A card on Hermes's kanban board, worked on by a Bot in a chat of its own that only the board may run. Bots often create them by themselves. Agora shows the card's chat read-only in that Bot's Side Chats and lets you answer what the card asks of you (comment, unblock, approve); the board itself stays in Hermes. See `docs/adr/0002-kanban-tasks-are-handled-not-managed.md`.
_Avoid_: job, ticket, kanban session
