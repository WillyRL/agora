import Foundation

/// Reads your tailnet: the JSON of `tailscale status --json`.
public protocol TailnetSource: Sendable {
    /// Throws `TailnetUnavailable.notInstalled` when there's no Tailscale on this Mac.
    func status() async throws -> JSON
}

public enum TailnetUnavailable: Error, Sendable {
    case notInstalled
}

/// A Hermes found on a machine in your tailnet.
public struct TailnetGateway: Sendable, Equatable, Identifiable {
    public var id: String { url.absoluteString }
    /// The machine's name in Tailscale ("Studio Mac mini").
    public var deviceName: String
    public var url: URL
    public var status: RemoteAccess.Status
    /// The saved Connection pointing at this Hermes, if any.
    public var savedConnectionID: UUID?

    public init(deviceName: String, url: URL, status: RemoteAccess.Status, savedConnectionID: UUID? = nil) {
        self.deviceName = deviceName
        self.url = url
        self.status = status
        self.savedConnectionID = savedConnectionID
    }

    /// Agora needs Hermes 0.23 or newer (the canonical session protocol).
    public var isSupported: Bool { status.version.map { Self.version($0, atLeast: [0, 23]) } ?? true }

    static func version(_ v: String, atLeast minimum: [Int]) -> Bool {
        let parts = v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for (i, m) in minimum.enumerated() {
            let p = i < parts.count ? parts[i] : 0
            if p != m { return p > m }
        }
        return true
    }
}

/// The last tailnet scan.
public struct TailnetScan: Sendable, Equatable {
    public var scanning = false
    public var gateways: [TailnetGateway] = []
    /// Why nothing could be scanned (Tailscale missing or off).
    public var problem: String?
    /// False when this Mac has no Tailscale at all.
    public var tailscaleInstalled = true
    public init() {}
}

/// A machine in the tailnet worth asking for Hermes.
struct TailnetDevice: Sendable, Equatable {
    var name: String
    /// MagicDNS name (or Tailscale IP when MagicDNS is off).
    var host: String
    var hasDNSName: Bool

    /// `hermes serve` is reached through Tailscale Serve (HTTPS on the MagicDNS name) or on its default port 9119.
    var candidates: [URL] {
        var urls: [URL] = []
        if hasDNSName, let u = URL(string: "https://\(host)") { urls.append(u) }
        if let u = URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):9119") { urls.append(u) }
        return urls
    }

    /// The machines worth probing: online, in your own tailnet, able to run Hermes. Never this Mac.
    static func from(status j: JSON) throws -> [TailnetDevice] {
        guard j["BackendState"].string == "Running" else { throw HermesError.hermesUnavailable("Tailscale is turned off on this Mac.") }
        let magicDNS = j["CurrentTailnet"]["MagicDNSEnabled"].bool ?? true
        let peers = j["Peer"].object?.values.map { $0 } ?? []
        return peers.compactMap { p -> TailnetDevice? in
            guard p["Online"].bool == true, p["ShareeNode"].bool != true else { return nil }
            let os = p["OS"].string ?? ""
            guard !["iOS", "android", "tvOS"].contains(os) else { return nil }
            var dns = p["DNSName"].string ?? ""
            while dns.hasSuffix(".") { dns.removeLast() }
            guard !dns.isEmpty else { return nil }
            let label = String(dns.split(separator: ".").first ?? "")
            var name = p["HostName"].string ?? ""
            if name.isEmpty || name == "localhost" { name = label }
            if magicDNS { return TailnetDevice(name: name, host: dns, hasDNSName: true) }
            let ipv4 = p["TailscaleIPs"].array?.compactMap(\.string).first { $0.contains(".") }
            return ipv4.map { TailnetDevice(name: name, host: $0, hasDNSName: false) }
        }
    }
}

extension AgoraCore {
    /// Looks for Hermes on the machines of your tailnet. Results land in `tailnet`.
    public func scanTailnet() async {
        guard !tailnet.scanning else { return }
        tailnet.scanning = true
        defer { tailnet.scanning = false }
        let devices: [TailnetDevice]
        do {
            guard let source = env.tailnet else { throw TailnetUnavailable.notInstalled }
            devices = try TailnetDevice.from(status: try await source.status())
        } catch TailnetUnavailable.notInstalled {
            tailnet.problem = "Tailscale isn't installed on this Mac."
            tailnet.tailscaleInstalled = false
            tailnet.gateways = []
            return
        } catch {
            tailnet.problem = (error as? HermesError)?.errorDescription ?? "Couldn't read your tailnet: \(error.localizedDescription)"
            tailnet.gateways = []
            return
        }
        let http = env.http
        let found = await withTaskGroup(of: (Int, Int, TailnetGateway)?.self) { group in
            for (d, device) in devices.enumerated() {
                for (c, url) in device.candidates.enumerated() {
                    group.addTask {
                        guard let status = await Self.probeHermes(url, http: http) else { return nil }
                        return (d, c, TailnetGateway(deviceName: device.name, url: url, status: status))
                    }
                }
            }
            // One Hermes per machine: the first candidate that answered (HTTPS before :9119).
            var best: [Int: (Int, TailnetGateway)] = [:]
            for await result in group {
                guard let (d, c, gateway) = result else { continue }
                if let current = best[d], current.0 < c { continue }
                best[d] = (c, gateway)
            }
            return best.values.map(\.1)
        }
        tailnet.problem = nil
        tailnet.tailscaleInstalled = true
        tailnet.gateways = found
            .map { g in
                var g = g
                g.savedConnectionID = savedConnection(for: g.url)?.id
                return g
            }
            .sorted { $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending }
    }

    /// The saved Connection for a Hermes URL, if any.
    public func savedConnection(for url: URL) -> SavedConnection? {
        let key = RemoteAccess.credentialKey(for: url)
        return registry.connections.first { $0.remoteURL.map(RemoteAccess.credentialKey(for:)) == key }
    }

    /// Adds a Hermes found on the tailnet with browser sign-in, named after its machine, and makes it active.
    @discardableResult
    public func connect(
        to gateway: TailnetGateway, receiver: LoopbackReceiver, openBrowser: @escaping @Sendable (URL) -> Void
    ) async throws -> SavedConnection {
        try await addRemoteConnection(name: gateway.deviceName, url: gateway.url, receiver: receiver, openBrowser: openBrowser)
    }

    /// `GET /api/status`, accepted only if it looks like Hermes. Gives up after `timeout`.
    nonisolated static func probeHermes(_ url: URL, http: HTTPClient, timeout: Duration = .seconds(3)) async -> RemoteAccess.Status? {
        await withTaskGroup(of: RemoteAccess.Status??.self) { group in
            group.addTask {
                guard let response = try? await http.send(HTTPRequest(method: "GET", url: url.appending(path: "api/status"))),
                    response.status == 200, let auth = response.json["auth_required"].bool, let version = response.json["version"].string
                else { return .some(nil) }
                let j = response.json
                return .some(
                    RemoteAccess.Status(
                        version: version, authRequired: auth, authProviders: j["auth_providers"].array?.compactMap(\.string) ?? [],
                        authFlows: j["auth_flows"].array?.compactMap(\.string) ?? []))
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .some(nil)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }
}
