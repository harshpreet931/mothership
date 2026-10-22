import Foundation
import ThemeKit

/// Scenes that exercise one renderer each, plus the combinations the brief names, for the
/// gallery and the CPU harness. Written as theme JSON, like a user theme.
enum SampleScenes {
    static func scene(_ json: String) -> Scene {
        do {
            return try JSONDecoder().decode(Scene.self, from: Data(json.utf8))
        } catch {
            preconditionFailure("sample scene doesn't decode: \(error)\n\(json)")
        }
    }

    static func gradient(_ hexes: [String]) -> String {
        "[" + hexes.enumerated().map { ##"{"color": "\##($0.element)", "location": \##(Double($0.offset) / Double(max(hexes.count - 1, 1)))}"## }.joined(separator: ", ") + "]"
    }

    static let night = gradient(["#03060F", "#0A1228", "#16203D"])
    static let dusk = gradient(["#1B1C45", "#5A4C82", "#E39A86"])
    static let day = gradient(["#4A80CC", "#8EB0DC", "#DCE7F3"])
    static let slate = gradient(["#1A222C", "#2A3440", "#3D4A57"])
    static let forest = gradient(["#050B10", "#0A1618", "#07130D"])
    static let sea = gradient(["#0B4A66", "#042238", "#020D1C"])
    static let ink = gradient(["#05020C", "#120824", "#0A0218"])
    static let fire = gradient(["#070403", "#22100A", "#3A170B"])
    static let desert = gradient(["#2A1A12", "#5A3420", "#8A5A3A"])
    static let autumn = gradient(["#3A2A3A", "#8A5A4A", "#D9A070"])

    static func single(_ gradient: String, _ layer: String) -> Scene {
        scene(##"{"gradient": \##(gradient), "layers": [\##(layer)]}"##)
    }

    /// One scene per layer kind (particles once per particle kind).
    static var perKind: [(name: String, scene: Scene)] {
        var result: [(String, Scene)] = [
            ("stars", single(night, ##"{"kind": "stars", "density": 0.7}"##)),
            ("shootingStars", single(night, ##"{"kind": "shootingStars", "everySeconds": [2, 4]}"##)),
            ("moon", single(night, ##"{"kind": "moon", "position": {"x": 0.3, "y": 0.25}, "size": 0.3}"##)),
            ("moon-earth", single(night, ##"{"kind": "moon", "colors": ["#4A8FE0", "#2E6FCF", "#F2F7FF", "#3E9E6A"], "position": {"x": 0.6, "y": 0.4}, "size": 0.3}"##)),
            ("sun", single(dusk, ##"{"kind": "sun", "colors": ["#FFF0C2", "#FFB14E"], "position": {"x": 0.7, "y": 0.6}, "size": 0.1}"##)),
            ("sun-retro", single(ink, ##"{"kind": "sun", "colors": ["#FFE14D", "#FF8A3D", "#FF2975"], "position": {"x": 0.5, "y": 0.5}, "size": 0.4}"##)),
            ("clouds", single(day, ##"{"kind": "clouds", "colors": ["#FFFFFF", "#D7E3F3"], "density": 0.6, "speed": 0.9}"##)),
            ("aurora", single(night, ##"{"kind": "aurora", "speed": 0.8}"##)),
            ("nebula", single(ink, ##"{"kind": "nebula", "speed": 0.8}"##)),
            ("grid", single(ink, ##"{"kind": "grid", "position": {"x": 0.5, "y": 0.55}}"##)),
            ("digitalRain", single(gradient(["#000000", "#02100A"]), ##"{"kind": "digitalRain", "opacity": 0.6}"##)),
            ("grain", single(gradient(["#1A1B1F", "#24262B"]), ##"{"kind": "grain", "opacity": 0.12}"##)),
        ]
        let backgrounds: [SceneLayer.Particle: String] = [
            .snow: slate, .rain: slate, .petals: dusk, .embers: fire, .bubbles: sea, .fireflies: forest, .dust: desert, .leaves: autumn,
        ]
        for particle in SceneLayer.Particle.allCases {
            result.append(("particles-\(particle.rawValue)", single(backgrounds[particle] ?? night, ##"{"kind": "particles", "particle": "\##(particle.rawValue)", "density": 0.6, "speed": 0.6}"##)))
        }
        return result
    }

    /// The combinations named in the brief.
    static var combos: [(name: String, scene: Scene)] {
        [
            ("night-aurora", scene(##"""
            {"gradient": \##(night),
             "glows": [{"color": "#2BD9A033", "center": {"x": 0.5, "y": 0.35}, "radius": 0.7}],
             "layers": [
               {"kind": "stars", "density": 0.7, "speed": 0.3},
               {"kind": "aurora", "colors": ["#3CF5A3", "#2FD6C9", "#7B5CFF"], "position": {"x": 0.5, "y": 0.3}, "size": 0.6, "speed": 0.4},
               {"kind": "shootingStars", "everySeconds": [20, 40]},
               {"kind": "grain", "opacity": 0.025}]}
            """##)),
            ("synthwave-sunset", scene(##"""
            {"gradient": [{"color": "#0A0119", "location": 0}, {"color": "#3E0B58", "location": 0.45}, {"color": "#FF6A6E", "location": 0.62},
                          {"color": "#14042A", "location": 0.62}, {"color": "#0A0218", "location": 1}],
             "glows": [{"color": "#FF297566", "center": {"x": 0.5, "y": 0.62}, "radius": 0.5}],
             "layers": [
               {"kind": "stars", "density": 0.4, "speed": 0.3, "opacity": 0.6},
               {"kind": "sun", "colors": ["#FFE14D", "#FF8A3D", "#FF2975"], "position": {"x": 0.5, "y": 0.5}, "size": 0.36},
               {"kind": "grid", "colors": ["#FF2BD6", "#FF8A3D"], "speed": 0.5, "position": {"x": 0.5, "y": 0.62}},
               {"kind": "grain", "opacity": 0.03}]}
            """##)),
            ("monsoon-rain", scene(##"""
            {"gradient": \##(slate),
             "layers": [
               {"kind": "clouds", "colors": ["#4B5967", "#2E3843"], "density": 0.85, "speed": 0.3, "opacity": 0.8},
               {"kind": "particles", "particle": "rain", "colors": ["#B9C8D8", "#8FA3B8"], "density": 0.7, "speed": 0.75, "size": 0.25, "direction": 12, "opacity": 0.6},
               {"kind": "grain", "opacity": 0.025}]}
            """##)),
            ("sakura-dawn", scene(##"""
            {"gradient": \##(gradient(["#8FA6D6", "#F2C1C8", "#FFD7B8"])),
             "glows": [{"color": "#FFC89AA6", "center": {"x": 0.2, "y": 0.84}, "radius": 0.7}],
             "layers": [
               {"kind": "sun", "colors": ["#FFF6E8", "#FFC89A"], "position": {"x": 0.2, "y": 0.82}, "size": 0.07},
               {"kind": "clouds", "colors": ["#FFE2D6", "#F3C4CF"], "density": 0.4, "speed": 0.3, "opacity": 0.55},
               {"kind": "particles", "particle": "petals", "density": 0.55, "speed": 0.4, "size": 0.5, "direction": 65, "opacity": 0.95},
               {"kind": "grain", "opacity": 0.02}]}
            """##)),
            ("ember-dark", scene(##"""
            {"gradient": \##(gradient(["#070403", "#120806", "#22100A", "#3A170B"])),
             "glows": [{"color": "#FF6A1F73", "center": {"x": 0.5, "y": 1.08}, "radius": 0.75}],
             "layers": [
               {"kind": "particles", "particle": "embers", "density": 0.55, "speed": 0.45, "size": 0.4, "direction": 182, "opacity": 0.95},
               {"kind": "particles", "particle": "dust", "colors": ["#FFB070"], "density": 0.3, "speed": 0.3, "size": 0.2, "opacity": 0.25},
               {"kind": "grain", "opacity": 0.035}]}
            """##)),
        ]
    }

    /// Every built-in theme: fixed scenes once; sun cycles at night, golden hour and day.
    static var builtIns: [(name: String, scene: Scene?)] {
        ThemeLibrary.builtIn.flatMap { theme -> [(String, Scene?)] in
            switch theme.backdrop.kind {
            case .sunCycle:
                [("\(theme.id)@night", ThemeLibrary.scene(for: theme, sunAltitude: -20)),
                 ("\(theme.id)@golden", ThemeLibrary.scene(for: theme, sunAltitude: 4)),
                 ("\(theme.id)@day", ThemeLibrary.scene(for: theme, sunAltitude: 30))]
            case .fixed, .desktop:
                [(theme.id, ThemeLibrary.scene(for: theme, sunAltitude: 30))]
            }
        }
    }
}
