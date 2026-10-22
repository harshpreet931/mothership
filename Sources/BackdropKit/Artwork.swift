import AppKit
import CoreImage
import CoreText
import ThemeKit

/// Procedural images, drawn once and cached. Sprites are white or grayscale so emitter cells
/// and layers tint them; artwork that can't be tinted afterwards (clouds, nebulae, glyphs)
/// is cached per color.
@MainActor
enum Artwork {
    private static var cache: [String: CGImage] = [:]

    private static func cached(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        if let image = cache[key] { return image }
        guard let image = make() else { return nil }
        // Bounded: themes use a handful of colors; a pathological user theme can't grow this forever.
        if cache.count > 400 { cache.removeAll() }
        cache[key] = image
        return image
    }

    nonisolated static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func radial(_ context: CGContext, center: CGPoint, radius: CGFloat, color: RGBA, alphas: [CGFloat], locations: [CGFloat]) {
        let colors = alphas.map { color.cgColor(alpha: Double($0)) } as CFArray
        guard let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: locations) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    static func blurred(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input, kCIInputRadiusKey: radius]),
              let output = filter.outputImage else { return image }
        return ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: sRGB) ?? image
    }

    // MARK: Sky

    /// A star with a soft halo, 32 px.
    static var softDot: CGImage? {
        cached("softDot") {
            guard let context = bitmap(width: 32, height: 32) else { return nil }
            radial(context, center: CGPoint(x: 16, y: 16), radius: 16, color: .white, alphas: [1, 0.55, 0.12, 0], locations: [0, 0.14, 0.42, 1])
            return context.makeImage()
        }
    }

    /// A soft moon with a wide glow, 264 px; the disc is a fifth of the sprite.
    static func moon(_ tint: RGBA) -> CGImage? {
        cached("moon-\(tint.hex)") {
            let side = 264
            guard let context = bitmap(width: side, height: side) else { return nil }
            let center = CGPoint(x: Double(side) / 2, y: Double(side) / 2)
            let glow = tint.lerp(RGBA(0xDDE4FF), 0.5)
            radial(context, center: center, radius: CGFloat(side) / 2, color: glow, alphas: [0.34, 0.12, 0.04, 0], locations: [0, 0.2, 0.5, 1])
            let radius: CGFloat = 26
            context.saveGState()
            context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.clip()
            let shaded = tint.lerp(RGBA(0x9A9484), 0.22)
            if let shade = CGGradient(colorsSpace: sRGB, colors: [tint.cgColor, shaded.cgColor] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(shade, start: CGPoint(x: center.x - radius, y: center.y + radius), end: CGPoint(x: center.x + radius, y: center.y - radius), options: [])
            }
            // Faint maria.
            context.setFillColor(RGBA(0xBFB9AA).cgColor(alpha: 0.16))
            for (dx, dy, r) in [(-7.8, 6.5, 7.8), (6.5, -3.9, 5.2), (-2.6, -10.4, 3.9), (9.1, 9.1, 3.25)] {
                context.fillEllipse(in: CGRect(x: center.x + dx - r, y: center.y + dy - r, width: r * 2, height: r * 2))
            }
            context.restoreGState()
            return context.makeImage()
        }
    }

    /// The Earth seen from the Moon, 256 px with the disc 70 % across: ocean (`colors[0]`,
    /// shaded toward `colors[1]`), land in the most saturated other color, clouds in the
    /// lightest, lit from the upper left with the night side falling into shadow, and a thin
    /// atmosphere.
    static func earth(_ colors: [RGBA]) -> CGImage? {
        cached("earth-" + colors.map(\.hex).joined()) {
            let side = 256
            guard let context = bitmap(width: side, height: side), let ocean = colors.first else { return nil }
            let center = CGPoint(x: 128, y: 128)
            let radius = 89.6
            let deep = colors.count > 2 ? colors[1] : ocean.lerp(RGBA(0x0A1A40), 0.4)
            let others = colors.count > 2 ? Array(colors.dropFirst(2)) : Array(colors.dropFirst())
            func saturation(_ c: RGBA) -> Double { max(c.red, c.green, c.blue) - min(c.red, c.green, c.blue) }
            func lightness(_ c: RGBA) -> Double { c.red + c.green + c.blue }
            let light = others.max { lightness($0) < lightness($1) }
            let cloud = light.flatMap { lightness($0) > 2.2 ? $0 : nil } ?? RGBA(0xF2F7FF)
            let land = others.filter { $0 != cloud }.max { saturation($0) < saturation($1) } ?? RGBA(0x3E9E6A)
            radial(context, center: center, radius: 128, color: ocean.lerp(.white, 0.35), alphas: [0, 0, 0.3, 0.1, 0], locations: [0, 0.66, 0.71, 0.82, 1])
            context.saveGState()
            context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.clip()
            if let gradient = CGGradient(colorsSpace: sRGB, colors: [ocean.lerp(.white, 0.15).cgColor, ocean.cgColor, deep.cgColor] as CFArray, locations: [0, 0.45, 1]) {
                context.drawRadialGradient(gradient, startCenter: CGPoint(x: center.x - 30, y: center.y + 30), startRadius: 0, endCenter: center, endRadius: radius * 1.1, options: [.drawsAfterEndLocation])
            }
            var random = SplitMix(seed: 0xEA27)
            // Continents: soft-edged blobs of overlapping lobes.
            for _ in 0 ..< 4 {
                let c = CGPoint(x: center.x + random.centered() * radius * 0.65, y: center.y + random.centered() * radius * 0.65)
                for _ in 0 ..< 6 {
                    let lobe = CGPoint(x: c.x + random.centered() * 22, y: c.y + random.centered() * 16)
                    radial(context, center: lobe, radius: random.range(10, 22), color: land, alphas: [0.95, 0.85, 0], locations: [0, 0.7, 1])
                }
            }
            // Clouds: long soft bands and a few swirls.
            for _ in 0 ..< 14 {
                context.saveGState()
                let c = CGPoint(x: center.x + random.centered() * radius * 0.8, y: center.y + random.centered() * radius * 0.8)
                context.translateBy(x: c.x, y: c.y)
                context.rotate(by: random.range(-0.5, 0.5))
                context.scaleBy(x: random.range(2, 4), y: 1)
                radial(context, center: .zero, radius: random.range(5, 10), color: cloud, alphas: [0.75, 0.4, 0], locations: [0, 0.5, 1])
                context.restoreGState()
            }
            // Night side: lit from the upper left, dark toward the lower right.
            let night = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.15), CGColor(gray: 0, alpha: 0.88)] as CFArray
            if let shadow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: night, locations: [0, 0.55, 0.8]) {
                context.drawLinearGradient(shadow, start: CGPoint(x: center.x - radius, y: center.y + radius), end: CGPoint(x: center.x + radius, y: center.y - radius), options: [.drawsAfterEndLocation])
            }
            context.restoreGState()
            return context.makeImage()
        }
    }

    /// The sun's halo: a wide soft falloff with a brighter inner corona.
    static func sunGlow(_ color: RGBA) -> CGImage? {
        cached("sunGlow-\(color.hex)") {
            let side = 256
            guard let context = bitmap(width: side, height: side) else { return nil }
            radial(context, center: CGPoint(x: 128, y: 128), radius: 128, color: color, alphas: [0.9, 0.5, 0.18, 0.06, 0], locations: [0, 0.12, 0.3, 0.6, 1])
            return context.makeImage()
        }
    }

    /// The sun's disc: bright, slightly limb-darkened, with a crisp but antialiased edge.
    static func sunDisc(_ color: RGBA) -> CGImage? {
        cached("sunDisc-\(color.hex)") {
            let side = 128
            guard let context = bitmap(width: side, height: side) else { return nil }
            let center = CGPoint(x: 64, y: 64)
            let core = color.lerp(.white, 0.55)
            guard let gradient = CGGradient(colorsSpace: sRGB, colors: [core.cgColor, color.cgColor, color.cgColor(alpha: 0.9), color.cgColor(alpha: 0)] as CFArray, locations: [0, 0.7, 0.94, 1]) else { return nil }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 64, options: [])
            return context.makeImage()
        }
    }

    /// A retro sun: a vertical gradient through `colors` (top to bottom), with horizontal
    /// slits cut through its lower half that widen toward the bottom. 256 px, disc edge to edge.
    static func retroSun(_ colors: [RGBA]) -> CGImage? {
        cached("retroSun-" + colors.map(\.hex).joined()) {
            let side = 256
            guard let context = bitmap(width: side, height: side) else { return nil }
            context.addEllipse(in: CGRect(x: 1, y: 1, width: side - 2, height: side - 2))
            context.clip()
            // Slits: even-odd against the whole square cuts them out of the disc.
            context.addRect(CGRect(x: 0, y: 0, width: side, height: side))
            for index in 0 ..< 7 {
                let progress = Double(index) / 6
                let height = 3 + progress * 14
                let y = 112 - progress * 104 - height / 2
                context.addRect(CGRect(x: 0, y: y, width: Double(side), height: height))
            }
            context.clip(using: .evenOdd)
            let stops = colors.indices.map { CGFloat($0) / CGFloat(max(colors.count - 1, 1)) }
            if let gradient = CGGradient(colorsSpace: sRGB, colors: colors.map(\.cgColor) as CFArray, locations: stops) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 128, y: 256), end: CGPoint(x: 128, y: 0), options: [])
            }
            return context.makeImage()
        }
    }

    /// A procedural cloud: many faint puffs piled on a low dome with a shaded underside,
    /// then blurred so no single puff reads as a ball.
    static func cloud(seed: UInt64, tint: RGBA, shade: RGBA) -> CGImage? {
        cached("cloud-\(seed)-\(tint.hex)-\(shade.hex)") {
            let width = 480, height = 172
            guard let context = bitmap(width: width, height: height) else { return nil }
            var random = SplitMix(seed: seed)
            func centered() -> Double { (random.unit() + random.unit() + random.unit()) / 3 }
            for _ in 0 ..< 14 {
                let x = 80 + centered() * 320
                radial(context, center: CGPoint(x: x, y: random.range(50, 62)), radius: random.range(30, 48), color: shade, alphas: [0.22, 0.1, 0], locations: [0, 0.5, 1])
            }
            for _ in 0 ..< 46 {
                let u = centered()
                let x = 40 + u * 400
                let dome = sin(u * .pi)
                let y = 62 + dome * random.range(4, 38)
                let radius = 20 + dome * random.range(12, 30)
                radial(context, center: CGPoint(x: x, y: y), radius: radius, color: tint, alphas: [0.3, 0.16, 0], locations: [0, 0.5, 1])
            }
            guard let image = context.makeImage() else { return nil }
            return blurred(image, radius: 7)
        }
    }

    /// 64 px noise tiled against gradient banding: gray (lightens and darkens), or `tint`
    /// with the noise as alpha (paper tooth, colored film).
    static func noiseTile(tint: RGBA?) -> CGImage? {
        cached("noise-\(tint?.hex ?? "gray")") {
            let side = 64
            var random = SplitMix(seed: 0xA5A5)
            if let tint {
                guard let context = bitmap(width: side, height: side) else { return nil }
                for y in 0 ..< side {
                    for x in 0 ..< side {
                        context.setFillColor(tint.cgColor(alpha: random.unit()))
                        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
                return context.makeImage()
            }
            var pixels = [UInt8](repeating: 0, count: side * side)
            for index in pixels.indices { pixels[index] = UInt8(random.unit() * 255) }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }
    }

    // MARK: Aurora and nebula

    /// An aurora curtain as an alpha mask, two periods of 1024 × 256 side by side (so sliding
    /// it by one period loops): a folded lower edge that's brightest, fine vertical rays of
    /// varying height and strength, fading upward.
    static func auroraCurtain(seed: UInt64) -> CGImage? {
        cached("curtain-\(seed)") {
            let period = 1024, width = period * 2, height = 256
            guard let context = bitmap(width: width, height: height) else { return nil }
            var random = SplitMix(seed: seed)
            // Periodic in x (whole cycles per period), so the halves match.
            var folds: [(cycles: Double, amplitude: Double, phase: Double)] = []
            for index in 0 ..< 3 {
                let harmonic = Double(index + 1)
                folds.append((harmonic * random.range(2, 4).rounded(), random.range(7, 15) / harmonic, random.range(0, 2 * .pi)))
            }
            var rays: [(cycles: Double, weight: Double, phase: Double)] = []
            for index in 0 ..< 6 {
                rays.append((random.range(index < 3 ? 12 : 50, index < 3 ? 40 : 140).rounded(), index < 3 ? 1 : 0.6, random.range(0, 2 * .pi)))
            }
            let gray = CGColorSpaceCreateDeviceGray()
            for x in 0 ..< width {
                let u = Double(x) / Double(period)
                var edge = 70.0
                for fold in folds { edge += fold.amplitude * sin(2 * .pi * fold.cycles * u + fold.phase) }
                // Rays don't all start on one line: the brighter ones reach lower.
                var ray = 0.0, total = 0.0
                for wave in rays {
                    ray += wave.weight * sin(2 * .pi * wave.cycles * u + wave.phase)
                    total += wave.weight
                }
                let level = (ray / total + 1) / 2
                let strength = 0.2 + 0.8 * pow(level, 2.4)
                let reach = 70 + 130 * level
                edge -= 10 * level
                let alphas: [CGFloat] = [0, strength * 0.55, strength, strength * 0.7, strength * 0.28, 0]
                guard let gradient = CGGradient(colorsSpace: gray, colors: alphas.map { CGColor(gray: 1, alpha: $0) } as CFArray, locations: [0, 0.05, 0.12, 0.25, 0.55, 1]) else { continue }
                context.saveGState()
                context.clip(to: CGRect(x: x, y: 0, width: 1, height: height))
                context.drawLinearGradient(gradient, start: CGPoint(x: Double(x), y: edge - 3), end: CGPoint(x: Double(x), y: edge + reach), options: [])
                context.restoreGState()
            }
            guard let image = context.makeImage() else { return nil }
            return blurred(image, radius: 1.2)
        }
    }

    /// A cloudy nebula blob in `color`, 256 px: many puffs along a few curving filaments, a
    /// brighter heart, and darker dust lanes cut through it.
    static func nebula(seed: UInt64, color: RGBA) -> CGImage? {
        cached("nebula-\(seed)-\(color.hex)") {
            let side = 256
            guard let context = bitmap(width: side, height: side) else { return nil }
            var random = SplitMix(seed: seed)
            let heart = color.lerp(.white, 0.35)
            radial(context, center: CGPoint(x: 128, y: 128), radius: 120, color: color, alphas: [0.22, 0.1, 0], locations: [0, 0.55, 1])
            for _ in 0 ..< 4 {
                // A filament: puffs along a bent arc.
                var point = CGPoint(x: 128 + random.centered() * 50, y: 128 + random.centered() * 50)
                var angle = random.range(0, 2 * .pi)
                for _ in 0 ..< 12 {
                    radial(context, center: point, radius: random.range(14, 34), color: color, alphas: [random.range(0.12, 0.28), 0.05, 0], locations: [0, 0.55, 1])
                    angle += random.range(-0.5, 0.5)
                    point = CGPoint(x: point.x + cos(angle) * 12, y: point.y + sin(angle) * 12)
                }
            }
            for _ in 0 ..< 4 {
                let center = CGPoint(x: 128 + random.centered() * 28, y: 128 + random.centered() * 28)
                radial(context, center: center, radius: random.range(14, 30), color: heart, alphas: [0.28, 0.1, 0], locations: [0, 0.45, 1])
            }
            context.setBlendMode(.destinationOut)
            context.setLineCap(.round)
            for _ in 0 ..< 3 {
                context.setStrokeColor(CGColor(gray: 0, alpha: random.range(0.25, 0.45)))
                context.setLineWidth(random.range(6, 14))
                let start = CGPoint(x: random.range(40, 216), y: random.range(40, 216))
                context.move(to: start)
                context.addQuadCurve(to: CGPoint(x: start.x + random.centered() * 120, y: start.y + random.centered() * 120), control: CGPoint(x: random.range(40, 216), y: random.range(40, 216)))
                context.strokePath()
            }
            guard let image = context.makeImage() else { return nil }
            return blurred(image, radius: 6)
        }
    }

    // MARK: Particles (white, tinted by the cell)

    static var flake: CGImage? {
        cached("flake") {
            guard let context = bitmap(width: 32, height: 32) else { return nil }
            radial(context, center: CGPoint(x: 16, y: 16), radius: 16, color: .white, alphas: [1, 0.85, 0.35, 0], locations: [0, 0.3, 0.6, 1])
            return context.makeImage()
        }
    }

    /// A thin streak, brightest at its leading (lower) end.
    static var rainStreak: CGImage? {
        cached("rain") {
            guard let context = bitmap(width: 8, height: 96) else { return nil }
            let colors = [CGColor(gray: 1, alpha: 0.95), CGColor(gray: 1, alpha: 0.5), CGColor(gray: 1, alpha: 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.25, 1]) else { return nil }
            context.addPath(CGPath(roundedRect: CGRect(x: 2.5, y: 0, width: 3, height: 96), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: 4, y: 0), end: CGPoint(x: 4, y: 96), options: [])
            return context.makeImage()
        }
    }

    /// A sakura petal: a rounded teardrop with the notch at its tip, lighter at the base.
    /// `narrow` is the same petal seen edge-on mid-tumble.
    static func petal(narrow: Bool) -> CGImage? {
        cached("petal-\(narrow)") {
            let width = narrow ? 22 : 40, height = 48
            guard let context = bitmap(width: width, height: height) else { return nil }
            let w = CGFloat(width), h = CGFloat(height)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: w / 2, y: 2))
            path.addCurve(to: CGPoint(x: w * 0.38, y: h - 3), control1: CGPoint(x: -w * 0.1, y: h * 0.3), control2: CGPoint(x: w * 0.05, y: h * 0.95))
            path.addLine(to: CGPoint(x: w / 2, y: h - 9))
            path.addLine(to: CGPoint(x: w * 0.62, y: h - 3))
            path.addCurve(to: CGPoint(x: w / 2, y: 2), control1: CGPoint(x: w * 0.95, y: h * 0.95), control2: CGPoint(x: w * 1.1, y: h * 0.3))
            context.addPath(path)
            context.clip()
            let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.93, alpha: 0.95), CGColor(gray: 0.82, alpha: 0.9)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.6, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: w / 2, y: 0), end: CGPoint(x: w / 2, y: h), options: [])
            }
            return context.makeImage()
        }
    }

    /// An ember: a hot core in a soft halo.
    static var ember: CGImage? {
        cached("ember") {
            guard let context = bitmap(width: 24, height: 24) else { return nil }
            radial(context, center: CGPoint(x: 12, y: 12), radius: 12, color: .white, alphas: [1, 1, 0.5, 0.12, 0], locations: [0, 0.18, 0.4, 0.7, 1])
            return context.makeImage()
        }
    }

    /// A bubble: clear middle, a bright rim and a specular highlight. `turn` (radians) is
    /// how far the emitter is tilted, so the highlight is pre-rotated to stay up and left.
    static func bubble(turn: Double = 0) -> CGImage? {
        let degrees = Int((turn * 180 / .pi).rounded())
        return cached("bubble-\(degrees)") {
            let side = 64
            guard let context = bitmap(width: side, height: side) else { return nil }
            radial(context, center: CGPoint(x: 32, y: 32), radius: 31, color: .white, alphas: [0.04, 0.08, 0.5, 0.9, 0], locations: [0, 0.6, 0.86, 0.95, 1])
            func spot(_ dx: Double, _ dy: Double) -> CGPoint {
                let angle = -Double(degrees) * .pi / 180
                return CGPoint(x: 32 + dx * cos(angle) - dy * sin(angle), y: 32 + dx * sin(angle) + dy * cos(angle))
            }
            radial(context, center: spot(-10, 11), radius: 9, color: .white, alphas: [0.95, 0.4, 0], locations: [0, 0.45, 1])
            radial(context, center: spot(9, -11), radius: 5, color: .white, alphas: [0.35, 0], locations: [0, 1])
            return context.makeImage()
        }
    }

    /// A firefly's glow: a small bright core in a wide halo.
    static var firefly: CGImage? {
        cached("firefly") {
            guard let context = bitmap(width: 48, height: 48) else { return nil }
            radial(context, center: CGPoint(x: 24, y: 24), radius: 24, color: .white, alphas: [1, 0.9, 0.45, 0.15, 0], locations: [0, 0.12, 0.3, 0.6, 1])
            return context.makeImage()
        }
    }

    static var mote: CGImage? {
        cached("mote") {
            guard let context = bitmap(width: 12, height: 12) else { return nil }
            radial(context, center: CGPoint(x: 6, y: 6), radius: 6, color: .white, alphas: [0.9, 0.5, 0], locations: [0, 0.4, 1])
            return context.makeImage()
        }
    }

    /// Leaves: 0 an oval leaf with a midrib and veins, 1 a three-lobed maple-ish leaf.
    static func leaf(_ variant: Int) -> CGImage? {
        cached("leaf-\(variant)") {
            let side = 48
            guard let context = bitmap(width: side, height: side) else { return nil }
            let path = CGMutablePath()
            if variant == 0 {
                path.move(to: CGPoint(x: 24, y: 2))
                path.addCurve(to: CGPoint(x: 24, y: 46), control1: CGPoint(x: 2, y: 14), control2: CGPoint(x: 8, y: 38))
                path.addCurve(to: CGPoint(x: 24, y: 2), control1: CGPoint(x: 40, y: 38), control2: CGPoint(x: 46, y: 14))
            } else {
                let points: [(Double, Double)] = [(24, 2), (19, 14), (6, 12), (11, 24), (2, 32), (17, 33), (21, 46), (27, 46), (31, 33), (46, 32), (37, 24), (42, 12), (29, 14)]
                path.move(to: CGPoint(x: points[0].0, y: points[0].1))
                for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
                path.closeSubpath()
            }
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0.92, alpha: 1))
            context.fillPath()
            context.addPath(path)
            context.clip()
            let colors = [CGColor(gray: 1, alpha: 0.6), CGColor(gray: 0.7, alpha: 0.6)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 8, y: 40), end: CGPoint(x: 40, y: 8), options: [])
            }
            context.setStrokeColor(CGColor(gray: 0.55, alpha: 0.7))
            context.setLineWidth(1.4)
            context.move(to: CGPoint(x: 24, y: 2))
            context.addLine(to: CGPoint(x: 24, y: 44))
            for y in stride(from: 12.0, through: 36, by: 8) {
                context.move(to: CGPoint(x: 24, y: y))
                context.addLine(to: CGPoint(x: 14, y: y + 6))
                context.move(to: CGPoint(x: 24, y: y))
                context.addLine(to: CGPoint(x: 34, y: y + 6))
            }
            context.strokePath()
            return context.makeImage()
        }
    }

    // MARK: Digital rain

    static let glyphColumns = 8
    static let glyphsPerColumn = 26
    static let glyphCell = CGSize(width: 18, height: 22)

    /// Columns of glyphs, each brightening toward its head (the bottom), at 2×. Alternate
    /// columns use the second color; heads use the third (or a whitened first).
    static func glyphAtlas(_ colors: [RGBA]) -> CGImage? {
        cached("glyphs-" + colors.map(\.hex).joined()) {
            let scale = 2.0
            let cellWidth = glyphCell.width * scale, cellHeight = glyphCell.height * scale
            let width = Int(cellWidth) * glyphColumns, height = Int(cellHeight) * glyphsPerColumn
            guard let context = bitmap(width: width, height: height) else { return nil }
            let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜ0123456789:=*+<>")
            let font = CTFontCreateWithName("Menlo" as CFString, cellHeight * 0.72, nil)
            var random = SplitMix(seed: 0x6C79)
            for column in 0 ..< glyphColumns {
                for row in 0 ..< glyphsPerColumn {
                    // Row 0 is the top of the image (CG's y is up): the tail; the head is last.
                    let progress = Double(row + 1) / Double(glyphsPerColumn)
                    let isHead = row == glyphsPerColumn - 1
                    let body = colors[column % 2 == 1 && colors.count > 1 ? 1 : 0]
                    let tint = isHead ? (colors.count > 2 ? colors[2] : body.lerp(.white, 0.7)) : body
                    let alpha = isHead ? 1 : pow(progress, 1.8) * 0.85
                    let glyph = String(glyphs[Int(random.unit() * Double(glyphs.count)) % glyphs.count])
                    let attributes: [NSAttributedString.Key: Any] = [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): tint.cgColor(alpha: alpha),
                    ]
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: attributes))
                    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
                    let x = Double(column) * cellWidth + (cellWidth - bounds.width) / 2 - bounds.minX
                    let y = Double(height) - Double(row + 1) * cellHeight + (cellHeight - bounds.height) / 2 - bounds.minY
                    context.textPosition = CGPoint(x: x, y: y)
                    CTLineDraw(line, context)
                }
            }
            return context.makeImage()
        }
    }
}
