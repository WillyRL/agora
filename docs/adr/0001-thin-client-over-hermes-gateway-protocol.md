# Agora is a thin client over the Hermes gateway protocol

Agora contains no agent logic. It talks to Hermes only through the same protocol the official Hermes Desktop app uses: JSON-RPC 2.0 over the `/api/ws` WebSocket, plus REST under `/api/*`. One code path serves both a Local Connection (access tickets come from `~/.hermes/gateway.sock`) and a Remote one (`hermes serve`, logged in through the native browser sign-in or a token, with tickets from `/api/auth/ws-ticket`). We chose this protocol because it is the only one with everything Agora needs. That includes approvals, clarify and secret prompts, Bot (profile) management, routines (cron) and session history. Avatars, titles and colours are stored in each profile's `profile.yaml` under `ui_meta.hermes-bots`, the same place the official app uses, so both apps can run against the same Hermes.

## Considered Options

- **OpenAI-compatible API server (`/v1/runs`)**: rejected. It has no approvals, no Bot management and no routines.
- **ACP over stdio (`hermes acp`)**: rejected. It needs a local Hermes process, so it can't serve a Remote-only Mac.
- **Calling models directly from Agora**: rejected. It would duplicate Hermes' memory, tools and Bots, which is the bloat we're avoiding.

## Consequences

- After `gateway.ready`, Agora must call `client.capabilities {"server_requests": true}`. If it doesn't, Hermes silently withdraws every approval prompt.
- A Bot Chat is recognised by its exact session title, `Bot Chat`. Agora must create Bot Chats with that title and must never let you rename them.
- The protocol changes quickly. Before using a feature, check `gateway.capabilities` instead of assuming it's there.
