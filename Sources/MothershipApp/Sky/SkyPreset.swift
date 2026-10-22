import AppKit
import SwiftUI
import ThemeKit

/// The sky presets from before themes (§7), kept only to migrate the old `sky.preset`
/// preference and the `MOTHERSHIP_SKY` debug switch to theme ids.
enum LegacySkyPreset: String, CaseIterable, Sendable {
    case auto, day, dusk, night, graphite, desktop

    var themeID: String {
        switch self {
        case .auto, .day: ThemeLibrary.defaultThemeID
        case .dusk: "golden-hour"
        case .night: "midnight"
        case .graphite: "graphite"
        case .desktop: "desktop"
        }
    }
}

/// The backdrop as it should look right now, for the active theme.
struct SkyState: Equatable, Sendable {
    enum Kind: Sendable {
        /// The theme's scene (`ThemeLibrary.scene(for:sunAltitude:)`), drawn by BackdropKit.
        case scene
        /// Behind-window blur of the wallpaper.
        case desktop
    }

    var kind: Kind
    var sun: SunPosition
    /// The sky itself is dark (text drawn on it is white; light glass needs a lift).
    var isDark: Bool
    var themeID: String = ThemeLibrary.defaultThemeID
    var scene: ThemeKit.Scene?

    /// "Golden hour", "Night"… for Settings.
    var phaseName: String {
        guard kind == .scene else { return "Desktop" }
        switch ThemeLibrary.phase(forSunAltitude: sun.altitude) {
        case .night: return "Night"
        case .twilight: return "Twilight"
        case .blueHour: return "Blue hour"
        case .goldenHour: return "Golden hour"
        case .day: return "Day"
        }
    }

    /// Brightness of the sky behind the chrome, for debug logs.
    var luminance: Double {
        guard let scene else { return 0 }
        return [0.2, 0.45].map { scene.color(at: $0).luminance }.reduce(0, +) / 2
    }
}

extension ThemeKit.Scene {
    /// The gradient's color at `location` (0 top … 1 bottom), linear between stops.
    func color(at location: Double) -> RGBA {
        guard let first = gradient.first else { return RGBA(red: 0, green: 0, blue: 0) }
        guard let upper = gradient.firstIndex(where: { $0.location >= location }) else { return gradient.last?.color ?? first.color }
        guard upper > 0 else { return first.color }
        let a = gradient[upper - 1], b = gradient[upper]
        let span = max(b.location - a.location, 0.0001)
        let t = (location - a.location) / span
        return RGBA(
            red: a.color.red + (b.color.red - a.color.red) * t, green: a.color.green + (b.color.green - a.color.green) * t,
            blue: a.color.blue + (b.color.blue - a.color.blue) * t
        )
    }

    /// Dark where chrome text would sit (the upper-middle of the window).
    var isDark: Bool {
        let samples = [0.2, 0.45].map { color(at: $0) }
        let luminance = samples.map(\.luminance).reduce(0, +) / Double(samples.count)
        return luminance < 0.2
    }
}
