import AppKit
import ThemeKit

/// Tiny deterministic PRNG so stars, clouds, scatters and noise never shimmer between renders.
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

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func range(_ lower: Double, _ upper: Double) -> Double { lower + unit() * (upper - lower) }

    /// Roughly normal around 0 (sum of three uniforms), in −1…1.
    mutating func centered() -> Double { (unit() + unit() + unit()) / 1.5 - 1 }
}

/// FNV-1a: a stable seed from a string (Swift's `Hasher` is randomized per process).
func stableSeed(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x0000_0100_0000_01B3
    }
    return hash
}

extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// The color with its alpha multiplied by `factor`.
    func cgColor(alpha factor: Double) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: max(0, min(1, alpha * factor)))
    }

    /// Straight sRGB interpolation (cheap; ThemeKit's `mixed(with:t:)` blends in OKLab).
    func lerp(_ other: RGBA, _ t: Double) -> RGBA {
        RGBA(
            red: red + (other.red - red) * t, green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t, alpha: alpha + (other.alpha - alpha) * t
        )
    }

    func with(alpha: Double) -> RGBA { RGBA(red: red, green: green, blue: blue, alpha: alpha) }

    static let white = RGBA(red: 1, green: 1, blue: 1)

    /// `#RRGGBB` literals for built-in defaults.
    init(_ hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// How the relative 0…1 fields scale a renderer's defaults: 0.5 is the renderer's own look,
/// and each end is a factor of `range` away (log-symmetric, so 0 and 1 feel equally far).
enum Relative {
    static func factor(_ value: Double?, range: Double) -> Double {
        guard let value, value.isFinite else { return 1 }
        return pow(range, (min(max(value, 0), 1) - 0.5) * 2)
    }
}

extension SceneLayer {
    /// 0 → ¼×, 0.5 → 1×, 1 → 4× as many.
    var densityFactor: Double { Relative.factor(density, range: 4) }
    /// 0 → ¼×, 0.5 → 1×, 1 → 4× as fast.
    var speedFactor: Double { Relative.factor(speed, range: 4) }
    /// 0 → 0.4×, 0.5 → 1×, 1 → 2.5× as large.
    var sizeFactor: Double { Relative.factor(size, range: 2.5) }

    /// The layer's tints, or `defaults` when it has none.
    func palette(_ defaults: [RGBA]) -> [RGBA] {
        if let colors, !colors.isEmpty { return colors }
        return defaults
    }

    /// Radians, from `direction` degrees (0 = down, 90 = toward the right).
    var directionRadians: Double { (direction ?? 0) * .pi / 180 }

    /// Equal apart from `opacity`, which can animate in place.
    func matchesIgnoringOpacity(_ other: SceneLayer) -> Bool {
        var copy = other
        copy.opacity = opacity
        return copy == self
    }
}

/// Gradients as `CAGradientLayer` colors and locations, stops exactly as written (two at
/// one location make a hard edge). To morph between gradients with different stops, both are
/// expressed at the union of their locations, so the arrays line up.
enum GradientSampler {
    struct Shape: Equatable {
        var colors: [RGBA]
        var locations: [Double]
    }

    static func sorted(_ stops: [GradientStop]) -> [GradientStop] {
        // Stable: stops at one location keep their order (the hard edge's two sides).
        stops.enumerated().sorted { ($0.element.location, $0.offset) < ($1.element.location, $1.offset) }.map(\.element)
    }

    static func shape(_ stops: [GradientStop]) -> Shape {
        let sorted = sorted(stops)
        guard !sorted.isEmpty else { return Shape(colors: [RGBA(0x000000), RGBA(0x000000)], locations: [0, 1]) }
        if sorted.count == 1 { return Shape(colors: [sorted[0].color, sorted[0].color], locations: [0, 1]) }
        return Shape(colors: sorted.map(\.color), locations: sorted.map { min(max($0.location, 0), 1) })
    }

    /// `a` and `b` at the same locations: each distinct location appears as many times as
    /// either gradient has stops there.
    static func aligned(_ a: [GradientStop], _ b: [GradientStop]) -> (from: Shape, to: Shape) {
        let first = shape(a), second = shape(b)
        var locations: [Double] = []
        let all = (first.locations + second.locations).sorted()
        var index = 0
        while index < all.count {
            let location = all[index]
            let multiplicity = max(first.locations.filter { abs($0 - location) < 1e-6 }.count, second.locations.filter { abs($0 - location) < 1e-6 }.count, 1)
            locations.append(contentsOf: Array(repeating: location, count: multiplicity))
            while index < all.count, abs(all[index] - location) < 1e-6 { index += 1 }
        }
        func sample(_ shape: Shape) -> [RGBA] {
            var seen: [Double: Int] = [:]
            return locations.map { location in
                let occurrence = seen[location, default: 0]
                seen[location] = occurrence + 1
                return color(shape, at: location, occurrence: occurrence)
            }
        }
        return (Shape(colors: sample(first), locations: locations), Shape(colors: sample(second), locations: locations))
    }

    /// The color at `location`; at a hard edge, `occurrence` picks the side.
    static func color(_ shape: Shape, at location: Double, occurrence: Int = 0) -> RGBA {
        let exact = shape.locations.indices.filter { abs(shape.locations[$0] - location) < 1e-6 }
        if !exact.isEmpty { return shape.colors[exact[min(occurrence, exact.count - 1)]] }
        guard let firstLocation = shape.locations.first, let lastLocation = shape.locations.last,
              let firstColor = shape.colors.first, let lastColor = shape.colors.last else { return RGBA(0x000000) }
        if location <= firstLocation { return firstColor }
        if location >= lastLocation { return lastColor }
        guard let upper = shape.locations.firstIndex(where: { $0 > location }), upper > 0 else { return lastColor }
        let low = shape.locations[upper - 1], high = shape.locations[upper]
        return shape.colors[upper - 1].lerp(shape.colors[upper], (location - low) / (high - low))
    }
}

/// What the scene clock is doing.
enum Motion: Equatable {
    case running
    /// Frozen where it is (`isAnimating = false`).
    case paused
    /// Reduce Motion or a still render: frozen, emitters shown as a static scatter.
    case still
}

/// Live in a view, or a one-off still render (which may show a mid-flight meteor).
enum Purpose { case live, thumbnail }

/// What every renderer needs to lay itself out.
struct NodeContext {
    var size: CGSize
    var scale: CGFloat
    /// Height of the top chrome band where the sky always shows (twinklers and the default
    /// moon favor it); 0 when there's no such band.
    var topBand: CGFloat
    var purpose: Purpose

    var area: Double { Double(size.width * size.height) }
    var isEmpty: Bool { size.width < 1 || size.height < 1 }

    /// Scene coordinates (0…1, y from the top) to layer coordinates (points, y up).
    func point(_ unit: UnitPoint2) -> CGPoint {
        CGPoint(x: unit.x * size.width, y: (1 - unit.y) * size.height)
    }

    func point(x: Double, fromTop y: Double) -> CGPoint {
        CGPoint(x: x, y: size.height - y)
    }
}

@MainActor
enum Timing {
    /// Loops start at the scene clock's epoch, so a frozen clock (`timeOffset`) shows the same
    /// frame every time: stills are deterministic.
    static let epoch: CFTimeInterval = 1e-6

    /// Ambient loops ask for at most 30 frames a second: slow drifts look the same, and the
    /// window server composites half the frames on a 60 Hz display (a quarter on ProMotion).
    /// Fast ones (a shooting star's streak) keep the display's rate.
    static var ambientFrameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)

    static func loop<Animation: CAAnimation>(_ animation: Animation, duration: CFTimeInterval, phase: Double = 0, autoreverses: Bool = false, fast: Bool = false) -> Animation {
        if !fast { animation.preferredFrameRateRange = ambientFrameRate }
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.autoreverses = autoreverses
        animation.beginTime = epoch
        animation.timeOffset = phase * duration * (autoreverses ? 2 : 1)
        animation.isRemovedOnCompletion = false
        return animation
    }

    static var easeInOut: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
    static var linear: CAMediaTimingFunction { CAMediaTimingFunction(name: .linear) }
}

extension CALayer {
    /// Sets properties without implicit animations.
    static func quietly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
