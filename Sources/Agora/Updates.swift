import Foundation
import Sparkle

/// Which builds this copy updates to.
enum UpdateChannel: String, CaseIterable, Identifiable {
    /// Tagged releases.
    case stable
    /// Built every night from `main`; newest features, rougher edges.
    case nightly

    var id: String { rawValue }
    var label: String { self == .stable ? "Stable" : "Nightly" }

    static let key = "updateChannel"

    /// The saved choice; a nightly build starts on Nightly, everything else on Stable.
    static var saved: UpdateChannel {
        get {
            if let raw = UserDefaults.standard.string(forKey: key), let c = UpdateChannel(rawValue: raw) { return c }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            return version.contains("-nightly") ? .nightly : .stable
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// In-app updates through Sparkle. Only release builds have them: `scripts/package-release.sh` puts the
/// update feeds and our public signing key into Info.plist. Builds made from source (and the demo) leave
/// them out, so they never offer to replace themselves with a release.
@MainActor
@Observable
final class AppUpdater {
    private let controller: SPUStandardUpdaterController?
    private let feeds: FeedChooser

    /// This build can update itself.
    var isAvailable: Bool { controller != nil }
    /// This build knows a nightly feed (so the channel can be switched).
    var hasNightly: Bool { feeds.nightly != nil }

    var channel: UpdateChannel {
        didSet {
            UpdateChannel.saved = channel
            controller?.updater.resetUpdateCycle()
        }
    }

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let configured = Bundle.main.bundleURL.pathExtension == "app"
            && (info["SUFeedURL"] as? String)?.isEmpty == false
            && (info["SUPublicEDKey"] as? String)?.isEmpty == false
        let quiet = env["AGORA_DEMO"] != nil || env["AGORA_SNAPSHOT"] != nil
        channel = UpdateChannel.saved
        feeds = FeedChooser(nightly: (info["AgoraNightlyFeedURL"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        controller = configured && !quiet
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: feeds, userDriverDelegate: nil) : nil
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Checks about once a day in the background (Sparkle asks the first time; this is that choice).
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }
}

/// Points Sparkle at the nightly feed when that channel is chosen (the stable one is SUFeedURL).
final class FeedChooser: NSObject, SPUUpdaterDelegate {
    let nightly: String?
    init(nightly: String?) { self.nightly = nightly }

    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateChannel.saved == .nightly ? nightly : nil
    }
}
