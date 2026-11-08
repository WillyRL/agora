import AgoraCore
import Foundation
import Sparkle

/// In-app updates through Sparkle. Agora updates from tagged releases and Agora Nightly from nightly builds;
/// `scripts/package-release.sh` puts the right feed and our public signing key into Info.plist. Agora Dev
/// (built from source) and the demo have neither, so they never replace themselves.
@MainActor
@Observable
final class AppUpdater {
    private let controller: SPUStandardUpdaterController?

    /// This build can update itself.
    var isAvailable: Bool { controller != nil }

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let configured = Bundle.main.bundleURL.pathExtension == "app"
            && (info["SUFeedURL"] as? String)?.isEmpty == false
            && (info["SUPublicEDKey"] as? String)?.isEmpty == false
        let quiet = env["AGORA_DEMO"] != nil || env["AGORA_SNAPSHOT"] != nil
        controller = configured && !quiet
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: channels, userDriverDelegate: nil) : nil
    }

    private let channels = BetaChannel()

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

/// A beta (a version with a dash, like 0.2.0-beta.1) also takes newer betas; a stable release only stable
/// ones. The feed marks beta items with `<sparkle:channel>beta</sparkle:channel>`.
final class BetaChannel: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return version.contains("-") ? ["beta"] : []
    }
}
