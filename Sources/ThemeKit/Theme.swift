import Foundation

// CONTRACT shared by ThemeKit (catalog, loading, validation), BackdropKit (rendering) and the
// app (picker, application). Types and field names are fixed; add fields only as optionals.
// Themes are plain JSON so users can write and share their own:
//
//   {"id": "aurora", "name": "Aurora", "summary": "Northern lights over a quiet night",
//    "version": 1, "tone": "dark", "tags": ["animated", "night"],
//    "backdrop": {"kind": "fixed", "scene": {
//        "gradient": [{"color": "#050B1A", "location": 0}, {"color": "#0E1C33", "location": 1}],
//        "layers": [{"kind": "stars", "density": 0.6},
//                   {"kind": "aurora", "colors": ["#3CF5A3", "#7B5CFF"], "speed": 0.3}]}},
//    "palette": {"attention": "#FF8A33", "danger": "#F2555A",
//                "lightGlass": "#FFFFFF8C", "darkGlass": "#0B1424A6"},
//    "terminal": {"dark": "Nord"}}

/// An sRGB color, written in JSON as `"#RRGGBB"` or `"#RRGGBBAA"`.
public struct RGBA: Hashable, Sendable, Codable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        red = Double((value >> (16 + shift)) & 0xFF) / 255
        green = Double((value >> (8 + shift)) & 0xFF) / 255
        blue = Double((value >> shift) & 0xFF) / 255
        alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
    }

    public var hex: String {
        func byte(_ value: Double) -> String { String(format: "%02X", Int((max(0, min(1, value)) * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    public var description: String { hex }

    /// WCAG relative luminance (alpha ignored).
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = RGBA(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a #RRGGBB(AA) color: \(text)"))
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// Which way the chrome (glass, text, selection) leans.
public enum ThemeTone: String, Sendable, Codable, CaseIterable {
    case light, dark
    /// Content-led: follow the terminal background's luminance (the default rule).
    case auto
}

/// Where the sun is, coarse enough for scene keyframes. Altitudes: night < −12° ≤ twilight
/// < −6° ≤ blueHour < 0° ≤ goldenHour < 8° ≤ day.
public enum SunPhase: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    case night, twilight, blueHour, goldenHour, day
}

public struct UnitPoint2: Hashable, Sendable, Codable {
    /// 0 = left, 1 = right.
    public var x: Double
    /// 0 = top, 1 = bottom.
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct GradientStop: Hashable, Sendable, Codable {
    public var color: RGBA
    /// 0 = top of the window, 1 = bottom.
    public var location: Double
    public init(color: RGBA, location: Double) {
        self.color = color
        self.location = location
    }
}

/// A soft radial glow (the sun's side of the sky, a city glow, a nebula core).
public struct Glow: Hashable, Sendable, Codable {
    public var color: RGBA
    public var center: UnitPoint2
    /// Fraction of the window's larger side.
    public var radius: Double
    public init(color: RGBA, center: UnitPoint2, radius: Double) {
        self.color = color
        self.center = center
        self.radius = radius
    }
}

/// One element of a scene. Fields are generic so new layer kinds don't need new types; each
/// renderer reads what applies and ignores the rest. Relative values are 0…1.
public struct SceneLayer: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case stars, shootingStars, moon, sun, clouds, aurora, nebula, particles, grid, digitalRain, grain
    }

    public enum Particle: String, Sendable, Codable, CaseIterable {
        case snow, rain, petals, embers, bubbles, fireflies, dust, leaves
    }

    public var kind: Kind
    /// For `.particles`.
    public var particle: Particle?
    /// Tints; renderers cycle or blend them.
    public var colors: [RGBA]?
    public var density: Double?
    public var speed: Double?
    public var opacity: Double?
    public var size: Double?
    /// Moon/sun position, grid horizon (`y`), nebula core.
    public var position: UnitPoint2?
    /// Degrees; 0 = straight down (rain, snow), 90 = drifting right.
    public var direction: Double?
    /// Seconds between occasional events (shooting stars), as `[min, max]`.
    public var everySeconds: [Double]?

    public init(
        kind: Kind, particle: Particle? = nil, colors: [RGBA]? = nil, density: Double? = nil, speed: Double? = nil,
        opacity: Double? = nil, size: Double? = nil, position: UnitPoint2? = nil, direction: Double? = nil,
        everySeconds: [Double]? = nil
    ) {
        self.kind = kind
        self.particle = particle
        self.colors = colors
        self.density = density
        self.speed = speed
        self.opacity = opacity
        self.size = size
        self.position = position
        self.direction = direction
        self.everySeconds = everySeconds
    }
}

/// Everything behind the glass at one moment.
public struct Scene: Hashable, Sendable, Codable {
    /// Top-to-bottom sky gradient.
    public var gradient: [GradientStop]
    public var glows: [Glow]?
    public var layers: [SceneLayer]

    public init(gradient: [GradientStop], glows: [Glow]? = nil, layers: [SceneLayer] = []) {
        self.gradient = gradient
        self.glows = glows
        self.layers = layers
    }
}

public struct Backdrop: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// One scene, always.
        case fixed
        /// A scene per sun phase, blended continuously by the sun's altitude.
        case sunCycle
        /// No scene: the desktop shows through (behind-window blur).
        case desktop
    }

    public var kind: Kind
    public var scene: Scene?
    public var phases: [SunPhase: Scene]?

    public init(kind: Kind, scene: Scene? = nil, phases: [SunPhase: Scene]? = nil) {
        self.kind = kind
        self.scene = scene
        self.phases = phases
    }
}

public struct ChromePalette: Hashable, Sendable, Codable {
    /// "Needs you". Must stay distinct from everything else in the theme (validated).
    public var attention: RGBA
    public var danger: RGBA
    /// Glass tint in light tone (alpha = opacity).
    public var lightGlass: RGBA
    /// Glass tint in dark tone.
    public var darkGlass: RGBA
    /// Optional selection fill override (light tone defaults to a white card, dark to frosted white).
    public var selection: RGBA?

    public init(attention: RGBA, danger: RGBA, lightGlass: RGBA, darkGlass: RGBA, selection: RGBA? = nil) {
        self.attention = attention
        self.danger = danger
        self.lightGlass = lightGlass
        self.darkGlass = darkGlass
        self.selection = selection
    }
}

/// Terminal color themes (names from the GhosttyTheme catalog) that suit the scene.
public struct TerminalPairing: Hashable, Sendable, Codable {
    public var dark: String?
    public var light: String?
    public init(dark: String? = nil, light: String? = nil) {
        self.dark = dark
        self.light = light
    }
}

public struct Theme: Identifiable, Hashable, Sendable, Codable {
    /// Lowercase, `[a-z0-9-]`; user themes may not reuse a built-in id.
    public var id: String
    public var name: String
    public var summary: String
    public var author: String?
    public var version: Int
    public var tone: ThemeTone
    public var tags: [String]
    public var backdrop: Backdrop
    public var palette: ChromePalette
    public var terminal: TerminalPairing?

    public init(
        id: String, name: String, summary: String, author: String? = nil, version: Int = 1, tone: ThemeTone,
        tags: [String] = [], backdrop: Backdrop, palette: ChromePalette, terminal: TerminalPairing? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.author = author
        self.version = version
        self.tone = tone
        self.tags = tags
        self.backdrop = backdrop
        self.palette = palette
        self.terminal = terminal
    }
}

public struct ThemeIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var message: String
    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
    public var description: String { "\(severity.rawValue): \(message)" }
}

/// The theme catalog. The catalog engineer replaces these stub bodies; signatures are fixed.
public enum ThemeLibrary {
    /// Every built-in theme, default first ("mothership-sky", the sun cycle).
    public static var builtIn: [Theme] { BuiltInThemes.catalog }

    public static let defaultThemeID = "mothership-sky"

    /// Built-ins plus valid user themes from `directory` (`*.json`); invalid files are skipped
    /// and reported.
    public static func load(userDirectory: URL) -> (themes: [Theme], problems: [String: [ThemeIssue]]) {
        ThemeLoading.load(userDirectory: userDirectory, builtIn: builtIn)
    }

    /// Schema, color, contrast and distinctness checks. Errors make a theme unusable.
    /// Contrast and distinctness are errors for built-in ids and warnings for user themes.
    public static func validate(_ theme: Theme) -> [ThemeIssue] {
        ThemeValidation.validate(theme, asBuiltIn: BuiltInThemes.ids.contains(theme.id))
    }

    /// The scene to show for a sun altitude (degrees): `fixed` returns its scene, `sunCycle`
    /// blends the two nearest phases continuously, `desktop` returns nil.
    public static func scene(for theme: Theme, sunAltitude: Double) -> Scene? {
        switch theme.backdrop.kind {
        case .fixed: return theme.backdrop.scene
        case .sunCycle: return theme.backdrop.phases.flatMap { SceneBlending.scene(phases: $0, altitude: sunAltitude) } ?? theme.backdrop.scene
        case .desktop: return nil
        }
    }

    // MARK: Additions

    public static func theme(id: String) -> Theme? { builtIn.first { $0.id == id } }

    /// Pretty-printed JSON with sorted keys (stable bytes), for sharing a theme.
    public static func export(_ theme: Theme) -> Data { ThemeLoading.export(theme) }
}
