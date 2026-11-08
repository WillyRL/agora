import CryptoKit
import Foundation

/// Waits for the browser to come back to `http://127.0.0.1:<port>/callback?code=…&state=…`.
public protocol LoopbackReceiver: Sendable {
    /// Starts listening and returns the redirect URI to hand to the server.
    func start() async throws -> URL
    /// The callback URL the browser hit. Throws on timeout or cancel.
    func callback() async throws -> URL
    func stop()
}

/// The native browser sign-in for a Remote Connection: OAuth 2.0 with PKCE, brokered by
/// the Hermes gateway (no client id, JSON bodies, absolute `expires_at`).
public struct BrowserSignIn: Sendable {
    public let baseURL: URL
    let http: HTTPClient
    let credentials: CredentialStore

    public init(baseURL: URL, http: HTTPClient, credentials: CredentialStore) {
        self.baseURL = baseURL
        self.http = http
        self.credentials = credentials
    }

    public struct PKCE: Sendable {
        public var verifier: String
        public var challenge: String
        public var state: String

        public static func make() -> PKCE {
            let verifier = base64url(randomBytes(32))
            return PKCE(verifier: verifier, challenge: challenge(for: verifier), state: base64url(randomBytes(24)))
        }

        public static func challenge(for verifier: String) -> String {
            base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    public func authorizeURL(pkce: PKCE, redirect: URL, provider: String? = nil) -> URL {
        var comps = URLComponents(url: baseURL.appending(path: "auth/native/authorize"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        if let provider { items.append(URLQueryItem(name: "provider", value: provider)) }
        comps.queryItems = items
        return comps.url!
    }

    /// Runs the whole flow: listen, open the browser, check `state`, swap the code for tokens, store them.
    public func run(receiver: LoopbackReceiver, openBrowser: @Sendable (URL) -> Void, pkce: PKCE = .make()) async throws {
        let redirect = try await receiver.start()
        defer { receiver.stop() }
        openBrowser(authorizeURL(pkce: pkce, redirect: redirect))
        let callback = try await receiver.callback()
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw HermesError.signInRequired("Sign-in failed: \(error).")
        }
        guard items.first(where: { $0.name == "state" })?.value == pkce.state else {
            throw HermesError.signInRequired("Sign-in was interrupted (state mismatch). Try again.")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw HermesError.signInRequired("Hermes didn't return a sign-in code.")
        }
        try await exchange(code: code, verifier: pkce.verifier)
    }

    public func exchange(code: String, verifier: String) async throws {
        let body: JSON = ["code": .string(code), "code_verifier": .string(verifier)]
        let response = try await http.send(
            HTTPRequest(
                method: "POST", url: baseURL.appending(path: "auth/native/token"),
                headers: ["Content-Type": "application/json"], body: body.data()))
        guard response.status == 200 else {
            throw HermesError.signInRequired(response.json["detail"].string ?? "Sign-in failed (HTTP \(response.status)).")
        }
        credentials.save(try Self.credential(from: response.json), for: RemoteAccess.credentialKey(for: baseURL))
    }

    static func credential(from j: JSON) throws -> RemoteCredential {
        guard let access = j["access_token"].string, let refresh = j["refresh_token"].string else {
            throw HermesError.protocolViolation("token response without tokens")
        }
        return .oauth(access: access, refresh: refresh, expiresAt: j["expires_at"].double ?? 0, provider: j["provider"].string)
    }
}

func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
    return Data(bytes)
}

func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
