import AppKit
import Foundation
import Testing
import ThemeKit
@testable import BackdropKit

// MARK: - Helpers

@MainActor
private func scene(_ json: String) throws -> Scene {
    try JSONDecoder().decode(Scene.self, from: Data(json.utf8))
}

private let darkGradient = ##"[{"color": "#05080F", "location": 0}, {"color": "#16203D", "location": 1}]"##

@MainActor
private func layers(_ list: String, gradient: String = darkGradient) throws -> Scene {
    try scene(##"{"gradient": \##(gradient), "layers": [\##(list)]}"##)
}

@MainActor
private func stage(_ scene: Scene?, size: CGSize = CGSize(width: 1440, height: 900), motion: Motion = .running) -> Stage {
    let stage = Stage(purpose: .live)
    stage.layout(size: size, scale: 2, topBand: 0)
    stage.setMotion(motion)
    stage.apply(scene, transition: 0)
    return stage
}

private func pixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

/// Mean absolute channel difference, 0…255.
private func difference(_ a: CGImage?, _ b: CGImage?) -> Double {
    guard let a, let b else { return 0 }
    let pa = pixels(a), pb = pixels(b)
    guard pa.count == pb.count, !pa.isEmpty else { return 255 }
    var total = 0
    for index in pa.indices { total += abs(Int(pa[index]) - Int(pb[index])) }
    return Double(total) / Double(pa.count)
}

@MainActor
private func still(_ scene: Scene, size: CGSize = CGSize(width: 320, height: 200)) -> CGImage? {
    OffscreenRenderer.still(of: scene, size: size, scale: 1)
}

// MARK: - Gradients and parameters

@Test func gradientKeepsHardEdges() {
    let stops = [
        GradientStop(color: RGBA(0x000000), location: 0), GradientStop(color: RGBA(0xFF0000), location: 0.6),
        GradientStop(color: RGBA(0x0000FF), location: 0.6), GradientStop(color: RGBA(0xFFFFFF), location: 1),
    ]
    let shape = GradientSampler.shape(stops)
    #expect(shape.locations == [0, 0.6, 0.6, 1])
    #expect(shape.colors[1] == RGBA(0xFF0000) && shape.colors[2] == RGBA(0x0000FF))
}

@Test func gradientsAlignAtTheUnionOfTheirStops() {
    let hard = [
        GradientStop(color: RGBA(0x000000), location: 0), GradientStop(color: RGBA(0xFF0000), location: 0.5),
        GradientStop(color: RGBA(0x0000FF), location: 0.5), GradientStop(color: RGBA(0xFFFFFF), location: 1),
    ]
    let plain = [GradientStop(color: RGBA(0x000000), location: 0), GradientStop(color: RGBA(0xFFFFFF), location: 1)]
    let (from, to) = GradientSampler.aligned(plain, hard)
    #expect(from.locations == to.locations)
    #expect(from.locations == [0, 0.5, 0.5, 1])
    // The plain gradient is the same color on both sides of the edge; the hard one isn't.
    #expect(from.colors[1] == from.colors[2])
    #expect(to.colors[1] == RGBA(0xFF0000) && to.colors[2] == RGBA(0x0000FF))
}

@Test func relativeValuesScaleAroundTheDefault() {
    #expect(Relative.factor(nil, range: 4) == 1)
    #expect(abs(Relative.factor(0.5, range: 4) - 1) < 1e-9)
    #expect(abs(Relative.factor(0, range: 4) - 0.25) < 1e-9)
    #expect(abs(Relative.factor(1, range: 4) - 4) < 1e-9)
    #expect(Relative.factor(.nan, range: 4) == 1)
}

// MARK: - Scene changes

@MainActor
@Test func gradientOnlyChangesKeepEveryNode() throws {
    let first = try layers(##"{"kind": "stars"}, {"kind": "clouds"}"##)
    let stage = stage(first)
    let before = stage.nodes.map(ObjectIdentifier.init)
    var second = first
    second.gradient = [GradientStop(color: RGBA(0x4A80CC), location: 0), GradientStop(color: RGBA(0xDCE7F3), location: 1)]
    stage.apply(second, transition: 1.5)
    #expect(stage.nodes.map(ObjectIdentifier.init) == before)
    #expect(stage.sky.gradient.animation(forKey: "morph-colors") != nil)
}

@MainActor
@Test func opacityChangesAnimateInPlace() throws {
    let stage = stage(try layers(##"{"kind": "stars", "opacity": 1}"##))
    let node = try #require(stage.nodes.first)
    stage.apply(try layers(##"{"kind": "stars", "opacity": 0.3}"##), transition: 1)
    #expect(stage.nodes.first === node)
    #expect(abs(node.layer.opacity - 0.3) < 0.001)
    #expect(node.layer.animation(forKey: "fade") != nil)
}

@MainActor
@Test func particlesRetuneInPlaceButOtherKindsCrossFade() throws {
    let stage = stage(try layers(##"{"kind": "particles", "particle": "snow", "density": 0.3}, {"kind": "stars", "density": 0.3}"##))
    let snow = stage.nodes[0], stars = stage.nodes[1]
    stage.apply(try layers(##"{"kind": "particles", "particle": "snow", "density": 0.8}, {"kind": "stars", "density": 0.8}"##), transition: 1)
    #expect(stage.nodes[0] === snow)
    #expect(stage.nodes[1] !== stars)
    // The old stars fade out on top of the new ones until the fade ends.
    #expect(stars.layer.superlayer === stage.canvas)
    #expect(stars.layer.animation(forKey: "fade") != nil)
}

@MainActor
@Test func layersFollowTheSceneOrder() throws {
    let stage = stage(try layers(##"{"kind": "stars"}, {"kind": "grain"}"##))
    stage.apply(try layers(##"{"kind": "nebula"}, {"kind": "stars"}, {"kind": "grain"}"##), transition: 0)
    let kinds = (stage.canvas.sublayers ?? []).compactMap { layer in stage.nodes.first { $0.layer === layer }?.spec.kind }
    #expect(kinds == [.nebula, .stars, .grain])
}

@MainActor
@Test func removedLayersGoAtOnceWhenNothingAnimates() throws {
    let stage = stage(try layers(##"{"kind": "stars"}, {"kind": "aurora"}"##), motion: .paused)
    stage.apply(try layers(##"{"kind": "stars"}"##), transition: 1.5)
    #expect(stage.canvas.sublayers?.count == 1)
}

@MainActor
@Test func noSceneClearsEverything() throws {
    let stage = stage(try layers(##"{"kind": "stars"}"##))
    stage.apply(nil, transition: 0)
    #expect(stage.nodes.isEmpty)
    #expect(stage.sky.layer.opacity == 0)
}

// MARK: - Motion

@MainActor
@Test func pausingFreezesTheClockAndStopsBirths() throws {
    let view = BackdropView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    view.apply(try layers(##"{"kind": "particles", "particle": "rain"}, {"kind": "aurora"}"##), transition: 0)
    let rain = try #require(view.stage.nodes.first as? ParticlesNode)
    #expect(view.stage.canvas.speed == 1)
    #expect(rain.emitters.allSatisfy { $0.birthRate == 1 })

    view.isAnimating = false
    #expect(view.stage.canvas.speed == 0)
    #expect(rain.emitters.allSatisfy { $0.birthRate == 0 })
    // Frozen, not gone: the emitters stay on screen.
    #expect(rain.emitters.allSatisfy { !$0.isHidden && $0.superlayer?.isHidden == false })

    view.isAnimating = true
    #expect(view.stage.canvas.speed == 1)
    #expect(rain.emitters.allSatisfy { $0.birthRate == 1 })
}

@MainActor
@Test func reduceMotionShowsAStaticScatter() throws {
    let view = BackdropView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    view.apply(try layers(##"{"kind": "particles", "particle": "snow"}"##), transition: 0)
    view.reducesMotion = true
    let snow = try #require(view.stage.nodes.first as? ParticlesNode)
    #expect(view.stage.canvas.speed == 0)
    let scatter = try #require(snow.layer.sublayers?.first { $0.contents != nil && !$0.isHidden })
    #expect(scatter.bounds.size == CGSize(width: 800, height: 500))
    #expect(snow.emitters.first?.superlayer?.isHidden == true)
    view.reducesMotion = false
    #expect(snow.emitters.first?.superlayer?.isHidden == false)
}

// MARK: - Particles scale with the view

@MainActor
private func totalBirthRate(_ node: ParticlesNode) -> Double {
    node.emitters.reduce(0) { sum, emitter in sum + (emitter.emitterCells ?? []).reduce(0) { $0 + Double($1.birthRate) } }
}

@MainActor
@Test func birthRatesScaleWithAreaUnderACap() throws {
    let dust = try layers(##"{"kind": "particles", "particle": "dust", "density": 0.4}"##)
    func rate(_ size: CGSize) throws -> Double {
        let node = try #require(stage(dust, size: size).nodes.first as? ParticlesNode)
        return totalBirthRate(node)
    }
    let small = try rate(CGSize(width: 720, height: 450)), large = try rate(CGSize(width: 1440, height: 900))
    #expect(abs(large / small - 4) < 0.2)
    // A huge window doesn't multiply without bound.
    let huge = try rate(CGSize(width: 7680, height: 4320))
    #expect(huge < large * 6)
}

@MainActor
@Test func fieldsChangeTheEmitters() throws {
    func cells(_ json: String) throws -> [CAEmitterCell] {
        let node = try #require(stage(try layers(json)).nodes.first as? ParticlesNode)
        return node.emitters.flatMap { $0.emitterCells ?? [] }.filter { $0.name != "carrier" }
    }
    let base = try cells(##"{"kind": "particles", "particle": "snow"}"##)
    let dense = try cells(##"{"kind": "particles", "particle": "snow", "density": 0.9}"##)
    let fast = try cells(##"{"kind": "particles", "particle": "snow", "speed": 0.9}"##)
    let large = try cells(##"{"kind": "particles", "particle": "snow", "size": 0.9}"##)
    let tinted = try cells(##"{"kind": "particles", "particle": "snow", "colors": ["#FF0000"]}"##)
    let sum = { (cells: [CAEmitterCell]) in cells.reduce(0.0) { $0 + Double($1.birthRate) } }
    #expect(sum(dense) > sum(base) * 2)
    #expect((fast.first?.velocity ?? 0) > (base.first?.velocity ?? 0) * 2)
    #expect((large.first?.scale ?? 0) > (base.first?.scale ?? 0) * 1.5)
    #expect(tinted.first?.color?.components?.first == 1)
    #expect(tinted.first?.color?.components?[1] == 0)
}

@MainActor
@Test func directionTiltsFallsAndRises() throws {
    func turn(_ json: String) throws -> CGFloat {
        let node = try #require(stage(try layers(json)).nodes.first as? ParticlesNode)
        let transform = try #require(node.emitters.first?.superlayer?.transform)
        return atan2(transform.m12, transform.m11)
    }
    #expect(abs(try turn(##"{"kind": "particles", "particle": "rain"}"##)) < 0.001)
    #expect(abs(try turn(##"{"kind": "particles", "particle": "rain", "direction": 20}"##) - 20 * .pi / 180) < 0.001)
    // Embers rise by default (180°).
    #expect(abs(abs(try turn(##"{"kind": "particles", "particle": "embers"}"##)) - .pi) < 0.001)
}

// MARK: - Stills

@MainActor
@Test func stillsAreDeterministicAndShowParticles() throws {
    let snow = try layers(##"{"kind": "particles", "particle": "snow", "density": 0.8}"##)
    let empty = try layers("")
    let first = still(snow), second = still(snow)
    #expect(first != nil)
    #expect(difference(first, second) == 0)
    #expect(difference(first, still(empty)) > 1)
}

@MainActor
@Test func renderImageHasTheRequestedSize() throws {
    let image = try #require(BackdropView.renderImage(of: try layers(##"{"kind": "stars"}"##), size: CGSize(width: 300, height: 200), scale: 2))
    #expect(image.size == CGSize(width: 300, height: 200))
    #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 600)
}

@MainActor
@Test func densitySizeAndColorsChangeTheStill() throws {
    let base = still(try layers(##"{"kind": "stars", "density": 0.5}"##))
    #expect(difference(base, still(try layers(##"{"kind": "stars", "density": 1}"##))) > 0.3)
    #expect(difference(base, still(try layers(##"{"kind": "stars", "density": 0.5, "size": 1}"##))) > 0.3)
    let sun = still(try layers(##"{"kind": "sun", "colors": ["#FFFFFF", "#FFB46A"], "size": 0.1}"##))
    #expect(difference(sun, still(try layers(##"{"kind": "sun", "colors": ["#FF3030", "#FF3030"], "size": 0.1}"##))) > 0.3)
    #expect(difference(sun, still(try layers(##"{"kind": "sun", "colors": ["#FFFFFF", "#FFB46A"], "size": 0.2}"##))) > 0.3)
}

@MainActor
@Test func hardGradientEdgesStayHard() throws {
    let edge = ##"[{"color": "#FF0000", "location": 0}, {"color": "#FF0000", "location": 0.5}, {"color": "#0000FF", "location": 0.5}, {"color": "#0000FF", "location": 1}]"##
    let image = try #require(still(try layers("", gradient: edge), size: CGSize(width: 40, height: 100)))
    let bytes = pixels(image)
    func red(row: Int) -> UInt8 { bytes[(row * image.width + 20) * 4] }
    #expect(red(row: 48) > 240)
    #expect(red(row: 52) < 15)
}

@MainActor
@Test func earthAndRetroSunFollowTheirColors() throws {
    let moon = still(try layers(##"{"kind": "moon", "colors": ["#F4F1E8"], "position": {"x": 0.5, "y": 0.5}, "size": 0.5}"##))
    let earth = still(try layers(##"{"kind": "moon", "colors": ["#4A8FE0", "#2E6FCF", "#F2F7FF", "#3E9E6A"], "position": {"x": 0.5, "y": 0.5}, "size": 0.5}"##))
    #expect(difference(moon, earth) > 1)
    let sun = still(try layers(##"{"kind": "sun", "colors": ["#FFE14D", "#FF2975"], "position": {"x": 0.5, "y": 0.5}, "size": 0.5}"##))
    let retro = still(try layers(##"{"kind": "sun", "colors": ["#FFE14D", "#FF8A3D", "#FF2975"], "position": {"x": 0.5, "y": 0.5}, "size": 0.5}"##))
    #expect(difference(sun, retro) > 1)
}

@MainActor
@Test func stillStarsDoNotTwinkle() throws {
    let stage = stage(try layers(##"{"kind": "stars", "speed": 0}"##))
    let twinklers = (stage.nodes.first?.layer.sublayers ?? []).filter { $0.contents != nil }
    #expect(!twinklers.isEmpty)
    #expect(twinklers.allSatisfy { $0.animationKeys() == nil })
}

// MARK: - Budgets

@MainActor
@Test func layerCountStaysBounded() throws {
    var all: [String] = SceneLayer.Kind.allCases.filter { $0 != .particles }.map { ##"{"kind": "\##($0.rawValue)", "density": 1}"## }
    all += SceneLayer.Particle.allCases.map { ##"{"kind": "particles", "particle": "\##($0.rawValue)", "density": 1}"## }
    let stage = stage(try layers(all.joined(separator: ", ")), size: CGSize(width: 3840, height: 2160))
    #expect(stage.layerCount < 400)
}

@MainActor
@Test func everyBuiltInRenders() throws {
    for theme in ThemeLibrary.builtIn {
        for altitude in [-20.0, 4, 30] {
            guard let scene = ThemeLibrary.scene(for: theme, sunAltitude: altitude) else { continue }
            let image = BackdropView.renderImage(of: scene, size: CGSize(width: 160, height: 100), scale: 1)
            #expect(image != nil, "\(theme.id) at \(altitude)°")
        }
    }
}
