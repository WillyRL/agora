import Foundation
import Security
import Synchronization

/// Small persistent preferences (saved Connections, mutes, last Bot …).
public protocol KeyValueStore: Sendable {
    func data(for key: String) -> Data?
    func set(_ data: Data?, for key: String)
}

extension KeyValueStore {
    func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        data(for: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func encode<T: Encodable>(_ value: T?, _ key: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, for: key)
    }
}

public final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    let defaults: UserDefaults
    let prefix: String
    public init(defaults: UserDefaults = .standard, prefix: String = "agora.") {
        self.defaults = defaults
        self.prefix = prefix
    }
    public func data(for key: String) -> Data? { defaults.data(forKey: prefix + key) }
    public func set(_ data: Data?, for key: String) { defaults.set(data, forKey: prefix + key) }
}

public final class InMemoryKeyValueStore: KeyValueStore {
    private let values = Mutex<[String: Data]>([:])
    public init() {}
    public func data(for key: String) -> Data? { values.withLock { $0[key] } }
    public func set(_ data: Data?, for key: String) { values.withLock { $0[key] = data } }
}

/// Remote logins in the macOS Keychain, keyed by the Connection's base URL.
public final class KeychainCredentialStore: CredentialStore {
    let service: String
    // A fixed name, not the bundle ID: it predates `io.github.willyrl.agora`, and keeping it keeps saved logins.
    public init(service: String = "app.agora.remote-login") { self.service = service }

    public func load(for key: String) -> RemoteCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(RemoteCredential.self, from: data)
    }

    public func save(_ credential: RemoteCredential?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let credential, let data = try? JSONEncoder().encode(credential) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

public final class InMemoryCredentialStore: CredentialStore {
    private let values = Mutex<[String: RemoteCredential]>([:])
    public init() {}
    public func load(for key: String) -> RemoteCredential? { values.withLock { $0[key] } }
    public func save(_ credential: RemoteCredential?, for key: String) { values.withLock { $0[key] = credential } }
    public var keys: [String] { values.withLock { Array($0.keys) } }
}
