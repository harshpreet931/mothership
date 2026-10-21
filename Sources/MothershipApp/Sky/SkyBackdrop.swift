import AppKit
import IOKit.ps
import Observation
import SwiftUI

/// Sky presets (§7). `auto` follows the time of day and the system appearance.
enum SkyPreset: String, CaseIterable, Codable, Sendable {
    case auto, day, dusk, night, graphite, desktop

    var title: String {
        switch self {
        case .auto: "Auto"
        case .day: "Day"
        case .dusk: "Dusk"
        case .night: "Night"
        case .graphite: "Graphite"
        case .desktop: "Desktop"
        }
    }

    /// The concrete sky for `auto`: Day while the system is light, Dusk around sunset and
    /// sunrise, Night otherwise.
    func resolved(systemDark: Bool, date: Date = Date()) -> SkyPreset {
        guard self == .auto else { return self }
        guard systemDark else { return .day }
        let hour = Calendar.current.component(.hour, from: date)
        return (17 ..< 21).contains(hour) || (5 ..< 7).contains(hour) ? .dusk : .night
    }

    /// Day pairs with light chrome; Dusk, Night and Graphite with dark. Desktop follows the system.
    func chromeIsDark(systemDark: Bool) -> Bool {
        switch resolved(systemDark: systemDark) {
        case .day: false
        case .dusk, .night, .graphite: true
        case .desktop, .auto: systemDark
        }
    }

    /// 3×3 mesh colors, row-major from the top-left.
    var meshColors: [Color] {
        let hexes: [UInt32] = switch self {
        case .day, .auto:
            [0x4A80CC, 0x5B8FD6, 0x7AA5DE,
             0x7C9FCB, 0xA6C0E0, 0xCAD9EB,
             0x8FA9C8, 0xC2CFDD, 0xE9EEF4]
        case .dusk:
            [0x3C4080, 0x4B4F8C, 0x5D5797,
             0x8B6EA5, 0xB98BB5, 0xCE98AE,
             0xE2A48D, 0xF2B38A, 0xF6C59F]
        case .night:
            [0x0B1020, 0x0E1429, 0x131A34,
             0x141B35, 0x1B2340, 0x231F3F,
             0x18182F, 0x2A1F3D, 0x1D1934]
        case .graphite:
            [0x1A1B1F, 0x1B1C20, 0x1C1D22,
             0x1E1F23, 0x202126, 0x212328,
             0x222428, 0x23252A, 0x24262B]
        case .desktop:
            Array(repeating: 0x000000, count: 9)
        }
        return hexes.map { hex in
            Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
    }

    /// Swatch for Settings.
    var swatch: [Color] {
        let colors = meshColors
        return [colors[0], colors[4], colors[8]]
    }
}

/// When the sky may move: idle only, never while typing (3 s), on battery or with Reduce Motion.
@MainActor
@Observable
final class SkyMotion {
    static let shared = SkyMotion()

    private(set) var paused = false
    @ObservationIgnored private var pausedSince: Date?
    @ObservationIgnored private var pausedTotal: TimeInterval = 0
    @ObservationIgnored private var lastKeystroke = Date.distantPast
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var onBattery = false
    /// Snapshots and tests pin the sky.
    @ObservationIgnored var forcePaused = false

    private init() {}

    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.keystroke() }
            return event
        }
        onBattery = Self.isOnBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    /// Seconds of drift time, which stands still while paused so resuming never jumps.
    func driftTime(at date: Date) -> TimeInterval {
        let pausedNow = pausedSince.map { date.timeIntervalSince($0) } ?? 0
        return date.timeIntervalSinceReferenceDate - pausedTotal - pausedNow
    }

    private func keystroke() {
        lastKeystroke = Date()
        update()
    }

    private var batteryCheck = 0

    private func update() {
        batteryCheck += 1
        if batteryCheck >= 30 {
            batteryCheck = 0
            onBattery = Self.isOnBattery()
        }
        let typing = Date().timeIntervalSince(lastKeystroke) < 3
        let shouldPause = forcePaused || typing || onBattery || SkyAccessibility.reduceMotion
        guard shouldPause != paused else { return }
        if shouldPause {
            pausedSince = Date()
        } else if let since = pausedSince {
            pausedTotal += Date().timeIntervalSince(since)
            pausedSince = nil
        }
        paused = shouldPause
    }

    private static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

/// The full-bleed sky: a drifting 3×3 mesh, a star grain at night, and 2 % noise.
struct SkyBackdrop: View {
    let preset: SkyPreset
    /// Fixed drift time for snapshots; nil animates.
    var frozenTime: TimeInterval?
    var motion = SkyMotion.shared

    var body: some View {
        if preset == .desktop {
            Color.clear
        } else if let frozenTime {
            layers(time: frozenTime)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: motion.paused)) { context in
                layers(time: motion.driftTime(at: context.date))
            }
        }
    }

    private func layers(time: TimeInterval) -> some View {
        ZStack {
            MeshGradient(width: 3, height: 3, points: Self.points(time: time), colors: preset.meshColors, smoothsColors: true)
            if preset == .day || preset == .auto { Clouds(time: time, opacity: 1) }
            if preset == .dusk { Clouds(time: time, opacity: 0.55) }
            if preset == .night { StarGrain() }
            NoiseOverlay()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Edge and center points wander on ~60 s loops; corners stay pinned.
    static func points(time: TimeInterval) -> [SIMD2<Float>] {
        let phase = time / 60 * 2 * .pi
        func wobble(_ seed: Double, _ amount: Double) -> Float {
            Float(sin(phase + seed) * amount)
        }
        return [
            [0, 0], [0.5 + wobble(0.3, 0.06), 0], [1, 0],
            [0, 0.5 + wobble(1.7, 0.07)], [0.5 + wobble(2.4, 0.08), 0.5 + wobble(4.1, 0.07)], [1, 0.5 + wobble(3.3, 0.06)],
            [0, 1], [0.5 + wobble(5.2, 0.07), 1], [1, 1],
        ]
    }
}

/// Soft, heavily diffused cloud banks (Hark's blurred sky photo, procedurally): stretched
/// radial washes of white that drift a few points per minute.
struct Clouds: View {
    let time: TimeInterval
    let opacity: Double

    /// (x, y, radius, stretch, alpha) in unit space.
    private static let banks: [(Double, Double, Double, Double, Double)] = [
        (0.18, 0.30, 0.16, 2.6, 0.20), (0.62, 0.22, 0.12, 3.2, 0.16), (0.88, 0.42, 0.18, 2.2, 0.24),
        (0.30, 0.68, 0.22, 2.4, 0.30), (0.72, 0.78, 0.26, 2.0, 0.38), (0.08, 0.92, 0.20, 2.8, 0.26),
        (0.50, 0.50, 0.14, 3.0, 0.14),
    ]

    var body: some View {
        Canvas { context, size in
            let drift = time / 60 * 2 * .pi
            for (index, bank) in Self.banks.enumerated() {
                let (x, y, radius, stretch, alpha) = bank
                let dx = sin(drift + Double(index) * 1.3) * 0.012
                let center = CGPoint(x: (x + dx) * size.width, y: y * size.height)
                let r = radius * max(size.width, size.height) * 0.5
                var layer = context
                layer.translateBy(x: center.x, y: center.y)
                layer.scaleBy(x: stretch, y: 1)
                let gradient = Gradient(stops: [
                    .init(color: .white.opacity(alpha * opacity), location: 0),
                    .init(color: .white.opacity(alpha * opacity * 0.45), location: 0.45),
                    .init(color: .white.opacity(0), location: 1),
                ])
                layer.fill(
                    Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)),
                    with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: r)
                )
            }
        }
    }
}

/// Faint deterministic stars for the Night sky.
struct StarGrain: View {
    var body: some View {
        Canvas { context, size in
            var generator = SplitMix(seed: 0x5EED)
            for _ in 0 ..< 140 {
                let x = generator.unit() * size.width
                let y = generator.unit() * size.height * 0.85
                let radius = 0.4 + generator.unit() * 0.9
                let alpha = 0.15 + generator.unit() * 0.45
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)), with: .color(.white.opacity(alpha)))
            }
        }
    }
}

/// 2 % monochrome noise against gradient banding.
struct NoiseOverlay: View {
    var body: some View {
        if let image = Self.tile {
            Image(decorative: image, scale: 2)
                .resizable(resizingMode: .tile)
                .opacity(0.02)
        }
    }

    @MainActor private static let tile: CGImage? = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side)
        var generator = SplitMix(seed: 0xA5A5)
        for index in pixels.indices { pixels[index] = UInt8(generator.unit() * 255) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }()
}

/// Tiny deterministic PRNG so stars and noise never shimmer between renders.
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
}
