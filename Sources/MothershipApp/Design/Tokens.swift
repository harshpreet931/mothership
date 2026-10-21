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
    /// The composer pill (collapsed) and field (open), floating 6 pt above the window's
    /// bottom edge, over the gutter and the bottom-row cards' clear margin.
    static let composerPillHeight: CGFloat = 30
    static let composerHeight: CGFloat = 36
    static let composerBottom: CGFloat = 6
    /// Clear margin at the bottom of bottom-row cards while the composer shows. With the
    /// terminal's own 14 pt bottom padding, glyphs stay above the open field (36 + 6 − 10).
    static let composerClearance: CGFloat = 22
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
    /// Secondary and tertiary text keep ≥ 4.5:1 over glass on every sky (ink 56 %/36 %
    /// measured ~4.4 and ~2.3–3:1).
    static let secondary = Color(nsColor: .skySecondary)
    static let tertiary = Color(nsColor: .skyTertiary)
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

    // MARK: Diffs (the diff viewer is a document, so it alone gets a calm sage for
    // additions; everywhere else stats stay ink)

    static let diffAddFill = Color(nsColor: .skyDiffAddFill)
    static let diffAddMark = Color(nsColor: .skyDiffAddMark)
    static let diffRemoveFill = Color(nsColor: .skyDiffRemoveFill)
    static let diffRemoveMark = Color(nsColor: .skyDiffRemoveMark)
    /// Search matches in the diff viewer.
    static let findMatch = Color(nsColor: .skyFindMatch)

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
    static let skySecondary = dynamic(light: rgb(0x0D0E11, 0.68), dark: rgb(0xF4F5F7, 0.64))
    static let skyTertiary = dynamic(light: rgb(0x0D0E11, 0.58), dark: rgb(0xF4F5F7, 0.48))
    static let skySelection = dynamic(light: rgb(0x0D0E11), dark: rgb(0xFFFFFF, 0.16))
    static let skySelectionStroke = dynamic(light: rgb(0x0D0E11, 0), dark: rgb(0xFFFFFF, 0.2))
    static let skyOnSelection = NSColor.white
    static let skyCardStroke = dynamic(light: rgb(0x0D0E11, 0.06), dark: rgb(0xFFFFFF, 0.08))
    static let skyAccentToggle = dynamic(light: rgb(0x0D0E11), dark: rgb(0x5B7CF0))
    static let skyDiffAddFill = dynamic(light: rgb(0x2E9A6F, 0.09), dark: rgb(0x4CC495, 0.11))
    static let skyDiffAddMark = dynamic(light: rgb(0x2A8763), dark: rgb(0x67CFA6))
    static let skyDiffRemoveFill = dynamic(light: rgb(0xE5484D, 0.07), dark: rgb(0xF2555A, 0.1))
    static let skyDiffRemoveMark = dynamic(light: rgb(0xC9373C), dark: rgb(0xF27A7E))
    static let skyFindMatch = dynamic(light: rgb(0xFF7A1A, 0.28), dark: rgb(0xFF8A33, 0.34))
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
