import Foundation

/// A task a Bot runs by itself on a schedule (a Hermes cron job).
public struct Routine: Sendable, Identifiable, Equatable {
    public var id: String
    public var bot: String
    /// The name without its `[bot:<name>]` tag.
    public var title: String
    public var schedule: String
    public var nextRun: Date?
    public var lastRun: Date?
    /// `ok`, `error` … (nil before the first run).
    public var lastStatus: String?
    public var lastError: String?
    public var paused: Bool
    public var running: Bool

    init(job j: JSON, bot: String) {
        id = j["id"].string ?? ""
        self.bot = bot
        title = Routine.title(from: j["name"].string ?? "")
        schedule = j["schedule_display"].string ?? j["schedule"]["display"].string ?? j["schedule"].string ?? ""
        nextRun = Routine.date(j["next_run_at"])
        lastRun = Routine.date(j["last_run_at"])
        lastStatus = j["last_status"].string
        lastError = j["last_error"].string ?? j["last_failure"]["error"].string
        paused = j["enabled"].bool == false || j["state"].string == "paused"
        let execution = j["latest_execution"]["status"].string
        running = !j["live_execution"].isNull || execution == "running" || execution == "claimed"
    }

    static var tagPattern: Regex<(Substring, Substring)> { /^\[bot:([a-z0-9][a-z0-9_-]*)\]\s*/.ignoresCase() }

    static func title(from name: String) -> String {
        if let m = name.firstMatch(of: tagPattern) { return String(name[m.range.upperBound...]) }
        return name
    }

    static func date(_ j: JSON) -> Date? {
        guard let s = j.string else { return j.double.map { Date(timeIntervalSince1970: $0) } }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

extension AgoraCore {
    /// Loads a Bot's Routines (the cron jobs in its own profile).
    public func loadRoutines(for bot: String) async {
        guard let connection else { return }
        do {
            let r = try await connection.rest("GET", "/api/cron/jobs", profile: bot)
            let jobs = r.array ?? r["jobs"].array ?? []
            // The Bot's own profile holds its Routines; skip any tagged `[bot:<other>]` for a different Bot.
            routines[bot] = jobs.filter { job in
                guard let m = (job["name"].string ?? "").firstMatch(of: Routine.tagPattern) else { return true }
                return String(m.1).lowercased() == bot.lowercased()
            }
            .map { Routine(job: $0, bot: bot) }.filter { !$0.id.isEmpty }
            features.routines = true
        } catch HermesError.http(let status, _) where status == 404 || status == 403 {
            features.routines = false
            routines[bot] = []
        } catch {
            if !isCancellation(error) { notice = "Couldn't load Routines: \(error.localizedDescription)" }
        }
    }

    public func pause(_ routine: Routine) async {
        await routineAction(routine, "POST", "/pause")
    }

    public func resume(_ routine: Routine) async {
        await routineAction(routine, "POST", "/resume")
    }

    /// Runs a Routine now. Hermes runs it to completion before answering, so this can take a while;
    /// its result also arrives in the Bot Chat.
    public func runNow(_ routine: Routine) async {
        setRoutine(routine.id, bot: routine.bot) { $0.running = true }
        await routineAction(routine, "POST", "/trigger")
    }

    public func delete(_ routine: Routine) async {
        guard let connection else { return }
        do {
            _ = try await connection.rest("DELETE", "/api/cron/jobs/\(routine.id)", profile: routine.bot)
            routines[routine.bot]?.removeAll { $0.id == routine.id }
        } catch {
            if !isCancellation(error) { notice = "Couldn't delete the Routine: \(error.localizedDescription)" }
        }
    }

    private func routineAction(_ routine: Routine, _ method: String, _ suffix: String) async {
        guard let connection else { return }
        do {
            let job = try await connection.rest(method, "/api/cron/jobs/\(routine.id)\(suffix)", profile: routine.bot)
            if job["id"].string != nil {
                let fresh = Routine(job: job, bot: routine.bot)
                setRoutine(routine.id, bot: routine.bot) { $0 = fresh }
            } else {
                await loadRoutines(for: routine.bot)
            }
        } catch {
            setRoutine(routine.id, bot: routine.bot) { $0.running = false }
            notice = "Couldn't update the Routine: \(error.localizedDescription)"
        }
    }

    private func setRoutine(_ id: String, bot: String, _ change: (inout Routine) -> Void) {
        guard let i = routines[bot]?.firstIndex(where: { $0.id == id }) else { return }
        change(&routines[bot]![i])
    }
}
