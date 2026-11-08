import Foundation
import Observation

/// A saved Connection: the Hermes Agora talks to.
public struct SavedConnection: Sendable, Codable, Identifiable, Equatable {
    public enum Kind: Sendable, Codable, Equatable {
        /// Hermes on this Mac.
        case local
        /// `hermes serve` on another machine.
        case remote(URL)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind

    public var isLocal: Bool { kind == .local }
    public var remoteURL: URL? {
        if case .remote(let url) = kind { return url }
        return nil
    }
}

/// Saved Connections, and which one is active. Only one Connection is active at a time.
@MainActor
@Observable
public final class ConnectionRegistry {
    public private(set) var connections: [SavedConnection] = []
    public private(set) var activeID: UUID?

    private let store: KeyValueStore
    private static let listKey = "connections"
    private static let activeKey = "connections.active"

    public init(store: KeyValueStore) {
        self.store = store
        connections = store.decode([SavedConnection].self, Self.listKey) ?? []
        activeID = store.decode(UUID.self, Self.activeKey)
        if activeID.flatMap({ id in connections.first { $0.id == id } }) == nil { activeID = connections.first?.id }
    }

    public var active: SavedConnection? { connections.first { $0.id == activeID } }

    @discardableResult
    public func add(name: String, kind: SavedConnection.Kind) -> SavedConnection {
        let c = SavedConnection(id: UUID(), name: name, kind: kind)
        connections.append(c)
        if activeID == nil { activeID = c.id }
        save()
        return c
    }

    public func rename(_ id: UUID, to name: String) {
        guard let i = connections.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        connections[i].name = trimmed
        save()
    }

    /// Removes a Connection and returns it (the caller deletes its Keychain entry).
    @discardableResult
    public func remove(_ id: UUID) -> SavedConnection? {
        guard let i = connections.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = connections.remove(at: i)
        if activeID == id { activeID = connections.first?.id }
        save()
        return removed
    }

    public func activate(_ id: UUID) {
        guard connections.contains(where: { $0.id == id }) else { return }
        activeID = id
        save()
    }

    private func save() {
        store.encode(connections, Self.listKey)
        store.encode(activeID, Self.activeKey)
    }
}
