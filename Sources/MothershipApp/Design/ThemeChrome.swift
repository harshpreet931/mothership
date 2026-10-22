import AppKit
import Observation
import SwiftUI
import ThemeKit

/// The active theme's chrome colors (glass tints, selection, attention, danger) as dynamic
/// NSColors that resolve light or dark by appearance. `Sky` tokens read them; a theme
/// change publishes new color objects, so every view that used one re-renders.
@MainActor
@Observable
final class ThemeChrome {
    static let shared = ThemeChrome()

    private(set) var paletteID = ""
    private(set) var glass: NSColor
    private(set) var glassDense: NSColor
    private(set) var attention: NSColor
    private(set) var attentionSoft: NSColor
    private(set) var danger: NSColor
    /// The theme's own selection fill, when it sets one (else the tone's).
    private(set) var selection: NSColor?

    private init() {
        let palette = ThemeLibrary.theme(id: ThemeLibrary.defaultThemeID)?.palette ?? Self.fallback
        glass = Self.glass(palette, dense: false)
        glassDense = Self.glass(palette, dense: true)
        attention = palette.attention.nsColor
        attentionSoft = palette.attention.nsColor.withAlphaComponent(0.16)
        danger = palette.danger.nsColor
        selection = palette.selection?.nsColor
        paletteID = palette.signature
    }

    func apply(_ palette: ChromePalette) {
        guard palette.signature != paletteID else { return }
        paletteID = palette.signature
        glass = Self.glass(palette, dense: false)
        glassDense = Self.glass(palette, dense: true)
        attention = palette.attention.nsColor
        attentionSoft = palette.attention.nsColor.withAlphaComponent(0.16)
        danger = palette.danger.nsColor
        selection = palette.selection?.nsColor
    }

    /// Light glass for light chrome, dark glass for dark; the dense variant (palette,
    /// toasts, the open composer) keeps the hue at 90 %.
    private static func glass(_ palette: ChromePalette, dense: Bool) -> NSColor {
        let light = palette.lightGlass.nsColor
        let dark = palette.darkGlass.nsColor
        return NSColor(name: nil) { appearance in
            let base = appearance.isDark ? dark : light
            return dense ? base.withAlphaComponent(0.9) : base
        }
    }

    static let fallback = ChromePalette(
        attention: RGBA(red: 1, green: 0.54, blue: 0.2), danger: RGBA(red: 0.95, green: 0.33, blue: 0.35),
        lightGlass: RGBA(red: 1, green: 1, blue: 1, alpha: 0.55), darkGlass: RGBA(red: 0.06, green: 0.08, blue: 0.12, alpha: 0.62)
    )
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(nsColor: nsColor) }
}

extension ChromePalette {
    /// Stable identity for "did anything change".
    var signature: String {
        [attention.hex, danger.hex, lightGlass.hex, darkGlass.hex, selection?.hex ?? "-"].joined(separator: ",")
    }
}
