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
        /// Mothership Sky, drawn natively from the sun model (`SkyPalette`).
        case living
        /// Any other theme's scene (`ThemeLibrary.scene(for:sunAltitude:)`).
        case scene
        /// Behind-window blur of the wallpaper.
        case desktop
    }

    var kind: Kind
    var palette: SkyPalette
    var sun: SunPosition
    /// The sky itself is dark (text drawn on it is white; light glass needs a lift).
    var isDark: Bool
    var themeID: String = ThemeLibrary.defaultThemeID
    var scene: ThemeKit.Scene?

    /// "Golden hour", "Night"… for Settings.
    var phaseName: String {
        switch kind {
        case .desktop: return "Desktop"
        case .living, .scene:
            let altitude = sun.altitude
            if altitude < -12 { return "Night" }
            if altitude < -6 { return "Twilight" }
            if altitude < 0 { return "Blue hour" }
            if altitude < 8 { return "Golden hour" }
            return "Day"
        }
    }

    /// The native living sky at the sun's position.
    static func living(sun: SunPosition) -> SkyState {
        let palette = SkyPalette.forAltitude(sun.altitude)
        return SkyState(kind: .living, palette: palette, sun: sun, isDark: palette.isDark)
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

extension RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

/// Tiny deterministic PRNG so stars, clouds and noise never shimmer between renders.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func range(_ lower: Double, _ upper: Double) -> Double {
        lower + unit() * (upper - lower)
    }
}
