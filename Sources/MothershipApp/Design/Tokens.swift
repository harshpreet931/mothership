import AppKit
import SwiftUI

/// "Sky" design tokens (docs/DESIGN.md §4). Every color is dynamic over Day (light chrome)
/// and Night (dark chrome); the window's appearance is set from the active sky preset.
enum Sky {
    // MARK: Spacing & radii

    static let gutter: CGFloat = 10
    static let panelPadding: CGFloat = 14
    static let radiusChip: CGFloat = 8
    static let radiusControl: CGFloat = 12
    static let radiusPane: CGFloat = 18
    static let radiusPanel: CGFloat = 24
    static let topBarHeight: CGFloat = 52
    static let composerBand: CGFloat = 56
    static let sidebarWidth: CGFloat = 260

    // MARK: Type

    enum Font {
        /// Ambient clock: SF Pro Display 64/60, tracking −2 %.
        static let displayXL = SwiftUI.Font.system(size: 64, weight: .regular)
        /// Page titles: 34 regular.
        static let displayL = SwiftUI.Font.system(size: 34, weight: .regular)
        /// Editorial headings in New York.
        static let serifL = SwiftUI.Font.system(size: 26, weight: .regular, design: .serif)
        static let title = SwiftUI.Font.system(size: 15, weight: .medium)
        static let body = SwiftUI.Font.system(size: 13.5, weight: .regular)
        static let meta = SwiftUI.Font.system(size: 11.5, weight: .regular, design: .monospaced).monospacedDigit()
        static let label = SwiftUI.Font.system(size: 12, weight: .medium)
    }

    // MARK: Color

    static let ink = Color(nsColor: .skyInk)
    static let onInk = Color(nsColor: .skyOnInk)
    static let secondary = Color(nsColor: .skyInk.withAlphaComponent(0.56))
    static let tertiary = Color(nsColor: .skyInk.withAlphaComponent(0.36))
    static let glassFill = Color(nsColor: .skyGlassFill)
    /// Glass over busy content (terminal text): the §9 scrim, folded into the tint.
    static let glassDense = Color(nsColor: .skyGlassDense)
    static let glassHighlight = Color(nsColor: .skyGlassHighlight)
    static let bubble = Color(nsColor: .skyBubble)
    static let bubbleUser = Color(nsColor: .skyBubbleUser)
    static let pillSecondary = Color(nsColor: .skyPillSecondary)
    static let attention = Color(nsColor: .skyAttention)
    static let attentionSoft = Color(nsColor: .skyAttentionSoft)
    static let danger = Color(nsColor: .skyDanger)
    /// Hairlines inside glass lists.
    static let hairline = Color(nsColor: .skyInk.withAlphaComponent(0.08))
    /// Recessed chip behind inline code.
    static let recess = Color(nsColor: .skyRecess)
    /// Selection (sidebar row, segmented pill, palette row, active circle): solid ink by
    /// Day; at night a frosted white 16 % with a 20 % white hairline and white text.
    static let selection = Color(nsColor: .skySelection)
    /// Hairline around opaque cards floating over the sky (toasts).
    static let cardStroke = Color(nsColor: .skyCardStroke)
    static let selectionStroke = Color(nsColor: .skySelectionStroke)
    static let onSelection = Color(nsColor: .skyOnSelection)
    /// Switches: ink track by Day, a calm blue at night (white on white reads as off).
    static let accentToggle = Color(nsColor: .skyAccentToggle)

    // MARK: Motion

    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let hover = Animation.easeOut(duration: 0.12)
}

extension NSColor {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
        )
    }

    static let skyInk = dynamic(light: rgb(0x0D0E11), dark: rgb(0xF4F5F7))
    static let skyOnInk = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x0D0E11))
    static let skyGlassFill = dynamic(light: rgb(0xFFFFFF, 0.55), dark: rgb(0x14161B, 0.55))
    static let skyGlassDense = dynamic(light: rgb(0xF7F9FC, 0.9), dark: rgb(0x16181E, 0.9))
    static let skyGlassHighlight = dynamic(light: rgb(0xFFFFFF, 0.70), dark: rgb(0xFFFFFF, 0.08))
    static let skyBubble = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x1D1F25))
    static let skyBubbleUser = dynamic(light: rgb(0xFFFFFF, 0.40), dark: rgb(0xFFFFFF, 0.10))
    static let skyPillSecondary = dynamic(light: rgb(0xFFFFFF), dark: rgb(0xFFFFFF, 0.12))
    static let skyAttention = dynamic(light: rgb(0xFF7A1A), dark: rgb(0xFF8A33))
    static let skyAttentionSoft = dynamic(light: rgb(0xFF7A1A, 0.14), dark: rgb(0xFF8A33, 0.18))
    static let skyDanger = dynamic(light: rgb(0xE5484D), dark: rgb(0xF2555A))
    static let skyRecess = dynamic(light: rgb(0x0D0E11, 0.05), dark: rgb(0x000000, 0.28))
    static let skySelection = dynamic(light: rgb(0x0D0E11), dark: rgb(0xFFFFFF, 0.16))
    static let skySelectionStroke = dynamic(light: rgb(0x0D0E11, 0), dark: rgb(0xFFFFFF, 0.2))
    static let skyOnSelection = NSColor.white
    static let skyCardStroke = dynamic(light: rgb(0x0D0E11, 0.06), dark: rgb(0xFFFFFF, 0.08))
    static let skyAccentToggle = dynamic(light: rgb(0x0D0E11), dark: rgb(0x5B7CF0))
    /// Solid stand-in for glass under Reduce Transparency.
    static let skySolidPanel = dynamic(light: rgb(0xF4F6F9), dark: rgb(0x1D1F25))

    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let raw = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((raw >> 16) & 0xFF) / 255, green: CGFloat((raw >> 8) & 0xFF) / 255,
            blue: CGFloat(raw & 0xFF) / 255, alpha: 1
        )
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? true
    }
}

/// Accessibility switches the whole UI reads (§9).
enum SkyAccessibility {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}
