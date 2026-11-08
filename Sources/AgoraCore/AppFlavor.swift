import Foundation

/// Which copy of Agora this is. Stable, Nightly and Dev are separate apps (own bundle ID, name, settings
/// and saved logins), so they install side by side and trying one never touches another.
public enum AppFlavor: String, Sendable, CaseIterable {
    /// Tagged releases: "Agora".
    case stable
    /// Built every night from `main`: "Agora Nightly".
    case nightly
    /// Built from source with `scripts/build-app.sh`: "Agora Dev".
    case dev

    public static let baseBundleID = "io.github.willyrl.agora"

    /// The flavor a bundle ID belongs to. No bundle ID means a bare binary from `swift run`: Dev.
    public init(bundleID: String?) {
        guard let id = bundleID else { self = .dev; return }
        if id.hasSuffix(".nightly") {
            self = .nightly
        } else if id.hasSuffix(".dev") {
            self = .dev
        } else {
            self = .stable
        }
    }

    public static var current: AppFlavor { AppFlavor(bundleID: Bundle.main.bundleIdentifier) }

    public var bundleID: String { self == .stable ? Self.baseBundleID : "\(Self.baseBundleID).\(rawValue)" }

    public var appName: String {
        switch self {
        case .stable: return "Agora"
        case .nightly: return "Agora Nightly"
        case .dev: return "Agora Dev"
        }
    }

    /// Where saved logins and tokens live in the Keychain. Stable keeps the name it has always had.
    public var keychainService: String {
        self == .stable ? "app.agora.remote-login" : "app.agora.remote-login.\(rawValue)"
    }
}
