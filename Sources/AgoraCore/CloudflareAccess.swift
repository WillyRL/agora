import CryptoKit
import Foundation
import Security
import Synchronization

/// Hermes behind Cloudflare Access (a Cloudflare Tunnel with a login in front). Cloudflare answers
/// every request with a redirect to its login page until you log in. Agora logs in once in a small
/// web view, keeps the app token Cloudflare sets (`CF_Authorization`), and sends it as
/// `cf-access-token` on every request and WebSocket to that host, as `cloudflared access` does.
public enum CloudflareAccess {
    /// The cookie Cloudflare Access sets on the app's host after login. Its value is the app token.
    public static let cookieName = "CF_Authorization"
    static let header = "cf-access-token"

    /// Is this Cloudflare asking for a login rather than Hermes answering?
    public static func isChallenge(_ response: HTTPResponse) -> Bool {
        if response.header("www-authenticate")?.lowercased().hasPrefix("cloudflare-access") == true { return true }
        guard (300..<400).contains(response.status), let location = response.header("location"),
            let host = URL(string: location)?.host?.lowercased()
        else { return false }
        return host.hasSuffix(".cloudflareaccess.com") || host == "cloudflareaccess.com"
    }

    /// Tokens are kept per host (with its port, if any).
    public static func key(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Where to log in: the server's origin.
    static func origin(of url: URL) -> URL {
        var comps = URLComponents()
        comps.scheme = url.scheme
        comps.host = url.host
        comps.port = url.port
        return comps.url ?? url
    }
}

/// Cloudflare Access app tokens, by host.
public protocol AccessTokenStore: Sendable {
    func token(for host: String) -> String?
    func save(_ token: String?, for host: String)
}

public final class InMemoryAccessTokenStore: AccessTokenStore {
    private let values = Mutex<[String: String]>([:])
    public init() {}
    public func token(for host: String) -> String? { values.withLock { $0[host] } }
    public func save(_ token: String?, for host: String) { values.withLock { $0[host] = token } }
}

/// Cloudflare Access tokens in the macOS Keychain, next to the Remote logins.
public final class KeychainAccessTokenStore: AccessTokenStore {
    let service: String
    public init(service: String) { self.service = service }

    public func token(for host: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: host,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String?, for host: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: host]
        SecItemDelete(base as CFDictionary)
        guard let token else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Sends the host's Cloudflare Access token with each request, and turns Cloudflare's login
/// redirect into `HermesError.accessLoginRequired`, so it isn't mistaken for Hermes answering.
struct AccessGatedHTTP: HTTPClient {
    let inner: HTTPClient
    let tokens: AccessTokenStore

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var request = request
        let key = CloudflareAccess.key(for: request.url)
        let token = key.flatMap(tokens.token(for:))
        if let token { request.headers[CloudflareAccess.header] = token }
        let response = try await inner.send(request)
        if CloudflareAccess.isChallenge(response) {
            // Cloudflare no longer takes it (expired or revoked): log in again.
            if let key, token != nil { tokens.save(nil, for: key) }
            throw HermesError.accessLoginRequired(CloudflareAccess.origin(of: request.url))
        }
        return response
    }
}

/// Sends the host's Cloudflare Access token when opening the WebSocket.
struct AccessGatedSockets: SocketFactory {
    let inner: SocketFactory
    let tokens: AccessTokenStore

    func open(_ dial: WebSocketDial) async throws -> FrameSocket {
        var dial = dial
        if let key = CloudflareAccess.key(for: dial.url), let token = tokens.token(for: key) {
            dial.headers[CloudflareAccess.header] = token
        }
        return try await inner.open(dial)
    }
}

/// Logging in to Cloudflare Access in your own browser, the way `cloudflared access login` does:
/// the browser logs in on `<host>/cdn-cgi/access/cli`, and Cloudflare's login helper hands the app
/// token back sealed to a one-time key that only Agora holds (cloudflared's token/transfer.go).
public struct AccessBrowserLogin: Sendable {
    public let origin: URL
    let http: HTTPClient
    let key: Curve25519.KeyAgreement.PrivateKey
    static let store = URL(string: "https://login.cloudflareaccess.org/")!

    init(origin: URL, http: HTTPClient, key: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.origin = CloudflareAccess.origin(of: origin)
        self.http = http
        self.key = key
    }

    /// The one-time public key, as cloudflared writes it (base64url with padding). It also names the hand-over.
    var publicKey: String {
        key.publicKey.rawRepresentation.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// Opens the login in the browser and waits (up to `timeout`) for Cloudflare to hand over the token.
    public func run(openBrowser: @Sendable (URL) -> Void, timeout: Duration = .seconds(600)) async throws -> String {
        openBrowser(try await loginURL())
        return try await waitForToken(timeout: timeout)
    }

    /// The Access application's id (AUD), from the metadata in Cloudflare's login redirect.
    func appAUD() async throws -> String {
        let response = try await http.send(HTTPRequest(method: "GET", url: origin))
        guard CloudflareAccess.isChallenge(response), let location = response.header("location"),
            let items = URLComponents(string: location)?.queryItems
        else { throw HermesError.hermesUnavailable("\(origin.host ?? "This address") no longer asks for a Cloudflare Access login.") }
        if let meta = items.first(where: { $0.name == "meta" })?.value, let claims = Self.claims(meta),
            let aud = claims["aud"].string, claims["hostname"].string?.lowercased() == origin.host?.lowercased() {
            return aud
        }
        guard let kid = items.first(where: { $0.name == "kid" })?.value, !kid.isEmpty else {
            throw HermesError.protocolViolation("Cloudflare's login redirect has no application id")
        }
        return kid
    }

    func loginURL() async throws -> URL {
        let aud = try await appAUD()
        let first = [("token", publicKey), ("aud", aud)]
        let redirect = origin.absoluteString + "?" + Self.encode(first)
        let query = first + [
            ("redirect_url", redirect), ("send_org_token", "true"), ("edge_token_transfer", "true"), ("close_interstitial", "true"),
        ]
        return URL(string: origin.absoluteString + "/cdn-cgi/access/cli?" + Self.encode(query))!
    }

    /// Asks the login helper for the token until it has it. Until you've logged in it answers 404.
    func waitForToken(timeout: Duration) async throws -> String {
        let url = Self.store.appending(path: "transfer/" + publicKey)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let response: HTTPResponse
            do {
                response = try await http.send(HTTPRequest(method: "GET", url: url))
            } catch let error as URLError where error.code == .timedOut {
                continue
            }
            if response.status >= 500 {
                throw HermesError.http(status: response.status, detail: "Cloudflare's login helper failed")
            }
            if response.status == 200, !response.body.isEmpty {
                return try open(response)
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw HermesError.timeout("Cloudflare Access login")
    }

    func open(_ response: HTTPResponse) throws -> String {
        let text = String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sealed = Data(base64Encoded: text), sealed.count > 24,
            let senderText = response.header("service-public-key"), let senderData = Self.base64url(senderText),
            let sender = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderData),
            let plain = NaClBox.open(sealed.dropFirst(24), nonce: sealed.prefix(24), sender: sender, recipient: key),
            let token = (try? JSON(data: plain))?["app_token"].nonEmptyString
        else { throw HermesError.protocolViolation("Cloudflare's login helper sent a login Agora can't read") }
        return token
    }

    /// Like Go's `url.Values.Encode`: sorted, everything but letters, digits and `-_.~` escaped.
    static func encode(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return items.sorted { $0.0 < $1.0 }.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func base64url(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// A JWT's claims, unverified: only used to name the application to log in to.
    static func claims(_ jwt: String) -> JSON? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let data = base64url(String(parts[1])) else { return nil }
        return try? JSON(data: data)
    }
}
