import AppKit
import SwiftUI

/// Sky presets (§7). `auto` follows the sun; Day, Dusk and Night pin it; Graphite is flat
/// near-black; Desktop lets the wallpaper through.
enum SkyPreset: String, CaseIterable, Codable, Sendable {
    case auto, day, dusk, night, graphite, desktop

    var title: String {
        switch self {
        case .auto: "Follows the sun"
        case .day: "Day"
        case .dusk: "Dusk"
        case .night: "Night"
        case .graphite: "Graphite"
        case .desktop: "Desktop"
        }
    }

    /// Short label under a swatch.
    var shortTitle: String { self == .auto ? "Sun" : title }

    /// The sun a manual preset pins (an evening sun, so Dusk glows in the west).
    var pinnedSun: SunPosition? {
        switch self {
        case .day: SunPosition(altitude: 34, isMorning: false)
        case .dusk: SunPosition(altitude: -3.5, isMorning: false)
        case .night: SunPosition(altitude: -26, isMorning: false)
        case .auto, .graphite, .desktop: nil
        }
    }

    /// What the sky shows for this preset, given the real sun.
    func state(sun: SunPosition, systemDark: Bool) -> SkyState {
        switch self {
        case .graphite:
            return SkyState(kind: .graphite, palette: .graphite, sun: sun, isDark: true)
        case .desktop:
            return SkyState(kind: .desktop, palette: .graphite, sun: sun, isDark: systemDark)
        case .auto, .day, .dusk, .night:
            let shown = pinnedSun ?? sun
            let palette = SkyPalette.forAltitude(shown.altitude)
            return SkyState(kind: .living, palette: palette, sun: shown, isDark: palette.isDark)
        }
    }

    /// Top → middle → horizon, for Settings swatches.
    var swatch: [Color] {
        let palette: SkyPalette = switch self {
        case .graphite, .desktop: .graphite
        default: SkyPalette.forAltitude(pinnedSun?.altitude ?? 34)
        }
        return [palette.top, palette.middle, palette.horizon].map(\.color)
    }
}

/// The sky as it should look right now.
struct SkyState: Equatable, Sendable {
    enum Kind: Sendable { case living, graphite, desktop }

    var kind: Kind
    var palette: SkyPalette
    var sun: SunPosition
    /// Dark chrome over this sky (from its luminance; Desktop follows the system).
    var isDark: Bool

    /// "Golden hour", "Night"… for Settings.
    var phaseName: String {
        switch kind {
        case .graphite: return "Graphite"
        case .desktop: return "Desktop"
        case .living:
            let altitude = sun.altitude
            if altitude < -12 { return "Night" }
            if altitude < -6 { return "Twilight" }
            if altitude < 0 { return "Blue hour" }
            if altitude < 8 { return "Golden hour" }
            return "Day"
        }
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
