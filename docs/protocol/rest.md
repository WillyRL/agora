# Hermes gateway REST reference (for Agora)

Target: Hermes Agent v0.23.0. Source root `H=/Users/me/.hermes/hermes-agent`. All paths below are relative to `H`.
Server = FastAPI routers in `hermes_cli/web_routers/*.py`, request models in `hermes_cli/web_models.py`. The same app is
served by the gateway's own listener (`api_origin`, e.g. `http://127.0.0.1:56904`) and by `hermes dashboard`.
Live examples marked **(live)** were captured read-only against the running gateway on 2026-11-06 (GETs only).
Items marked **UNVERIFIED** are inferred, not confirmed by code + live probe.

> Key finding: several Bot-Mode operations the desktop app performs are **JSON-RPC over `/api/ws`, not REST**:
> `profiles.list` (with `ui_meta`), `profiles.configure` (ui_meta CAS write), `profiles.set_asset`/`get_asset` (avatar image),
> `profiles.create` (ws twin of POST /api/profiles), `cron.manage` (Routines). There is **no** `PATCH /api/profiles/<id>/ui-meta`.
> REST `GET /api/profiles` exposes only the derived `bot_title`, not `ui_meta`. These RPCs are summarised in §1.4 so the WS doc can pick them up.

---

## 0. Auth & scoping (read first)

### 0.1 Local gateway: `X-Hermes-Gateway-Ticket` (native-http)

1. **Discover endpoint** — connect to the control socket `~/.hermes/gateway.sock` (or, if absent, the path in `~/.hermes/gateway.sock.path`,
   which must be `<dir>/hermes-gw-<sha256(home)[:16]>/control.sock`) — `apps/desktop/electron/local-gateway.ts:598-616`.
   Send one JSON line `{"verb":"identify","id":1}\n` → response `{"ok":true,"protocol":N,"result":{...}}`. Fields used
   (`gateway/run_bootstrap.py:295-299`, validation `hermes_cli/gateway_runtime.py:100-145`): **(live)**
   ```json
   {"instance_id":"cc85826d737e41719fa42571c3668626","api_origin":"http://127.0.0.1:56904",
    "served_profiles":[{"profile_id":"/Users/me/.hermes","home":"/Users/me/.hermes"},
                       {"profile_id":"/Users/me/.hermes/profiles/coder","home":"/Users/me/.hermes/profiles/coder"}, "..."],
    "capabilities":["session-authority-v1","durable-admission-v1","event-replay-v1"],
    "state":"ready","runtime_protocol":1,"authority_epoch":3,"hermes_home":"/Users/me/.hermes","profile":"default"}
   ```
   Require `state=="ready"`, `"session-authority-v1" ∈ capabilities`, loopback `api_origin`. (Electron gets the same via `hermes gateway ensure --json` → `payload.endpoint`, `electron/main.ts:11828`; that command may *start* a gateway, so prefer `identify` when one is running.)
2. **Mint a ticket** — same socket, one line (`gateway/control_socket.py:339-394`, client `electron/local-gateway.ts:664`):
   ```json
   {"protocol":1,"id":1,"verb":"session-ticket","params":{"profile_id":"/Users/me/.hermes/profiles/coder","instance_id":"<instance_id>","purpose":"native-http"}}
   ```
   → `{"ok":true,"protocol":..,"result":{"ticket":"<urlsafe32>","expires_in_seconds":30,"instance_id":"..","profile_id":"..","runtime_protocol":1}}`.
   Allowed params keys: `profile_id, instance_id, purpose, scope, subject, restart_wait`. Peer must be same uid (SO_PEERCRED); home dir must be owned by you and not group/other-writable.
   `scope:"host"` is only allowed for `purpose:"interactive"` (the WS ticket) — `gateway/runtime_bootstrap.py:37-55`.
3. **Use it** — header `X-Hermes-Gateway-Ticket: <ticket>`, **no `Origin` header**, from 127.0.0.1/::1 — `hermes_cli/dashboard_auth/native_http.py:197-221,324-348`.
   - **Single use, 30 s TTL** (`TicketStore.redeem` deletes the entry, `runtime_bootstrap.py:58-79`): **mint one ticket per HTTP request.**
   - Invalid/expired → `401 {"detail":"Unauthorized"}`; wrong profile → `403 {"detail":"profile_scope_mismatch"}`.
4. **Purposes** (`gateway/runtime_bootstrap.py:9-20`; chooser `electron/local-gateway.ts:487-504`):
   | purpose | for | minted for `profile_id` = |
   |---|---|---|
   | `native-http` | every REST route below except the two rows below | home of the profile the request targets |
   | `native-profile-create` | `POST /api/profiles` only | any served home (Electron uses the launch home) |
   | `native-profile-registry` | `PATCH`/`DELETE /api/profiles/{name}` only | **the target profile's home**; never the launch home (except PATCH rename of root `default` which only sets display_name) — `native_http.py:142-160` |
5. **Profile-scope rules for `native-http`** (`native_http.py:62-108`) — the ticket binds a *home*; every `profile` selector must name that home:
   - every `?profile=` value and a JSON body `"profile"` must resolve to the ticket's home (`current`/empty allowed except on `/api/profiles/*`, `/api/cron/jobs*`, `/api/sessions*`, `/api/fs/download`, `/api/fs/read-data-url`).
   - `/api/cron/jobs*` **requires** an explicit `?profile=<name>` matching the ticket (no cross-profile "all" listing). **(live)**: ticket for default + `GET /api/cron/jobs` → 403; ticket for `finance-assistant` + `?profile=chart-technical-analysts` → 403; matching → 200.
   - `GET /api/profiles` is allowed with any ticket (discovery); `POST /api/profiles` needs the create purpose.
   - `/api/profiles/{name}/...` → `{name}` must be the ticket's profile. `/api/profiles/sessions` needs `?profile=`, `/sessions/sidebar` needs `?recents_profile=`.
   - Default profile name = `default`, home = `~/.hermes`; named profile home = `~/.hermes/profiles/<name>` (resolved/realpath) — `electron/local-gateway.ts:450-485`.

### 0.2 Remote gateway

`apps/desktop/electron/connection-config.ts:11-19`, `electron/main.ts:5220-5231,7310-7320`:
- **token mode** (legacy): header `X-Hermes-Session-Token: <token>`; WS uses `?token=`. Token = server's `HERMES_DASHBOARD_SESSION_TOKEN` env (or `file:<path>`), else random per process — `hermes_cli/web_server_session_token.py:16-38`, header name `hermes_cli/web_server.py:225`.
- **oauth mode** (gateway's public `GET /api/status` → `auth_required: true`): browser cookie `hermes_session_at`/`_rt` (+ `__Host-`/`__Secure-` and `_<16hex>` suffixed variants), or RFC 8252 native flow `Authorization: Bearer <access_token>` (refresh at `/auth/native/refresh`); WS needs single-use ticket from `POST /api/auth/ws-ticket` (`hermes_cli/dashboard_auth/routes.py:573`).
- Remote profile scoping is plain `?profile=<name>` on the path (Electron `pathWithProfileScope`, `connection-config.ts:1017-1052`): added unless the path already has `profile` or is `/api/profiles/{name}/…`.

### 0.3 Unauthenticated
`GET /api/status` is public **(live)** → `{"version":"0.23.0","release_date":"2026.9.24","gateway_running":true,"gateway_platforms":{...},...}`. Everything else → 401 without credentials **(live)**.

### 0.4 Errors
FastAPI shape `{"detail": "<string or object>"}`. Session store busy → 503; corrupt store → 503 with `CORRUPT_STORE_DETAIL` object.

---

## 1. Profiles ("Bots")

Router: `hermes_cli/web_routers/profiles.py`. Models: `hermes_cli/web_models.py:454-500`.

### 1.1 List — `GET /api/profiles` (`profiles.py:809`)
Row builder `_profile_to_dict` (`profiles.py:84-100`). **(live)**
```json
{"profiles":[
 {"name":"finance-assistant","path":"/Users/me/.hermes/profiles/finance-assistant","is_default":false,
  "model":"claude-opus-5-5","provider":"anthropic","has_env":true,"skill_count":123,"gateway_running":true,
  "description":"Finance Assistant — Budgets, bills and receipts",
  "description_auto":false,"display_name":"","bot_title":"Finance Assistant",
  "distribution_name":null,"distribution_version":null,"distribution_source":null,"has_alias":true}]}
```
`bot_title` = `ui_meta["hermes-bots"].title` (`hermes_cli/profiles.py:672,872-875`). No `ui_meta`, no revisions, no avatar flag here → use WS `profiles.list` (§1.4) for the roster.
`GET /api/profiles/active` → `{"active":"default","current":"default"}` (`profiles.py:890`). `POST /api/profiles/active {"name":".."}` sets sticky CLI default (not needed for Agora).

### 1.2 Create — `POST /api/profiles` (`profiles.py:814-887`; purpose `native-profile-create`)
Body `ProfileCreate` (`web_models.py:454-472`):
```json
{"name":"researcher","description":"Finds and summarises sources","soul":"# Researcher\nYou are ...",
 "provider":"anthropic","model":"claude-opus-5-5",
 "clone_from":null,"clone_all":false,"clone_channels":false,"no_skills":false,
 "mcp_servers":[],"keep_skills":[],"hub_skills":[]}
```
Only `name` required. Omitted `clone_from` ⇒ fresh profile + bundled skills seeded + `~/.local/bin/<name>` alias if safe. Model set is best-effort (validated against the *serving* home's catalog).
Response:
```json
{"ok":true,"name":"researcher","path":"/Users/me/.hermes/profiles/researcher","model_set":true,"model_error":"",
 "mcp_written":0,"skills_disabled":0,"hub_installs":[],"soul_set":true}
```
Errors: 400 on bad/duplicate name (`ValueError`, `FileExistsError`). Note: REST create does **not** mirror launch credentials (.env/auth.json); the WS twin `profiles.create` does by default (`mirror_credentials:true`, `tui_gateway/methods_profiles.py:306-350`) — that's what the desktop Bots plugin uses. For Agora prefer the WS RPC or the new bot has no provider keys. **UNVERIFIED** whether the gateway hot-serves the new profile immediately for native tickets (code says create "asks a live multiplexer to serve the profile now", `profiles.py:829-831`; `identify.served_profiles` should then include it).
Bot Mode create also: writes `ui_meta.hermes-bots` (§1.4) and creates the canonical "Bot Chat" session (§4.6).

### 1.3 Per-profile writes
| Op | Request | Response | Source |
|---|---|---|---|
| Read SOUL | `GET /api/profiles/{name}/soul` | `{"content":"...","exists":true}` (`exists:false, content:""` if no file) | `profiles.py:1005` |
| Write SOUL | `PUT /api/profiles/{name}/soul` `{"content":"..."}` | `{"ok":true}` (atomic write of `<home>/SOUL.md`) | `profiles.py:1020` |
| Description | `PUT /api/profiles/{name}/description` `{"description":"..."}` | `{"ok":true,"description":"...","description_auto":false}` (written to profile.yaml) | `profiles.py:1042` |
| Auto-describe | `POST /api/profiles/{name}/describe-auto` `{"overwrite":false}` | `{"ok":bool,"reason":..,"description":..,"description_auto":bool}` | `profiles.py:1071` |
| Model | `PUT /api/profiles/{name}/model` `{"provider":"anthropic","model":"claude-opus-5-5"}` (both required, else 400) | `{"ok":true,"provider":"..","model":".."}` — writes `model.provider`/`model.default` in that profile's config.yaml; **no** expensive-model confirm here | `profiles.py:1056` |
| Rename | `PATCH /api/profiles/{name}` `{"new_name":"x"}` (registry ticket) | `{"ok":true,"name":"x","path":".."}`; for `default`: `{"ok":true,"name":"default","display_name":"x","path":..}`. Stops the profile's gateway, moves dir. | `profiles.py:965` |
| Delete | `DELETE /api/profiles/{name}` (registry ticket for that profile) | `{"ok":true,"path":".."}` or `{"ok":true,"path":..,"identity_settled":false,"settlement_pending":true,"retry_command":".."}` | `profiles.py:984` |
| Export / import | `POST /api/profiles/{name}/export {"extra_files":{},"output":""}` → `{"ok":true,"archive":"/path.tar.gz"}`; `POST /api/profiles/import {"archive":"/path","name":null}` → `{"ok":true,"name":..,"path":..,"desktop":null}` | `profiles.py:1102,1120` |

"Default" profile cannot be deleted (desktop guard `plugins/hermes-bots/profile-ops.ts:463`).

### 1.4 Bot UI metadata — `profile.yaml` → `ui_meta["hermes-bots"]` (JSON-RPC only)

Storage (`tui_gateway/methods_profiles.py:605-668`): `profile.yaml` top-level `ui_meta: {<namespace>: <any JSON>}` plus `_ui_meta_revisions: {<namespace>: int}`.

**Read**: WS `profiles.list` `{"include_sessions":false}` (`methods_profiles.py:282-303`). Each row:
```json
{"name":"chart-technical-analysts","path":"..","is_default":false,"model":"..","provider":"..","description":"..",
 "display_name":"","skill_count":122,"previous_names":[],
 "ui_meta_revisions":{"hermes-bots":1},
 "ui_meta":{"hermes-bots":{"shape":"blobatar","imageKind":"shape","title":"Chart Technical Analysts","created":1789065792155}},
 "has_avatar":false,
 "last_session":{..},"worker_session":{..},"canonical_session":{"id":"..","resolved_id":"..", "...":"..."}}
```
Top level also `"bot_mode_protocol":true,"install_id":".."`. `ui_meta_revisions` always present on CAS-capable gateways (feature-detect). `include_sessions` (default true) adds `last_session`/`worker_session`/`canonical_session`. YAML timestamps are coerced to ISO strings.

**Write**: WS `profiles.configure` (`methods_profiles.py:386-409`, CAS `605-668`):
```json
{"name":"chart-technical-analysts",
 "ui_meta":{"hermes-bots":{"shape":"blobatar","imageKind":"shape","title":"Chart Analyst","created":1789065792155,"color":"blue","hidden":false}},
 "ui_meta_expected_revisions":{"hermes-bots":1}}
```
Semantics:
- Merge is **per namespace key** of `ui_meta`: `ui_meta["hermes-bots"]` is **replaced whole**; other namespaces (e.g. `user-sections`, `shared-room`, a future `agora`) are untouched. `null` value deletes the namespace.
- Therefore **unknown keys inside `hermes-bots` are preserved only by client read-modify-write**: desktop re-reads `profiles.list`, spreads the server object, overlays its patch, strips `chat`/`image`/`pet`, retries up to 3× on conflict (`apps/desktop/src/plugins/hermes-bots/data.ts:336-421`). Agora must do the same.
- CAS: `ui_meta_expected_revisions[key]` must equal current revision (0 if never written) or **whole write rejected**. Revisions increment per written key, survive deletion.
- 64 KB cap on `json.dumps(ui_meta)` (silently `applied.ui_meta=false`).
- Response: `{"ok":true,"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":2}}}`; conflict:
  `{"ok":false,"applied":{"ui_meta":false,"ui_meta_conflicts":{"hermes-bots":{"expected":1,"actual":2}},"ui_meta_revisions":{"hermes-bots":2}}}`.
- Same RPC also accepts `soul`, `description`, `model`+`provider` (+`confirm_expensive_model`; may answer `confirm_required`+`confirm_message` and write nothing), `disabled_skills`, `enabled_toolsets`, `enabled_mcp_servers`; each reported in `applied`.

**Avatar image** (not in ui_meta): WS `profiles.set_asset {"name":"..","asset":"avatar","data":"data:image/png;base64,..."}` (PNG/JPEG/WebP ≤ 2 MB, stored `<home>/assets/avatar.<ext>`) or `{"clear":true}`; `profiles.get_asset {"name":"..","asset":"avatar"}` → `{"found":true,"mime":"image/png","size":N,"data":"data:..."}` / `{"found":false}` (`methods_profiles.py:412-461`).

**`hermes-bots` schema** (`apps/desktop/src/plugins/hermes-bots/types.ts` `BotMeta`): `title?:string`, `description?:string`, `color?:string|null`, `shape?:string` (`circle|squircle|pill|triangle|hexagon|cloud|drop` or `blobatar`, `blobatar:<seed>`, `blobatar:<seed>:<kind>` — `avatar.tsx:26,117-122`), `imageKind?:'photo'|'shape'`, `custom?:bool`, `hidden?:bool`, `pinned?:bool`, `groups?:string[]`, `group?:string|null` (legacy scalar), `sectionId?:string|null`, `sectionName?:string|null`, `screenAutoOpen?:bool`, `created?:number` (ms epoch). Client-only: `image` (data URL → goes to set_asset), `pet`; legacy `chat` is dropped on sight. No `revision` field inside the object — revision lives in `_ui_meta_revisions`.

**Real files (read-only)**:
```yaml
# ~/.hermes/profiles/finance-assistant/profile.yaml
description: Finance Assistant — My personal finance management, including manage
  the budget app
description_auto: false
ui_meta:
  hermes-bots:
    shape: blobatar
    color: null
    imageKind: photo
    title: Finance Assistant
    created: 1788539709939
_ui_meta_revisions:
  hermes-bots: 1
```
```yaml
# ~/.hermes/profiles/coder/profile.yaml
description: This agent profile dedicated to Coding purposes
description_auto: false
ui_meta:
  hermes-bots:
    groups:
      - Hermes, Coder, Reviewer
    group: Hermes, Coder, Reviewer
_ui_meta_revisions:
  hermes-bots: 1
```
`business-team` has `title: ''` + shape fields; `devops` has **no** ui_meta (not yet Bot-managed); the default profile (`~/.hermes/profile.yaml`) — not inspected/none.

### 1.5 Bot Mode semantics (`website/docs/user-guide/bot-mode.md`)
- A Bot **is** a profile (`:12-16`). One canonical forever chat per Bot = the profile's session titled exactly **`Bot Chat`** (core UNIQUE(title) ⇒ registry of one; `:39`, `:208-216`; `apps/desktop/src/plugins/hermes-bots/canonical-chat.ts:24-50,382-520`; server lookup `tui_gateway/methods_profiles.py:162-190`). `/new` in it is rerouted to `/compact`. Archiving it retires it (next click creates a new one); `sessions.auto_archive` never archives a Bot Chat (`:45`).
- Bot-to-bot: `message_agent(target=..., message=..., expects_reply?, constraints?, expecting?)` tool, injected **only** in canonical Bot Chat sessions on a Bot-Mode-managed install, i.e. (a) `agent.bot_mode_protocol: true` (default), (b) session title `Bot Chat`, (c) ≥1 profile on the install has a `ui_meta: {hermes-bots: …}` block (`:213-226`). Delivery is fire-and-forget into the target's Bot Chat; reply returns as a completion notification. Loop guard `gateway.bot_loop_guard.max_hops` (default 4) (`:179-205`). No Agora REST involvement — Agora just renders the transcript (messages appear prefixed `Message from 🤖 <name> (@handle):`).
- Hidden bots, sections, title, look: all in `ui_meta.hermes-bots` so they follow the profile across desktops (`:43,57,98`).

---

## 2. Models

### 2.1 Picker — `GET /api/model/options` (`hermes_cli/web_routers/models.py:138-171`)
Query: `profile`, `refresh` (bust 1 h cache), `include_unconfigured`, `explicit_only` (desktop sends `explicit_only=1`, `apps/desktop/src/api/models.ts:36-62`). 503 `"Restart required: …"` on code skew. Shape `ModelOptionsResult` (`apps/shared/src/gateway-contract.generated.ts:822-855`). **(live, trimmed)**
```json
{"model":"claude-opus-5-5","provider":"anthropic",
 "providers":[
  {"slug":"anthropic","name":"Anthropic","is_current":true,"is_user_defined":false,
   "models":["claude-fable-5.1","claude-fable-5","claude-opus-5-5","claude-opus-5","..."],"total_models":14,
   "source":"built-in","authenticated":true,"featured_models":[],
   "capabilities":{"claude-fable-5.1":{"fast":false,"reasoning":true}},"pricing":{},
   "usage":{"accounts":[{"id":"fp:0373…","label":"ANTHROPIC_TOKEN","windows":[],"state":"limited","resets_at":"2026-11-06T15:25:58Z"}]}},
  {"slug":"openrouter","name":"OpenRouter","models":["anthropic/claude-fable-5.1","..."],"total_models":74,"featured_models":["..."],"authenticated":true,"source":"built-in"},
  {"slug":"moa","name":"Mixture of Agents","models":["default"],"source":"virtual","auth_type":"virtual","warning":"..."},
  {"slug":"openai-codex","...":"..."}]}
```
Other optional provider fields: `aliases, api_url, auth_type, key_env, warning, unavailable_models, plan_usage, usage_levels, limit, free_tier*, pricing_pending`. With a native ticket, `?profile=` must equal the ticket's profile.

### 2.2 Set default model
- Per profile (Bots): `PUT /api/profiles/{name}/model` (§1.3) — simplest.
- Generic: `POST /api/model/set?profile=<name>` (`models.py:376-420`), body `ModelAssignment` (`web_models.py:113-131`):
  `{"scope":"main","provider":"anthropic","model":"claude-opus-5-5","base_url":"","api_key":"","confirm_expensive_model":false}`.
  Guarded/expensive pick → `{"ok":false,"scope":"main","provider":..,"model":..,"confirm_required":true,"confirm_message":".."}`; resend with `confirm_expensive_model:true`. Applies to **new** sessions only.
- `GET /api/model/info?profile=` → `{"model","provider","auto_context_length","config_context_length","effective_context_length","capabilities"}` (`models.py:90-135`).
- `GET /api/model/recommended-default?provider=X` → `{"provider","model","free_tier"}`.

---

## 3. Cron ("Routines") — `hermes_cli/web_routers/cron.py:734-807`

Stored per profile at `<home>/cron/jobs.json` (`{"jobs":[...],"updated_at":..}`). **Native ticket: always pass `?profile=<name>` = ticket's profile.**

| Op | Request | Response |
|---|---|---|
| List | `GET /api/cron/jobs?profile=<name>` (default `all` — forbidden for native tickets) | `CronJob[]` (bare array), includes paused/disabled (`list_jobs(True)`) |
| Get | `GET /api/cron/jobs/{id}?profile=` | `CronJob`; 404 if missing |
| Runs | `GET /api/cron/jobs/{id}/runs?profile=&limit=20` | `{"runs":[SessionInfo…]}` newest first (agent sessions `source='cron'` + script-only rows `id:"cron_output:<job>:exec:<n>"`) |
| Create | `POST /api/cron/jobs?profile=` body `CronJobCreate` | `CronJob` |
| Update | `PUT /api/cron/jobs/{id}?profile=` body `{"updates":{...}}` | `CronJob` |
| Pause | `POST /api/cron/jobs/{id}/pause?profile=` | `CronJob` (`enabled:false,state:"paused"`) |
| Resume | `POST /api/cron/jobs/{id}/resume?profile=` | `CronJob` |
| Run now | `POST /api/cron/jobs/{id}/trigger?profile=` — **synchronous, waits for the whole run** (desktop timeout 24 h, `api/cron.ts:21-24`); paused jobs are force-run | refreshed `CronJob`; 409 `"Job is already running or was claimed by another scheduler"` |
| Stop run | `POST /api/cron/jobs/{id}/cancel?profile=` | `{"cancelled":bool,"detail"?,"execution_id"?,"job_id":".."}` |
| Delete | `DELETE /api/cron/jobs/{id}?profile=` | `{"ok":true}` |
| Targets | `GET /api/cron/delivery-targets?profile=` | `{"targets":[{"id":"local","name":"Local (save only)","home_target_set":true,"home_env_var":null},…]}` |

`CronJobCreate` (`web_models.py:325-350`):
```json
{"name":"[bot:researcher] Morning digest","schedule":"every day at 08:00","prompt":"Summarise ...",
 "deliver":"local","repeat":null,"paused":false,"skills":null,"model":null,"provider":null,
 "script":null,"no_agent":false,"timezone":null,"grace_minutes":null,"catch_up":null,"workdir":null,"enabled_toolsets":null}
```
(`schedule` required; grammar per `website/docs/user-guide/features/cron.md` — e.g. `every 10m`, cron expr, `once in 2h`.) Update keys desktop sends: `name, prompt, schedule, deliver, enabled, model, provider, catch_up` (`apps/desktop/src/types/hermes.ts:1141-1150`).

**CronJob (live, `chart-technical-analysts`, prompt trimmed)**:
```json
{"id":"a6e1bb6568e7","name":"Silver alert: touch 48.21 / close below 50","prompt":"Silver (SI=F) price watchdog…",
 "skills":[],"skill":null,"model":null,"provider":null,"base_url":null,"script":"silver_alert.py","no_agent":true,
 "monitor_script":null,"monitor_url":null,"monitor_state":null,"context_from":null,
 "schedule":{"kind":"interval","minutes":10,"display":"every 10m"},"schedule_display":"every 10m",
 "repeat":{"times":1080,"completed":991},
 "enabled":true,"state":"scheduled","paused_at":null,"paused_reason":null,
 "created_at":"2026-10-30T20:14:30.696294+07:00",
 "next_run_at":"2026-11-06T22:23:33.408557+07:00","last_run_at":"2026-11-06T22:13:33.408557+07:00",
 "last_status":"ok","last_error":null,"last_delivery_error":null,"last_delivery_unverified":null,"last_failure":null,"failure_streak":0,
 "deliver":"telegram","origin":null,"enabled_toolsets":null,"workdir":null,
 "last_dispatch":{"scheduled_at":"…","dispatched_at":"…","lateness_seconds":59.7,"kind":"on_time"},"fire_claim":null,
 "latest_execution":{"id":"fcc4…","job_id":"a6e1bb6568e7","source":"builtin","status":"completed","claimed_at":"…","started_at":"…","finished_at":"…","error":null,"delivery_outcome":"suppressed","scheduled_instant":"…","progress_at":null,"pid":57005,"process_id":"…","process_started_at":179397355748,"handoff_pending":0,"handoff_started_at":null},
 "live_execution":null,
 "profile":"chart-technical-analysts","profile_name":"chart-technical-analysts","hermes_home":"/Users/me/.hermes/profiles/chart-technical-analysts",
 "is_default_profile":false,"scheduler_heartbeat_age_s":53.17}
```
Status mapping for UI: paused ⇔ `enabled==false || state=="paused"`; running ⇔ `live_execution != null` (or `latest_execution.status ∈ {claimed,running}`); last result = `last_status` (`ok`/error…) + `last_error`; `state` also `completed` for exhausted one-shots. Agent-routine output = the run sessions (`/runs`).

**Bot routines convention** (`apps/desktop/src/plugins/hermes-bots/cron.tsx:71-75,217-232,272-288,1013-1017`): name `"[bot:<profile>] <title>"`, regex `^\[bot:([a-z0-9][a-z0-9_-]*)\]\s*` (case-insens.). Desktop creates them via WS `cron.manage {"action":"add","name":..,"schedule":..,"prompt":..,"profile":"<bot>","repeat"?:N}` in **the bot's own profile store**; list via `cron.manage {"action":"list","include_disabled":true,"profile":"<bot>"}` → `{"jobs":[...],"scoped":"<bot>"}`. If the job lives in the bot's own profile, prompt is the plain instruction; otherwise it is wrapped with marker `[bot-mode:routine:v2] ` and a `hermes -p <bot> chat -c "Routine: <title>" -q …` delegation. Filtering: if the store is scoped to the bot → show all its jobs; else filter by tag (untagged → `default`). With REST + per-profile `?profile=` Agora gets the scoped behaviour for free.

---

## 4. Sessions & history — `hermes_cli/web_routers/sessions.py`, `profiles.py:455-800`

### 4.1 List one profile — `GET /api/sessions` (`sessions.py:182-275`)
Query: `limit` (≤100, default 20), `offset`, `min_messages`, `archived=exclude|only|include`, `order=created|recent`, `source`, `sources` (csv), `exclude_sources` (csv; desktop recents use `exclude_sources=cron`), `cwd_prefix`, `full`, `profile`.
Response `{"sessions":[…],"total":N,"limit":..,"offset":..,"storage":{}}`. Row **(live, trimmed)**:
```json
{"id":"20261106_210918_657bdf","runtime_revision":0,"runtime_generation":0,"source":"desktop","model":"claude-opus-5-5",
 "parent_session_id":null,"started_at":1793974168.61,"ended_at":null,"end_reason":null,"message_count":16,"tool_call_count":7,
 "input_tokens":18,"output_tokens":2747,"estimated_cost_usd":0.171,"title":"Claude auth error on Mac mini t3code","title_source":"llm",
 "last_activity_at":1793974168.64,"profile_name":"default","archived":false,"auto_archived":0,"pinned":false,"hidden":0,
 "last_read_at":null,"last_active":1793974207.49,"preview":"I get this on my mac mini…","unread":false,"is_active":false,
 "profile":"default","is_default_profile":true}
```
Observed **(live)**: `finance-assistant` returned `{"sessions":[],"total":2}` — `total` counts rows the page filters out (likely `hidden` Bot-Chat/worker rows). **UNVERIFIED** exact cause; don't rely on `total` for emptiness.
Multi-profile: `GET /api/profiles/sessions?profile=<name>&limit=&offset=&min_messages=&archived=` (≤500) → `{"sessions","total","profile_totals":{"name":N},"limit","offset","errors":[],"storage":{}}`; sidebar batch `GET /api/profiles/sessions/sidebar?recents_profile=…` → `{"recents":{sessions,profiles_truncated,profiles_usage},"cron":{sessions},"messaging":{sessions,total},"errors","storage"}`.
Other: `GET /api/sessions/search?q=&limit=&profile=` → `{"results":[…]}`; `GET /api/sessions/{id}?profile=` (id or unique prefix) → full row + `profile`; `GET /api/sessions/stats?profile=`.

### 4.2 Messages — `GET /api/sessions/{id}/messages` (`sessions.py:743-802`)
Query: `profile`, `limit` (≤500; omitted ⇒ latest 500), `offset`, `order=oldest|latest`, `include_compacted`, `inline_images` (default true). Includes compression ancestors. **(live)**
```json
{"session_id":"20261106_210516_1a4d1b","profile":"default",
 "pagination":{"limit":2,"offset":0,"order":"latest","returned":2},
 "messages":[
  {"id":65735,"session_id":"…","role":"user","content":"If I want to create my own Hermes Desktop…","tool_call_id":null,"tool_calls":null,"tool_name":null,
   "timestamp":1793973948.55,"finish_reason":null,"reasoning":null,"active":1,"compacted":0,"display_kind":null,"display_metadata":null,
   "message_uid":"05c2eb4d…","…":"…"},
  {"id":65736,"role":"assistant","content":"If you want to keep the Hermes mythology…","finish_reason":"stop",
   "reasoning":"…","reasoning_content":"…","reasoning_details":"[{\"type\": \"thinking\", …}]","message_uid":"2ea2de6b…"}]}
```
Desktop's first page: `limit=120&order=latest` (`apps/desktop/src/api/sessions.ts:474-520`). Rows may carry `display_content` (projected). Paging by prompt: `GET /api/sessions/{id}/timeline?limit=&after_row_id=` → `{session_id,profile,…,next_cursor}`; `GET /api/sessions/{id}/messages/around?row_id=&limit≤120`. Export: `GET /api/sessions/{id}/export` (streamed JSON).

### 4.3 Mutations (rename / archive / pin / hide / unread / delete) — fenced CAS
All need `request_id` (UUIDv4) + `expected_revision` (+ `expected_generation`), else **409** `client_upgrade_required` / `mutation_identity_required` (`hermes_cli/web_server_sessions.py:271-318`). Flow (`apps/shared/src/session-http-mutations.ts`, `apps/desktop/src/api/sessions.ts:401-430`):
1. `GET /api/sessions/{id}/mutation-snapshot?profile=` → **(live)** `{"session_id":"…","exists":true,"runtime_revision":0,"runtime_generation":0}`
2. `PATCH /api/sessions/{id}` body (`SessionRename`, `web_models.py:280-290`):
   ```json
   {"request_id":"6f1c…","expected_revision":0,"expected_generation":0,"profile":"coder",
    "title":"New title","archived":true,"pinned":false,"hidden":null,"unread":null}
   ```
   Any subset of `title, archived, hidden, pinned, unread` (null = untouched). Desktop archive sends `{archived:true,pinned:false}`. → `{"ok":true, …receipt}`.
3. `DELETE /api/sessions/{id}?profile=&request_id=&expected_revision=&expected_generation=` (identity in **query**). Already-absent → `{"ok":true,"already_absent":true}`.
Retry rule: on an ambiguous failure, **resend the same request_id/revision** (idempotent receipt); on definitive refusals (`revision_conflict|stale_generation|permission_denied|profile_mismatch|invalid_params|session_busy|not_found|…`) re-read snapshot. Status mapping 409/404/503 (`session_busy`, `storage_unavailable`).
Bulk: `POST /api/sessions/bulk-delete {"ids":[…≤500],"profile":".."}` → `{"ok":true,"deleted":N,"skipped_active":[…]}`; `GET /api/sessions/empty/count?profile=` → `{"count":N}`; `DELETE /api/sessions/empty?profile=` → `{"ok":true,"deleted":N}`; `POST /api/sessions/prune {"older_than_days":90,"dry_run":true,"profile":..,…}`. Destructive ops require explicit profile (`destructive_profile`).

### 4.4 Auto-archive
Server-side, config `sessions.auto_archive: false` (default), `sessions.auto_archive_days: 3` (`hermes_cli/config_defaults.py:2267-2271`), run by `SessionDB.maybe_auto_archive` (`hermes_state_maintenance.py:333-354`); soft-hide only, sets `auto_archived=1`; pinned sessions and Bot Chats exempt; resume/new activity un-archives (`website/docs/user-guide/sessions.md:551-557,680`). Toggle via `PUT /api/config` (not detailed here). No REST "run sweep now".

### 4.5 Creating sessions / sending
Not REST — WS (`session.create`, `prompt.submit`, `session.title`). See WS doc.

### 4.6 Bot Chat
Find: WS `profiles.list` → `canonical_session` ({`id`, `resolved_id` = compression tip}), or REST search by exact title. Create: WS session create + `session.title {"title":"Bot Chat"}` (`canonical-chat.ts:382-520`). Never rename/archive it casually (archive = retire).

---

## 5. Uploads & media — `hermes_cli/web_routers/files.py`, `uploads.py`

### 5.1 Images (base64 JSON) — `POST /api/chat/image-upload?profile=<name>` (`files.py:568-612`)
Body `ChatImageUpload` (`web_models.py:95-97`): `{"data_url":"data:image/png;base64,iVBOR…","filename":"screenshot.png"}`.
Must be `data:image/*;base64,` ; magic-sniffed PNG/JPEG/GIF/WebP/BMP; ≤ 25 MiB (`web_upload_limit.py:20`).
→ `{"ok":true,"path":"/Users/me/.hermes/profiles/coder/images/dashboard_20261106_221500_ab12cd34_screenshot.png","name":"…","bytes":12345,"mime_type":"image/png"}`.
Then pass `path` as the attachment in the WS prompt submission (desktop `upload-server-image.ts:13-50`; attachment shape belongs to WS doc).

### 5.2 Any file (multipart) — `POST /api/chat/file-upload?profile=` (`uploads.py:22-53`)
`multipart/form-data`, field `file`. ≤ 16 MiB (`WEBAPP_ATTACHMENT_MAX_BYTES`, `hermes_constants.py:29`). → `{"ok":true,"path":"<home>/uploads/…","size":N,"staged_upload":{…}?}` for the `file.attach` flow.

### 5.3 Fetching bot-produced images/files
- `GET /api/fs/read-data-url?path=<abs path or file:…>&profile=&session_id=` (`files.py:1197-1238`) → `{"dataUrl":"data:image/png;base64,…"}`; ≤ 16 MiB; supports `ETag`/`If-None-Match` → 304. Desktop default for transcript images (`apps/desktop/src/lib/media.ts:141`). `session_id` resolves `/workspace`-relative paths in that session's sandbox.
- `GET /api/media?path=<abs>` (`files.py:427-448`) → `{"data_url":"…"}`; image extensions only, ≤ 25 MiB, must be under media roots (403 otherwise; may 403 remotely).
- `GET /api/media/proxy?url=<https://…fal.media/…>` (`files.py:471-…`) → `{"data_url":"…"}`; allowlisted CDNs (`fal.media`, `fal.run`, `storage.googleapis.com`, `*.fal.media`, `*.fal.run`) for remote-generated images.
- `GET|HEAD /api/files/stream?path=&profile=&session_id=` (`files.py:833-860`) — inline bytes with HTTP Range (audio/video, `media_only`). Browser-style callers use `?ticket=` from `POST /api/files/ticket {"route":"stream"|"download","path":..,"profile":..,"session_id":..}` → `{"ticket":".."}`; a native client can simply send its auth header instead. **UNVERIFIED** that a native-http ticket header alone works on `/api/files/stream` (route itself doesn't forbid it; Electron's `media-protocol.ts:139-163,235-258` adds auth headers + `profile`).
- `GET /api/fs/download?path=&profile=&session_id=` — attachment download (`files.py:1356`).
For Agora: images → `read-data-url` (or `media/proxy` for http URLs); video/audio/large → `files/stream` with Range.

---

## 6. Agora checklist
1. `identify` once per gateway instance (re-identify on 401 / instance change).
2. Per REST call: mint ticket for the **target profile's home** with the right purpose → send with `X-Hermes-Gateway-Ticket`, no `Origin`.
3. Always add `?profile=<name>` for cron, sessions, model, uploads; omit it on `/api/profiles/{name}/…`.
4. Roster + ui_meta + avatars + Bot-Chat lookup + routine create/list go over WS (`profiles.list`, `profiles.configure` with CAS RMW, `profiles.get_asset/set_asset`, `cron.manage`); everything in §§1.3, 2, 3, 4, 5 works over REST.
