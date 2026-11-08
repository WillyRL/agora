import AgoraCore
import AppKit
import SwiftUI

@main
struct AgoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Agora", id: "main") {
            MainView()
                .background(WindowOpenerBridge())
                .environment(delegate.model.core)
                .environment(delegate.model)
                .frame(minWidth: 820, minHeight: 520)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1120, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                if delegate.model.updater.isAvailable {
                    Button("Check for Updates…") { delegate.model.updater.checkForUpdates() }
                }
            }
            CommandGroup(after: .newItem) {
                Button("Quick Ask") { delegate.model.quickAsk.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Today") { delegate.model.destination = .today }
                    .keyboardShortcut("0", modifiers: .command)
                Button("All Bots") { delegate.model.destination = .allBots }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Picker("Appearance", selection: Binding(get: { delegate.model.appearance }, set: { delegate.model.appearance = $0 })) {
                    ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
                }
                Button("Toggle Dark Mode") { delegate.model.toggleAppearance() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
            }
            CommandMenu("Bot") {
                Button("New Side Chat") {
                    if let bot = delegate.model.destination.bot { Task { await delegate.model.newSideChat(bot: bot, carryContext: false) } }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(delegate.model.destination.bot == nil)
                Button("New Side Chat with Context") {
                    if let bot = delegate.model.destination.bot { Task { await delegate.model.newSideChat(bot: bot, carryContext: true) } }
                }
                .disabled(delegate.model.destination.bot == nil)
                Divider()
                Button(delegate.model.focusMode ? "Exit Focus" : "Focus") { delegate.model.setFocus(!delegate.model.focusMode) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Show Routines") { delegate.model.showRoutines.toggle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("New Bot…") { delegate.model.destination = .newBot }
            }
        }

        Settings {
            SettingsView()
                .environment(delegate.model.core)
                .environment(delegate.model)
                .tint(Theme.accent)
        }
    }
}

/// Lets non-view code (notifications, Quick Ask) reopen the main window after it was closed.
struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var app
    var body: some View {
        Color.clear.onAppear {
            app.openMainWindow = { openWindow(id: "main") }
        }
    }
}
