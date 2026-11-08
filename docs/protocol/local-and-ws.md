# Hermes local gateway protocol — control socket + `/api/ws` (canonical, `hermes-gateway-v1`)

Target: Hermes Agent **v0.23.0** (`code_version` live), source `~/.hermes/hermes-agent`. All `file:line`
refs are relative to that tree unless prefixed. "Live" = observed on this machine's running gateway
(read-only probe: `identify`, one unredeemed `interactive` ticket, `gateway ensure --json`).
Anything not proven from source or live is marked **UNVERIFIED**.

> **Key architectural fact.** On a *local* connection the Desktop app does **not** talk to the legacy
> TUI sidecar (`tui_gateway/server.py`). It dials the gateway **owner** ("session authority") over
> `/api/ws` with a native ticket; the socket is wrapped by `gateway/session_controls.py::AuthorityConnection`
> (`tui_gateway/ws.py:376-385`). Method shapes are the **canonical** contracts in
> `tui_gateway/contracts/canonical.py` + `canonical_sessions.py` + `canonical_projections.py`, which
> **override** the legacy ones in `gateway-contract.openrpc.json` for the same names. Several "legacy"
> verbs in the website docs (`session.title`, `session.archive`, `session.delete`, `session.compress`,
> `session.activate`, approvals as server requests) do **not** exist on this path — they are
> translated by `apps/desktop/src/api/canonical-protocol.ts` into canonical verbs. Agora must speak
> the canonical verbs directly.

---

## 1. Control socket `~/.hermes/gateway.sock`

Server: `gateway/control_socket.py::GatewayControlServer`, started from `gateway/run_bootstrap.py:270-380`.
Client reference: `apps/desktop/electron/local-gateway.ts`.

### 1.1 Location & security
- Path `$HERMES_HOME/gateway.sock`, mode `0600`, created under umask `0177` (`control_socket.py:281-287`).
- Fallback when path > 100 bytes or FS refuses sockets: `<$XDG_RUNTIME_DIR or tmp>/hermes-gw-<sha256(home)[:16]>/control.sock`,
  and `$HERMES_HOME/gateway.sock.path` is a text file naming it (`control_socket.py:70-119`). Agora: if
  `gateway.sock` is absent but `gateway.sock.path` exists, read it.
- `session-ticket` is only granted when the peer **uid == gateway uid** (`getpeereid` on macOS,
  `control_socket.py:399-413`, `hermes_cli/gateway_runtime_discovery.py:106`) **and** the home is a
  real non-symlinked dir owned by the user and not group/other-writable (`gateway_runtime_discovery.py:50`).
  Otherwise: `PermissionError: authenticated runtime bootstrap unavailable`.
- Electron pre-checks before dialing (`local-gateway.ts:389-418, 598-616, 642`): socket is a socket,
  owned by our uid, no group/other bits; home not other-writable; home path canonical (== realpath).
  Agora should replicate (cheap defence against a planted socket).

### 1.2 Framing
**One request per connection.** Client writes exactly one JSON object + `\n`; server writes one JSON
object + `\n`, then closes (`control_socket.py:6, 415-432`). Request line ≤ 64 KiB, response ≤ 512 KiB,
server waits ≤ 2 s for the request line.

Request envelope:
```json
{"protocol":1,"id":1,"verb":"identify","params":{}}
```
Responses (`control_socket.py:323-367`):
```json
{"ok":true,"protocol":1,"id":1,"result":{ ... }}
{"ok":false,"protocol":1,"id":1,"error":"PermissionError: stale runtime instance"}
{"ok":false,"protocol":1,"id":1,"error":"unknown verb: 'x'","supported_verbs":["active-work","identify",...]}
{"ok":false,"protocol":1,"error":"response_too_large","code":"response_too_large","limit":524288}
```
`error` is `"<PythonExceptionType>: <message>"`. Live supported verbs: `active-work, identify,
migrate-profile-identity, pause-for-update, purge-profile-identity, relay-link, reload-plugins,
rescan-profiles, serve-profile, status, unserve-profile, session-ticket`. Agora needs only
`identify` and `session-ticket`. **Never call the others** (they mutate the gateway).

### 1.3 `identify`
Built by `control_socket.py:177-192` (`build_identify_payload`) + `run_bootstrap.py:294-310`.
Live response (trimmed lists):
```json
{"ok":true,"protocol":1,"id":1,"result":{
  "protocol":1,"kind":"hermes-gateway","pid":57005,"start_time":179397355748,
  "hermes_home":"/Users/me/.hermes","profile":"default",
  "supervisor":"launchd","launch_supervisor":"launchd",
  "code_sha":"2bd378ed…","code_version":"0.23.0",
  "served_profiles":[
    {"profile_id":"/Users/me/.hermes","home":"/Users/me/.hermes"},
    {"profile_id":"/Users/me/.hermes/profiles/coder","home":"/Users/me/.hermes/profiles/coder"}],
  "instance_id":"cc85826d737e41719fa42571c3668626","runtime_protocol":1,"authority_epoch":3,
  "state":"ready","api_origin":"http://127.0.0.1:56904","parked_profiles":{},
  "capabilities":["session-authority-v1","durable-admission-v1","event-replay-v1"]}}
```
- No `host`/`port` fields: use `api_origin` (always loopback `http://127.0.0.1:<dynamic port>`).
- `state`: `"ready"` | `"draining"` (+ `drain_reason`, `capabilities: []`). Only dial on `ready`.
- `profile_id` everywhere = **absolute profile home path** (`~/.hermes` for `default`,
  `~/.hermes/profiles/<name>` for others), *not* the profile name.
- `instance_id` changes on gateway restart → tickets for the old one fail with `stale runtime instance`.
- `supervisor` collapses `manual`/`desktop` to `"none"`; real value is `launch_supervisor`.

### 1.4 `session-ticket`
Request exactly as Electron sends it (`local-gateway.ts:664`, scope helper `:621-623`):
```json
{"protocol":1,"id":7,"verb":"session-ticket","params":{
  "profile_id":"/Users/me/.hermes","instance_id":"cc85826d737e41719fa42571c3668626",
  "purpose":"interactive","scope":"host"}}
```
- Top-level keys allowed: only `protocol, verb, id, params`; `protocol` must be `1` (`control_socket.py:372`).
- `params` keys allowed: `profile_id, instance_id, purpose` (required) + `scope, subject, restart_wait`
  (`control_socket.py:375-378`).
- `purpose` ∈ `interactive | native-http | native-profile-create | native-profile-registry | exposure | worker-adoption`
  (`gateway/runtime_bootstrap.py:9-20`). WS = `interactive`; REST (`/api/...`) = `native-http`.
- `scope` ∈ `profile` (default) | `host` (only with `interactive`). **`host`** = the socket may address any
  served profile via `params.profile` (see §8). Electron always sends `scope:"host"` for interactive.

Live response (ticket redacted):
```json
{"ok":true,"protocol":1,"id":7,"result":{
  "ticket":"g-2p…(43 chars, token_urlsafe(32))","expires_in_seconds":30,
  "instance_id":"cc85826d737e41719fa42571c3668626","profile_id":"/Users/me/.hermes","runtime_protocol":1}}
```
- **Single use, 30 s TTL** (`runtime_bootstrap.py:26,50`); max 1024 outstanding (`bootstrap capacity exhausted`).
  Mint a fresh ticket for **every** WS dial / reconnect and every REST request.
- Validate like Electron (`local-gateway.ts:676`): `ok`, `protocol==1`, same `id`, echoed
  `instance_id`/`profile_id` equal to the request.
- Errors: `stale runtime instance`, `invalid bootstrap envelope`, `invalid bootstrap parameters`,
  `invalid bootstrap subject`, `bootstrap binding rejected` (unserved profile / bad purpose / bad scope),
  `bootstrap capacity exhausted`.

### 1.5 `hermes gateway ensure --json`
`hermes_cli/gateway_runtime_cli.py:17-37`, logic `hermes_cli/gateway_runtime.py:390-495`, flag
`--timeout` (default 60). If an owner is `ready` it only discovers; it starts one only if none is
running/starting, and replaces one only if it is `incompatible` (older runtime protocol). Prints one
line of compact sorted-key JSON, **no credentials**:
```json
{"client_code_sha":"2bd378ed…","detail":null,"endpoint":{
   "api_origin":"http://127.0.0.1:56904","authority_epoch":3,
   "capabilities":["durable-admission-v1","event-replay-v1","session-authority-v1"],
   "code_sha":"2bd378ed…","control_home":null,"instance_id":"cc85826d737e41719fa42571c3668626",
   "profile_id":"/Users/me/.hermes","runtime_protocol":1,"supervisor":"launchd"},
 "reason_code":null,"state":"ready"}
```
- With `--profile coder`: same origin/instance, `"profile_id":"…/profiles/coder"`, `"control_home":"/Users/me/.hermes"`
  → mint tickets on the **control_home**'s socket. One process serves all profiles here (7 live).
- `state` ∈ `ready|starting|draining|incompatible|inaccessible|conflict|absent`. Exit codes: 0 ready,
  2 bad invocation, 3 incompatible, 4 auth/profile mismatch, 5 starting/deadline, 6 draining/update-paused,
  7 inaccessible/conflict.
- Electron: `runGatewayEnsure` (`local-gateway.ts:15-58`; HERMES_HOME set, 75 s timeout, 64 KiB cap) →
  `parseGatewayEnsureOutput` (`:147`) → `ensureLocalGateway` (`:219-255`): requires exit 0 +
  `state=="ready"`, loopback origin, `runtime_protocol==1`, `session-authority-v1` in capabilities
  (`:172-181`); if `endpoint.code_sha != client_code_sha` it restarts the stale owner (Agora: **don't**;
  just report). Called from `apps/desktop/electron/main.ts:11828` (primary) / `:11422` (pool).
- Agora recommendation: prefer `identify` over the socket (no subprocess); use `ensure --json` only
  as a fallback to *start* a gateway when the socket is absent (it is the official idempotent starter).

---

## 2. WebSocket connect

### 2.1 URL & subprotocols
```
ws://127.0.0.1:<port>/api/ws?native_dial=<uuid>
Sec-WebSocket-Protocol: hermes-gateway-v1, hermes-gateway-ticket.<ticket>
```
- Host/port from `api_origin` (`http`→`ws`). Electron builds `…/api/ws?native_dial=<uuid>&ticket=<t>`
  (`local-gateway.ts:353-355`, `main.ts:7580-7592`) and the renderer moves the ticket into the
  subprotocol list (`apps/desktop/src/api/canonical-protocol.ts:12-21`). `native_dial` is Electron
  bookkeeping only; harmless to send, not required by server.
- **No `profile` query param.** Profile routing is per-request (`params.profile`, §8).
- Server requires `hermes-gateway-v1` + **exactly one** `hermes-gateway-ticket.*` entry
  (`hermes_cli/web_server_boundary.py:160-171`), accepts with subprotocol `hermes-gateway-v1`
  (`gateway/run_api.py:490`, `tui_gateway/ws.py:638`). Verify the negotiated protocol.

### 2.2 Header requirements
- **No `Origin` header.** Electron strips it (`local-gateway.ts:374-376`, `main.ts:8225`). An upgrade
  carrying `Origin` is routed to the dashboard path, not the native one (`gateway/run_api.py:432`);
  Origin + ticket → 4403. `URLSessionWebSocketTask` does not add Origin by default — verify it doesn't.
- Peer must be `127.0.0.1`/`::1` (`run_api.py:430`). `Host` must match the bound host
  (`web_server_boundary.py:251`, `ws_host_origin_reason`) → use `127.0.0.1:<port>` literally, not `localhost`.

### 2.3 Close codes on `/api/ws`
| code | meaning | source |
|---|---|---|
| 1013 | gateway not ready / draining / socket cut by drain / ticket's profile no longer has an authority → re-`identify`, back off, redial | `run_api.py:390,405,442,460,472`; `chat_ws.py:682` |
| 4403 | native path refused: bad/ambiguous subprotocols, embedded chat disabled, Host/Origin mismatch, non-loopback peer, Origin+ticket, granted profile not served → fatal until config changes | `run_api.py:445-448,477`; `chat_ws.py:107,113,690` |
| 4401 | bad credential on dashboard path. An invalid/expired native ticket falls through to the dashboard handler (`run_api.py:457-462`) which then **likely** closes 4401 — **UNVERIFIED live**. Treat as "mint new ticket, retry once" | `chat_ws.py:110` |
| 1011 | server abort (send deadline / fanout backlog overflow) → reconnect + replay | `tui_gateway/ws.py:290,325` |
| 4400/4404/4408 | other dashboard sockets only, not native `/api/ws` | `web_server_chat.py:446-477` |

Plain HTTP while not ready: `503 {"error":"gateway_not_ready","state":…}`.

### 2.4 Framing on the socket
Text frames, one JSON-RPC 2.0 object per frame (server strips whitespace, ignores blank frames,
`tui_gateway/ws.py:690-700`). Parse error → `{"jsonrpc":"2.0","error":{"code":-32700,"message":"parse error"},"id":null}`.
Client request ids: any JSON id (desktop uses its own counter via `createRequestId`). **Server→client
request ids are strings starting `srq-`** (`gateway/session_server_requests.py::is_response_frame`);
your responses to them must echo that string id, with `result` or `error` and **no `method`**.
Max frame the clients accept: 8 MiB (`gateway/session_tui_ops.py` comment re `hermes_cli/gateway_client.py`).

### 2.5 Reconnect
`apps/shared/src/reconnect-backoff.ts`: full-jitter exponential, base 300 ms, cap 15 s,
`delay = random(0, min(15000, 300·2^attempt))`; a socket that dies < 5 s after open counts as a failed
attempt (no ladder reset). Each redial: new ticket (and re-`identify` if 1013 / `stale runtime instance`).

---

## 3. Handshake

### 3.1 `gateway.ready` (first server frame, unsolicited) — `tui_gateway/ws.py:651-657`
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{
  "skin":{"name":"…","colors":{},"light_colors":{},"dark_colors":{},"branding":{},"banner_logo":"","banner_hero":"","tool_prefix":"","help_header":"","description":""},
  "change_events":true,"heartbeat":true,"replay_epoch":"<process epoch>","session_authority":true}}}
```
Contract `GatewayReadyPayload` (`tui_gateway/contracts/events.py:50-63`). `session_authority:true` ⇒
canonical wire. `replay_epoch` here is the **process** epoch (sessions have their own, §4.3).

### 3.2 `client.capabilities` (send once per connection, right after ready)
Desktop sends **two** calls (`apps/shared/src/json-rpc-channel.ts:266-268` on attach,
`:545-555` on ready):
```json
→ {"jsonrpc":"2.0","id":1,"method":"client.capabilities","params":{"desktop_local":true}}
→ {"jsonrpc":"2.0","id":2,"method":"client.capabilities","params":{"server_requests":true}}
← {"jsonrpc":"2.0","id":2,"result":{"server_requests":["approval","clarify","sudo","secret",…],
     "declines_not_shown":true,"canonical_clarify_batch":true}}
```
Params (`tui_gateway/contracts/liveness.py:28-40`, both optional bool, `extra=forbid`):
`server_requests` — **mandatory for Agora**: without it every server→client request is failed fast for
this socket. `desktop_local` — marks "Desktop on this machine" (enables welcome trial / onboarding);
Agora should **omit** it (it is a Desktop-identity flag; not needed for chat). Handler:
`tui_gateway/methods_voice.py:522-541` (not an authority verb → served by legacy fallback,
`tui_gateway/ws.py:399-403`). Result: `server_requests` = sorted `contracts.SERVER_REQUESTS`;
`canonical_clarify_batch:true` ⇒ you may send `clarify_batch:true` on `prompt.submit`.

### 3.3 `gateway.capabilities`
`{"method":"gateway.capabilities","params":{}}` → `{"per_session_exclusive_submit":true|false}` — the
only field (`liveness.py:21-25`, `methods_voice.py:514-519`). For canonical capability discovery use
**`runtime.describe`** instead:
```json
→ {"jsonrpc":"2.0","id":3,"method":"runtime.describe","params":{}}
← {"jsonrpc":"2.0","id":3,"result":{"instance_id":"cc85…","profile_id":"/Users/me/.hermes","authority_epoch":3,
   "capabilities":["durable-admission-v1","event-replay-v1","local-cli-create-v1","acp-editor-policy-v1","acp-session-mcp-v1","clarify-batch-v1"],
   "session_create":{"sources":["acp","cli","gui","oneshot","tool","tui"],"parameters":[…CREATE_FIELDS…,"title"]},
   "skin":{…}}}
```
(`gateway/session_controls.py:547-558`, contract `canonical.py:334-354`; must have `params:{}` exactly.)

### 3.4 Heartbeat
Only if `gateway.ready.heartbeat == true`. Every 15 s send
`{"jsonrpc":"2.0","id":"heartbeat-N","method":"gateway.ping","params":{}}` → `{"jsonrpc":"2.0","result":{"ok":true},"id":"heartbeat-N"}`
(answered on the reader loop even mid-turn, `tui_gateway/ws.py:703-707`). Drop+reconnect if no
response/pong for 45 s; ≤ 8 outstanding pings (`json-rpc-channel.ts:170-172`). Also `ping` →
`{"pong":true}` (authority verb; requires empty params).

### 3.5 Recommended connection sequence (Agora)
1. `identify` over gateway.sock → `api_origin`, `instance_id`, `served_profiles`, `state=="ready"`.
2. `session-ticket {profile_id:<primary home>, instance_id, purpose:"interactive", scope:"host"}`.
3. WS dial (§2). Wait `gateway.ready` (assert `session_authority:true`).
4. `client.capabilities {server_requests:true}`; start heartbeat.
5. Optional `runtime.describe {}`; `profiles.list {}` for the roster (§8).

---

## 4. Event notifications

### 4.1 Envelope
All server→client notifications use `method:"event"` (no `id`). Canonical session frames are built
in `gateway/session_events.py:78-89`:
```json
{"jsonrpc":"2.0","method":"event","params":{
  "type":"message.delta",
  "session_id":"<canonical session id>",
  "payload":{ … per-type … },
  "replay_epoch":"<per-session epoch hex>",
  "seq":42,
  "authority_epoch":3,"execution_generation":7,"admission_id":"…"}}
```
- `message.delta`/`reasoning.delta`/`thinking.delta` are coalesced server-side for ~33 ms; any other frame
  flushes the batch first, so ordering is preserved (`tui_gateway/ws.py:131-132`).
- `payload` is omitted entirely for payload-less events (e.g. `voice.interrupted`).
- `seq`: per-session monotonic counter (stamped by `tui_gateway/event_replay.py::_stamp_event`); absent on
  session-less broadcasts (e.g. `sessions.changed`, `skin.changed`).
- `replay_epoch` (per session) changes when the replay ring is evicted/reset → your seq watermark is invalid.
- `authority_epoch` / `execution_generation` / `admission_id`: owner execution stamp spread beside
  `type`/`payload` for turn frames (`apps/shared/src/gateway-events.ts:62-87`). Track the highest
  `execution_generation` per session; **drop frames whose generation < current** (desktop does,
  `canonical-protocol.ts:613-620`). You need the current generation for `session.interrupt`/`steer`/`approval.respond`.
- `params.profile` is **not** sent by the server (desktop adds it client-side); you know the profile from
  which `params.profile` you resumed with.
- Backlog overflow: server ends your subscription and sends
  `{"type":"session.replay_gap","session_id":…,"payload":{"replay_epoch":…,"latest_seq":N}}` (no seq)
  → re-`session.resume` for a fresh snapshot (`session_events.py:94-101`).

### 4.2 Payloads (contracts `tui_gateway/contracts/events.py`; Payload models are `extra=forbid` unless noted)
Turn stream:
```jsonc
// message.start  (events.py:137-151) — usually {} for a normal admission
{"display_kind":null,"display_text":null,"notification_category":null,"text":null,"turn_id":"…"}
// message.delta  (events.py:155-178) — text:null = segment boundary (ignore / close bubble)
{"text":"Hel","rendered":null,"verbose":null,"turn_id":"…","segment":0,"offset":0}
//   offset = UTF-16 code units of this segment already sent → dedupe re-sent chunks by (turn_id,segment,offset)
// reasoning.delta / reasoning.available / thinking.delta  (StreamDeltaPayload, events.py:155-181)
{"text":"…","rendered":null,"verbose":null}
// message.interim (events.py:184-195) — assistant commentary sealed as its own segment (beside tool calls)
{"text":"Let me check…","already_streamed":true,"turn_id":"…","segment":0}
// message.complete (events.py:270-305) — turn ended
{"text":"final reply","usage":{…Usage…},"status":"complete|error|interrupted","reasoning":null,
 // canonical builder (gateway/session_settlement_recovery.py:55-106) ADDS: "content":"<=text>","admission_id":"…","outcome":"completed|cancelled|failed|…"
 // a cancelled queued row emits {"text":"","content":"","admission_id":"…","outcome":"cancelled"} with no status (session_authority.py:853)
 "warning":null,"response_previewed":null,"response_reused":null,"response_transformed":null,
 "billing":null,"failure_reason":null,"rendered":null,"error":null,"recoverable":null,
 "error_surface":{"layer":"…","code":"…","retryable":true,"provider":null,"model":null,"resets_at":null,"usage_limit":null},
 "partial":null,
 "persisted_turn":{"row_ids":[101,102],"complete":true,"user_row_id":101,"final_assistant_row_id":102,
                   "user_row_ids":[101],"submission_id":"<your submission_id>"}}
```
`Usage` (`contracts/common.py:28-53`, open model): `model, input, output, reasoning, prompt, completion,
total, calls, compressions?, context_used?, context_max?, context_percent?, context_source?,
context_estimated?, cache_hit_pct?, cache_read?, cache_write?, avg_latency_s?, avg_tps?,
active_subagents?, dev_credits_spent_micros?, cost_usd?, cost_status?`.

Tools:
```jsonc
// tool.generating (events.py:436-442)
{"name":"terminal"}
// tool.start (events.py:401-413)
{"tool_id":"call_abc","name":"terminal","context":"ls -la","args":{"command":"ls -la"},"args_text":null,"preview":null,"labels":null}
//   canonical adds "tool_call_id","tool_name" (gateway/run_turn_progress.py:45-56); context = 80-char preview
// tool.progress (events.py:458-470) — MCP progress, ≤1/500ms/call
{"tool_id":"call_abc","name":"mcp_x","progress":3,"total":10,"percent":30,"message":"…"}
// tool.complete (events.py:416-433)
{"tool_id":"call_abc","name":"terminal","args":{…},"duration_s":0.42,"result":<any JSON>,"summary":"…",
 "result_text":"…","inline_diff":null,"todos":null,"revision":null,"labels":null,"image_path":null}
//   canonical adds "is_error":bool; result is size-bounded (run_turn_progress.py:59-70)
// tool.output_risk (events.py:446-455)
{"tool_id":"…","name":"…","risk":"…","findings":["…"],"redacted":true}
// todo.updated (events.py:473-480)
{"todos":[…],"revision":3}
```
Status / misc: `status.update {kind,text}` (kind: status|lifecycle|compacting|goal|loop|heartbeat|process…);
`agent.print {text}`; `error {message}` (session failure outside a turn, events.py:113-120);
`notice {message}`; `session.usage {usage:{…Usage…}, …deprecated counters}`;
`session.title {session_id,title}` (auto-title); `notification.show / notification.clear`;
`review.summary {text}`; `message.reaction`; `sessions.changed` (session-less: refetch list).

Canonical session-state events (owner-only, `gateway/`):
```jsonc
// session.info — after every admission change (gateway/session_authority.py:462-479); also on policy refresh
{"stored_session_id":"…","pending":[<PendingAdmission>…],"authority_epoch":3,
 "desktop_protocol":"hermes-gateway-v1","running":true,"execution_generation":7,"revision":12}
//   ← the ONLY way a viewer learns the new CAS `revision` after a turn (turns bump revision silently)
// session.updated — a committed session.mutate receipt broadcast to all viewers (session_mutations.py:334)
{"session_id":"…","operation":"rename","revision":13,"title":"New title", …operation projection}
// approval.request (session_pending_controls.py:27-38)
{"kind":"approval","prompt_id":"…","execution_generation":7,"command":"rm -rf build","description":"…",
 "choices":["once","deny","session","always"],"edit":{…}?,"timeout_s":120?}
// clarify.request (session_pending_controls.py:43-51)
{"kind":"clarify","prompt_id":"…","execution_generation":7,"question":"Which?","choices":["a","b"],"multi_select":false,"timeout_s":…?}
// approval.settled / clarify.settled (session_pending_controls.py:62-63, 84-85)
{"prompt_id":"…","execution_generation":7}
// request.cancel — a server→client request withdrawn (session_server_requests.py:199,207)
{"id":"srq-…","method":"sudo","reason":"timeout|interrupted|shutdown|resolved|session_closed"}  // contracts/server_requests.py:363-379
```
There are **no** `session.busy/idle/created/closed` events: busy = `running` in `session.info` / snapshots.
A title change (incl. auto-title) re-publishes `session.info` with full local info canonically
(`run_turn_progress.py:960-966`) rather than `session.title`. `agent.step {iteration}`,
`session.tools_changed {mcp_servers, execution_generation}`.
Other owner event types seen: `session.control.update`, `connection.update`,
`skin.changed`, `preview.restart.progress`.

### 4.3 Sequence numbers & `session.events.since`
Contract `canonical_sessions.py:295-321`; handler `session_controls.py:745-757`; ring `session_events.py:122-138`.
```json
→ {"jsonrpc":"2.0","id":9,"method":"session.events.since","params":{
     "session_id":"local-…","profile":"coder","last_sequence":42,"replay_epoch":"<session epoch>"}}
← {"jsonrpc":"2.0","id":9,"result":{
     "events":[{"type":"message.delta","session_id":"local-…","payload":{…},"replay_epoch":"…","seq":43,
                "authority_epoch":3,"execution_generation":7,"admission_id":"…"}],
     "latest_seq":57,"last_sequence":57,"epoch":"…","replay_epoch":"…",
     "truncated":false,"snapshot_required":false,"count":15,
     "open_requests":[{"id":"srq-…","method":"sudo","params":{…}}]}}
```
- Params: `session_id` (req), `last_sequence` int ≥ 0 (alias `last_seen`), `replay_epoch` str|null, `profile`.
- `snapshot_required:true` (epoch mismatch, seq ahead, ring truncated) → `events:[]` → call `session.resume`.
- Cursor sources: `session.resume`/`session.create` result `replay_epoch` + `last_sequence`, then each
  event's `seq`/`replay_epoch`.
- Ring limits: 512 events / 4 MiB per session, 64 sessions, 64 MiB total (`tui_gateway/event_replay.py:30-36`).
- Reconnect order the server optimises for: `session.events.since` **then** `session.resume` on the same
  socket — the resume replays frames published between them (`session_events.py:107-120`,
  `replay_cursors` in `session_controls.py:150,623,755`).

---

## 5. Methods (canonical owner)

General rules:
- Params models are **closed** (`extra=forbid`): unknown or missing keys → error `4001 invalid_params`
  with `data:{reason:"invalid_params",fields:[…]}` (`session_controls.py:327-331`).
- Every method accepts `profile` (profile **name**, e.g. `"coder"`; `"default"` for the root) to route
  on a host-scoped socket (§8). It is stripped before validation for session verbs (`_PROFILE_IMPLICIT`,
  `session_controls.py:98-102`).
- Error shape: `{"code":4001,"message":"<reason>","data":{"reason":"<reason>","field"?,"detail"?,"revision"?,"execution_generation"?,"admitted"?}}`
  (`session_controls.py:22-37`). Reasons seen: `invalid_params, permission_denied, not_found,
  profile_mismatch, runtime_draining (retryable), revision_conflict, stale_generation, session_busy,
  admission_conflict, queue_full, unsupported_control, execution_not_ready, admission_started, session_idle,
  steer_unavailable`. `5001 storage_unavailable`; `-32601` + `data.reason:"unknown_method"` for verbs the
  owner doesn't serve (`:356-363`).
- Only methods on the authority table (`session_controls.py:217-282`) or non-session legacy verbs
  (`ws_legacy_fallback.py`) work. Legacy `session.*`/`prompt.*`/`message.*` verbs **not** on the
  authority are refused `-32601` (except `session.most_recent, session.active_list, session.events.stats,
  session.foreign.*`).

### 5.1 `session.list` — `session_controls.py:567-613`, contract `canonical_sessions.py:164-186`
Params: `{profile?, scope?: "live"|"stored" (default "live"), limit?: int 1..200 (default 200), title?: str, include_hidden?: bool}`.
`title` and `scope` are mutually exclusive.
- `scope:"live"` → sessions currently mounted in the owner (not closed), hiding `hidden`/`archived`
  rows unless `include_hidden`, hiding internal sources (kanban/tool/oneshot); sorted by `started_at` desc.
- `scope:"stored"` → `stored_picker_sessions` (resumable history) (`gateway/session_listing.py`).
- `title:"Bot Chat"` → exact title lookup (indexed, resolves compression tip), `scope:"stored"` in result.
```json
← {"sessions":[{"session_id":"…","id":"…","title":"Bot Chat","source":"gui","started_at":1762300000.1,
     "message_count":84,"running":false,"model":"…","resolved_id":"…tip id","root_title":"Bot Chat"}],"scope":"stored"}
```
Row: `session_id, id, title (""=untitled), source, started_at (epoch s float|null), message_count, running,
model?, resolved_id?, root_title?`. **No `archived` flag** in canonical rows (archived rows are excluded
from live unless `include_hidden`). For a rich sidebar (archived, pinned, last_active, costs,
pagination) the Desktop uses REST, §5.13.

### 5.2 `session.create` — `session_controls.py:473-538`, params `canonical_sessions.py:21-55`
Desktop sends (`canonical-protocol.ts:526-556`):
```json
→ {"jsonrpc":"2.0","id":10,"method":"session.create","params":{
     "request_id":"<uuid, reuse on retry>","source":"gui","profile":"coder","title":"My chat",
     "cwd":null,"model":null,"provider":null,"reasoning":null,"hidden":false}}
```
Allowed keys: `request_id, source ('cli'|'tui'|'gui'|'acp'|'tool'|'oneshot', default 'cli'), cwd, row_cwd, model,
provider, base_url, api_key, toolsets, reasoning, max_turns, ignore_rules, yolo, safe_mode,
ignore_user_config, skills, checkpoints, accept_hooks, pass_session_id, editor, title, hidden,
follow_profile_config, service_tier, cwd_explicit, run_budget, verbose, client_env, profile`.
- Use `source:"gui"` (maps to surface `desktop`, `gateway/session_policy.py:85`). Omit nulls (send only set keys).
- `request_id` = idempotency key: an exact retry returns the same session.
- `title` given and a session with that title exists → **returns the existing one** (resolve-or-create,
  serialized per authority). `title:"Bot Chat"` additionally sets `follow_profile_config:true`
  (`:402-408`). `hidden:true` hides from sidebar (Bot Chats are born hidden).
- Result = the same **snapshot** as `session.resume` (§5.3); the creating connection is subscribed.

### 5.3 `session.resume` — `session_controls.py:615-713`, contract `canonical_sessions.py:58-161`
(`session.activate` does not exist canonically — Desktop rewrites it to `session.resume`, `canonical-protocol.ts:320-322`.)
```json
→ {"jsonrpc":"2.0","id":11,"method":"session.resume","params":{"session_id":"…","profile":"coder"}}
```
Params: `session_id` | `title` (exact title, e.g. `"Bot Chat"`) | `latest:"cli"|"tui"` (+`workspace`);
plus `source?, editor?, api_key?, defer_history?, omit_messages? (bool), cols?, display_projection? (bool)`.
`local-<16hex>` short ids are resolved. Resuming **subscribes this socket** to the session's events
(multi-viewer; other clients keep theirs).
```json
← {"session_id":"…","stored_session_id":"…",
   "messages":[<TranscriptMessage>…],"messages_omitted":false,"display_messages":[…]?,
   "message_count":84,"running":false,
   "authority_epoch":3,"replay_epoch":"<session epoch>","last_sequence":120,"subscription_id":"<hex>",
   "revision":12,"execution_generation":7,
   "pending":[{"admission_id":"…","ref":{"profile_id":"/Users/…/coder","session_id":"…"},"sequence":5,
               "status":"queued","outcome":null,"authority_epoch":3,"execution_generation":null,
               "input_id":"<submission_id>","text":"queued prompt","controls":["steer","replace"],"steering":null}],
   "prompts":[{"kind":"approval","prompt_id":"…","execution_generation":7,"choices":["once","deny","session","always"],
               "command":"…","description":"…","edit":null,"question":null,"multi_select":null,"timeout_s":120}],
   "info":{"desktop_protocol":"hermes-gateway-v1","source":"gui","model":"…","profile_id":"…","profile_name":"coder",
           "cwd":"…","title":"…","started_at":…,"last_active_at":…,"reasoning_effort":"…","provider":"…",
           "usage":{…},"context_length":…, …SessionInventoryFields},
   "pending_connection":null,"todo_state":null,
   "open_requests":[{"id":"srq-…","method":"sudo","params":{"session_id":"…","command":"…"}}]}
```
- Save `revision` (CAS for `session.mutate`), `execution_generation` (fence for controls/prompts),
  `replay_epoch`+`last_sequence` (event cursor), `subscription_id` (for `session.detach`).
- Pending approvals/clarifies come in **`prompts`** (canonical) — render them as cards; server→client
  requests still open come in **`open_requests`** — re-deliver to your request handler.
- `messages` are **raw stored OpenAI-format rows** (§6.1), not the display projection; add
  `display_projection:true` to also get `display_messages` (§6.2).
- `running:true` ⇒ a turn is live; its tail arrives as events. No `inflight` canonically (§6.5).
- Desktop maps each `prompts[]` entry to a synthetic open request `{id: prompt_id, method: kind, params}`
  (`apps/desktop/src/api/canonical-protocol.ts:752-767`) so one card UI serves both; Agora can do the same
  but must answer them via `approval.respond`/`clarify.respond`, not a JSON-RPC response.
- `omit_messages:true` → `messages:[]`, `messages_omitted:true`; page the transcript via REST (§5.13).
  Desktop does this for long chats.
- `session.detach {session_id, subscription_id, end_reason?}` drops the subscription
  (`session_controls.py:720-743`; `end_reason` matches `[a-z][a-z_]{0,31}`; with it the last viewer
  leaving an idle local session ends the row). Result `{session_id, subscription_id, detached}`.

### 5.4 `session.history` — `gateway/session_tui_ops.py:121-133`
`{session_id, profile?}` → `{"count":N,"messages":[<TranscriptMessage>…]}`: full display projection of the
current physical row **including compression ancestors**, each with `row_id`. **No pagination params.**
Caller must be subscribed / have read access (`_live_ref`). Use REST for paging.

### 5.5 `prompt.submit` — `session_controls.py:759-839`, contract `canonical_sessions.py:209-247`
```json
→ {"jsonrpc":"2.0","id":12,"method":"prompt.submit","params":{
     "session_id":"…","profile":"coder","text":"Hello","submission_id":"<uuid>",
     "attachments":[{"path":"/Users/me/.hermes/profiles/coder/cache/images/upload_ab12.png","mime":"image/png"}]}}
← {"jsonrpc":"2.0","id":12,"result":{"admission_id":"…","ref":{"profile_id":"/Users/me/.hermes/profiles/coder","session_id":"…"},
     "sequence":17,"status":"queued","outcome":null,"authority_epoch":3,"execution_generation":null}}
```
- **`submission_id` (or `input_id`) is required** (non-empty string) — the idempotency key. Retry with the
  same id after a lost ACK; a different payload under the same id → `admission_conflict`
  (`data.field=="request_id"`, `ADMITTED_REQUEST_CONFLICT`). Desktop adds a random UUID if missing
  (`canonical-protocol.ts:217-219`).
- Caller must be **subscribed** (resume/create first) else `permission_denied`.
- Allowed keys: `session_id, text, submission_id, input_id, queued, attachments, finite, unattended, surface,
  voice_context, interrupted, voice_turn, display_kind ("hidden"), title_preview, turn_author, api_text,
  model_override, clarify_batch, profile`.
- Result `AdmissionStatus` (`canonical.py:29-38`): `status` ∈ `queued|started|unknown|terminal`;
  `outcome` (open set) ∈ `completed|interrupted|rejected|failed|cancelled|steered|unknown|settled_unknown|…`.
  Or `{"voice_stopped":true}` (voice stop phrase; ignore for Agora).
- Busy session: the submit is **queued** FIFO (always intent "queue"); it shows in `pending` /
  `session.info.pending`. `prompt.cancel {session_id, admission_id}`, `prompt.steer_queued`,
  `prompt.replace_queued {session_id, admission_id, submission_id, text, attachments?}`, and
  `prompt.receipt {session_id, admission_id, include_result?}` manage queued rows (`canonical.py:41-77`,
  `canonical_sessions.py:250-263, 337-350`).
- Turn output arrives as events (§4); `message.complete.persisted_turn.submission_id` echoes your id.
- No truncate/rewind keys canonically: edit/regenerate = `session.mutate {operation:"rewind", payload:{target_message_id:<row_id>}}`
  then a plain submit (`canonical-protocol.ts:151-173`).

**Images.** Attachments must be `[{path, mime}]`, 1..10 items, `mime` ∈ `image/png|image/jpeg|image/gif|image/webp`,
and `path` absolute **inside the owning profile's `cache/images/` dir** (`gateway/session_ingress_media.py:122-156`).
Stage bytes first with `image.attach_bytes` (`gateway/session_images.py:8-45`):
```json
→ {"method":"image.attach_bytes","params":{"session_id":"…","profile":"coder",
     "content_base64":"iVBORw0KGgo…","filename":"shot.png"}}
← {"attached":true,"path":"/Users/me/.hermes/profiles/coder/cache/images/upload_….png","mime":"image/png",
   "name":"upload_….png","count":1,"remainder":"","text":"[User attached image: upload_….png]","bytes":12345}
```
Params: `session_id, profile?, content_base64 | data (alias; may be a data:image/...;base64, URL), filename?, ext?`
(all strings). Max 25 MiB (`tui_gateway/prompt_attachments.py:21`); type sniffed from magic bytes;
caller must be subscribed. Then submit with `attachments:[{path,mime}]` from the result.

### 5.6 `session.steer` / `session.redirect` — `gateway/session_busy_controls.py:13, 176-218`
```json
→ {"method":"session.steer","params":{"session_id":"…","profile":"coder","text":"also check X","execution_generation":7}}
← {"status":"queued","text":"also check X","execution_generation":7,"authority_epoch":3}
```
Exactly `{session_id, text, execution_generation, profile?}`. `status`: `queued` (agent accepted; applied at
next tool boundary) | `rejected` (+ `delivered:false` only when no agent was live — then safe to submit
as a new prompt) | `redirected` (redirect). Stale generation → `stale_generation`.

### 5.7 `session.interrupt` — `session_controls.py:909-913`, `gateway/session_authority.py:934-961`
```json
→ {"method":"session.interrupt","params":{"session_id":"…","profile":"coder","execution_generation":7}}
← {"ref":{"profile_id":"…","session_id":"…"},"instance_id":"…","authority_epoch":3,"revision":12,
   "execution_generation":7,"execution_state":"idle|running|waiting|unknown|terminal"}
```
`execution_generation` required (from snapshot / latest event). Stale → `stale_generation` (turn already over).
Turn then ends with `message.complete` `status:"interrupted"`.

### 5.8 `session.mutate` (title / archive / delete / compress / rewind / branch / model …)
Contract `canonical.py:82-109`; validation `hermes_state_mutations.py:8-86`; handler `session_controls.py:841-862`.
```json
→ {"method":"session.mutate","params":{"session_id":"…","profile":"coder","request_id":"<uuid>",
     "expected_revision":12,"operation":"rename","payload":{"title":"Trip planning"}}}
← {"session_id":"…","operation":"rename","revision":13,"title":"Trip planning", …}
```
| operation | payload | `expected_generation` |
|---|---|---|
| `rename` | `{"title":str}` | no |
| `archive` | `{"archived":bool}` | no |
| `sidebar` | subset of metadata fields (pinned/unread/… `METADATA_FIELDS`) | no |
| `delete` | `{}` | **required** |
| `compress` | `{focus?:str, preview?:bool, partial?:bool, keep_last?:int}` | required |
| `rewind` | `{target_message_id:int(row_id) , preserve_compaction_handoff?:bool}` | required |
| `branch` | `{title?, through_message_id?:int}` | required |
| `model` | `{model, provider?, reasoning?, confirm?}` | required |
| `reasoning` | `{effort:str|null}` · `workspace` `{cwd}` · `reset` `{}` | required |
- `request_id` = retry idempotency (keep it across retries of the same intent).
- `revision_conflict` / `stale_generation` refusals carry fresh `data.revision` / `data.execution_generation`;
  adopt and (for value ops) retry once. Revision also advances via `session.info` / `session.updated` events.
- Busy (turn lease) → `session_busy` (retryable).
- Compress result has `status` (`preview` → `lines`), counts; Desktop re-`session.resume`s afterwards to repaint.

### 5.9 Approvals / clarify (canonical: events + response methods)
- `approval.respond {session_id, execution_generation, prompt_id, choice}` → `{"status":"resolved"|"already_resolved","prompt_id":"…"}`
  (`session_controls.py:931-935`; `choice` must be one of the prompt's `choices`).
- `clarify.respond {session_id, execution_generation, prompt_id, answer:str}` (empty = skipped) → same result.
- `clarify.lock {request_id, question_id, answer, profile?}` → `{status:"ok"|"expired", remaining?:[qid]}` for batch clarify (§7).

### 5.10 `session.info`, `session.stats`, `profiles.list`, `runtime.describe`, `ping`
`session.info {session_id}` → `CanonicalSessionInfo` (`canonical.py:147-207`). `session.stats {session_id}` →
token counters (`canonical.py:210-245`). `profiles.list {include_sessions?:bool=true}` → §8.

### 5.11 Not available canonically (refused or translated)
`session.title`, `session.archive`, `session.compress`, `session.branch`, `session.rewind`, `session.model` →
use `session.mutate`. `session.delete` → `session.mutate operation:"delete"`. `session.activate` →
`session.resume`. `image.attach {path}` (legacy, local path) — **UNVERIFIED** on canonical; use
`image.attach_bytes`. `prompt.submit` truncate keys → `rewind` mutation.

### 5.12 Other served verbs (handlers table `session_controls.py:217-282`)
`commands.catalog, complete.slash, complete.path, slash.exec, command.dispatch, command.observe, plugins.list,
config.get, config.set (limited keys), model.options, session.export, session.active_list, session.automation,
message.react, subagent.*, process.*, file.attach, approval.pending, rollback.*, prompt.background, prompt.btw,
llm.oneshot, groups.*, bot_relay.*, cron.*, setup.status, onboarding.*`.

### 5.13 REST (same origin; what the Desktop uses for lists & transcript paging)
Auth: header **`X-Hermes-Gateway-Ticket: <ticket>`** with a fresh `purpose:"native-http"` ticket per request
(no `scope`), scoped to `api_origin` (`apps/desktop/docs/canonical-gateway-protocol.md` §Authentication).
Exact header handling: `hermes_cli/dashboard_auth/native_http.py` — **UNVERIFIED live** (not probed).
- `GET /api/sessions?limit≤100&offset&min_messages&archived=exclude|only|include&order=created|recent&source&exclude_sources&profile=<name>`
  (`hermes_cli/web_routers/sessions.py:182`). Rows = `SessionInfo` (`apps/desktop/src/types/hermes.ts:611+`:
  `id, title?, archived?, pinned?, hidden?, last_active, started_at, message_count, model, source, ended_at, …`).
- `GET /api/sessions/{id}/messages?profile&limit≤500&offset&order=latest|oldest&include_compacted&inline_images=true`
  (`sessions.py:743-791`) → `{session_id, profile, messages:[SessionMessage], pagination:{limit,offset,order,returned}}`.
  Desktop's first page: `limit=120, order=latest, include_compacted=true`.
- `PATCH /api/sessions/{id}` `{archived|pinned|unread, …fence}` / `DELETE` — revision-fenced via
  `GET /api/sessions/{id}/mutation-snapshot` (`apps/desktop/src/api/sessions.ts:401-425`). Prefer `session.mutate` over WS.

---

## 6. Transcript / history item shapes

There are **three** row shapes; know which one you hold.

### 6.1 Canonical `session.resume` / `session.create` `messages` — RAW stored rows
Not the display projection. Source: `gateway/session_local_recovery.py:330-363` → `hermes_state_messages.py:1571-1661`.
OpenAI-format rows:
```json
{"role":"user|assistant|tool|system","content":"text" | [{"type":"text","text":"…"},{"type":"image_url","image_url":{"url":"…"}}],
 "row_id":101,"timestamp":1762300000.12,
 "tool_calls":[{"id":"call_abc","type":"function","function":{"name":"terminal","arguments":"{\"command\":\"ls\"}"}}],
 "tool_call_id":"call_abc","tool_name":"terminal",
 "display_kind":null,"display_metadata":{…decoded dict…},
 "reasoning":null,"reasoning_content":null,"reasoning_details":null,"finish_reason":"stop",
 "api_content":…,"message_id":…,"message_uid":…,"observed":…,"archived":true?,"archived_truncated":true?}
```
`function.arguments` is a JSON **string**. Tool results are `role:"tool"` rows keyed by `tool_call_id`.
UNVERIFIED: whether internal `_db_persisted` / `_tool_call_uid` keys are stripped on the wire — ignore unknown keys.
Pass `display_projection:true` to additionally get `display_messages` (shape 6.2).

### 6.2 Display projection (`TranscriptMessage`, `tui_gateway/contracts/common.py:168-186`)
Returned by `session.history` (canonical, `gateway/session_tui_ops.py:121-133`), by `display_messages`, and
(legacy) by resume. Builder `tui_gateway/session_history.py:297-373`.
```json
{"role":"user|assistant|tool|system","text":"flattened string","timestamp":1762300000.12,"row_id":101,
 "display_kind":null,"display_metadata":null,"reasoning":null}
{"role":"tool","name":"terminal","context":"ls -la","args":{"command":"ls -la"},"labels":[…],"tool_call_id":"call_abc",
 "timestamp":…,"display_metadata":…,"content":"<only for write_file/patch/skill_manage>"}
```
- Tool name/args recovered from the preceding assistant `tool_calls` (`session_history.py:285-345`).
- Dropped: `display_kind:"hidden"` rows and user rows starting with `[System:` (`:318, 228-237`).
- Images: inline data URL (default) or `[image]` with `inline_images:false`; verified user images rendered as
  `@image:<path>` lines after the caption, trailing `[screenshot]` placeholders removed (`:87-211`).
  Canonical native image history stores routing hints followed by flattened `[screenshot]` parts
  (`apps/desktop/docs/canonical-gateway-protocol.md` §Image history).
- Assistant extras: `reasoning, reasoning_content, reasoning_details, codex_*`.
- Skill turns: `display_kind:"skill_invocation"`, `text:"/skill args"`.

### 6.3 REST `/api/sessions/{id}/messages` rows (`SessionMessage`, `apps/desktop/src/types/hermes.ts:760-797`)
Same stored rows projected for display (`_project_for_display`), durable id as numeric **`id`** (not `row_id`);
`role, content, text?, timestamp?, tool_calls?, tool_call_id?, tool_name?, name?, context?, reasoning?, display_kind?, display_metadata?`.

### 6.4 Common semantics
- `timestamp` = Unix epoch **seconds** (float). `row_id`/`id` = durable `messages.id` (rewind/branch target).
- `display_kind` (open set): `hidden` (never render), `model_switch` `{model, provider?}`, `personality_switch`,
  `auto_continue`, `steer`, `skill_invocation`, `failed_turn` `{error?, error_surface}`, `process_complete`
  `{display_text}`, `async_delegation_complete` `{delegation_id, task_count, completed_count?, failed_count?,
  duration_seconds?, display_text?}`, `internal_notification`, `tool_result`. Producer cards (closed set):
  `internal_notification, process_complete, async_delegation_complete` (`gateway/response_filters.py:33-41`).
- `display_metadata` keys seen: `reactions:[{emoji, author:"agent"|"user", at, seen?}]`, `interrupted:true`,
  `model_only:true` (**never render**), `title_preview`, `submission_id`, `gateway_input_owner`,
  `reply_expected`, `notification_category`. May be a JSON **string** on older backends — decode defensively.
  Desktop rendering reference: `apps/desktop/src/lib/chat-messages/hydration.ts:155-345`.
- **Routine/cron results**: user rows with `display_kind` `async_delegation_complete` / `process_complete` /
  `internal_notification`; body like `[IMPORTANT: …]` or `[ASYNC DELEGATION …] --- RESULT ---`, optionally a
  `Cron job … --- JOB OUTPUT ---` section (parsed `hydration.ts:276-306`). No dedicated "routine" kind (UNVERIFIED that none exists).
- **Bot-to-bot (relay) messages**: no special `display_kind`; `role:"user"` rows whose text starts with
  `Message from 🤖 <name> (@<handle>[@<connection>]): ` (`tools/bot_relay.py:224-239`; legacy form
  `[Message from agent '<name>'] `). Desktop detects by regex (`apps/desktop/src/components/assistant-ui/thread/user-message.tsx:88-98`).
  No persisted author field found (UNVERIFIED).

### 6.5 In-flight turn on (re)attach
Canonical snapshots have **no `inflight`** (that is legacy, `tui_gateway/session_auto_continue.py:528-556`:
`{assistant, streaming, user, display_kind?, display_metadata?, corrections, correction_offsets, error?, status?, recoverable?, error_surface?}`).
Canonically rebuild the live turn from `running` + `pending[]` + `prompts[]` + events replayed after
`last_sequence` (`session.events.since`, or the catch-up the server pushes on resume). If the ring no longer
covers the turn start, you only see the tail until `message.complete` (whose `text` is the full final reply).

---

## 7. Server → client requests

Frame: `{"jsonrpc":"2.0","id":"srq-<…>","method":"<m>","params":{"session_id":"…", …}}`. Answer with
`{"jsonrpc":"2.0","id":"srq-<…>","result":{…}}` or `{"jsonrpc":"2.0","id":"srq-<…>","error":{"code":-32601,"message":"…"}}`.
Only viewers **subscribed** to that session with `session:respond` may settle (`session_server_requests.py:55-72`).
Timeout 120 s (`REQUEST_TIMEOUT_S`); withdrawal → `request.cancel` event `{id, method, reason}` — close that card only.
Contracts `tui_gateway/contracts/server_requests.py`:

| method | params (besides `session_id`) | result |
|---|---|---|
| `clarify` (batch; only when you sent `clarify_batch:true`) | `questions:[{qid,question,choices?:[str],multi_select:bool}]`, `answers?:{qid:str|null}` (replay only) | `{"answers":{"<qid>":"text"|null}, "outcome"?:"submitted"|"timed_out"|"cancelled"}`; `{}` = cancel all; lock early answers via `clarify.lock` |
| `sudo` | `command:str` | `{"value":"<password>"}` (`""` = declined) |
| `secret` | `env_var:str, prompt:str, metadata?:{…}` | `{"value":"…"}` |
| `approval` (legacy sidecar shape; canonical owner uses `approval.request` **events** instead) | `request_id, command, description, choices:[…], allow_permanent?, allow_session?, smart_denied?, tool_name?, gateway_session_id?` (+extra) | `{"choice":"once"|"session"|"always"|"deny","all"?:bool}` |
| `vault.unlock_prompt`, `vault.code`, `vault.save_login`, `terminal.read`, `preview.read`, `window.read`, `preview.act`, `tour`, `setup_beat`, `theme.apply`, `theme.pick`, `connection` | various | Agora: answer **`-32601`** immediately |

**Canonical approval/clarify are not server requests.** They arrive as `approval.request` / `clarify.request`
events (and in the resume snapshot's `prompts`), answered via `approval.respond` / `clarify.respond`
with the prompt's `execution_generation` (§4.2, §5.9). Approval `choices` are built in
`gateway/session_pending_controls.py:22-34`: always `"once"`,`"deny"`; `"session"` unless
`allow_session=false`/smart-denied; `"always"` unless `allow_permanent=false`/smart-denied; an `edit`
proposal restricts to `["once","deny"]`. Exact strings: **`once`, `session`, `always`, `deny`**
(`ApprovalChoice`, `server_requests.py:166-171`). Settled by anyone → `approval.settled`/`clarify.settled`.

```json
← {"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"…","seq":88,"replay_epoch":"…",
     "execution_generation":7,"payload":{"kind":"approval","prompt_id":"ap_1","execution_generation":7,
     "command":"rm -rf build","description":"recursive delete","choices":["once","deny","session","always"]}}}
→ {"jsonrpc":"2.0","id":20,"method":"approval.respond","params":{"session_id":"…","profile":"coder",
     "execution_generation":7,"prompt_id":"ap_1","choice":"once"}}
← {"jsonrpc":"2.0","id":20,"result":{"status":"resolved","prompt_id":"ap_1"}}
```

---

## 8. Profiles ↔ connections, and finding the Bot Chat

### 8.1 One socket for all served profiles
- A `scope:"host"` interactive ticket binds the socket to the ticket's `profile_id` (mint it for the
  primary/control home) **and** lets any request name a sibling served profile via `params.profile`
  (profile **name**: `"coder"`, `"default"`), routed by `AuthorityConnection._sibling_for`
  (`session_controls.py:175-199`; name→home match `hermes_cli/profiles.py:464-477`).
- Profile-scoped ticket naming another profile → `4001 profile_mismatch`. Profile still starting →
  `runtime_draining` (retryable); the socket holds such frames briefly (`tui_gateway/ws.py` `awaits_profile_start`).
- Desktop: primary socket + `profile` param when the primary serves the profile (`apps/desktop/src/store/gateway.ts:1022-1043`,
  `requestGatewayForProfile` adds `profile` at `:1120`); otherwise a separate pooled socket per profile with a
  ticket minted for that profile's home. Live here: one launchd gateway serves all 7 profiles
  (`default, business-team, chart-technical-analysts, coder, devops, finance-assistant, reviewer`) → **one WS suffices**.
- Server→client request responses name no profile; a host socket settles a sibling's request automatically
  (`session_controls.py:915-929`).
- Event frames carry no profile: map `session_id` → profile from what you resumed. (Session ids could repeat
  across profiles in principle; key state by `(profile, session_id)` like Desktop's `canonicalSessionKey`.)

### 8.2 Roster
`profiles.list {}` (canonical `include_sessions` defaults true; `canonical_projections.py:41-50`,
rows `profiles_vault_complete_foreign_subagents.py:136-180`):
```json
{"profiles":[{"name":"coder","path":"/Users/me/.hermes/profiles/coder","is_default":false,"model":"…","provider":"…",
  "description":"","display_name":"","skill_count":12,"previous_names":[],
  "last_session":{…},"worker_session":null,
  "canonical_session":{"id":"<registry row id>","resolved_id":"<live compression tip>","root_title":"Bot Chat","title":"Bot Chat",
                       "preview":"…","started_at":…,"last_active":…,"message_count":84,"live_message_count":80},
  "ui_meta_revisions":{},"ui_meta":null,"has_avatar":false}],
 "bot_mode_protocol":true,"install_id":"…"}
```

### 8.3 Bot Chat identity (`apps/desktop/src/AGENTS.md:63-95`, `src/plugins/hermes-bots/canonical-chat.ts`)
- Identity = **(profile, session titled exactly `"Bot Chat"`)**; DB `UNIQUE(title)` makes it ≤ 1 row per profile.
  **No stored session-id pin; never pick by recency.**
- Lookup every open (`canonical-chat.ts:281-342`):
  ```json
  {"method":"session.list","params":{"profile":"coder","title":"Bot Chat","limit":200,"include_hidden":true}}
  ```
  Row found → open `resolved_id`/`session_id` via `session.resume` (or `session.resume {title:"Bot Chat", profile}` directly).
- **Fail closed**: an RPC error, or an empty result while `profiles.list` still reports `canonical_session`,
  must **not** create a new chat (fork risk) — show "try again".
- Missing → `session.create {source:"gui", profile, title:"Bot Chat", hidden:true, request_id}`; server
  resolves-or-creates by title (adopts an existing row) and sets `follow_profile_config:true`. Desktop
  optionally submits a localized intro ("Hey, tell me about yourself!") only when creating a brand-new bot.
- Bot Chats are always hidden (excluded from sidebar lists); a compacted chat is on screen under its tip id
  while the registry names the root — match either `canonical_session.id` or `.resolved_id`.

---

## 9. Implementation checklist (Agora)
1. Socket: `identify` → `session-ticket(interactive, host)` → WS with subprotocols, **no Origin**, Host `127.0.0.1:<port>`.
2. On `gateway.ready`: `client.capabilities {server_requests:true}`; heartbeat `gateway.ping` 15 s / 45 s deadline.
3. `profiles.list` → roster; Bot Chat via `session.list {title:"Bot Chat", include_hidden:true, profile}`.
4. `session.resume` → keep `(profile, session_id)` → `{revision, execution_generation, replay_epoch, last_sequence, subscription_id}`.
5. Stream: route `event` frames by `session_id`; dedupe by `seq`; drop lower `execution_generation`; adopt `revision` from `session.info`/`session.updated`.
6. Send: `prompt.submit` with a UUID `submission_id` (retain for retries); images via `image.attach_bytes` → `attachments`.
7. Controls: `session.interrupt`/`session.steer` with current `execution_generation`; approvals via `approval.respond`.
8. Server requests: implement `sudo`, `secret`, `clarify`; answer everything else `-32601`.
9. Reconnect: full-jitter backoff; new ticket; `session.events.since` then `session.resume`; on `snapshot_required` or `session.replay_gap` just resume.
