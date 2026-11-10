import CryptoKit
import Foundation
import Testing

@testable import AgoraCore

@MainActor
struct CloudflareAccessTests {
    let server = URL(string: "https://hermes.example.com")!

    @Test func cloudflaresLoginRedirectAsksForAnAccessLoginNotHermesServe() async throws {
        let fake = try FakeHermes(named: "remote-cloudflare")

        await #expect(throws: HermesError.accessLoginRequired(server)) {
            try await TestCore.make(fake).probeRemote(server)
        }
    }

    @Test func afterTheAccessLoginEveryRequestAndTheWebSocketCarryTheToken() async throws {
        let fake = try FakeHermes(named: "remote-cloudflare")
        let credentials = InMemoryCredentialStore()
        credentials.save(.token("tok-123"), for: "https://hermes.example.com")
        let tokens = InMemoryAccessTokenStore()
        let core = TestCore.make(fake, credentials: credentials, remote: server, accessTokens: tokens)

        await core.start()
        #expect(core.status == .needsAccessLogin(server))

        core.saveAccessToken("cf-jwt", for: server)
        await core.start()

        #expect(core.status == .connected)
        #expect(tokens.token(for: "hermes.example.com") == "cf-jwt")
        let afterLogin = fake.httpRequests.dropFirst()
        #expect(!afterLogin.isEmpty)
        #expect(afterLogin.allSatisfy { $0.headers["cf-access-token"] == "cf-jwt" })
        #expect(fake.dials.first?.headers["cf-access-token"] == "cf-jwt")
    }

    @Test func aTokenCloudflareTurnsAwayIsForgotten() async throws {
        let fake = try FakeHermes(named: "remote-cloudflare")
        let tokens = InMemoryAccessTokenStore()
        tokens.save("expired", for: "hermes.example.com")

        await #expect(throws: HermesError.accessLoginRequired(server)) {
            try await TestCore.make(fake, accessTokens: tokens).probeRemote(server)
        }
        #expect(tokens.token(for: "hermes.example.com") == nil)
    }

    @Test func otherHostsAndOtherRedirectsAreLeftAlone() {
        #expect(CloudflareAccess.key(for: URL(string: "https://Hermes.Example.com:8443/x")!) == "hermes.example.com:8443")
        #expect(!CloudflareAccess.isChallenge(HTTPResponse(status: 302, body: Data(), headers: ["Location": "https://hermes.example.com/login"])))
        #expect(CloudflareAccess.isChallenge(HTTPResponse(status: 302, body: Data(), headers: ["location": "https://team.cloudflareaccess.com/cdn-cgi/access/login/x"])))
        #expect(CloudflareAccess.isChallenge(HTTPResponse(status: 401, body: Data(), headers: ["www-authenticate": "Cloudflare-Access resource_metadata=\"…\""])))
        #expect(!CloudflareAccess.isChallenge(HTTPResponse(status: 401, body: Data(), headers: ["WWW-Authenticate": "Bearer"])))
    }
}

struct AccessBrowserLoginTests {
    @Test func naclBoxOpensWhatPyNaClSealed() throws {
        let fx = try Fixtures.load("nacl-box")
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(base64Encoded: fx["recipientPrivate"].string!)!)
        let sender = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: AccessBrowserLogin.base64url(fx["senderPublic"].string!)!)
        for v in fx["vectors"].array! {
            let sealed = Data(base64Encoded: v["sealed"].string!)!
            let opened = NaClBox.open(sealed.dropFirst(24), nonce: sealed.prefix(24), sender: sender, recipient: recipient)
            #expect(opened == Data(base64Encoded: v["plain"].string!)!)
            var tampered = sealed
            tampered[tampered.count - 1] ^= 1
            #expect(NaClBox.open(tampered.dropFirst(24), nonce: tampered.prefix(24), sender: sender, recipient: recipient) == nil)
        }
    }

    @Test func theBrowserLogsInAndCloudflareHandsTheTokenToAgoraAlone() async throws {
        let fx = try Fixtures.load("cloudflare-browser-login")
        let fake = FakeHermes(fixture: fx)
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(base64Encoded: fx["recipientPrivate"].string!)!)
        let login = AccessBrowserLogin(origin: URL(string: "https://hermes.example.com/")!, http: fake, key: key)
        let opened = OpenedURL()

        let token = try await login.run { opened.set($0) }

        #expect(token == "cf-app-jwt")
        let url = try #require(opened.value)
        #expect(url.host == "hermes.example.com")
        #expect(url.path == "/cdn-cgi/access/cli")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["aud"] == "aud-123")
        #expect(query["token"] == fx["publicKey"].string)
        #expect(query["edge_token_transfer"] == "true")
        #expect(query["send_org_token"] == "true")
        #expect(query["redirect_url"] == "https://hermes.example.com?aud=aud-123&token=" + AccessBrowserLogin.encode([("t", fx["publicKey"].string!)]).dropFirst(2))
        #expect(fake.unexpected.isEmpty)
    }
}
