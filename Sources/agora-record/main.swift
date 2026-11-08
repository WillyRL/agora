import AgoraCore
import Foundation

// Records a real conversation with the local Hermes into a fixture for the fake Hermes.
//
//   swift run agora-record roster Tests/AgoraCoreTests/Fixtures/local-roster.json
//
// Scenarios are read-only unless noted. Secrets (tickets, tokens) are redacted.

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: agora-record <scenario> <output.json>\nscenarios: roster, botchat <profile>")
    exit(2)
}
let scenario = args[1]
let output = URL(fileURLWithPath: args[2])

let recorder = FixtureRecorder(description: "Recorded from a real Hermes: \(scenario)")
let access = LocalAccess(control: RecordingControlSocket(UnixControlSocket(), recorder: recorder))
let connection = HermesConnection(
    access: access, sockets: RecordingSocketFactory(URLSessionSockets(), recorder: recorder),
    http: RecordingHTTPClient(URLSessionHTTP(), recorder: recorder))

do {
    try await connection.connect()
    switch scenario {
    case "roster":
        let roster = try await connection.call("profiles.list", [:])
        print("profiles:", roster["profiles"].array?.compactMap { $0["name"].string } ?? [])
    case "botchat":
        let profile = args.count > 3 ? args[3] : "default"
        let list = try await connection.call(
            "session.list", ["profile": .string(profile), "title": "Bot Chat", "include_hidden": true, "limit": 200])
        print("bot chat rows:", list["sessions"].array?.count ?? 0)
        if let sid = list["sessions"][0]["session_id"].string {
            let snap = try await connection.call("session.resume", ["profile": .string(profile), "session_id": .string(sid)])
            print("messages:", snap["messages"].array?.count ?? 0)
        }
    default:
        print("unknown scenario \(scenario)")
        exit(2)
    }
    await connection.disconnect()
    try recorder.fixture().data().write(to: output)
    print("wrote", output.path)
} catch {
    print("failed:", error)
    try? recorder.fixture().data().write(to: output)
    exit(1)
}
