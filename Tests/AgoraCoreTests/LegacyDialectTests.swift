import Testing

@testable import AgoraCore

/// `hermes serve` speaks the older session dialect and rejects fields it doesn't know.
struct LegacyDialectTests {
    @Test func createTakesAnIdempotencyKey() {
        let (m, p) = LegacyDialect.translate("session.create", ["request_id": "r1", "source": "gui", "profile": "coder"])
        #expect(m == "session.create")
        #expect(p == ["idempotency_key": "r1", "source": "gui", "profile": "coder"])
    }

    @Test func submitSendsOnlyWhatTheOlderDialectKnows() {
        let (_, p) = LegacyDialect.translate(
            "prompt.submit", ["session_id": "s", "profile": "coder", "text": "hi", "submission_id": "x", "attachments": [["path": "/a.png"]]])
        #expect(p == ["session_id": "s", "profile": "coder", "text": "hi"])
    }

    @Test func generationsAndSequencesAreRenamedOrDropped() {
        #expect(LegacyDialect.translate("session.interrupt", ["session_id": "s", "execution_generation": 3]).1 == ["session_id": "s"])
        #expect(LegacyDialect.translate("session.events.since", ["session_id": "s", "last_sequence": 7]).1 == ["session_id": "s", "last_seen": 7])
        #expect(
            LegacyDialect.translate("approval.respond", ["session_id": "s", "prompt_id": "p", "execution_generation": 1, "choice": "once"]).1
                == ["session_id": "s", "request_id": "p", "choice": "once"])
    }

    @Test func mutationsBecomeTheirOwnMethods() {
        let base: [String: JSON] = ["session_id": "s", "profile": "coder", "request_id": "r", "expected_revision": 2]
        func t(_ op: String, _ payload: JSON) -> (String, JSON) {
            var p = base
            p["operation"] = .string(op)
            p["payload"] = payload
            return LegacyDialect.translate("session.mutate", .object(p))
        }
        #expect(t("rename", ["title": "Trip"]) == ("session.title", ["session_id": "s", "profile": "coder", "title": "Trip"]))
        #expect(t("compress", [:]) == ("session.compress", ["session_id": "s", "profile": "coder"]))
        #expect(t("archive", ["archived": true]) == ("session.archive", ["session_id": "s", "profile": "coder", "archived": true]))
        #expect(t("delete", [:]) == ("session.delete", ["session_id": "s", "profile": "coder"]))
    }
}
