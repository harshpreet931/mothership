import Foundation
import Synchronization
import Testing

@testable import ThemeKit

/// A small valid theme to break in tests.
func sampleTheme(id: String = "my-theme", tone: ThemeTone = .dark, scene: Scene? = nil) -> Theme {
    Theme(
        id: id, name: "Mine", summary: "A test theme", tone: tone, tags: ["still", "dark"],
        backdrop: Backdrop(kind: .fixed, scene: scene ?? Scene(
            gradient: [GradientStop(color: RGBA(red: 0.02, green: 0.03, blue: 0.08), location: 0), GradientStop(color: RGBA(red: 0.05, green: 0.06, blue: 0.14), location: 1)],
            layers: [SceneLayer(kind: .stars, density: 0.5)]
        )),
        palette: ChromePalette(
            attention: RGBA(red: 1, green: 0.54, blue: 0.2), danger: RGBA(red: 0.95, green: 0.33, blue: 0.35),
            lightGlass: RGBA(red: 1, green: 1, blue: 1, alpha: 0.55), darkGlass: RGBA(red: 0.08, green: 0.09, blue: 0.11, alpha: 0.55)
        ),
        terminal: TerminalPairing(dark: "Nord")
    )
}

func errors(_ issues: [ThemeIssue]) -> [String] { issues.filter { $0.severity == .error }.map(\.message) }

@Suite("Validation")
struct ValidationTests {
    @Test func sampleIsValid() {
        #expect(ThemeValidation.validate(sampleTheme(), asBuiltIn: true).isEmpty)
    }

    @Test func schemaProblemsAreErrors() {
        var theme = sampleTheme(id: "Bad ID!")
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("lowercase letters") })

        theme = sampleTheme()
        theme.backdrop.scene?.gradient = [GradientStop(color: RGBA(red: 0, green: 0, blue: 0), location: 0)]
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("at least two stops") })

        theme = sampleTheme()
        theme.backdrop.scene?.gradient = [
            GradientStop(color: RGBA(red: 0, green: 0, blue: 0), location: 0.8), GradientStop(color: RGBA(red: 0.1, green: 0.1, blue: 0.1), location: 0.2),
        ]
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("must ascend") })

        theme = sampleTheme()
        theme.backdrop.scene?.gradient[1].location = 1.4
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("within 0…1") })

        theme = sampleTheme()
        theme.backdrop.scene?.layers = [SceneLayer(kind: .stars, opacity: 1.5)]
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("opacity 1.5") })

        theme = sampleTheme()
        theme.backdrop.scene?.layers = [SceneLayer(kind: .stars, particle: .snow)]
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("only for particles") })

        theme = sampleTheme()
        theme.backdrop.scene?.layers = [SceneLayer(kind: .particles)]
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("needs a particle") })

        theme = sampleTheme()
        theme.backdrop.scene?.layers = [SceneLayer(kind: .shootingStars, everySeconds: [90, 30])]
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("everySeconds") })

        theme = sampleTheme()
        theme.backdrop.scene?.layers = [SceneLayer(kind: .shootingStars, everySeconds: [30])]
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("everySeconds") })

        theme = sampleTheme()
        theme.backdrop.scene?.glows = [Glow(color: RGBA(red: 1, green: 1, blue: 1), center: UnitPoint2(x: 3, y: 0.5), radius: 0.4)]
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("center") })

        theme = sampleTheme()
        theme.backdrop = Backdrop(kind: .fixed)
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("needs a scene") })

        theme = sampleTheme()
        theme.backdrop = Backdrop(kind: .sunCycle, phases: [.night: theme.backdrop.scene ?? Scene(gradient: [])])
        #expect(errors(ThemeLibrary.validate(theme)).contains { $0.contains("at least two phases") })

        theme = sampleTheme()
        theme.version = 0
        theme.name = " "
        let messages = errors(ThemeLibrary.validate(theme))
        #expect(messages.contains("version must be 1 or more") && messages.contains("name is empty"))
    }

    @Test func lowContrastIsAnErrorForBuiltInsAndAWarningForUsers() {
        // Dark chrome over a bright sky with a thin glass: white text can't be read.
        let bright = Scene(gradient: [
            GradientStop(color: RGBA(red: 0.9, green: 0.92, blue: 0.95), location: 0), GradientStop(color: RGBA(red: 0.95, green: 0.95, blue: 0.97), location: 1),
        ])
        var theme = sampleTheme(scene: bright)
        theme.palette.darkGlass = RGBA(red: 0.08, green: 0.09, blue: 0.11, alpha: 0.2)
        let strict = ThemeValidation.validate(theme, asBuiltIn: true)
        #expect(strict.contains { $0.severity == .error && $0.message.contains("needs 4.5:1") })
        let user = ThemeValidation.validate(theme, asBuiltIn: false)
        #expect(errors(user).isEmpty)
        #expect(user.contains { $0.severity == .warning && $0.message.contains("needs 4.5:1") })
        // Light tone over the same sky is fine.
        theme.tone = .light
        #expect(ThemeValidation.validate(theme, asBuiltIn: true).isEmpty)
        // Auto picks light chrome over a bright sky, dark over a dark one.
        theme.tone = .auto
        #expect(ThemeValidation.validate(theme, asBuiltIn: true).isEmpty)
        #expect(ThemeValidation.validate(sampleTheme(tone: .auto), asBuiltIn: true).isEmpty)
    }

    @Test func secondaryTextHasItsOwnBar() {
        // A mid-grey sky under a weak glass: primary ink passes, 56 % ink doesn't.
        let grey = Scene(gradient: [
            GradientStop(color: RGBA(red: 0.566, green: 0.566, blue: 0.566), location: 0), GradientStop(color: RGBA(red: 0.566, green: 0.566, blue: 0.566), location: 1),
        ])
        var theme = sampleTheme(tone: .dark, scene: grey)
        theme.palette.darkGlass = RGBA(red: 0.08, green: 0.08, blue: 0.08, alpha: 0.3)
        let report = ThemeValidation.contrastReport(theme)
        let row = try? #require(report.first)
        #expect((row?.primary ?? 0) >= 4.5)
        #expect((row?.secondary ?? 9) < 3)
        #expect(ThemeValidation.validate(theme, asBuiltIn: true).contains { $0.message.contains("secondary text") })
    }

    @Test func attentionMustStandOut() {
        var theme = sampleTheme()
        // Same orange as an ember layer.
        theme.backdrop.scene?.layers = [SceneLayer(kind: .particles, particle: .embers, colors: [RGBA(red: 1, green: 0.56, blue: 0.22)])]
        #expect(errors(ThemeValidation.validate(theme, asBuiltIn: true)).contains { $0.contains("embers layer") })
        #expect(errors(ThemeValidation.validate(theme, asBuiltIn: false)).isEmpty)
        // Same as a gradient stop.
        theme = sampleTheme()
        theme.backdrop.scene?.gradient[1].color = RGBA(red: 0.98, green: 0.5, blue: 0.18)
        #expect(errors(ThemeValidation.validate(theme, asBuiltIn: true)).contains { $0.contains("gradient color") })
        // Too close to danger.
        theme = sampleTheme()
        theme.palette.attention = RGBA(red: 0.95, green: 0.36, blue: 0.36)
        #expect(errors(ThemeValidation.validate(theme, asBuiltIn: true)).contains { $0.contains("too close to danger") })
        // A pale peach of the same hue is fine: the vivid orange still pops.
        theme = sampleTheme()
        theme.backdrop.scene?.gradient[1].color = RGBA(hex: "#F3D2B4") ?? RGBA(red: 0, green: 0, blue: 0)
        #expect(!ThemeValidation.validate(theme, asBuiltIn: true).contains { $0.message.contains("attention") })
    }

    @Test func hueDistanceWrapsAround() {
        #expect(ColorMath.hueDistance(350, 10) == 20)
        #expect(ColorMath.hueDistance(10, 190) == 180)
    }

    @Test func oklabRoundTrips() throws {
        for hex in ["#000000", "#FFFFFF", "#FF8A33", "#4A80CC", "#0B1128", "#3CF5A3"] {
            let color = try #require(RGBA(hex: hex))
            #expect(RGBA(oklab: color.oklab).hex == hex)
        }
        let white = try #require(RGBA(hex: "#FFFFFF"))
        #expect(abs(white.oklab.l - 1) < 0.001 && white.oklab.chroma < 0.001)
    }
}

@Suite("Sun-cycle blending")
struct BlendingTests {
    static let samples = [0, 0.15, 0.3, 0.5, 0.7, 0.85, 1.0]

    func colors(_ scene: Scene) -> [OKLab] {
        Self.samples.compactMap { ColorMath.color(in: scene.gradient, at: $0)?.oklab }
    }

    @Test func blendIsContinuousFromNightToDay() throws {
        for theme in ThemeLibrary.builtIn where theme.backdrop.kind == .sunCycle {
            var previous: Scene?
            var worst = 0.0
            var altitude = -20.0
            while altitude <= 30 {
                let scene = try #require(ThemeLibrary.scene(for: theme, sunAltitude: altitude))
                if let previous {
                    for (a, b) in zip(colors(previous), colors(scene)) { worst = max(worst, a.distance(to: b)) }
                    // Layers fade, never pop.
                    let before = Dictionary(previous.layers.map { ($0.kind.rawValue + ($0.particle?.rawValue ?? ""), $0.opacity ?? 1) }, uniquingKeysWith: max)
                    let after = Dictionary(scene.layers.map { ($0.kind.rawValue + ($0.particle?.rawValue ?? ""), $0.opacity ?? 1) }, uniquingKeysWith: max)
                    for key in Set(before.keys).union(after.keys) {
                        #expect(abs((before[key] ?? 0) - (after[key] ?? 0)) <= 0.16, "\(theme.id) \(key) at \(altitude)°")
                    }
                    for (a, b) in zip(previous.glows ?? [], scene.glows ?? []) {
                        #expect(abs(a.center.y - b.center.y) <= 0.06 && abs(a.color.alpha - b.color.alpha) <= 0.12, "\(theme.id) glow at \(altitude)°")
                    }
                }
                previous = scene
                altitude += 0.5
            }
            #expect(worst < 0.06, "\(theme.id): adjacent samples differ by ΔE \(worst)")
        }
    }

    @Test func anchorsShowTheirPhaseAndEndsHold() throws {
        let sky = try #require(ThemeLibrary.theme(id: "mothership-sky"))
        let phases = try #require(sky.backdrop.phases)
        for anchor in SceneBlending.anchors {
            #expect(ThemeLibrary.scene(for: sky, sunAltitude: anchor.altitude) == phases[anchor.phase], "\(anchor.phase)")
        }
        #expect(ThemeLibrary.scene(for: sky, sunAltitude: -60) == phases[.night])
        #expect(ThemeLibrary.scene(for: sky, sunAltitude: 75) == phases[.day])
        #expect(ThemeLibrary.scene(for: sky, sunAltitude: .nan) == phases[.night])
    }

    @Test func midpointIsAPerceptualMix() throws {
        let sky = try #require(ThemeLibrary.theme(id: "mothership-sky"))
        // Halfway between golden hour (4°) and day (20°): moon gone, clouds between.
        let scene = try #require(ThemeLibrary.scene(for: sky, sunAltitude: 12))
        #expect(!scene.layers.contains { $0.kind == .moon || $0.kind == .stars })
        let clouds = try #require(scene.layers.first { $0.kind == .clouds }?.opacity)
        #expect(clouds > 0.65 && clouds < 0.85)
        // The glow climbs with the sun.
        let glowY = try #require(scene.glows?.first?.center.y)
        #expect(glowY < 0.86 && glowY > 0.46)
        // Night → twilight: the moon fades out by opacity, stars dim.
        let dusk = try #require(ThemeLibrary.scene(for: sky, sunAltitude: -13.5))
        let moon = try #require(dusk.layers.first { $0.kind == .moon }?.opacity)
        #expect(moon > 0.1 && moon < 0.9)
    }

    @Test func phasesMaySkip() throws {
        // Only night and day: the blend spans the whole range.
        let night = Scene(gradient: [GradientStop(color: RGBA(red: 0, green: 0, blue: 0.1), location: 0), GradientStop(color: RGBA(red: 0, green: 0, blue: 0.2), location: 1)], layers: [SceneLayer(kind: .stars)])
        let day = Scene(gradient: [GradientStop(color: RGBA(red: 0.3, green: 0.5, blue: 0.8), location: 0), GradientStop(color: RGBA(red: 0.8, green: 0.9, blue: 1), location: 0.4), GradientStop(color: RGBA(red: 0.9, green: 0.9, blue: 1), location: 1)])
        let blended = try #require(SceneBlending.scene(phases: [.night: night, .day: day], altitude: 1))
        #expect(blended.gradient.map(\.location) == [0, 0.4, 1])
        let stars = try #require(blended.layers.first?.opacity)
        #expect(stars > 0 && stars < 1)
        #expect(SceneBlending.scene(phases: [:], altitude: 0) == nil)
    }
}

@Suite("User themes")
struct LoaderTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "themes-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, _ name: String, in directory: URL) throws {
        try text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
    }

    @Test func loadsValidThemesAndReportsTheRest() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var good = sampleTheme(id: "ocean-glass")
        try ThemeLibrary.export(good).write(to: folder.appending(path: "ocean.json"))
        good.id = "midnight"
        try ThemeLibrary.export(good).write(to: folder.appending(path: "dupe-builtin.json"))
        good.id = "ocean-glass"
        good.name = "Second"
        try ThemeLibrary.export(good).write(to: folder.appending(path: "zz-dupe-user.json"))
        try write("{ not json", "broken.json", in: folder)
        try write(#"{"id": "x", "name": "X", "summary": "s", "version": 1, "tone": "dark", "tags": []}"#, "missing.json", in: folder)
        let badColor = String(decoding: ThemeLibrary.export(sampleTheme(id: "bad-color")), as: UTF8.self).replacingOccurrences(of: "#FF8A33", with: "#GG8A33")
        try write(badColor, "bad-color.json", in: folder)
        var invalid = sampleTheme(id: "invalid")
        invalid.backdrop.scene?.layers = [SceneLayer(kind: .particles)]
        try ThemeLibrary.export(invalid).write(to: folder.appending(path: "invalid.json"))
        // Low contrast loads, with a warning.
        var dim = sampleTheme(id: "dim-glass", scene: Scene(gradient: [
            GradientStop(color: RGBA(red: 0.9, green: 0.9, blue: 0.9), location: 0), GradientStop(color: RGBA(red: 0.95, green: 0.95, blue: 0.95), location: 1),
        ]))
        dim.palette.darkGlass = RGBA(red: 0, green: 0, blue: 0, alpha: 0.1)
        try ThemeLibrary.export(dim).write(to: folder.appending(path: "dim.json"))
        try write("not a theme", "notes.txt", in: folder)

        let (themes, problems) = ThemeLibrary.load(userDirectory: folder)
        #expect(themes.count == ThemeLibrary.builtIn.count + 2)
        #expect(themes.prefix(19).map(\.id) == ThemeLibrary.builtIn.map(\.id))
        #expect(Set(themes.dropFirst(19).map(\.id)) == ["ocean-glass", "dim-glass"])
        #expect(problems["ocean.json"] == nil)
        #expect(problems["dupe-builtin.json"]?.first?.message.contains("built-in") == true)
        #expect(problems["zz-dupe-user.json"]?.first?.message.contains("already used by ocean.json") == true)
        #expect(problems["broken.json"]?.first?.message == "not valid JSON")
        #expect(problems["missing.json"]?.first?.message == "missing “backdrop”")
        #expect(problems["bad-color.json"]?.first?.message.contains("#GG8A33") == true)
        #expect(problems["invalid.json"]?.contains { $0.severity == .error } == true)
        #expect(problems["dim.json"]?.allSatisfy { $0.severity == .warning } == true)
        #expect(problems["notes.txt"] == nil)
    }

    /// The example in docs/themes.md is a valid theme.
    @Test func guideExampleIsValid() throws {
        let guide = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/themes.md")
        let text = try String(contentsOf: guide, encoding: .utf8)
        let start = try #require(text.range(of: "```json\n"))
        let end = try #require(text.range(of: "\n```", range: start.upperBound ..< text.endIndex))
        let theme = try JSONDecoder().decode(Theme.self, from: Data(text[start.upperBound ..< end.lowerBound].utf8))
        #expect(theme.id == "harbour-lights")
        #expect(ThemeValidation.validate(theme, asBuiltIn: true).isEmpty)
    }

    @Test func missingDirectoryIsJustBuiltIns() {
        let (themes, problems) = ThemeLibrary.load(userDirectory: URL(fileURLWithPath: "/nonexistent/themes"))
        #expect(themes == ThemeLibrary.builtIn)
        #expect(problems.isEmpty)
    }

    @Test func watcherReportsAddsEditsAndRemovals() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try ThemeLibrary.export(sampleTheme(id: "first")).write(to: folder.appending(path: "first.json"))
        let count = Mutex(0)
        let watcher = ThemeDirectoryWatcher(directory: folder, queue: DispatchQueue(label: "watcher-test"), latency: 0.05) {
            count.withLock { $0 += 1 }
        }
        #expect(watcher.start())
        defer { watcher.stop() }
        #expect(watcher.watchedFiles.count == 1)
        func changes(after action: () throws -> Void) async throws -> Bool {
            let before = count.withLock { $0 }
            try action()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if count.withLock({ $0 }) > before { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        // A new file.
        #expect(try await changes { try ThemeLibrary.export(sampleTheme(id: "second")).write(to: folder.appending(path: "second.json")) })
        // Saved in place (same inode).
        #expect(try await changes {
            let handle = try FileHandle(forWritingTo: folder.appending(path: "first.json"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" ".utf8))
            try handle.close()
        })
        // Replaced atomically, then edited in place again (the new inode is watched).
        #expect(try await changes { try ThemeLibrary.export(sampleTheme(id: "first")).write(to: folder.appending(path: "first.json"), options: .atomic) })
        #expect(try await changes {
            let handle = try FileHandle(forWritingTo: folder.appending(path: "first.json"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" ".utf8))
            try handle.close()
        })
        // Removed.
        #expect(try await changes { try FileManager.default.removeItem(at: folder.appending(path: "second.json")) })
        try await Task.sleep(for: .milliseconds(150))
        #expect(watcher.watchedFiles.map { ($0 as NSString).lastPathComponent } == ["first.json"])
        // Stopped: nothing more.
        watcher.stop()
        #expect(try await changes { try ThemeLibrary.export(sampleTheme(id: "third")).write(to: folder.appending(path: "third.json")) } == false)
    }

    @Test func watcherNeedsADirectory() {
        let watcher = ThemeDirectoryWatcher(directory: URL(fileURLWithPath: "/nonexistent/themes")) {}
        #expect(watcher.start() == false)
    }
}
