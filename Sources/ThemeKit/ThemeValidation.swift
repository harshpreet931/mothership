import Foundation

/// Schema, contrast and distinctness checks behind `ThemeLibrary.validate`.
///
/// Schema problems are always errors. Design problems (text contrast on the glass, an
/// attention color that blends into the scene or into danger) are errors for built-in
/// themes and warnings for user themes, which still load.
public enum ThemeValidation {
    /// Primary text in light chrome (the app's ink) and in dark chrome.
    public static let lightInk = RGBA(red: 13 / 255, green: 14 / 255, blue: 17 / 255)
    public static let darkInk = RGBA(red: 244 / 255, green: 245 / 255, blue: 247 / 255)
    /// Secondary text is ink at this opacity.
    public static let secondaryTextAlpha = 0.56
    public static let primaryContrast = 4.5
    public static let secondaryContrast = 3.0
    /// `auto` chrome goes light over scenes at least this bright (relative luminance of the
    /// mid-gradient color), like the sun-cycle sky.
    public static let autoLightThreshold = 0.2

    public static let knownTags: Set<String> = ["animated", "still", "light", "dark", "night", "seasonal", "calm", "vivid", "minimal"]

    public static func validate(_ theme: Theme, asBuiltIn: Bool) -> [ThemeIssue] {
        var issues: [ThemeIssue] = []
        let design: ThemeIssue.Severity = asBuiltIn ? .error : .warning
        func error(_ message: String) { issues.append(ThemeIssue(.error, message)) }

        if theme.id.isEmpty || theme.id.range(of: "^[a-z0-9-]+$", options: .regularExpression) == nil {
            error("id “\(theme.id)” must be lowercase letters, digits and dashes")
        }
        if theme.name.trimmingCharacters(in: .whitespaces).isEmpty { error("name is empty") }
        if theme.summary.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(ThemeIssue(.warning, "summary is empty")) }
        if theme.version < 1 { error("version must be 1 or more") }
        for tag in theme.tags where !knownTags.contains(tag) {
            issues.append(ThemeIssue(.warning, "unknown tag “\(tag)” (known: \(knownTags.sorted().joined(separator: ", ")))"))
        }

        let scenes = namedScenes(theme.backdrop)
        switch theme.backdrop.kind {
        case .fixed:
            if theme.backdrop.scene == nil { error("a fixed backdrop needs a scene") }
        case .sunCycle:
            if (theme.backdrop.phases?.count ?? 0) < 2 { error("a sunCycle backdrop needs at least two phases (night … day)") }
        case .desktop:
            break
        }
        for (label, scene) in scenes { issues += schemaIssues(scene, label: label) }

        // Design: contrast and distinctness (only meaningful once the schema holds).
        guard !issues.contains(where: { $0.severity == .error }) else { return issues }
        for (label, scene) in scenes {
            issues += contrastIssues(theme, scene: scene, label: label, severity: design)
        }
        issues += attentionIssues(theme, scenes: scenes, severity: design)
        return issues
    }

    /// Scenes with a label for messages ("scene", "night", "goldenHour" …), phases in sun order.
    static func namedScenes(_ backdrop: Backdrop) -> [(String, Scene)] {
        switch backdrop.kind {
        case .fixed: return backdrop.scene.map { [("scene", $0)] } ?? []
        case .sunCycle: return SunPhase.allCases.compactMap { phase in backdrop.phases?[phase].map { (phase.rawValue, $0) } }
        case .desktop: return []
        }
    }

    // MARK: Schema

    static func schemaIssues(_ scene: Scene, label: String) -> [ThemeIssue] {
        var issues: [ThemeIssue] = []
        func error(_ message: String) { issues.append(ThemeIssue(.error, "\(label): \(message)")) }
        func unit(_ value: Double?, _ name: String) {
            if let value, !(0 ... 1).contains(value) || !value.isFinite { error("\(name) \(value) must be within 0…1") }
        }

        if scene.gradient.count < 2 { error("the gradient needs at least two stops") }
        for (index, stop) in scene.gradient.enumerated() {
            unit(stop.location, "gradient stop \(index + 1) location")
            if index > 0, stop.location < scene.gradient[index - 1].location {
                error("gradient stop locations must ascend (stop \(index + 1) is above stop \(index))")
            }
        }
        for (index, glow) in (scene.glows ?? []).enumerated() {
            if !(0 ... 1.5).contains(glow.radius) { error("glow \(index + 1) radius \(glow.radius) must be within 0…1.5") }
            if !(-0.5 ... 1.5).contains(glow.center.x) || !(-0.5 ... 1.5).contains(glow.center.y) {
                error("glow \(index + 1) center must be within −0.5…1.5 (just off-window is fine)")
            }
        }
        for (index, layer) in scene.layers.enumerated() {
            let name = "layer \(index + 1) (\(layer.kind.rawValue))"
            unit(layer.density, "\(name) density")
            unit(layer.speed, "\(name) speed")
            unit(layer.opacity, "\(name) opacity")
            unit(layer.size, "\(name) size")
            unit(layer.position?.x, "\(name) position.x")
            unit(layer.position?.y, "\(name) position.y")
            if layer.kind == .particles, layer.particle == nil {
                error("\(name) needs a particle (\(SceneLayer.Particle.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            if layer.kind != .particles, let particle = layer.particle {
                error("\(name) can't have a particle (“\(particle.rawValue)” is only for particles layers)")
            }
            if let direction = layer.direction, !direction.isFinite || abs(direction) > 360 {
                error("\(name) direction must be within −360…360 degrees")
            }
            if let every = layer.everySeconds {
                if every.count != 2 || every[0] <= 0 || every[0] > every[1] {
                    error("\(name) everySeconds must be [min, max] with 0 < min ≤ max")
                }
            }
            if let colors = layer.colors, colors.isEmpty { error("\(name) colors is empty (leave it out for the default)") }
        }
        return issues
    }

    // MARK: Contrast

    /// The chrome over a scene: tone light/dark, or for `auto` light over bright scenes.
    static func chrome(_ theme: Theme, over mid: RGBA) -> (glass: RGBA, ink: RGBA, name: String) {
        let light: Bool
        switch theme.tone {
        case .light: light = true
        case .dark: light = false
        case .auto: light = mid.luminance >= autoLightThreshold
        }
        return light ? (theme.palette.lightGlass, lightInk, "light") : (theme.palette.darkGlass, darkInk, "dark")
    }

    static func contrastIssues(_ theme: Theme, scene: Scene, label: String, severity: ThemeIssue.Severity) -> [ThemeIssue] {
        guard let mid = ColorMath.color(in: scene.gradient.sorted { $0.location < $1.location }, at: 0.5)?.withAlpha(1) else { return [] }
        let chrome = chrome(theme, over: mid)
        let surface = chrome.glass.composited(over: mid)
        let primary = chrome.ink.contrast(with: surface)
        let secondary = chrome.ink.withAlpha(secondaryTextAlpha).composited(over: surface).contrast(with: surface)
        var issues: [ThemeIssue] = []
        if primary < primaryContrast {
            issues.append(ThemeIssue(severity, String(
                format: "%@: text on %@ glass over the sky (%@) is %.1f:1, needs %.1f:1. Make the %@Glass more opaque or the scene's middle %@",
                label, chrome.name, mid.hex, primary, primaryContrast, chrome.name, chrome.name == "light" ? "lighter" : "darker"
            )))
        }
        if secondary < secondaryContrast {
            issues.append(ThemeIssue(severity, String(
                format: "%@: secondary text on %@ glass over the sky (%@) is %.1f:1, needs %.1f:1",
                label, chrome.name, mid.hex, secondary, secondaryContrast
            )))
        }
        return issues
    }

    /// Text contrast over each scene, for tools and tests: (label, primary, secondary).
    public static func contrastReport(_ theme: Theme) -> [(scene: String, primary: Double, secondary: Double)] {
        namedScenes(theme.backdrop).compactMap { label, scene in
            guard let mid = ColorMath.color(in: scene.gradient.sorted { $0.location < $1.location }, at: 0.5)?.withAlpha(1) else { return nil }
            let chrome = chrome(theme, over: mid)
            let surface = chrome.glass.composited(over: mid)
            let secondary = chrome.ink.withAlpha(secondaryTextAlpha).composited(over: surface).contrast(with: surface)
            return (label, chrome.ink.contrast(with: surface), secondary)
        }
    }

    // MARK: Attention

    static func attentionIssues(_ theme: Theme, scenes: [(String, Scene)], severity: ThemeIssue.Severity) -> [ThemeIssue] {
        let attention = theme.palette.attention
        var issues: [ThemeIssue] = []
        if attention.alpha < 1 { issues.append(ThemeIssue(.warning, "attention \(attention.hex) is translucent; badges read best opaque")) }
        if ColorMath.confusable(attention.withAlpha(1), theme.palette.danger.withAlpha(1)) {
            issues.append(ThemeIssue(severity, "attention \(attention.hex) is too close to danger \(theme.palette.danger.hex)"))
        }
        var reported: Set<String> = []
        for (label, scene) in scenes {
            let sceneColors = scene.gradient.map { ($0.color, "gradient") }
                + scene.layers.flatMap { layer in (layer.colors ?? []).map { ($0, "\(layer.particle?.rawValue ?? layer.kind.rawValue) layer") } }
            for (color, source) in sceneColors where ColorMath.confusable(attention.withAlpha(1), color.withAlpha(1)) {
                let key = color.hex
                guard reported.insert(key).inserted else { continue }
                issues.append(ThemeIssue(severity, "\(label): attention \(attention.hex) is too close to the \(source) color \(color.hex); “needs you” must stand out"))
            }
        }
        return issues
    }
}
