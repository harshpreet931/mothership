import AppKit
import Foundation

/// Where the sun is, from the date and approximate coordinates (NOAA's solar position
/// approximation; minutes of accuracy are plenty for a backdrop).
struct SunPosition: Equatable, Sendable {
    /// Degrees above the horizon (negative below).
    var altitude: Double
    /// True before solar noon (sun in the east).
    var isMorning: Bool

    static func at(_ date: Date, latitude: Double, longitude: Double, timeZone: TimeZone = .current) -> SunPosition {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .hour, .minute, .second], from: date)
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let hour = Double(parts.hour ?? 12)
        let minute = Double(parts.minute ?? 0)
        let second = Double(parts.second ?? 0)
        let zoneHours = Double(timeZone.secondsFromGMT(for: date)) / 3600

        let gamma = 2 * Double.pi / 365 * (dayOfYear - 1 + (hour - 12) / 24)
        let equationOfTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let offset = equationOfTime + 4 * longitude - 60 * zoneHours
        let trueSolarMinutes = hour * 60 + minute + second / 60 + offset
        let hourAngle = (trueSolarMinutes / 4 - 180) * .pi / 180
        let lat = latitude * .pi / 180
        let cosZenith = sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle)
        let zenith = acos(min(max(cosZenith, -1), 1))
        return SunPosition(altitude: 90 - zenith * 180 / .pi, isMorning: hourAngle < 0)
    }
}

/// Approximate coordinates without asking for location: a small table of time zones
/// (where most people in that zone live), else the zone's meridian from its UTC offset and
/// a regional latitude (20°N by default).
enum ApproximateLocation {
    static func current(timeZone: TimeZone = .current, date: Date = Date()) -> (latitude: Double, longitude: Double) {
        if let known = byZone[timeZone.identifier] { return known }
        let longitude = Double(timeZone.secondsFromGMT(for: date)) / 3600 * 15
        return (latitudeByRegion(timeZone.identifier), longitude)
    }

    /// (latitude, longitude). Offsets alone are off by up to ~20° in places (Madrid, India,
    /// China), which moves sunset by an hour.
    private static let byZone: [String: (latitude: Double, longitude: Double)] = [
        "Asia/Kolkata": (20, 77.5), "Asia/Calcutta": (20, 77.5), "Asia/Tokyo": (35.7, 139.7),
        "Asia/Shanghai": (31.2, 116.4), "Asia/Singapore": (1.3, 103.8), "Asia/Dubai": (25.2, 55.3),
        "Asia/Seoul": (37.6, 127), "Asia/Hong_Kong": (22.3, 114.2), "Asia/Jakarta": (-6.2, 106.8),
        "Europe/London": (51.5, -0.1), "Europe/Dublin": (53.3, -6.3), "Europe/Paris": (48.9, 2.4),
        "Europe/Berlin": (52.5, 13.4), "Europe/Madrid": (40.4, -3.7), "Europe/Amsterdam": (52.4, 4.9),
        "Europe/Stockholm": (59.3, 18.1), "Europe/Moscow": (55.8, 37.6), "Europe/Lisbon": (38.7, -9.1),
        "America/New_York": (40.7, -74), "America/Chicago": (41.9, -87.6), "America/Denver": (39.7, -105),
        "America/Los_Angeles": (34.1, -118.2), "America/Toronto": (43.7, -79.4), "America/Mexico_City": (19.4, -99.1),
        "America/Sao_Paulo": (-23.6, -46.6), "America/Buenos_Aires": (-34.6, -58.4), "Australia/Sydney": (-33.9, 151.2),
        "Australia/Melbourne": (-37.8, 145), "Pacific/Auckland": (-36.8, 174.8), "Africa/Johannesburg": (-26.2, 28),
        "Africa/Lagos": (6.5, 3.4), "Africa/Cairo": (30, 31.2),
    ]

    private static func latitudeByRegion(_ identifier: String) -> Double {
        if identifier.hasPrefix("Australia") || identifier.hasPrefix("Antarctica") { return -30 }
        if identifier.hasPrefix("Europe") { return 48 }
        if identifier.hasPrefix("America") { return 35 }
        return 20
    }
}

/// The sky's colors for a sun altitude, interpolated continuously between keyframes
/// (night < −12° < twilight < −6° < blue hour < 0° < golden hour < 8° < day).
struct SkyPalette: Equatable, Sendable {
    var top: RGB
    var middle: RGB
    var horizon: RGB
    /// Warm glow where the sun is; alpha carries its strength.
    var glow: RGB
    var glowStrength: Double
    /// 0…1: how visible stars (and the moon) are.
    var stars: Double
    /// 0…1: cloud opacity, and their tint.
    var clouds: Double
    var cloudTint: RGB

    /// Relative luminance of the sky behind the chrome (mostly its upper half), which
    /// drives light/dark chrome: Day ≈ 0.33, golden hour ≈ 0.3, sunset ≈ 0.18, night < 0.02.
    var luminance: Double { middle.luminance * 0.6 + top.luminance * 0.4 }
    /// Light chrome only once the sky is properly lit (the sun ~2° up).
    var isDark: Bool { luminance < 0.2 }

    static func forAltitude(_ altitude: Double) -> SkyPalette {
        let keys = Self.keyframes
        guard let upper = keys.firstIndex(where: { $0.altitude >= altitude }) else { return keys[keys.count - 1].palette }
        guard upper > 0 else { return keys[0].palette }
        let a = keys[upper - 1], b = keys[upper]
        let t = (altitude - a.altitude) / (b.altitude - a.altitude)
        return a.palette.mixed(with: b.palette, t: smooth(t))
    }

    /// Flat near-black for the Graphite preset: no glow, stars or clouds.
    static let graphite = SkyPalette(
        top: RGB(0x1A1B1F), middle: RGB(0x1E1F23), horizon: RGB(0x24262B), glow: RGB(0x24262B),
        glowStrength: 0, stars: 0, clouds: 0, cloudTint: RGB(0xFFFFFF)
    )

    func mixed(with other: SkyPalette, t: Double) -> SkyPalette {
        SkyPalette(
            top: top.mixed(with: other.top, t: t), middle: middle.mixed(with: other.middle, t: t),
            horizon: horizon.mixed(with: other.horizon, t: t), glow: glow.mixed(with: other.glow, t: t),
            glowStrength: glowStrength + (other.glowStrength - glowStrength) * t,
            stars: stars + (other.stars - stars) * t, clouds: clouds + (other.clouds - clouds) * t,
            cloudTint: cloudTint.mixed(with: other.cloudTint, t: t)
        )
    }

    private static func smooth(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    private static let keyframes: [(altitude: Double, palette: SkyPalette)] = [
        // Deep night.
        (-18, SkyPalette(top: RGB(0x050814), middle: RGB(0x0B1128), horizon: RGB(0x161B3A), glow: RGB(0x2A2350), glowStrength: 0.0, stars: 1, clouds: 0, cloudTint: RGB(0x8890B8))),
        // Night/twilight edge.
        (-12, SkyPalette(top: RGB(0x080D20), middle: RGB(0x141B3E), horizon: RGB(0x2A2C5C), glow: RGB(0x4B3A78), glowStrength: 0.15, stars: 0.9, clouds: 0.05, cloudTint: RGB(0x8890C0))),
        // Twilight → blue hour.
        (-6, SkyPalette(top: RGB(0x15214A), middle: RGB(0x2E3F7A), horizon: RGB(0x7E6AA6), glow: RGB(0xE38A84), glowStrength: 0.45, stars: 0.35, clouds: 0.25, cloudTint: RGB(0xC79BBE))),
        // Sunrise / sunset.
        (0, SkyPalette(top: RGB(0x2F4D8F), middle: RGB(0x6E86C2), horizon: RGB(0xF2A98A), glow: RGB(0xFFB46A), glowStrength: 0.85, stars: 0, clouds: 0.55, cloudTint: RGB(0xFFC2A6))),
        // Golden hour.
        (8, SkyPalette(top: RGB(0x3E73CF), middle: RGB(0x79A6E3), horizon: RGB(0xF3D7B5), glow: RGB(0xFFD08A), glowStrength: 0.5, stars: 0, clouds: 0.8, cloudTint: RGB(0xFFF3E4))),
        // Day.
        // Day: a saturated cornflower zenith fading to a pale horizon, so the sky still reads
        // as sky around dark glass (content-led tone keeps a dark terminal's chrome dark).
        (20, SkyPalette(top: RGB(0x2B6AD8), middle: RGB(0x5C97E8), horizon: RGB(0xCBE1F6), glow: RGB(0xFFF4DC), glowStrength: 0.25, stars: 0, clouds: 0.95, cloudTint: RGB(0xFFFFFF))),
        (60, SkyPalette(top: RGB(0x2463D5), middle: RGB(0x5492E6), horizon: RGB(0xC2DBF5), glow: RGB(0xFFFFFF), glowStrength: 0.15, stars: 0, clouds: 0.95, cloudTint: RGB(0xFFFFFF))),
    ]
}

struct RGB: Equatable, Sendable {
    var r: Double, g: Double, b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    func mixed(with other: RGB, t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    func cgColor(alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
