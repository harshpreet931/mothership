import Foundation

/// Continuous blends between sun-phase scenes, so the sky never jumps.
///
/// Each phase sits at an anchor altitude (night −18°, twilight −9°, blue hour −3°, golden
/// hour 4°, day 20°). Between the two nearest defined phases the scene is blended with a
/// smoothstep: gradient stops in OKLab (resampled at the union of both gradients' stop
/// locations), glows pairwise by index (so the sun's glow rises), and layers matched by kind
/// and particle (values interpolated; a layer only one side has fades by opacity). Below the
/// first anchor and above the last, the end scenes hold.
public enum SceneBlending {
    public static let anchors: [(phase: SunPhase, altitude: Double)] = [
        (.night, -18), (.twilight, -9), (.blueHour, -3), (.goldenHour, 4), (.day, 20),
    ]

    public static func scene(phases: [SunPhase: Scene], altitude: Double) -> Scene? {
        let keyframes = anchors.compactMap { anchor in phases[anchor.phase].map { (altitude: anchor.altitude, scene: $0) } }
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        guard altitude.isFinite else { return first.scene }
        if altitude <= first.altitude { return first.scene }
        if altitude >= last.altitude { return last.scene }
        for (lower, upper) in zip(keyframes, keyframes.dropFirst()) where altitude <= upper.altitude {
            let t = ColorMath.smoothstep((altitude - lower.altitude) / (upper.altitude - lower.altitude))
            return blend(lower.scene, upper.scene, t: t)
        }
        return last.scene
    }

    /// `a` at t = 0, `b` at t = 1, continuous in between.
    public static func blend(_ a: Scene, _ b: Scene, t: Double) -> Scene {
        if t <= 0 { return a }
        if t >= 1 { return b }
        return Scene(gradient: blendGradients(a.gradient, b.gradient, t: t), glows: blendGlows(a.glows, b.glows, t: t), layers: blendLayers(a.layers, b.layers, t: t))
    }

    static func blendGradients(_ a: [GradientStop], _ b: [GradientStop], t: Double) -> [GradientStop] {
        let sortedA = a.sorted { $0.location < $1.location }
        let sortedB = b.sorted { $0.location < $1.location }
        var locations: [Double] = []
        for location in (sortedA + sortedB).map(\.location).sorted() where locations.last.map({ location - $0 > 0.0005 }) ?? true {
            locations.append(location)
        }
        return locations.compactMap { location in
            guard let from = ColorMath.color(in: sortedA, at: location), let to = ColorMath.color(in: sortedB, at: location) else { return nil }
            return GradientStop(color: from.mixed(with: to, t: t), location: location)
        }
    }

    static func blendGlows(_ a: [Glow]?, _ b: [Glow]?, t: Double) -> [Glow]? {
        let from = a ?? [], to = b ?? []
        guard !from.isEmpty || !to.isEmpty else { return nil }
        var result: [Glow] = []
        for index in 0 ..< max(from.count, to.count) {
            switch (index < from.count ? from[index] : nil, index < to.count ? to[index] : nil) {
            case let (x?, y?):
                result.append(Glow(
                    color: x.color.mixed(with: y.color, t: t),
                    center: UnitPoint2(x: lerp(x.center.x, y.center.x, t), y: lerp(x.center.y, y.center.y, t)),
                    radius: lerp(x.radius, y.radius, t)
                ))
            case let (x?, nil):
                result.append(Glow(color: x.color.withAlpha(x.color.alpha * (1 - t)), center: x.center, radius: x.radius))
            case let (nil, y?):
                result.append(Glow(color: y.color.withAlpha(y.color.alpha * t), center: y.center, radius: y.radius))
            case (nil, nil):
                break
            }
        }
        return result
    }

    /// Layers pair up by kind + particle (the n-th clouds with the n-th clouds). Order follows
    /// `a`, then layers only `b` has; list layers in the same order in every phase.
    static func blendLayers(_ a: [SceneLayer], _ b: [SceneLayer], t: Double) -> [SceneLayer] {
        func keys(_ layers: [SceneLayer]) -> [String] {
            var seen: [String: Int] = [:]
            return layers.map { layer in
                let base = layer.kind.rawValue + "/" + (layer.particle?.rawValue ?? "")
                let occurrence = seen[base, default: 0]
                seen[base] = occurrence + 1
                return base + "#\(occurrence)"
            }
        }
        let keysA = keys(a), keysB = keys(b)
        let indexB = Dictionary(uniqueKeysWithValues: zip(keysB, b.indices))
        var result: [SceneLayer] = []
        for (key, layer) in zip(keysA, a) {
            if let match = indexB[key] {
                result.append(blendLayer(layer, b[match], t: t))
            } else {
                result.append(fading(layer, by: 1 - t))
            }
        }
        let matched = Set(keysA)
        for (key, layer) in zip(keysB, b) where !matched.contains(key) {
            result.append(fading(layer, by: t))
        }
        return result.filter { ($0.opacity ?? 1) > 0.001 }
    }

    static func blendLayer(_ x: SceneLayer, _ y: SceneLayer, t: Double) -> SceneLayer {
        var layer = x
        layer.opacity = mix(x.opacity, y.opacity, t, missing: 1)
        layer.density = mix(x.density, y.density, t)
        layer.speed = mix(x.speed, y.speed, t)
        layer.size = mix(x.size, y.size, t)
        layer.direction = mix(x.direction, y.direction, t)
        layer.colors = mixColors(x.colors, y.colors, t)
        switch (x.position, y.position) {
        case let (p?, q?): layer.position = UnitPoint2(x: lerp(p.x, q.x, t), y: lerp(p.y, q.y, t))
        case let (p, q): layer.position = p ?? q
        }
        switch (x.everySeconds, y.everySeconds) {
        case let (p?, q?) where p.count == q.count: layer.everySeconds = zip(p, q).map { lerp($0, $1, t) }
        case let (p, q): layer.everySeconds = t < 0.5 ? (p ?? q) : (q ?? p)
        }
        return layer
    }

    static func fading(_ layer: SceneLayer, by factor: Double) -> SceneLayer {
        var faded = layer
        faded.opacity = (layer.opacity ?? 1) * factor
        return faded
    }

    /// Element-wise in OKLab, cycling the shorter list.
    static func mixColors(_ x: [RGBA]?, _ y: [RGBA]?, _ t: Double) -> [RGBA]? {
        guard let x, !x.isEmpty else { return y }
        guard let y, !y.isEmpty else { return x }
        return (0 ..< max(x.count, y.count)).map { x[$0 % x.count].mixed(with: y[$0 % y.count], t: t) }
    }

    /// Both set: interpolate. One set: that value (or toward `missing` when given, e.g. an
    /// opacity the other side leaves at its default of 1).
    static func mix(_ x: Double?, _ y: Double?, _ t: Double, missing: Double? = nil) -> Double? {
        switch (x, y) {
        case let (p?, q?): return lerp(p, q, t)
        case let (p?, nil): return missing.map { lerp(p, $0, t) } ?? p
        case let (nil, q?): return missing.map { lerp($0, q, t) } ?? q
        case (nil, nil): return nil
        }
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
