import AppKit
import Foundation
import GhosttyTerminal
import GhosttyTheme

/// What Settings stores for the terminal color theme.
public enum TerminalThemeChoice: Sendable, Hashable {
    /// The theme from the user's Ghostty config if it sets one, else Mothership's own.
    case automatic
    case mothership
    /// A theme from the bundled iTerm2-Color-Schemes catalog, by name.
    case named(String)

    public var storageValue: String {
        switch self {
        case .automatic: "automatic"
        case .mothership: "mothership"
        case .named(let name): "theme:" + name
        }
    }

    public init(storageValue: String?) {
        switch storageValue {
        case "mothership": self = .mothership
        case let value? where value.hasPrefix("theme:"): self = .named(String(value.dropFirst("theme:".count)))
        default: self = .automatic
        }
    }
}

/// Owns the single `TerminalController` every surface shares: Ghostty config, theme and
/// font size. One per app.
@MainActor
public final class TerminalRuntime {
    public static let shared = TerminalRuntime()

    public static let defaultFontSize: Float = 13
    public static let fontSizeRange: ClosedRange<Float> = 8 ... 32

    public let controller: TerminalController
    /// The Ghostty config file whose fonts and colors were adopted, if any.
    public private(set) var userConfigPath: String?
    /// Set when the user's Ghostty config could not be loaded in full.
    public private(set) var configurationIssue: String?

    private var composed: ComposedGhosttyConfig
    private var themeChoiceStorage: TerminalThemeChoice
    private var fontSizeOverride: Float?

    /// Called after the theme or font size changed, so chrome can re-tint to the new background.
    public var onConfigurationChange: (() -> Void)?

    public init(themeChoice: TerminalThemeChoice = .automatic, fontSize: Float? = nil) {
        ResourceBundleBootstrap.prepare()
        let path = GhosttyConfigComposer.locateUserConfig()
        var composed = GhosttyConfigComposer.compose(path: path)
        self.userConfigPath = path
        self.themeChoiceStorage = themeChoice
        self.fontSizeOverride = fontSize.map(Self.clamp)

        controller = TerminalController(
            configSource: .generated(composed.base),
            theme: Self.theme(for: themeChoice, composed: composed),
            terminalConfiguration: Self.overrides(composed: composed, fontSize: fontSize.map(Self.clamp), backgroundOpacity: 1)
        )

        if let issue = controller.lastConfigurationIssue {
            // Keep what's safe (fonts, colors, padding) rather than dropping everything.
            configurationIssue = issue
            NSLog("Mothership: Ghostty config at %@ not fully loadable: %@", path ?? "-", issue)
            composed = GhosttyConfigComposer.compose(path: path, strict: true)
            if !controller.updateConfigSource(.generated(composed.base)) {
                composed = GhosttyConfigComposer.compose(path: nil)
                controller.updateConfigSource(.generated(""))
            }
            controller.setTheme(Self.theme(for: themeChoice, composed: composed))
            controller.setTerminalConfiguration(Self.overrides(composed: composed, fontSize: fontSizeOverride, backgroundOpacity: 1))
        }
        self.composed = composed
    }

    /// Below 1 lets the pane's blur (and the sky) through the terminal background.
    public var backgroundOpacity: Double = 1 {
        didSet {
            guard backgroundOpacity != oldValue else { return }
            applyOverrides()
        }
    }

    private func applyOverrides() {
        controller.setTerminalConfiguration(Self.overrides(composed: composed, fontSize: fontSizeOverride, backgroundOpacity: backgroundOpacity))
        onConfigurationChange?()
    }

    // MARK: Theme

    public var themeChoice: TerminalThemeChoice {
        get { themeChoiceStorage }
        set {
            guard newValue != themeChoiceStorage else { return }
            themeChoiceStorage = newValue
            controller.setTheme(Self.theme(for: newValue, composed: composed))
            onConfigurationChange?()
        }
    }

    /// Every theme name in the bundled catalog, for a picker.
    public static var availableThemeNames: [String] {
        GhosttyThemeCatalog.allThemes.map(\.name)
    }

    /// True when the user's Ghostty config chooses its own colors.
    public var userConfigHasTheme: Bool {
        composed.userTheme != nil || composed.definesColors
    }

    /// The effective terminal background, for tinting pane chrome to match.
    public var backgroundColor: NSColor {
        let color = controller.backgroundColor
        return NSColor(
            srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255, alpha: 1
        )
    }

    /// Background of a named catalog theme (or Mothership's), for swatches in Settings.
    public static func previewColors(for choice: TerminalThemeChoice, dark: Bool) -> (background: NSColor, foreground: NSColor, accents: [NSColor])? {
        switch choice {
        case .automatic:
            return nil
        case .mothership:
            // Dark in every sky: dark cards on a Day sky are part of the look (DESIGN §8).
            return (hex("0E1013"), hex("D9DCE3"), ["F2777A", "A3D68E", "EDC57E", "7FA7F5", "C59BF2"].map(hex))
        case .named(let name):
            guard let theme = GhosttyConfigComposer.catalogTheme(named: name) else { return nil }
            let accents = (1 ... 5).compactMap { theme.palette[$0] }.map(hex)
            return (hex(theme.background), hex(theme.foreground), accents)
        }
    }

    // MARK: Font size

    /// Points; follows the Ghostty config until the user changes it here.
    public var fontSize: Float {
        fontSizeOverride ?? composed.userFontSize ?? Self.defaultFontSize
    }

    public var hasFontSizeOverride: Bool { fontSizeOverride != nil }

    public func setFontSize(_ size: Float?) {
        let clamped = size.map(Self.clamp)
        guard clamped != fontSizeOverride else { return }
        fontSizeOverride = clamped
        applyOverrides()
    }

    public func adjustFontSize(by delta: Float) {
        setFontSize(fontSize + delta)
    }

    public func resetFontSize() {
        setFontSize(nil)
    }

    // MARK: Private

    private static func clamp(_ size: Float) -> Float {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    private static func theme(for choice: TerminalThemeChoice, composed: ComposedGhosttyConfig) -> TerminalTheme {
        switch choice {
        case .automatic:
            if let theme = composed.userTheme { return theme }
            // The user picked colors line by line; an empty theme leaves them in charge.
            return composed.definesColors ? TerminalTheme() : .mothership
        case .mothership:
            return .mothership
        case .named(let name):
            return GhosttyConfigComposer.catalogTheme(named: name)?.toTerminalTheme() ?? .mothership
        }
    }

    private static func overrides(composed: ComposedGhosttyConfig, fontSize: Float?, backgroundOpacity: Double) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            if let size = fontSize ?? (composed.userFontSize == nil ? defaultFontSize : nil) {
                builder.withFontSize(size)
            }
            if !composed.definesPadding {
                // Sky §8: 16 / 14 inside a radius-18 card.
                builder.withWindowPaddingX(16)
                builder.withWindowPaddingY(14)
                builder.withCustom("window-padding-balance", "true")
            }
            if backgroundOpacity < 1 {
                builder.withBackgroundOpacity(backgroundOpacity)
            }
            // Panes close through Mothership's own UI; Ghostty's quit/close prompts don't apply.
            builder.withCustom("confirm-close-surface", "false")
        }
    }
}

private func hex(_ value: String) -> NSColor {
    let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard digits.count >= 6, let raw = UInt32(digits.prefix(6), radix: 16) else { return .black }
    return NSColor(
        srgbRed: CGFloat((raw >> 16) & 0xFF) / 255, green: CGFloat((raw >> 8) & 0xFF) / 255,
        blue: CGFloat(raw & 0xFF) / 255, alpha: 1
    )
}
