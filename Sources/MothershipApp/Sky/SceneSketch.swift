import AppKit
import CoreGraphics
import ThemeKit

/// A still Core Graphics sketch of a ThemeKit scene: the fallback for gallery thumbnails
/// and for the layers the living sky doesn't draw natively, until BackdropKit's renderer
/// lands. Deterministic (seeded), so a scene always sketches the same.
enum SceneSketch {
    enum Parts {
        /// Everything (thumbnails).
        case all
        /// Only what `LivingSkyView` can't draw itself: aurora, nebula, sun, particles,
        /// grid and digital rain.
        case extras
    }

    static let nativeKinds: Set<SceneLayer.Kind> = [.stars, .shootingStars, .moon, .clouds, .grain]

    /// Whether `scene` has anything only the sketch can draw.
    static func hasExtras(_ scene: ThemeKit.Scene) -> Bool {
        scene.layers.contains { !nativeKinds.contains($0.kind) }
    }

    static func image(of scene: ThemeKit.Scene, size: CGSize, scale: CGFloat = 2, parts: Parts = .all) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Top-left origin, in points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(scene, in: context, size: size, parts: parts)
        return context.makeImage()
    }

    static func draw(_ scene: ThemeKit.Scene, in context: CGContext, size: CGSize, parts: Parts) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        if parts == .all {
            let colors = scene.gradient.map(\.color.cgColor) as CFArray
            let locations = scene.gradient.map { CGFloat($0.location) }
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            for glow in scene.glows ?? [] {
                radial(context, at: CGPoint(x: glow.center.x * size.width, y: glow.center.y * size.height),
                       radius: glow.radius * max(size.width, size.height), color: glow.color)
            }
        }
        var random = SplitMix(seed: 0x7E3E)
        // A retro floor hides what's below its horizon (Synthwave's sun sets into it).
        let horizon = scene.layers.first { $0.kind == .grid }.map { ($0.position?.y ?? 0.6) * size.height }
        for layer in scene.layers {
            if parts == .extras, nativeKinds.contains(layer.kind) { continue }
            context.saveGState()
            if let horizon, layer.kind == .sun || layer.kind == .moon {
                context.clip(to: CGRect(x: 0, y: 0, width: size.width, height: horizon))
            }
            draw(layer, in: context, size: size, random: &random)
            context.restoreGState()
        }
    }

    private static func draw(_ layer: SceneLayer, in context: CGContext, size: CGSize, random: inout SplitMix) {
        let opacity = layer.opacity ?? 1
        let colors = layer.colors ?? [RGBA(red: 1, green: 1, blue: 1)]
        let density = layer.density ?? 0.5
        let position = layer.position ?? UnitPoint2(x: 0.5, y: 0.3)
        let shorter = min(size.width, size.height)
        switch layer.kind {
        case .stars:
            let count = Int(40 + density * 220 * (size.width * size.height) / (1280 * 800))
            for index in 0 ..< count {
                let color = colors[index % colors.count]
                let r = random.range(0.4, 1.3)
                let center = CGPoint(x: random.unit() * size.width, y: pow(random.unit(), 1.4) * size.height * 0.9)
                context.setFillColor(color.withAlpha(opacity * random.range(0.35, 1)).cgColor)
                context.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
        case .shootingStars:
            let start = CGPoint(x: size.width * 0.62, y: size.height * 0.12)
            streak(context, from: start, length: shorter * 0.22, angle: 0.5, color: colors[0], alpha: opacity * 0.8, width: 1.2)
        case .moon, .sun:
            let diameter = (layer.size ?? 0.1) * shorter
            let center = CGPoint(x: position.x * size.width, y: position.y * size.height)
            let base = colors[0]
            radial(context, at: center, radius: diameter * (layer.kind == .sun ? 2.4 : 1.6), color: base.withAlpha(opacity * (layer.kind == .sun ? 0.5 : 0.25)))
            let disc = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            if layer.kind == .sun, colors.count > 1 {
                // A sun shades from its first color at the top to its second at the bottom.
                context.saveGState()
                context.addEllipse(in: disc)
                context.clip()
                let shades = [base.withAlpha(opacity).cgColor, colors[1].withAlpha(opacity).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: shades, locations: [0, 1]) {
                    context.drawLinearGradient(gradient, start: CGPoint(x: disc.midX, y: disc.minY), end: CGPoint(x: disc.midX, y: disc.maxY), options: [])
                }
                context.restoreGState()
                return
            }
            context.setFillColor(base.withAlpha(opacity).cgColor)
            context.fillEllipse(in: disc)
            if colors.count > 1 {
                // A second color marks the surface (an Earth's land, a planet's band).
                context.setFillColor(colors[1].withAlpha(opacity * 0.7).cgColor)
                context.fillEllipse(in: CGRect(x: center.x - diameter * 0.2, y: center.y - diameter * 0.3, width: diameter * 0.35, height: diameter * 0.28))
            }
        case .clouds:
            let light = colors[0], shade = colors.count > 1 ? colors[1] : colors[0]
            // Soft banks: a few big overlapping puffs each, shaded underneath.
            let count = Int(2 + density * 4)
            for _ in 0 ..< count {
                let center = CGPoint(x: random.unit() * size.width, y: random.range(0.1, 0.8) * size.height)
                let width = random.range(0.3, 0.55) * size.width
                for puff in 0 ..< 5 {
                    let t = Double(puff) / 4
                    let dx = (t - 0.5) * width * 0.75
                    let dy = -sin(t * .pi) * width * 0.08
                    let r = width * random.range(0.2, 0.3)
                    radial(context, at: CGPoint(x: center.x + dx, y: center.y + dy + r * 0.35), radius: r, color: shade.withAlpha(opacity * 0.22))
                    radial(context, at: CGPoint(x: center.x + dx, y: center.y + dy), radius: r, color: light.withAlpha(opacity * 0.34))
                }
            }
        case .aurora:
            for (index, color) in colors.enumerated() {
                let x = (position.x + Double(index) * 0.16 - 0.1) * size.width
                for step in 0 ..< 8 {
                    let t = Double(step) / 7
                    let center = CGPoint(x: x + sin(t * .pi * 1.5 + Double(index)) * size.width * 0.12 + t * size.width * 0.3,
                                         y: (position.y + (t - 0.5) * 0.12) * size.height)
                    radial(context, at: center, radius: (layer.size ?? 0.4) * shorter * 0.45, color: color.withAlpha(opacity * 0.32))
                }
            }
        case .nebula:
            for (index, color) in colors.enumerated() {
                let center = CGPoint(x: (position.x + random.range(-0.12, 0.12)) * size.width, y: (position.y + random.range(-0.1, 0.1)) * size.height)
                radial(context, at: center, radius: (layer.size ?? 0.5) * shorter * (0.6 + Double(index) * 0.2), color: color.withAlpha(opacity * 0.5))
            }
        case .particles:
            particles(layer, in: context, size: size, colors: colors, opacity: opacity, random: &random)
        case .grid:
            let horizon = position.y * size.height
            let color = colors[0].withAlpha(opacity).cgColor
            context.setStrokeColor(color)
            context.setLineWidth(1)
            let vanishing = CGPoint(x: position.x * size.width, y: horizon)
            for index in -12 ... 12 {
                context.move(to: vanishing)
                context.addLine(to: CGPoint(x: vanishing.x + Double(index) * size.width * 0.12, y: size.height))
            }
            var y = horizon + 2.0
            var gap = 3.0
            while y < size.height {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: size.width, y: y))
                y += gap
                gap *= 1.35
            }
            context.strokePath()
        case .digitalRain:
            let columns = Int(size.width / 14)
            for column in 0 ..< columns where random.unit() < 0.35 + density * 0.4 {
                let x = Double(column) * 14 + 4
                var y = random.range(-0.2, 0.8) * size.height
                let length = Int(random.range(4, 16))
                for cell in 0 ..< length {
                    let fade = Double(cell) / Double(length)
                    context.setFillColor(colors[cell % colors.count].withAlpha(opacity * (0.15 + fade * 0.85)).cgColor)
                    context.fill(CGRect(x: x, y: y, width: 5, height: 7))
                    y += 11
                }
            }
        case .grain:
            break
        }
    }

    private static func particles(_ layer: SceneLayer, in context: CGContext, size: CGSize, colors: [RGBA], opacity: Double, random: inout SplitMix) {
        let count = Int(30 + (layer.density ?? 0.5) * 160)
        let base = (layer.size ?? 0.3)
        let angle = (layer.direction ?? 0) * .pi / 180
        for index in 0 ..< count {
            let color = colors[index % colors.count]
            let point = CGPoint(x: random.unit() * size.width, y: random.unit() * size.height)
            let alpha = opacity * random.range(0.4, 1)
            switch layer.particle ?? .dust {
            case .rain:
                let length = 8 + base * 18
                let dx = sin(angle) * length, dy = cos(angle) * length
                context.setStrokeColor(color.withAlpha(alpha * 0.7).cgColor)
                context.setLineWidth(0.8)
                context.move(to: point)
                context.addLine(to: CGPoint(x: point.x + dx, y: point.y + dy))
                context.strokePath()
            case .snow, .dust:
                let r = random.range(0.6, 1.6) * (0.5 + base * 2)
                context.setFillColor(color.withAlpha(alpha).cgColor)
                context.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
            case .petals, .leaves:
                let r = random.range(2, 4) * (0.6 + base)
                context.saveGState()
                context.translateBy(x: point.x, y: point.y)
                context.rotate(by: random.range(0, .pi))
                context.setFillColor(color.withAlpha(alpha).cgColor)
                context.fillEllipse(in: CGRect(x: -r, y: -r * 0.55, width: r * 2, height: r * 1.1))
                context.restoreGState()
            case .embers, .fireflies:
                let r = random.range(0.8, 1.8) * (0.6 + base)
                radial(context, at: point, radius: r * 4, color: color.withAlpha(alpha * 0.45))
                context.setFillColor(color.withAlpha(alpha).cgColor)
                context.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
            case .bubbles:
                let r = random.range(1.5, 4) * (0.6 + base)
                context.setStrokeColor(color.withAlpha(alpha * 0.7).cgColor)
                context.setLineWidth(0.8)
                context.strokeEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
            }
        }
    }

    private static func radial(_ context: CGContext, at center: CGPoint, radius: CGFloat, color: RGBA) {
        guard radius > 0, color.alpha > 0.001 else { return }
        let colors = [color.cgColor, color.withAlpha(color.alpha * 0.4).cgColor, color.withAlpha(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.4, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    private static func streak(_ context: CGContext, from start: CGPoint, length: CGFloat, angle: Double, color: RGBA, alpha: Double, width: CGFloat) {
        let end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        let colors = [color.withAlpha(0).cgColor, color.withAlpha(alpha).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
        context.saveGState()
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
    }
}

extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    func withAlpha(_ value: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: min(max(value, 0), 1))
    }
}
