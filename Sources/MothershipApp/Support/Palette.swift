import AppKit
import ShipModel
import SwiftUI

/// Colors shared by AppKit chrome and SwiftUI views. Dark-first; every token has a light twin.
enum Palette {
    /// Brand accent: focus rings, selection, primary buttons.
    static let accent = Color(nsColor: .accentShip)
    /// Agent waiting on the user.
    static let attention = Color(nsColor: .attentionShip)
    static let success = Color(red: 0.36, green: 0.80, blue: 0.52)
    static let failure = Color(red: 0.95, green: 0.38, blue: 0.38)
    /// Inset behind inline code (commands in permission cards).
    static let codeWell = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.black.withAlphaComponent(0.24) : NSColor.black.withAlphaComponent(0.055)
    })

    static func agentColor(_ kind: AgentKind) -> Color {
        Color(nsColor: agentNSColor(kind))
    }

    static func agentNSColor(_ kind: AgentKind) -> NSColor {
        switch kind {
        case .claude: NSColor(hex: "D97757") ?? .systemOrange
        case .codex: NSColor(name: nil) { appearance in
                appearance.isDark ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.22, alpha: 1)
            }
        case .opencode: NSColor(hex: "8B8CF6") ?? .systemIndigo
        case .gemini: NSColor(hex: "4B8DF8") ?? .systemBlue
        default: .secondaryLabelColor
        }
    }

    /// SF Symbol for each agent's badge.
    static func agentSymbol(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .opencode: "curlybraces"
        case .gemini: "sparkle"
        default: "cpu"
        }
    }

    static let workspaceColors: [(name: String, hex: String)] = [
        ("Ember", "F07D5A"), ("Amber", "E8B04A"), ("Moss", "7CC47F"), ("Lagoon", "4FC1C9"),
        ("Iris", "7C8CFF"), ("Orchid", "C58AF0"), ("Rose", "EE7FA6"), ("Slate", "8E96A8"),
    ]
}

extension NSColor {
    /// Periwinkle: reads as "Mothership" without fighting agent colors.
    static let accentShip = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.52, green: 0.58, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.33, green: 0.38, blue: 0.92, alpha: 1)
    }

    static let attentionShip = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.24, alpha: 1)

    /// Behind the panes: a touch darker than the terminal so gaps read as structure.
    static let canvasShip = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.050, green: 0.055, blue: 0.066, alpha: 1)
            : NSColor(srgbRed: 0.905, green: 0.910, blue: 0.925, alpha: 1)
    }

    static let paneBorderShip = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 0, alpha: 0.09)
    }

    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let raw = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((raw >> 16) & 0xFF) / 255, green: CGFloat((raw >> 8) & 0xFF) / 255,
            blue: CGFloat(raw & 0xFF) / 255, alpha: 1
        )
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "000000" }
        return String(
            format: "%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? true
    }
}
