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
