import AgoraCore
import SwiftUI

enum Theme {
    /// The one accent, from the app icon.
    static let accent = Color(red: 0x7c / 255, green: 0x3a / 255, blue: 0xed / 255)
    static let secondaryText = Color(red: 0x6e / 255, green: 0x6a / 255, blue: 0x75 / 255)
    static let hairline = Color.black.opacity(0.08)
    static let cardBackground = Color(nsColor: .textBackgroundColor)
    static let contentBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.105, green: 0.1, blue: 0.115, alpha: 1) : NSColor(red: 0.988, green: 0.984, blue: 0.992, alpha: 1)
    })
    static let sidebarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.13, green: 0.12, blue: 0.15, alpha: 1) : NSColor(red: 0.965, green: 0.96, blue: 0.972, alpha: 1)
    })
}

extension BotColor {
    var swiftUI: Color { Color(red: red, green: green, blue: blue) }
}

/// A round avatar with the Bot's colour and initial (the design's look).
struct BotAvatar: View {
    let bot: Bot
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .fill(bot.color.swiftUI)
            .frame(width: size, height: size)
            .overlay(
                Text(bot.initial)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(bot.color.isDark ? .white : .black.opacity(0.8))
            )
            .accessibilityHidden(true)
    }
}

extension View {
    /// macOS 26 blurs content scrolling under the (hidden) title bar; Agora's flat layout doesn't want that.
    /// Xcode 16 (Swift 6.0/6.1) has no macOS 26 SDK, so the call is compiled only with Xcode 26+.
    @ViewBuilder func noScrollEdgeEffect() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
