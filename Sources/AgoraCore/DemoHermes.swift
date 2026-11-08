import Foundation
import Synchronization

/// A made-up Hermes for screenshots and trying Agora without one: six Bots, a few chats and a live
/// chart. Run Agora with `AGORA_DEMO=1` to use it. Nothing leaves the app; what you send is shown
/// but never answered.
public final class DemoHermes: SocketFactory, HTTPClient, ControlSocket, GatewayStarter, @unchecked Sendable {
    public init() {}

    /// An environment wired to the demo (nothing saved, no Keychain, no Tailscale).
    public static func environment(notifier: Notifier) -> AgoraEnvironment {
        let demo = DemoHermes()
        return AgoraEnvironment(
            sockets: demo, http: demo, control: demo, starter: demo, credentials: InMemoryCredentialStore(), notifier: notifier,
            store: InMemoryKeyValueStore())
    }

    // MARK: Control socket

    public func request(_ message: JSON) async throws -> JSON {
        switch message["verb"].string {
        case "identify":
            return [
                "ok": true, "protocol": 1,
                "result": [
                    "api_origin": "http://127.0.0.1:9", "authority_epoch": 1, "capabilities": ["session-authority-v1", "event-replay-v1"],
                    "code_version": "0.23.0", "hermes_home": "/Users/demo/.hermes", "instance_id": "demo", "kind": "hermes-gateway",
                    "profile": "default", "protocol": 1, "runtime_protocol": 1, "state": "ready", "supervisor": "launchd",
                    "served_profiles": .array(Self.bots.map { ["home": .string("/Users/demo/.hermes/profiles/\($0.name)"), "profile_id": .string($0.name)] }),
                ],
            ]
        case "session-ticket":
            return ["ok": true, "protocol": 1, "result": ["ticket": "demo", "expires_in_seconds": 3600, "instance_id": "demo", "runtime_protocol": 1]]
        default:
            return ["ok": true, "protocol": 1, "result": [:]]
        }
    }

    public func ensure() async throws -> JSON { ["ok": true, "state": "ready"] }

    // MARK: WebSocket

    public func open(_ dial: WebSocketDial) async throws -> FrameSocket { DemoSocket(owner: self) }

    func answer(_ method: String, _ p: JSON) -> JSON {
        switch method {
        case "client.capabilities": return ["server_requests": []]
        case "profiles.list": return ["profiles": .array(Self.bots.map(\.row))]
        case "session.list":
            let bot = p["profile"].string ?? ""
            return ["sessions": [["session_id": .string("chat-\(bot)"), "id": .string("chat-\(bot)"), "resolved_id": .string("chat-\(bot)"), "title": "Bot Chat"]]]
        case "session.resume":
            let id = p["session_id"].string ?? ""
            return [
                "session_id": .string(id), "session_key": .string(id), "message_count": .number(Double(Self.history[id]?.count ?? 0)),
                "running": false, "revision": 1, "execution_generation": 1, "last_sequence": 0, "replay_epoch": "demo", "prompts": [],
                "info": ["title": .string(Self.sideChats.values.joined().first { $0.id == id }?.title ?? "Bot Chat")],
            ]
        case "session.create":
            return ["session_id": .string("demo-\(UUID().uuidString.prefix(8))"), "message_count": 0, "running": false, "info": ["title": ""]]
        case "prompt.submit": return ["status": "queued", "sequence": 1]
        case "llm.oneshot":
            let name = (p["input"].string ?? "").split(separator: "\n").first?.replacingOccurrences(of: "Bot name: ", with: "") ?? "this Bot"
            return ["text": .string(Self.persona(for: String(name)))]
        default: return [:]
        }
    }

    static func persona(for name: String) -> String {
        """
        # \(name)

        ## Who you are
        You are \(name). You turn rough requests into finished work the user can use straight away.

        ## How you work
        - Ask one short question when the goal is unclear; otherwise start.
        - Show a first version early, then refine it.
        - Ask before anything that sends, publishes or spends.

        ## How you talk
        Short and plain. Lead with the result, then what changed.

        ## What you avoid
        Filler, long preambles, and guessing at facts you can check.
        """
    }

    // MARK: REST

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let comps = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let path = comps?.path ?? ""
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        func json(_ j: JSON) -> HTTPResponse { HTTPResponse(status: 200, body: j.data()) }

        if path.hasPrefix("/api/sessions/"), path.hasSuffix("/messages") {
            let id = path.dropFirst("/api/sessions/".count).dropLast("/messages".count)
            return json(["messages": .array(Self.history[String(id)] ?? [])])
        }
        switch path {
        case "/api/sessions":
            let bot = query["profile"] ?? ""
            let rows: [JSON] = (Self.sideChats[bot] ?? []).map {
                [
                    "id": .string($0.id), "title": .string($0.title), "source": "desktop", "last_active": .number(Self.at($0.minutesAgo)),
                    "message_count": 4, "archived": false, "hidden": 0, "auto_archived": 0, "preview": .string($0.preview), "profile": .string(bot),
                ]
            }
            return json(["sessions": .array(rows)])
        case "/api/fs/download":
            return HTTPResponse(status: 200, body: Data(Self.chartHTML.utf8))
        case "/api/cron/jobs":
            return json(["jobs": .array(query["profile"] == "markets" ? [Self.routine] : [])])
        case "/api/status":
            return json(["version": "0.23.0", "auth_required": false])
        default:
            return json([:])
        }
    }

    // MARK: The demo's world

    struct DemoBot {
        var name: String
        var title: String
        var description: String
        var color: String
        var preview: String
        var minutesAgo: Double

        var row: JSON {
            [
                "name": .string(name), "description": .string(description), "has_avatar": false, "is_default": .bool(name == "default"),
                "ui_meta": ["hermes-bots": ["title": .string(title), "color": .string(color), "custom": true]],
                "canonical_session": [
                    "id": .string("chat-\(name)"), "resolved_id": .string("chat-\(name)"), "preview": .string(preview),
                    "last_active": .number(DemoHermes.at(minutesAgo)),
                ],
            ]
        }
    }

    struct DemoSideChat {
        var id: String
        var title: String
        var preview: String
        var minutesAgo: Double
    }

    static func at(_ minutesAgo: Double) -> Double { Date().timeIntervalSince1970 - minutesAgo * 60 }

    static let bots: [DemoBot] = [
        DemoBot(name: "default", title: "Hermes", description: "Your main assistant", color: "#8b5cf6",
                preview: "Your morning brief is ready: 3 meetings, 1 bill due.", minutesAgo: 25),
        DemoBot(name: "markets", title: "Markets Analyst", description: "Charts, levels and macro, with sources", color: "#10b981",
                preview: "Gold held 2,380 into the close; levels are on the chart.", minutesAgo: 4),
        DemoBot(name: "research", title: "Research", description: "Reads papers and the web, cites everything", color: "#3b82f6",
                preview: "Here are the five papers worth reading first.", minutesAgo: 95),
        DemoBot(name: "coder", title: "Coder", description: "Writes and reviews code in your repos", color: "#a855f7",
                preview: "Tests pass. I opened a PR with the fix.", minutesAgo: 60 * 26),
        DemoBot(name: "ops", title: "Ops", description: "Servers, logs and deploys (asks before changing anything)", color: "#ef4444",
                preview: "All 4 services healthy. Disk on web-2 is at 81%.", minutesAgo: 60 * 5),
        DemoBot(name: "writer", title: "Writer", description: "Drafts, edits and tightens your writing", color: "#f59e0b",
                preview: "Shorter version below: 120 words, same points.", minutesAgo: 60 * 50),
    ]

    static let sideChats: [String: [DemoSideChat]] = [
        "markets": [
            DemoSideChat(id: "side-gold-yields", title: "Gold vs real yields", preview: "The correlation broke in 2022…", minutesAgo: 60 * 3),
            DemoSideChat(id: "side-earnings", title: "Earnings calendar this week", preview: "Five names report…", minutesAgo: 60 * 30),
        ],
        "research": [DemoSideChat(id: "side-papers", title: "Long-context evals", preview: "Five papers…", minutesAgo: 60 * 8)],
    ]

    static let routine: JSON = [
        "id": "r1", "name": "Weekly gold levels", "prompt": "Chart gold for the week and update the levels.",
        "schedule": ["kind": "cron", "expr": "0 7 * * 1", "display": "Mondays at 07:00"], "schedule_display": "Mondays at 07:00",
        "enabled": true, "state": "scheduled", "next_run_at": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400 * 2))),
    ]

    static func row(_ id: Int, _ role: String, _ content: String, minutesAgo: Double, extra: [String: JSON] = [:]) -> JSON {
        var r: [String: JSON] = ["id": .number(Double(id)), "role": .string(role), "content": .string(content), "timestamp": .number(at(minutesAgo))]
        for (k, v) in extra { r[k] = v }
        return .object(r)
    }

    static func toolCall(_ id: String, _ name: String, _ args: String) -> JSON {
        ["id": .string(id), "call_id": .string(id), "type": "function", "function": ["name": .string(name), "arguments": .string(args)]]
    }

    static let history: [String: [JSON]] = [
        "chat-markets": [
            row(1, "user", "Chart gold for this week and give me the key levels.", minutesAgo: 9),
            row(2, "assistant", "", minutesAgo: 8.8, extra: [
                "finish_reason": "tool_calls",
                "tool_calls": [
                    toolCall("t1", "web_search", #"{"query": "gold futures weekly close"}"#),
                    toolCall("t2", "execute_code", #"{"code": "compute_levels(ohlc)"}"#),
                    toolCall("t3", "write_file", #"{"path": "charts/gold-week.html"}"#),
                ],
            ]),
            row(3, "tool", #"{"results": 8}"#, minutesAgo: 8.7, extra: ["tool_call_id": "t1", "tool_name": "web_search"]),
            row(4, "tool", #"{"output": "levels computed"}"#, minutesAgo: 8.6, extra: ["tool_call_id": "t2", "tool_name": "execute_code"]),
            row(5, "tool", #"{"ok": true}"#, minutesAgo: 8.5, extra: ["tool_call_id": "t3", "tool_name": "write_file"]),
            row(6, "assistant", """
                Here's gold for the week. It held **2,380** into Friday's close after testing 2,352 on Wednesday.

                ::preview{file="/Users/demo/charts/gold-week.html"}

                | Level | Price | Why it matters |
                |---|---|---|
                | Resistance | 2,412 | Last week's high |
                | Pivot | 2,380 | Friday's close, held twice |
                | Support | 2,352 | Wednesday's low, bought quickly |

                **Read:** a higher low inside a range. A daily close above 2,412 opens the next leg; below 2,352 the range breaks down.
                """, minutesAgo: 4, extra: ["finish_reason": "stop"]),
        ],
        "chat-default": [
            row(1, "user", "What's on today?", minutesAgo: 27),
            row(2, "assistant", "Three meetings (10:00 standup, 13:30 design review, 16:00 1:1) and the electricity bill is due Friday. Want me to block focus time before the review?", minutesAgo: 25, extra: ["finish_reason": "stop"]),
        ],
    ]

    /// A themed, self-sizing widget, the way Hermes Bots write them: it uses the app's colors.
    static let chartHTML = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body{padding:4px 0}
        .h{font-weight:600;margin:0 0 2px}.s{color:var(--muted-foreground);font-size:12px;margin:0 0 10px}
        svg{display:block;width:100%;height:auto}
        .lvl{stroke-dasharray:4 4;stroke-width:1}
        text{font:11px -apple-system,sans-serif;fill:var(--muted-foreground)}
        </style></head><body>
        <p class="h">Gold (XAU/USD), hourly, this week</p><p class="s">Close 2,380 · range 2,352 – 2,412</p>
        <svg id="c" viewBox="0 0 640 260"></svg>
        <script>
        var s=document.getElementById('c'),w=640,h=230,lo=2340,hi=2420,y=v=>h-(v-lo)/(hi-lo)*(h-20);
        var seed=11;function r(){seed=(seed*16807)%2147483647;return seed/2147483647-.5}
        var way=[2393,2371,2353,2368,2386,2409,2380],n=60,g='',p=way[0];
        [[2412,'var(--accent)','2,412'],[2380,'var(--foreground)','2,380'],[2352,'#ef4444','2,352']].forEach(l=>{
          g+='<line class="lvl" x1="0" x2="'+(w-44)+'" y1="'+y(l[0])+'" y2="'+y(l[0])+'" stroke="'+l[1]+'" opacity=".55"/>';
          g+='<text x="'+(w-40)+'" y="'+(y(l[0])+4)+'">'+l[2]+'</text>'});
        for(var i=0;i<n;i++){
          var t=i/(n-1)*(way.length-1),k=Math.min(way.length-2,Math.floor(t)),target=way[k]+(way[k+1]-way[k])*(t-k);
          var o=p,c=target+r()*11,hh=Math.max(o,c)+Math.abs(r())*5,ll=Math.min(o,c)-Math.abs(r())*5;p=c;
          var x=6+i*(w-60)/n,col=c>=o?'#10b981':'#ef4444';
          g+='<line x1="'+(x+3)+'" x2="'+(x+3)+'" y1="'+y(hh)+'" y2="'+y(ll)+'" stroke="'+col+'"/>';
          g+='<rect x="'+x+'" width="6" y="'+y(Math.max(o,c))+'" height="'+Math.max(1,Math.abs(y(o)-y(c)))+'" fill="'+col+'" rx="1"/>'}
        ['Mon','Tue','Wed','Thu','Fri'].forEach((d,i)=>g+='<text x="'+(10+i*(w-60)/5)+'" y="252">'+d+'</text>');
        s.innerHTML=g;
        </script></body></html>
        """
}

final class DemoSocket: FrameSocket, @unchecked Sendable {
    let owner: DemoHermes
    private let state = Mutex<(buffer: [String], waiter: CheckedContinuation<String, Error>?, closed: Bool)>(([], nil, false))

    init(owner: DemoHermes) {
        self.owner = owner
        let ready: JSON = [
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "gateway.ready", "payload": ["session_authority": true, "heartbeat": false, "replay_epoch": "demo"]],
        ]
        deliver(ready)
    }

    func deliver(_ frame: JSON) {
        let text = String(decoding: frame.data(), as: UTF8.self)
        let waiter = state.withLock { s -> CheckedContinuation<String, Error>? in
            if let w = s.waiter {
                s.waiter = nil
                return w
            }
            s.buffer.append(text)
            return nil
        }
        waiter?.resume(returning: text)
    }

    func send(_ text: String) async throws {
        guard let frame = try? JSON(text: text), let id = frame["id"].object == nil ? Optional(frame["id"]) : nil, !id.isNull,
            let method = frame["method"].string
        else { return }
        let result = owner.answer(method, frame["params"])
        deliver(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            let next = state.withLock { s -> Result<String, Error>? in
                if !s.buffer.isEmpty { return .success(s.buffer.removeFirst()) }
                if s.closed { return .failure(SocketClosed(code: 1000)) }
                s.waiter = c
                return nil
            }
            if let next { c.resume(with: next) }
        }
    }

    func close(code: Int) {
        let waiter = state.withLock { s -> CheckedContinuation<String, Error>? in
            s.closed = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(throwing: SocketClosed(code: code))
    }
}
