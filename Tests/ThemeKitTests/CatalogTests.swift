import Foundation
import GhosttyTheme
import Testing

@testable import ThemeKit

@Suite("Built-in catalog")
struct CatalogTests {
    static let expectedIDs = [
        "mothership-sky", "midnight", "aurora", "nebula", "deep-sea", "sakura", "ember", "monsoon", "first-snow", "dune",
        "firefly-forest", "synthwave", "digital-rain", "mars", "lunar", "golden-hour", "graphite", "paper", "desktop",
    ]

    @Test func allNineteenDecodeDefaultFirst() {
        let themes = ThemeLibrary.builtIn
        #expect(BuiltInThemes.json.count == 19)
        #expect(themes.map(\.id) == Self.expectedIDs)
        #expect(themes.first?.id == ThemeLibrary.defaultThemeID)
        #expect(themes.first?.backdrop.kind == .sunCycle)
        #expect(Set(themes.map(\.id)).count == themes.count)
    }

    @Test func everyBuiltInValidatesWithoutErrors() {
        for theme in ThemeLibrary.builtIn {
            let issues = ThemeLibrary.validate(theme)
            let errors = issues.filter { $0.severity == .error }
            #expect(errors.isEmpty, "\(theme.id): \(errors)")
            #expect(issues.isEmpty, "\(theme.id) warnings: \(issues)")
        }
    }

    @Test func everyBuiltInIsDescribed() {
        for theme in ThemeLibrary.builtIn {
            #expect(!theme.name.isEmpty && !theme.summary.isEmpty, "\(theme.id)")
            #expect(theme.tags.contains("animated") != theme.tags.contains("still"), "\(theme.id): animated or still")
            #expect(theme.tags.contains("light") || theme.tags.contains("dark"), "\(theme.id): light or dark")
            switch theme.tone {
            case .light: #expect(theme.tags.contains("light") && !theme.tags.contains("dark"), "\(theme.id)")
            case .dark: #expect(theme.tags.contains("dark") && !theme.tags.contains("light"), "\(theme.id)")
            case .auto: #expect(theme.tags.contains("light") && theme.tags.contains("dark"), "\(theme.id)")
            }
            #expect(theme.terminal != nil, "\(theme.id): terminal pairing")
            let animated = theme.backdrop.kind != .desktop && (ThemeLibrary.scene(for: theme, sunAltitude: 10)?.layers.contains { $0.kind != .grain && ($0.speed ?? 0.5) > 0 } ?? false)
            if theme.tags.contains("still") { #expect(!animated || theme.id == "lunar", "\(theme.id) is tagged still") }
        }
    }

    @Test func terminalPairingsExistInGhostty() {
        for theme in ThemeLibrary.builtIn {
            for name in [theme.terminal?.dark, theme.terminal?.light].compactMap({ $0 }) {
                #expect(GhosttyThemeCatalog.theme(named: name) != nil, "\(theme.id): no Ghostty theme named “\(name)”")
            }
        }
        // Light-tone themes pair with a light terminal theme; paper only with one.
        #expect(ThemeLibrary.theme(id: "paper")?.terminal == TerminalPairing(light: "Alabaster"))
        for theme in ThemeLibrary.builtIn where theme.tone == .light {
            #expect(theme.terminal?.light != nil, "\(theme.id)")
        }
    }

    @Test func pairedTerminalThemesMatchTheirSide() throws {
        func luminance(_ hex: String) throws -> Double { try #require(RGBA(hex: hex)).luminance }
        for theme in ThemeLibrary.builtIn {
            if let dark = theme.terminal?.dark, let definition = GhosttyThemeCatalog.theme(named: dark) {
                #expect(try luminance(definition.background) < 0.2, "\(theme.id): “\(dark)” isn't dark")
            }
            if let light = theme.terminal?.light, let definition = GhosttyThemeCatalog.theme(named: light) {
                #expect(try luminance(definition.background) > 0.5, "\(theme.id): “\(light)” isn't light")
            }
        }
    }

    @Test func desktopHasNoScene() throws {
        let desktop = try #require(ThemeLibrary.theme(id: "desktop"))
        #expect(desktop.backdrop.kind == .desktop)
        #expect(ThemeLibrary.scene(for: desktop, sunAltitude: 10) == nil)
        let graphite = try #require(ThemeLibrary.theme(id: "graphite"))
        #expect(ThemeLibrary.scene(for: graphite, sunAltitude: -40) == graphite.backdrop.scene)
    }

    @Test func roundTripsThroughExport() throws {
        for theme in ThemeLibrary.builtIn {
            let data = ThemeLibrary.export(theme)
            let decoded = try JSONDecoder().decode(Theme.self, from: data)
            #expect(decoded == theme, "\(theme.id)")
            // Stable: the same bytes every time, and again after a round trip.
            #expect(ThemeLibrary.export(decoded) == data)
        }
        let text = String(decoding: ThemeLibrary.export(ThemeLibrary.builtIn[0]), as: UTF8.self)
        #expect(text.contains("\n  \"author\" : \"Mothership\""))
        #expect(text.contains("\"night\" : {"))
    }

    /// The contrast numbers behind the validation, for the record.
    @Test func contrastReportCoversEveryScene() {
        for theme in ThemeLibrary.builtIn {
            let report = ThemeValidation.contrastReport(theme)
            #expect(report.count == (theme.backdrop.kind == .desktop ? 0 : (theme.backdrop.phases?.count ?? 1)))
            for row in report {
                #expect(row.primary >= 4.5, "\(theme.id) \(row.scene)")
                #expect(row.secondary >= 3, "\(theme.id) \(row.scene)")
            }
        }
    }
}
