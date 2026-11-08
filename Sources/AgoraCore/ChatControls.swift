import Foundation

extension AgoraCore {
    /// Stops the reply being generated.
    public func stop(_ c: Conversation) async {
        guard let connection else { return }
        for attempt in 0..<2 {
            do {
                _ = try await connection.call(
                    "session.interrupt",
                    ["session_id": .string(c.sessionID), "profile": .string(c.bot), "execution_generation": .number(Double(c.generation))])
                return
            } catch HermesError.rpc(_, _, "stale_generation", let data) where attempt == 0 {
                // The turn moved on before we heard about it: stop the current one.
                guard let fresh = data["execution_generation"].int, fresh != c.generation else {
                    c.isRunning = false
                    return
                }
                c.generation = fresh
            } catch let e as HermesError where e.rpcReason == "session_idle" || e.rpcReason == "stale_generation" {
                c.isRunning = false  // nothing is running any more
                return
            } catch {
                if !isCancellation(error) { notice = "Couldn't stop: \(error.localizedDescription)" }
                return
            }
        }
    }

    /// Condenses a long conversation (Hermes' compact) instead of starting a new one.
    public func condense(_ c: Conversation) async {
        do {
            c.statusLine = "Condensing…"
            try await mutate(c, operation: "compress", payload: [:], needsGeneration: true)
            c.statusLine = nil
            await refresh(c)
        } catch {
            c.statusLine = nil
            notice = "Couldn't condense: \(error.localizedDescription)"
        }
    }

    /// The bytes of an image in a message. Images on the Hermes host are fetched through REST,
    /// so this works the same for Local and Remote Connections.
    public func imageData(_ image: ChatImage, in c: Conversation) async -> Data? {
        if let d = image.decodedData { return d }
        if let cached = imageCache[image] { return cached }
        guard let connection else { return nil }
        let data: Data?
        switch image {
        case .hostPath(let path):
            let r = try? await connection.rest(
                "GET", "/api/fs/read-data-url", profile: c.bot, query: ["path": path, "session_id": c.storedSessionID])
            data = r.flatMap { ChatImage.dataURL($0["dataUrl"].string ?? $0["data_url"].string ?? "").decodedData }
        case .remote(let url):
            let r = try? await connection.rest("GET", "/api/media/proxy", profile: c.bot, query: ["url": url.absoluteString])
            data = r.flatMap { ChatImage.dataURL($0["data_url"].string ?? $0["dataUrl"].string ?? "").decodedData }
        default:
            data = nil
        }
        if let data { imageCache[image] = data }
        return data
    }
}
