# Remote connections & reconnection — protocol reference

Source of truth: Hermes Agent v0.23.0 checkout at `/Users/me/.hermes/hermes-agent` (release date `2026.9.24`, `hermes_cli/__init__.py:5`).
All paths below are relative to that root. Server = Python (`hermes_cli/`, `gateway/`, `tui_gateway/`); reference client = `apps/shared/src` + `apps/desktop/{electron,src}`.
Items marked **UNVERIFIED** were inferred, not read or tested end to end.

---

## 0. TL;DR for Agora (Swift)

| Concern | What to do |
|---|---|
| Discover auth | `GET {base}/api/status` (no credentials). `auth_required` false → token/loopback mode. true → gated. `auth_flows` contains `"native_pkce"` → system-browser PKCE sign-in is available. |
| Browser sign-in | `ASWebAuthenticationSession` won't do here: redirect must be `http://127.0.0.1:<port>/…` (an IP literal, never `localhost`). Run a one-shot `NWListener` on 127.0.0.1:0, open `GET {base}/auth/native/authorize?code_challenge=…&code_challenge_method=S256&redirect_uri=http://127.0.0.1:PORT/callback&state=…[&provider=…]` in the system browser, catch `?code=&state=`, then `POST {base}/auth/native/token` with JSON `{"code","code_verifier"}`. No `client_id`, no `grant_type`. |
| Token response | `{"access_token","refresh_token","token_type":"Bearer","expires_at":<unix s>,"provider","user_id"}`. It carries **`expires_at` (absolute), not `expires_in`**. |
| Refresh | `POST {base}/auth/native/refresh` JSON `{"refresh_token","provider"}`, same response shape. 401 `{"error":"session_expired"}` → drop the tokens and sign in again. 503 → transient, keep the tokens. Refresh 60 s before `expires_at`, and use one in-flight refresh per host. |
| REST auth | `Authorization: Bearer <access_token or pasted session token>`. `X-Hermes-Session-Token: <token>` only works on a **loopback-mode** server (`auth_required:false`). Bearer works in both modes. |
| WS auth (remote) | Gated mode: `POST {base}/api/auth/ws-ticket` with the Bearer header, which returns `{"ticket","ttl_seconds":30}`. Then dial `wss://host/api/ws?ticket=<t>`, or use the subprotocols `["hermes-gateway-v1","hermes-gateway-ticket.<t>"]`. Token mode: `ws(s)://host/api/ws?token=<token>`. The ticket is single-use, so **mint a new one before every dial**. |
| Profiles (remote) | REST: `?profile=<name>` (or `body.profile` for session writes). WS: one socket for the host, and every RPC carries `"profile":"<name>"`. Nothing goes on the WS URL. |
| Reconnect | Backoff is full jitter `random(0, min(15000, 300·2^n))` ms. Reset `n` only after a socket stayed open ≥ 5 s. Re-mint the ticket on every attempt. After open, call `session.events.since` for each session you hold a seq watermark for, and park live frames for that session until the replay answers. Dedupe by `seq <= watermark`. |
| After open | Wait for `event gateway.ready`. Then: `client.capabilities {"server_requests":true}`, and start a `gateway.ping` heartbeat every 15 s (deadline 45 s) if `payload.heartbeat === true`. Watch `payload.replay_epoch`. |

---

## 1. `GET /api/status` (public, no auth)

* Public by allowlist: `hermes_cli/dashboard_auth/public_paths.py:9-27` (`/api/health`, `/api/status`, `/api/config/defaults`, `/api/config/schema`, `/api/model/info`, `/api/dashboard/themes`, `/api/dashboard/plugins`, `/api/cron/fire`). These are exact matches, so `/api/status/extension` is not public (`dashboard_auth/middleware.py:56-61`).
* Handler: `hermes_cli/web_routers/status.py:530-636`. Auth readout: `_auth_gate_status()` at `status.py:383-407`.
* Optional `?profile=<name>` scopes the gateway readout. `current` or empty means unscoped. An unknown name gives 404 `{"detail":"Profile 'x' does not exist."}` (`web_server_profiles.py:190-199`). A signed-out caller on the gateway *Webapp* surface has `?profile` ignored.

### Auth advertisement (`status.py:383-407`)
```python
auth_flows = []
if auth_required:
    auth_flows.append("cookie")
    if list_interactive_providers():       # ≥1 provider with a browser/password login
        auth_flows.append("native_pkce")
return {"auth_required": ..., "auth_providers": [p.name for p in list_providers()], "auth_flows": auth_flows}
```
* `auth_required` is true on any non-loopback bind (`web_server_boundary.py` `should_require_auth`: `host not in _LOOPBACK_HOST_VALUES`). It is also true with a non-loopback `dashboard.public_url`, even on a loopback bind. `--insecure` is ignored (comment: "IGNORED since the June 2026 hermes-0day campaign").
* `auth_providers` lists provider names. The bundled plugins are in `plugins/dashboard_auth/{basic,nous,self_hosted,session_token,drain}`. Names seen: `"basic"` (username/password), `"nous"` (Nous Portal OAuth, `nous/__init__.py:48`), `"self-hosted"` (OIDC, `self_hosted/__init__.py:83`), `"session-token"` (provisioned `HERMES_DASHBOARD_SESSION_TOKEN`, `session_token/__init__.py:101`), `"drain-secret"` (token-only machine credential; not a session provider, `drain/__init__.py:71`).
* `"native_pkce"` does **not** depend on the provider being OAuth. Password providers (`basic`) count as interactive: native authorize sends the browser to the `/login` form, and the code comes back on loopback anyway (`routes.py:345-349`). `session-token` is *not* interactive (`interactive_login=False`). A token-only server therefore reports `auth_flows:["cookie"]`, and `GET /api/auth/providers` returns `{"providers":[]}`.
* No "basic auth" flow is advertised. HTTP `Authorization: Basic` is not used anywhere. "basic" is a *provider* whose credentials go through the HTML `/login` form → `POST /auth/password-login`.

### Full response shape (`status.py:575-631`)
```jsonc
{
  "version": "0.23.0",                 // get_version_info().base_version
  "release_date": "2026.9.24",
  "config_version": 0, "latest_config_version": 0,       // ints (UNVERIFIED types)
  "can_update_hermes": true,
  "gateway_running": true, "gateway_state": "running",    // running|degraded|starting|stopped|startup_failed|... |null
  "gateway_platforms": {}, "gateway_exit_reason": null,
  "gateway_updated_at": "2026-11-06T12:00:00Z",           // RFC3339 string | null
  "gateway_heartbeat_stale_s": null, "gateway_shared_with": null,
  "active_agents": 0, "gateway_busy": false, "gateway_drainable": true,
  "restart_drain_timeout": 0, "active_sessions": 0,
  "auth_required": true, "auth_providers": ["basic"], "auth_flows": ["cookie","native_pkce"],
  "nous_session_valid": "…",
  "install_id": "…",                    // omitted when unpersistable
  "shared_profile_warning": false,
  "components": { … }, "overall": "ok", // "ok" | "degraded"
  "fts_rebuild": { … },                 // optional
  "profiles": [ … ], "parked_profiles": [], "gateway_mode": "…", "multiplex_standalone_reason": null,
  // ONLY when auth_required == false:
  "hermes_home": "...", "config_path": "...", "env_path": "...", "gateway_pid": 123,
  "gateway_health_url": "...", "gateways": [ … ]
}
```
When the caller is signed out on the gateway's Webapp surface, the response is cut down to `version, release_date, gateway_running, gateway_state, overall, components, auth_required, auth_providers, auth_flows` (`status.py:507-509`).

### Cheaper probe: `GET /api/health` (`status.py:119-130`)
```json
{"ok": true, "version": "0.23.0", "displayVersion": "0.23.0+…", "commit": "<sha>", "auth_required": true}
```
Use it as the liveness/reachability check. Use `/api/status` to pick the auth mode, as the desktop does in `probeRemoteAuthMode` (`apps/desktop/electron/main.ts:10101-10165`). That function then calls `GET /api/auth/providers` (`routes.py:212-224`):
```json
{"providers": [{"name": "basic", "display_name": "…", "supports_password": true}]}
```
It returns 503 `{"detail":"no auth providers registered"}` when no session provider is registered.

### Desktop's auth-mode decision
* `authModeFromStatus = status.auth_required ? 'oauth' : 'token'` (`connection-config.ts:1132-1134`).
* `resolveLoginStrategy` (`native-oauth.ts:98-111`) works like this. If every advertised provider is `supports_password`, it uses `embedded`, i.e. a cookie webview (`native-auth-decisions.ts:229-237`). Otherwise it uses `native` if `auth_flows` includes `native_pkce`, and falls back to `embedded`.
  * **Agora recommendation:** don't build the embedded webview. Always use `native` when `native_pkce` is present. It also works for password providers, because the browser shows the `/login` form.

---

## 2. Native browser sign-in (RFC 8252 + PKCE, gateway-brokered)

Server: `hermes_cli/dashboard_auth/routes.py` (routes) and `native_flow.py` (store). Client: `apps/desktop/electron/native-oauth.ts`, `native-oauth-login.ts`, `native-access-token.ts`, `main.ts:7310-7430`.

The gateway acts as the authorization server for the app and as an OAuth client of the upstream IdP (`native_flow.py:1-13`). **There is no `client_id`.**

### 2.1 PKCE pair (client side, `native-oauth.ts:51-70`)
* `verifier = base64url_nopad(random 32 bytes)` (43 chars).
* `challenge = base64url_nopad(SHA256(ascii(verifier)))`.
* `state = base64url_nopad(random 24 bytes)`.
* Server check: `hmac.compare_digest(cc, base64url_nopad(sha256(verifier)))` (`native_flow.py:72-75,156`).

### 2.2 Loopback listener (`native-oauth-login.ts:94-211`)
* Bind `127.0.0.1` on port `0` (ephemeral). `redirectUri = "http://127.0.0.1:<port>/callback"`.
* Every request gets a 200 response with a "Signed in, close this window" HTML page. Requests without `code=`/`error=` in the query (e.g. favicon) are ignored.
* Client timeout is 5 min (`DEFAULT_LOGIN_TIMEOUT_MS`). Server pending TTL is 600 s and code TTL is 120 s (`native_flow.py:28-29`).
* Close the listener as soon as the callback arrives.

### 2.3 `GET /auth/native/authorize` (public; `routes.py:305-353`)
Query params:

| param | required | rule |
|---|---|---|
| `code_challenge` | yes | non-empty → else 400 `"code_challenge required"` |
| `code_challenge_method` | yes | case-insensitive `S256` → else 400 `"code_challenge_method must be S256"` |
| `redirect_uri` | yes | validated by `_validate_loopback_redirect_uri` (`routes.py:258-292`) |
| `state` | no (echoed) | stored and returned on the redirect unchanged |
| `provider` | no | omitted + exactly one interactive provider → auto-selected; omitted + several → HTML chooser page; unknown → 404 |

`redirect_uri` rules (each failure is HTTP 400 with a FastAPI `{"detail": "..."}`):
* ASCII only, no `\`, no control chars or spaces → `"native redirect_uri must use a canonical loopback URL"`
* scheme must be `http` → `"...must be http:// on the loopback interface"`
* no `#fragment`, no `user:pass@`
* host must be the IP literal `127.0.0.1` or `[::1]`. **`localhost` is rejected** → `"...host must be a loopback IP literal (127.0.0.1 / ::1)"`
* netloc must be canonical (`127.0.0.1:PORT`; no leading zeros etc.) → `"...must use a canonical loopback authority"`
* the port is optional; an empty path is normalised to `/`. Any path and query are kept. The server appends `?code=…&state=…`, or `&code=…` if the URI already has a `?` (`routes.py:139-142`).

Other responses:
* 400 `Provider does not support native login: 'session-token'` (non-interactive provider)
* 503 `"native-flow authorization store at capacity"` / `"too many pending native authorizations from this address"` (8 pending per IP, 256 global; `native_flow.py:30-33`)
* 503 `Provider unreachable: …`
* Success: 302 to the IdP (OAuth provider) or to `{prefix}/login` (password provider). Either way it sets a gateway PKCE cookie holding an opaque `broker_state`. The app's challenge and state never go in the cookie.

Example (desktop builder `buildNativeAuthorizeUrl`, `native-oauth.ts:119-138`; it keeps any reverse-proxy path prefix):
```
GET https://hermes.example.com/auth/native/authorize?code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&redirect_uri=http%3A%2F%2F127.0.0.1%3A53123%2Fcallback&state=Zx3…&provider=basic
```

### 2.4 Browser → loopback callback
After the user authenticates, the gateway mints a one-time code bound to the challenge (`native_flow.complete_pending`, `routes.py:128-142`) and redirects:
```
302 Location: http://127.0.0.1:53123/callback?code=<gw_code 43 chars>&state=<your state>
```
* Password provider: `POST /auth/password-login` returns JSON `{"ok":true,"next":"http://127.0.0.1:53123/callback?code=…&state=…"}`, and the login page script navigates there (`routes.py:464-510`).
* IdP error: the browser stops at a gateway 400 page (`OAuth error from provider: …`). The loopback receives **nothing**, so the app waits out its timeout (`routes.py:371-373`). The desktop's `parseLoopbackCallback` also handles `?error=&error_description=` (`native-oauth.ts:162-187`), but the server never sends that **(UNVERIFIED that any path does)**.
* **Verify `state` before redeeming.** On a mismatch, abort and never redeem.

### 2.5 `POST /auth/native/token` (public; `routes.py:590-608`)
Request: **JSON body**, not form-encoded (pydantic `_NativeTokenBody`):
```http
POST /auth/native/token HTTP/1.1
Content-Type: application/json

{"code": "<gw_code>", "code_verifier": "<verifier>"}
```
200 response (`_bearer_payload`, `routes.py:120-125`):
```json
{
  "access_token": "…",
  "refresh_token": "…",
  "token_type": "Bearer",
  "expires_at": 1762473600,
  "provider": "basic",
  "user_id": "admin"
}
```
* `expires_at` is absolute Unix seconds. **There is no `expires_in`.** The desktop stores `{accessToken, refreshToken, expiresAt, provider, userId}` (`native-oauth.ts:194-210`).
* Errors:
  * 400 `{"detail":"Invalid or expired authorization code."}`. This covers unknown, expired, already used, and PKCE mismatch. The code is consumed **before** the PKCE check, so it can't be retried (`native_flow.py:145-158`).
  * 422 (FastAPI validation) if `code` or `code_verifier` is missing.
  * This is **not** the RFC 6749 `{"error":"invalid_grant"}` shape. Parse `detail`.
* Typical lifetimes: basic provider access token 12 h (`HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS`), refresh 30 d (`plugins/dashboard_auth/basic/__init__.py:33-34`). Nous Portal access token ~15 min; refresh 24 h, rotating with reuse detection (`connection-config.ts:21-35`).

### 2.6 `POST /auth/native/refresh` (public; `routes.py:611-646`)
```http
POST /auth/native/refresh
Content-Type: application/json

{"refresh_token": "<rt>", "provider": "basic"}      // provider optional ("" = try all)
```
* 200: same shape as 2.5. **Always store the rotated refresh token.** Portal reuse detection revokes the session if a stale refresh token is replayed (`middleware.py:195-198`).
* 400 `{"detail":"refresh_token required"}`.
* 401 `{"error":"session_expired","detail":"Refresh token expired or invalid; start a new sign-in."}` → clear the tokens and start a new sign-in.
* 503 `{"detail":"Auth provider '…' unreachable"}` → transient; keep the tokens and retry later.
* Server-side refreshes are coalesced (`refresh_singleflight.py`). The client should still keep **one refresh in flight per host** (`native-access-token.ts:50-117`).
* Desktop policy: refresh when `now >= expires_at - 60` or when the expiry is unknown (`native-oauth.ts:242-253`). After one structured 401 on a bearer request, force a single refresh and retry once. A 403 never triggers a refresh (`native-auth-decisions.ts:254-256`, `oauth-rest-request.ts:155-176`). A refresh that returns 401 deletes the tokens (`main.ts:7405-7421`).

### 2.7 Using the access token
`Authorization: Bearer <access_token>` on every REST call (`request_utils.py:30-35`, scheme case-insensitive; `middleware.py:247-260`).
* The gate does **not** rotate bearer tokens server-side. The app has to refresh them itself.
* Gate 401 on `/api/*` (`middleware.py:108-123`):
  ```json
  {"error": "session_expired" | "unauthenticated", "detail": "Unauthorized",
   "reason": "invalid_or_expired_session" | "no_cookie" | "signed_out", "login_url": "/login?next=…"}
  ```
  `error:"session_expired"` means a bearer was presented but rejected. This structured body proves the request never reached a handler, so it is safe to replay after a refresh (`oauth-rest-request.ts:94-127`).
* 503 `{"detail":"Auth provider 'x' unreachable"}` → transient. Do not sign the user out.
* `GET /api/auth/me` returns `{user_id,email,display_name,org_id,provider,expires_at}` (`routes.py:541-570`). Useful to validate a token.
* Store tokens in the Keychain, keyed by normalized base URL (desktop uses safeStorage; `main.ts:7310-7330`).

---

## 3. Session-token login (pasted token)

There are two server modes:

| Server mode | REST credential | WS credential |
|---|---|---|
| **Loopback / ungated** (`auth_required:false`; e.g. `hermes serve` on 127.0.0.1 reached via SSH tunnel) | `X-Hermes-Session-Token: <t>` **or** `Authorization: Bearer <t>`. Exact match, constant-time (`web_server.py:224-225, 297-308`, middleware `457-476`) | `/api/ws?token=<t>` (`web_server_chat.py:350-361`) |
| **Gated** (`auth_required:true`, `auth_providers` contains `"session-token"`, server has `HERMES_DASHBOARD_SESSION_TOKEN`) | `Authorization: Bearer <t>` only. `X-Hermes-Session-Token` is **ignored** in gated mode (`_require_token`, `web_server.py:328-346`) | `/api/ws?token=<t>`, verified by the provider stack (`web_server_chat.py:296-347`). Alternatively bearer → `POST /api/auth/ws-ticket` → `?ticket=` (the bearer yields a `request.state.session`) |

* Provider: `plugins/dashboard_auth/session_token/__init__.py:91-140`. `verify_session` constant-time compares the token. The synthetic session is `user_id:"deployment-token"`, `provider:"session-token"`, expiry +24 h re-derived on each verify, and no refresh (refresh raises `RefreshExpiredError`).
* The desktop's token mode sends `X-Hermes-Session-Token` on REST (`main.ts:5224`) and `?token=` on WS (`connection-config.ts:91-97`). Gated deployments are documented as using `Authorization: Bearer $TOKEN` (`website/docs/user-guide/features/web-dashboard.md:863-890`).
* **Agora recommendation:** send `Authorization: Bearer <token>` always. It passes both the loopback check (`hmac.compare_digest(auth, f"Bearer {token}")`, `web_server.py:308`) and the gated provider. For the WS, use `?token=`.
* Wrong-token responses: loopback mode gives 401 `{"detail":"Unauthorized"}`. Gated mode gives the structured gate 401 (§2.7).
* Rotating the token server-side shows up as "HTTP reachable, WS fails" until the user pastes the new one (docs `web-dashboard.md:871`).
* For token mode, `?token=` on the WS URL is what the server expects (it ends up in proxy logs). Gated servers also accept the ticket route. **UNVERIFIED** whether the desktop uses tickets in gated token mode; it doesn't appear to.

---

## 4. `POST /api/auth/ws-ticket` and the `/api/ws` upgrade

### 4.1 Mint (`routes.py:573-585`, `ws_tickets.py`)
```http
POST /api/auth/ws-ticket HTTP/1.1
Authorization: Bearer <access_token>          (or session cookie)
Content-Length: 0
```
```json
{"ticket": "<base64url 32 bytes>", "ttl_seconds": 30}
```
* Requires `request.state.session`, so it only works in **gated** mode. Loopback/ungated mode returns 401 `"Unauthorized"` (use `?token=` there).
* The ticket is single-use (popped on consume) with a 30 s TTL (`ws_tickets.py:20-21, 52-64`). Mint one ticket per socket.
* Desktop: an 8 s timeout, and the call is marked `replayOn401` because minting is idempotent (`oauth-rest-request.ts:130-186`). Transient failures retry 3 times with `[250, 750]` ms delays. 401/403 are never retried (`connection-config.ts:202-233`, `main.ts:7562-7574`).

### 4.2 Dial
Two equivalent ways to present the ticket on a **remote** server (dashboard `/api/ws`, `web_routers/chat_ws.py:650-711` → `_consume_ws_ticket`, `web_server_chat.py:376-421`):

**A. Query (what the desktop does remotely; `connection-config.ts:99-105`)**
```
GET wss://hermes.example.com/api/ws?ticket=<t>
```
**B. Subprotocol (what the desktop does for local native tickets; `apps/desktop/src/api/canonical-protocol.ts:8-22`)**
```
Sec-WebSocket-Protocol: hermes-gateway-v1, hermes-gateway-ticket.<t>
```
* Rules (`web_server_boundary.py:156-171`): exactly one `hermes-gateway-ticket.*` entry, `hermes-gateway-v1` must be present, and the ticket must be non-empty. Otherwise the ticket is `invalid` and the socket closes with 4401.
* On accept the server picks **only** `hermes-gateway-v1`, so the ticket is never echoed back (`web_server_chat.py:417-421`). `URLSessionWebSocketTask(url:protocols:)` handles this.
* For a non-loopback peer, `gateway/run_api.py:428-433` forwards any subprotocol ticket to the dashboard handler, so B also works remotely.

Other credentials accepted on `/api/ws` (`web_server_chat.py:204-361`): `?token=` (loopback session token / gated provider token), `?internal=` (server-spawned children only), and `X-Hermes-Gateway-Ticket` header (local native grant; **refused** on `/api/ws` → `native_invalid` → 4401).

Base URL handling: `ws`/`wss` follows `http`/`https`, and any path prefix is kept (`{scheme}://{host}{prefix}/api/ws?...`).

**Do not send an `Origin` header** (URLSession sends none by default). If you do, it has to match the bound host (`web_server_boundary.py:250-290`). In gated mode the local-native path is also skipped whenever an Origin is present.

### 4.3 Profile scoping
* **REST (remote):** add `?profile=<name>`. Session *writes* are scoped by `body.profile`. The desktop's routing table is `connection-config.ts:680-830` (`pathWithProfileScope`, `resolveProfileBackendRoute`). `current`, empty, or omitted means the server's launch profile.
* **WS (remote):** the dashboard socket is host-scoped (`identity.profile_scope = 'host'`, `chat_ws.py:672-676`). **No `?profile=` on the URL.** Every profile-addressable RPC takes `"profile": "<name>"` (`tui_gateway/contracts/common.py:234-245` `SessionParams`/`ProfileParams`). Example resume: `{"session_id":"…","cols":96,"source":"desktop","defer_history":true,"omit_messages":true,"profile":"work"}` (`resume-owner.ts:118-132`).
* **Local native tickets** are minted per profile over `gateway.sock`. The ticket is bound to that home, and REST `profile` selectors that disagree with it return 403 `{"detail":"profile_scope_mismatch"}` (`dashboard_auth/native_http.py:62-110, 287-312`).

### 4.4 WS close codes (server → client)

| Code | Where | Meaning / client action |
|---|---|---|
| **4401** | `chat_ws.py:109-111` (`/api/ws`, `/api/pub`, `/api/events`); `web_session_sockets.py:44,107` (sign-out) | Bad, expired, or used credential (`no_credential`, `ticket_invalid`, `token_invalid`, `token_mismatch`, `token_unavailable` = IdP outage, `native_invalid`), or signed out. **Re-mint the ticket and redial.** If the mint itself returns 401/403, require sign-in and stop the loop. |
| **4403** | `chat_ws.py:106-108,112-114`; `run_api.py:448,477`; `chat_ws.py:687` | Embedded chat disabled, Host/Origin mismatch (`host_mismatch`/`origin_mismatch`), loopback-bound server with a non-loopback peer, or the ticket names a profile this process doesn't serve. **Configuration error: don't hot-loop.** Surface it to the user. |
| **1013** | `run_api.py:409-415,442,460,472`; `chat_ws.py:681` | Try again later: gateway not `ready`, draining, or restarting. Back off and redial. During a restart's after-turn wait, an interactive socket is still admitted so it can answer a parked prompt. |
| 4404 / 4408 / 4400 / 4409 / 4410 | `/api/pty`, `/api/console`, `/api/host-terminal`, `/api/pub` only (`web_server_chat.py:447-488`) | Not `/api/ws`. 4404 chat disabled, 4408 peer not allowed, 4400 missing channel, 4409 superseded, 4410 expired. The desktop terminal maps them in `apps/desktop/src/lib/browser-terminal.ts:59-62`. |
| 1011 | `web_server_chat.py:488` | Internal error. |

The JSON-RPC error code `4404` (`JSON_RPC_SESSION_NOT_SHOWN`) is unrelated. It is the client's *answer* to a window-owned server request.

The desktop's main socket does **not** branch on close code. Every close triggers the reconnect loop, which re-mints the ticket. Sign-in is surfaced only when the mint returns 401/403 (`isGatewayReauthRequired`, `use-gateway-boot.ts:592-604`). A close during the handshake rejects `connect()` with `"… (WebSocket closed during handshake: code 4401 <reason>)"` (`json-rpc-gateway.ts:321-339`). The web dashboard reloads once on a loopback 4401 (`web/src/lib/gatewayClient.ts:35`).

---

## 5. Wire protocol after open

### 5.1 First frame: `gateway.ready` (`tui_gateway/ws.py:650-658`, contract `contracts/events.py:51-64`)
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{
  "skin": {…}, "change_events": true, "heartbeat": true,
  "replay_epoch": "3f2a…uuid-hex",
  "session_authority": true            // only when bound to a canonical session authority
}}}
```

### 5.2 Client handshake (`apps/shared/src/json-rpc-channel.ts:256-270, 527-556`)
1. (Local desktop only) the first frame on the socket is `{"jsonrpc":"2.0","id":1,"method":"client.capabilities","params":{"desktop_local":true}}`. **Agora remote: skip it.** It is honoured only on a native-ticket connection.
2. On `gateway.ready`, send:
   ```json
   {"jsonrpc":"2.0","id":"r2","method":"client.capabilities","params":{"server_requests":true}}
   ```
   Result (`methods_voice.py:522-540`):
   ```json
   {"server_requests":["approval","clarify","sudo","secret", "…"],"declines_not_shown":true,"canonical_clarify_batch":true}
   ```
   **Required.** If you skip it, every server→client request (approval/clarify/sudo/…) fails immediately for this socket (`website/docs/developer-guide/programmatic-integration.md:99`).
3. If `payload.heartbeat === true`, start the heartbeat: every **15 s** send `{"jsonrpc":"2.0","id":"heartbeat-N","method":"gateway.ping","params":{}}`. The server answers on the reader thread with `{"jsonrpc":"2.0","result":{"ok":true},"id":"heartbeat-N"}` (`ws.py:703-707`). The desktop counts **any inbound frame** as liveness (`heartbeatLiveness:'any-inbound'`). If 45 s pass with nothing received, drop the socket (`json-rpc-channel.ts:170-171, 558-640`). Pings are skipped while one is outstanding.
4. If `payload.replay_epoch` differs from the one previously adopted, the server process restarted. See §6.4.

Ids: the desktop uses numeric ids (`createRequestId: nextId => nextId`, `apps/desktop/src/api/client.ts:578`). The shared default is `"r<n>"`. Server→client requests use **string** ids (`"srq-7"`). A frame that has both a string `id` and a `method` other than `"event"` is a server request (`json-rpc-channel.ts:60-61`).

### 5.3 Event frames
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"<runtime sid>","seq":42,"payload":{…},
  "replay_epoch":"<per-session epoch, canonical only>"}}
```
`seq` is per session, monotonic, and stamped on every event frame (`tui_gateway/event_replay.py:1-14`). Global/session-less events have no `seq`.

### 5.4 Timeouts (desktop defaults)
connect 15 s (`json-rpc-gateway.ts:58`), default request 120 s (`:40`), `approval.respond` 300 s (`:49`), replay fetch 10 s (`:54`), wake liveness probe uses `ping` → `{"pong":true}` (`contracts/liveness.py:17`). A `-32601` answer to the probe counts as **alive** (`use-gateway-boot.ts:705-717`).

---

## 6. Reconnection

### 6.1 Backoff (`apps/shared/src/reconnect-backoff.ts`)
```ts
DEFAULT_BASE_DELAY_MS = 300; DEFAULT_CAP_MS = 15_000; RECONNECT_STABLE_OPEN_MS = 5_000; MAX_EXPONENT = 32
delay(attempt) = jitter ? Math.random() * ceiling : ceiling
ceiling        = min(capMs, baseDelayMs * 2 ** clamp(trunc(attempt), 0, 32))   // attempt 0-indexed
isStableOpen(openedAt) = openedAt !== null && now - openedAt >= 5000
```
Ceilings: 300, 600, 1200, 2400, 4800, 9600, 15000, 15000, … ms. **The full-jitter delay is uniform in [0, ceiling).**
Reset `attempt = 0` only when the socket that just closed had been open ≥ 5 s. A socket that opens and dies within 5 s counts as a *failed* attempt (`reconnect-backoff.ts:28-38`; #83134).

Desktop reconnect loop (`apps/desktop/src/app/gateway/hooks/use-gateway-boot.ts:491-665`):
* `scheduleReconnect`: `delay = reconnectBackoffDelayMs(reconnectAttempt++)`.
* `attemptReconnect`, in order:
  1. Revalidate the backend.
  2. Fetch the connection descriptor.
  3. **Re-mint the WS URL**, i.e. a new ticket (`freshGatewayWsUrl`, `main.ts:7576-7607`).
  4. `gateway.connect(url)`.
  5. Reset tile runtime bindings so each open session is re-`session.resume`d.
  6. Clear stale busy flags.
  7. Refresh config and the session list.

  Each await is bounded by `RECONNECT_ATTEMPT_TIMEOUT_MS`.
* Mint 401/403 → reauth required. **Stop the loop**, show sign-in once per episode, and don't hammer the server.
* A non-blocking warning appears after 5 min of continuous failure (`RECONNECT_ESCALATE_AFTER_MS = 300_000`).
* Wake signals (power resume, `online`, focus, visibility) trigger `reconnectNow`. It resets the backoff and, if the socket still says OPEN, runs a `ping` liveness probe. Mid-turn, one probe timeout only schedules a re-probe; only repeated timeouts close the socket (#95327). Forced wakes are coalesced within 15 s (`WAKE_RECONNECT_HOLDOFF_MS`).
* Initial boot dial: 8 attempts × 3 s fixed, re-minting each time (`connectInitialGateway`, `use-gateway-boot.ts:220-256`). Remote boot self-heal: 5 attempts, backoff base 2000 ms (`:146-154`).

### 6.2 Replay on reconnect (`apps/shared/src/json-rpc-gateway.ts`)
State per client:
* `lastSeenSeq: Map<sid, seq>` (LRU, max **256** cursors). A retired cursor is announced as a synthetic `session.replay_gap` event (`:125-132, 500-517`).
* `replayEpoch` = the process epoch from `gateway.ready`. `replayEpochBySession` holds canonical per-session epochs.

On every successful open (`onOpen` → `fetchReplay`, `:284-297, 554-582`):
1. Install a **hold** (a barrier promise plus a parked-events array) for every sid with a watermark. Do this before `state = 'open'` listeners run.
2. For each sid, send in parallel:
   ```json
   {"jsonrpc":"2.0","id":7,"method":"session.events.since","params":{"session_id":"s1","last_seen":97}}
   ```
   Add `"replay_epoch":"<session epoch>"` **only** when a canonical per-session epoch is known. Never send the process epoch: an older legacy server rejects unknown keys with code 4000, which kills the replay and the open requests (`:590-608`; `json-rpc-gateway-legacy-replay.test.ts:75-112`).
3. While the request is in flight, live frames for that sid that carry a numeric `seq` are **parked**, not dispatched (`handleEvent`, `:467-473`).
4. On answer (`fetchSessionReplay`, `:584-662`):
   * `snapshot_required === true` → delete the cursor and epoch, emit `session.replay_gap {replay_epoch, latest_seq}`. The consumer re-resumes for a fresh snapshot.
   * The epoch changed (per-session `replay_epoch` differs, or the legacy `epoch` differs from `gateway.ready`'s) → the old numbering is gone. Drop the cursors and dispatch nothing from the window; REST history is authoritative.
   * `truncated === true` → **dispatch none of the window**. Advance the cursor to `max(latest_seq, event seqs)` and release the barrier so history reads resync (`:621-632, 704-714`).
   * Otherwise dispatch each `events[i]` as `{...event, replayed:true}` via `dispatchIfNewer`.
   * Error with `error.data.reason === 'not_found'` → the session is gone; forget its cursor. Other errors are swallowed.
   * `finally`: flush parked frames through `dispatchIfNewer`, then resolve the barrier as `true`.
5. `open_requests` in **any** RPC result (`session.events.since`, `session.resume`, `session.activate`) is re-delivered to the server-request handlers with `replayed:true` before the caller sees the result. The id is reused, so answering twice is a no-op (`json-rpc-channel.ts:448-463, 505-519`).

**Dedupe rule** (`dispatchIfNewer`, `:720-738`): if `sid && typeof seq === 'number'` and `seq <= lastSeenSeq[sid]`, drop the event. Otherwise advance the cursor and dispatch. Seq-less events always dispatch.

Barrier for history reads: `sessionReplayBarrier(sid)` (`:532-546`). Before painting a REST history page for a session, wait for it. `false` means the socket was lost, so discard that read.

Gold test (`json-rpc-gateway-replay.test.ts:239-316`): pre-drop seq 2. Reconnect; live 5 and 6 arrive during the replay and are parked. The replay returns 3, 4, 5. Dispatch order is `[2,3,4,5,6]`, the parked duplicate 5 is dropped, and the watermark ends at 6.

### 6.3 `session.events.since` shapes
Legacy (`tui_gateway/methods_session.py:2308-2320`, contract `contracts/sessions.py:724-742`):
```jsonc
// params
{"session_id": "s1", "last_seen": 97 /* int, default 0 */, "replay_epoch": "…" /* accepted & ignored */, "profile": "…"?}
// result
{"events": [ {"type":"message.delta","session_id":"s1","seq":98,"payload":{…}}, … ],   // event OBJECTS, not envelopes
 "latest_seq": 99, "truncated": false, "count": 2,
 "epoch": "<process replay epoch>",
 "open_requests": [ {"id":"srq-1","method":"approval","params":{"session_id":"s1", …}} ]}
```
`last_seen` that is not an int gives `-32602 "invalid params: last_seen must be an integer"`. `truncated = last_seen < evicted_through[sid]` (`event_replay.py:202-206`). Ring limits: 512 events / 4 MiB per session, 64 sessions, 64 MiB per process (`event_replay.py:27-35`).

Canonical (session-authority sockets; `gateway/session_controls.py:745-757`, `gateway/session_events.py:114-138`, contract `contracts/canonical_sessions.py:295-321`):
```jsonc
// params: {"session_id","last_sequence"|"last_seen": int>=0, "replay_epoch": str?}
{"events":[{"type","session_id","payload","replay_epoch","seq","authority_epoch"?,"execution_generation"?,"admission_id"?}],
 "latest_seq": 12, "last_sequence": 12, "epoch": "<session epoch>", "replay_epoch": "<session epoch>",
 "truncated": false, "snapshot_required": false, "count": 3, "open_requests": [...]}
```
`snapshot_required` (= `truncated`) is true when the epoch differs, the cursor is ahead of latest, or the window was evicted. When true, `events` is empty. Server-side, a canonical subscriber that falls behind on the live fan-out is sent a `session.replay_gap {replay_epoch, latest_seq}` frame (`session_events.py:94-100`). It has the same shape as the client's synthetic gap.

### 6.4 Epochs / server restart
* The legacy seq counter lives in-process, so a restart resets it to 1. `gateway.ready.replay_epoch` (and the result's `epoch`) is a UUID hex per process (`event_replay.py:22-25, 53-55`).
* Client (`adoptReplayEpoch`, `:745-777`): when a new process epoch is seen, delete every cursor that has no per-session epoch, cancel the in-flight replay (barriers resolve `true` so REST reads proceed), and re-dispatch the parked frames. Test: `json-rpc-gateway-legacy-replay.test.ts:134-163`. The client watermark was 97; the server answers `epoch:"proc-2"`; the watermarks are cleared; new seq 3 is accepted.
* Per-session canonical epochs (`adoptSessionReplayEpoch`, `:808-817`): when an epoch changes, delete that sid's cursor only.
* Each dispatched event is tagged with `replayEpoch` so a consumer with several sockets to the same process can dedupe across them (`:842-847`).

### 6.5 `session.resume` after reconnect
Params (`contracts/sessions.py:182-201`): `session_id` (stored id or exact title), `cols?`, `source?`, `lazy`, `defer_history`, `omit_messages`, `eager_build`, `close_on_disconnect`, `inline_images` (default true; set **false** for remote so images don't bloat the transcript), `profile?`.

Result = `LiveSessionSnapshot` (`contracts/sessions.py:20-98`):
```jsonc
{"session_id":"<runtime id>", "stored_session_id":"…", "message_count":12, "messages":[…], "info":{…},
 "resumed":"…", "session_key":"…", "messages_omitted":true, "hydrating":false,
 "running":true, "turn_started_at":1762470000.1, "started_at":…, "status":"working",   // idle|starting|waiting|working|streaming|resuming
 "inflight": {"user":"…", "assistant":"streamed so far", "streaming":true,
              "corrections":["…"], "correction_offsets":[120], "display_kind":null, "display_metadata":null,
              "error":null, "status":null, "recoverable":null, "error_surface":null},
 "queued": {"user":"…"},
 "pending_approval": {…},
 "open_requests": [{"id":"srq-3","method":"clarify","params":{…}}],
 "pending_connection": {…}, "todo_state": {"todos":[…],"revision":4},
 "auto_continue": {"attempt":1,"interrupted_at":…}}
```
Canonical resume additionally returns `authority_epoch, replay_epoch, last_sequence, subscription_id, revision, execution_generation, pending[], prompts[]` (`gateway/session_controls.py:690-709`). The canonical owner also writes frames published between `events.since` and `resume` straight to the socket (`catch_up`, `session_events.py:114-125`).

Usage (developer guide `programmatic-integration.md:101-105`; desktop `resume-reconcile.ts`): rebuild the live turn bubble from `inflight` (the user prompt plus the assistant text so far, with corrections placed at `correction_offsets`). Restore pending prompts from `open_requests` and `pending_approval`. `request.cancel {id, method, reason}` withdraws a prompt.

### 6.6 Local: `gateway.sock` missing → `hermes gateway ensure --json`
* CLI: `hermes gateway ensure [--json] [--timeout 60]` (`hermes_cli/subcommands/gateway.py:121-131`). It never installs a service. It attaches to the live owner, or starts one: the existing launchd/systemd service if installed, otherwise a detached daemon. Pending startup does not count as ready.
* stdout is **exactly one line** of compact sorted-key JSON. Legacy prints go to stderr (`gateway_runtime_cli.py:17-37`):
  ```json
  {"client_code_sha":"abc123…","detail":null,"endpoint":{"api_origin":"http://127.0.0.1:41234","authority_epoch":1,"capabilities":["session-authority-v1"],"code_sha":"abc123…","control_home":"/Users/u/.hermes","instance_id":"…","profile_id":"/Users/u/.hermes","runtime_protocol":1,"supervisor":"none"},"reason_code":null,"state":"ready"}
  ```
  `state` ∈ `absent|starting|ready|draining|incompatible|inaccessible|conflict` (`gateway/runtime_contract.py:6-8`). `endpoint` is null unless an owner is known.
  Invalid invocation prints `{"endpoint":null,"reason_code":"invalid_invocation","state":"inaccessible"}`.
* Exit codes (`gateway_runtime_cli.py:8-14`):
  * 0 ready
  * 2 invalid invocation
  * 3 incompatible
  * 4 `authorization` / `profile_mismatch` / `gateway_elevated` / `gateway_other_session`
  * 5 deadline / starting / absent
  * 6 draining (incl. `update_paused`)
  * 7 inaccessible / conflict
* `reason_code` values seen: `authorization control_timeout deadline foreign_stale_lock idle_exit invalid_api_origin invalid_control_peer invalid_runtime_identity invalid_runtime_state invalid_supervisor profile_mismatch profile_parked replaced runtime_exited runtime_protocol runtime_start_failed session_authority_unavailable update_paused restart_wait`.
* Desktop handling (`apps/desktop/electron/local-gateway.ts`):
  * Kill the client after 60 + 15 s.
  * A `ready` endpoint must pass `assertLocalGatewayEndpoint` (`:172-180`): `api_origin` is http(s) on 127.0.0.1 or [::1] with a port and no path, `runtime_protocol === 1`, and `capabilities` includes `"session-authority-v1"`.
  * `draining` + `restart_wait` + endpoint is still attachable.
  * `endpoint.code_sha != client_code_sha` means a stale owner that outlived `hermes update`. Restart it once (`gateway restart`), then re-ensure.
  * Any other non-ready result throws `Gateway <state> (<reason_code>). <detail first line> Use hermes gateway status|restart for recovery.`
  * Local WS URL = `${api_origin→ws}/api/ws?native_dial=unminted`. The ticket comes from `gateway.sock` per dial and travels as the subprotocol (`canonical-protocol.ts:11-22`).
  * When a cached descriptor stops answering, forget it once and re-run ensure (`local-gateway.ts:256-310`).

---

## 7. Capability gating / old-server detection

There is no version-number gating for the wire protocol. Every feature is **probed or advertised**:

| Signal | Source | Gate |
|---|---|---|
| `/api/status.auth_flows` contains `"native_pkce"` | `status.py:383-407` | Missing → older gateway, no native sign-in (`native-oauth.ts:72-80`). |
| `/api/health` 404 | `backend-health.ts:308`, `remote-liveness.ts:120` | Backend predates `/api/health`; fall back to `/api/status`. |
| `gateway.ready.heartbeat === true` | `ws.py:654` | Only then start `gateway.ping`. An older backend would answer `-32601` and look dead. |
| `gateway.ready.change_events` | same | true → rely on pushed `*.changed` events; false → keep legacy polling (`use-message-stream/gateway-event/lifecycle.ts:36`). |
| `gateway.ready.replay_epoch` | same | Restart detection (§6.4). |
| `gateway.ready.session_authority === true` | `ws.py:655`; `apps/desktop/src/api/client.ts:589-592` | Use the canonical session wire (`runtime.describe`, `session.create source=…`, canonical replay shapes). Otherwise use the legacy protocol. |
| `client.capabilities` result | `methods_voice.py:522-540` | `declines_not_shown` → may answer `4404` "not shown" for window-owned requests. `canonical_clarify_batch` → may send `clarify_batch` on `prompt.submit`. `server_requests[]` → the methods the server may send. `-32601` → old backend; ignore. |
| `gateway.capabilities` → `{"per_session_exclusive_submit": true}` | `contracts/liveness.py:21-26`, `methods_voice.py:514-519` | "What this build enforces; a client withholds a feature unless advertised." **No desktop/web consumer was found** (grep over `apps/`), so it is informational for Agora. |
| JSON-RPC `-32601` (method not found) | `json-rpc-channel.ts:88` | Treat as "server predates this method": degrade, don't error. Applies to `ping`, `client.capabilities`, `session.events.since`. |
| JSON-RPC `4000` "Extra inputs are not permitted" | pydantic contract (`legacy-replay.test.ts:93-95`) | An older server refuses unknown params. Send new optional keys only when advertised. |
| Error `data.reason` | e.g. `not_found`, `execution_not_ready`, `stale_generation`, `unsupported_control` (`json-rpc-channel.ts:76-86`) | Typed refusals. |
| `ensure` `endpoint.capabilities` must include `"session-authority-v1"`, `runtime_protocol === 1`; `incompatible`/`runtime_protocol` | `local-gateway.ts:172-180`, `gateway_runtime.py:124-126` | Local too-old/too-new gateway. |
| `/api/health.commit` vs local checkout | `status.py:121-126` | Desktop refuses to re-adopt a backend that booted from another commit. This applies to local only. |

The full method/event schema is in `apps/shared/src/gateway-contract.openrpc.json`, generated from `tui_gateway/contracts/*`.

---

## 8. Example end-to-end (remote, gated, native sign-in)

```text
→ GET https://h/api/status
← {"version":"0.23.0","auth_required":true,"auth_providers":["basic"],"auth_flows":["cookie","native_pkce"],…}
→ GET https://h/api/auth/providers
← {"providers":[{"name":"basic","display_name":"Username & password","supports_password":true}]}
   [listen 127.0.0.1:53123; open browser]
→ (browser) GET https://h/auth/native/authorize?code_challenge=C&code_challenge_method=S256&redirect_uri=http%3A%2F%2F127.0.0.1%3A53123%2Fcallback&state=S
← 302 /login  (user submits form → JSON {"ok":true,"next":"http://127.0.0.1:53123/callback?code=K&state=S"})
→ (loopback) GET /callback?code=K&state=S        [verify S]
→ POST https://h/auth/native/token  {"code":"K","code_verifier":"V"}
← {"access_token":"A","refresh_token":"R","token_type":"Bearer","expires_at":1762516800,"provider":"basic","user_id":"admin"}
→ POST https://h/api/auth/ws-ticket   Authorization: Bearer A
← {"ticket":"T","ttl_seconds":30}
→ WS wss://h/api/ws?ticket=T          (or Sec-WebSocket-Protocol: hermes-gateway-v1, hermes-gateway-ticket.T)
← {"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"heartbeat":true,"change_events":true,"replay_epoch":"E1","skin":{…}}}}
→ {"jsonrpc":"2.0","id":1,"method":"client.capabilities","params":{"server_requests":true}}
→ {"jsonrpc":"2.0","id":2,"method":"session.resume","params":{"session_id":"20261106_…","source":"desktop","cols":96,"inline_images":false,"profile":"default"}}
… every 15 s: {"jsonrpc":"2.0","id":"heartbeat-1","method":"gateway.ping","params":{}} ← {"jsonrpc":"2.0","result":{"ok":true},"id":"heartbeat-1"}

[socket drops]  attempt n: sleep random(0,min(15000,300·2^n)); refresh A if near expiry; mint new ticket; redial
← gateway.ready (replay_epoch "E1" ⇒ same process)
→ {"jsonrpc":"2.0","id":9,"method":"session.events.since","params":{"session_id":"rt-1","last_seen":57}}
← {"jsonrpc":"2.0","id":9,"result":{"events":[{"type":"message.delta","session_id":"rt-1","seq":58,…}],"latest_seq":58,"truncated":false,"count":1,"epoch":"E1","open_requests":[]}}
```

## 9. Open points / UNVERIFIED
* Whether `hermes serve` (as opposed to `hermes dashboard`) always mounts a gateway runtime such that `/api/ws` advertises `session_authority`. Agora should handle both legacy and canonical replay shapes (§6.3).
* Whether any server path sends `?error=` to the loopback redirect. As read, IdP errors stop at a gateway 400 page, so Agora needs a cancel button or timeout on the sign-in sheet.
* Exact types of `config_version` and `nous_session_valid` in `/api/status`.
* The desktop's handling of gated + token mode (it sends `X-Hermes-Session-Token`, which the gated gate ignores). Bearer is the server-documented path.
