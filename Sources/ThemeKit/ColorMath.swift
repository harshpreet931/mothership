import Foundation

/// A color in OKLab (Björn Ottosson): perceptually even, so blends between sky keyframes
/// don't dip through grey, and distances approximate how different two colors look.
public struct OKLab: Hashable, Sendable {
    /// Lightness, 0…1.
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// Chroma (colorfulness); below ~0.04 a color reads as grey.
    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// Hue angle in degrees, 0…360.
    public var hue: Double {
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Euclidean distance in OKLab (ΔE_OK). ~0.02 is barely visible; 0.1 is clearly different.
    public func distance(to other: OKLab) -> Double {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}

extension RGBA {
    public var oklab: OKLab {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(red), g = linear(green), b = linear(blue)
        let l = cbrt(0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b)
        let m = cbrt(0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b)
        let s = cbrt(0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b)
        return OKLab(
            l: 0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s,
            a: 1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s,
            b: 0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s
        )
    }

    public init(oklab: OKLab, alpha: Double = 1) {
        let l = pow(oklab.l + 0.396_337_777_4 * oklab.a + 0.215_803_757_3 * oklab.b, 3)
        let m = pow(oklab.l - 0.105_561_345_8 * oklab.a - 0.063_854_172_8 * oklab.b, 3)
        let s = pow(oklab.l - 0.089_484_177_5 * oklab.a - 1.291_485_548_0 * oklab.b, 3)
        func gamma(_ c: Double) -> Double {
            let clamped = min(max(c, 0), 1)
            return clamped <= 0.003_130_8 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        self.init(
            red: gamma(4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s),
            green: gamma(-1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s),
            blue: gamma(-0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s),
            alpha: alpha
        )
    }

    /// Perceptual blend: OKLab for the color, linear for alpha.
    public func mixed(with other: RGBA, t: Double) -> RGBA {
        if t <= 0 { return self }
        if t >= 1 { return other }
        let from = oklab, to = other.oklab
        let lab = OKLab(l: from.l + (to.l - from.l) * t, a: from.a + (to.a - from.a) * t, b: from.b + (to.b - from.b) * t)
        return RGBA(oklab: lab, alpha: alpha + (other.alpha - alpha) * t)
    }

    /// This color (with its alpha) laid over an opaque `background`, as the window server
    /// composites it (sRGB "over").
    public func composited(over background: RGBA) -> RGBA {
        RGBA(
            red: red * alpha + background.red * (1 - alpha), green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha), alpha: 1
        )
    }

    /// WCAG contrast ratio between two opaque colors (1…21).
    public func contrast(with other: RGBA) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }
}

enum ColorMath {
    /// Shortest angle between two hues, 0…180.
    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return difference > 180 ? 360 - difference : difference
    }

    /// Whether two colors would be mistaken for each other at a glance: nearly the same
    /// color (ΔE_OK < 0.1), or the same hue family at a similar colorfulness. A vivid orange
    /// still stands out against a pale peach of the same hue; it doesn't against a vivid one.
    static func confusable(_ x: RGBA, _ y: RGBA) -> Bool {
        let a = x.oklab, b = y.oklab
        let distance = a.distance(to: b)
        if distance < 0.1 { return true }
        let chromaA = a.chroma, chromaB = b.chroma
        guard chromaA >= 0.05, chromaB >= 0.05 else { return false }
        let similarColorfulness = min(chromaA, chromaB) / max(chromaA, chromaB) >= 0.6
        return hueDistance(a.hue, b.hue) < 22 && similarColorfulness && distance < 0.2
    }

    /// The gradient's color at `location` (stops sorted by location), blended in OKLab.
    static func color(in gradient: [GradientStop], at location: Double) -> RGBA? {
        guard let first = gradient.first, let last = gradient.last else { return nil }
        if location <= first.location { return first.color }
        if location >= last.location { return last.color }
        for (lower, upper) in zip(gradient, gradient.dropFirst()) where location <= upper.location {
            let span = upper.location - lower.location
            let t = span > 0 ? (location - lower.location) / span : 1
            return lower.color.mixed(with: upper.color, t: t)
        }
        return last.color
    }

    static func smoothstep(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
