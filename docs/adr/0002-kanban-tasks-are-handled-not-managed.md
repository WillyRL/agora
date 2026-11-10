# Agora handles kanban tasks but doesn't manage the board

Hermes has a kanban board. Bots create cards on it by themselves (`kanban_create`), and the board runs each card in its own chat with the assigned Bot. You can't stop a Bot from making cards, so Agora can't ignore them: a card's chat shows up in that Bot's Side Chats, its news arrives in the Bot Chat of the Bot that made it, and a card may wait for you (blocked, or ready for review).

Agora is for talking with your Bots (see `GLOSSARY.md`), so it handles a card where it meets a conversation, and leaves running the board to Hermes:

- **In Agora:** see a card's chat (read-only; only the board may run it), its status, block reason and comments; comment on it; unblock a blocked card; approve a card waiting for review. These are what a card asks of you, and a comment is a message to the Bot that works on it.
- **In Hermes:** the board view, creating cards, moving them between columns, assigning or reassigning Bots, links between cards, boards and their settings. To do any of these from Agora, ask a Bot ("put this on the board"); Hermes does it and Agora shows the result.

The test for a new kanban feature: does it answer a card that's waiting for you, or show what a Bot did? Then it belongs in Agora. Does it organise the work? Then it belongs in Hermes.

## Considered Options

- **Ignore kanban**: rejected. Card chats failed to open, and blocked cards waited with no way to answer them from Agora.
- **A full board in Agora**: rejected. It duplicates the Hermes dashboard and turns Agora into a project manager.

## Consequences

- Agora uses the kanban plugin's REST API (`/api/plugins/kanban/…`) with the same login as other REST calls. It reads `GET /tasks/{id}` and writes only `POST /tasks/{id}/comments` and `PATCH /tasks/{id}` with `status` `ready` (unblock) or `done` (approve).
- A card's id comes from the chat itself: the brief that opens a card's chat, or a `[kanban] Task t_… …` update. A card may live on any board, so Agora looks on the current board first, then the others.
- If Hermes has the kanban plugin turned off, Agora still shows card chats read-only, without the card's status or actions.
