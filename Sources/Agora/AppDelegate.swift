import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    override init() {
        SettingsMigration.run()  // before AppModel reads any setting
        model = AppModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model.appearance.apply()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.core.appIsActive = true
                self?.model.syncViewing()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.core.appIsActive = false }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.model.core.reconnectNow() }
            }
        }
        Task {
            await model.launch()
            if DebugSnapshot.prefix != nil { await DebugSnapshot.runScript(model: model) }
        }
    }

    /// Closing the window keeps Agora running so notifications and Quick Ask keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.openMainWindow?() }
        return true
    }
}

/// Agora's bundle ID was `app.agora.Agora` before the first release; macOS keeps an app's settings under its
/// bundle ID, so a copy built with the old one would start over (no saved Connections, hotkey, appearance…).
/// This copies them across once. Saved logins live in the Keychain under a fixed service name and need nothing.
enum SettingsMigration {
    static let oldBundleID = "app.agora.Agora"
    static let doneKey = "agora.settingsMigratedFromOldBundleID"

    static func run(defaults: UserDefaults = .standard) {
        guard Bundle.main.bundleIdentifier != oldBundleID, !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
