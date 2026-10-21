import AppKit
import SwiftUI

/// "Arch M" (DESIGN §11): two arches with three legs over a hovering disc. Geometry is the
/// spec's 120 × 120 viewBox, shifted up 1 unit to sit optically centered.
struct ArchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 120
        let origin = CGPoint(x: rect.midX - 60 * unit, y: rect.midY - 60 * unit - unit)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * unit, y: origin.y + y * unit) }
        var path = Path()
        // M28 68 V54 A16 16 0 0 1 60 54 V68
        path.move(to: p(28, 68))
        path.addLine(to: p(28, 54))
        path.addArc(center: p(44, 54), radius: 16 * unit, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: p(60, 68))
        // M60 54 A16 16 0 0 1 92 54 V68
        path.move(to: p(60, 54))
        path.addArc(center: p(76, 54), radius: 16 * unit, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: p(92, 68))
        return path
    }
}

/// The disc: `rect x18 y80 w84 h9 rx4.5` (h 11, rx 5.5 at small sizes).
struct DiscShape: Shape {
    var small = false

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 120
        let origin = CGPoint(x: rect.midX - 60 * unit, y: rect.midY - 60 * unit - unit)
        let height: CGFloat = small ? 11 : 9
        let frame = CGRect(x: origin.x + 18 * unit, y: origin.y + 80 * unit, width: 84 * unit, height: height * unit)
        return Path(roundedRect: frame, cornerRadius: height / 2 * unit, style: .continuous)
    }
}

struct MothershipMark: View {
    enum Variant {
        /// Light arches, blue disc: dark UI and the app icon.
        case dark
        /// Ink arches, deeper blue disc: on white.
        case light
        /// Ink arches, white disc on a Day sky; follows the scheme (Night uses `.dark`).
        case sky
        /// One color, heavier strokes: menu bar, template images, tiny sizes.
        case mono(Color)
    }

    var variant: Variant = .sky
    var size: CGFloat = 32
    /// 0…1 draws the disc out from its center (launch motion).
    var discProgress: CGFloat = 1
    /// Units the arches sit below their resting place (launch motion rises from 2 → 0).
    var archDrop: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    private var small: Bool {
        if case .mono = variant { return true }
        return size <= 32
    }

    var body: some View {
        let unit = size / 120
        ZStack {
            DiscShape(small: small)
                .fill(discStyle)
                .scaleEffect(x: max(discProgress, 0.001), y: 1, anchor: .center)
            ArchShape()
                .stroke(archColor, style: StrokeStyle(lineWidth: (small ? 12 : 10) * unit, lineCap: .round, lineJoin: .round))
                .offset(y: archDrop * unit)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Mothership")
    }

    private var resolved: Variant {
        if case .sky = variant, scheme == .dark { return .dark }
        return variant
    }

    private var archColor: Color {
        switch resolved {
        case .dark: Color(red: 0xF4 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
        case .light, .sky: Color(red: 0x0D / 255, green: 0x0E / 255, blue: 0x11 / 255)
        case .mono(let color): color
        }
    }

    private var discStyle: AnyShapeStyle {
        switch resolved {
        case .dark:
            AnyShapeStyle(LinearGradient(colors: [Self.hex(0x5B8FD6), Self.hex(0xC6DBFF)], startPoint: .leading, endPoint: .trailing))
        case .light:
            AnyShapeStyle(LinearGradient(colors: [Self.hex(0x3F74C4), Self.hex(0x8DB4F0)], startPoint: .leading, endPoint: .trailing))
        case .sky:
            AnyShapeStyle(Color.white)
        case .mono(let color):
            AnyShapeStyle(color)
        }
    }

    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// Plays the launch motion once per run: the disc draws out from its center, then the
/// arches rise 2 units into place (≤ 600 ms). Reduce Motion shows it at rest.
struct AnimatedMothershipMark: View {
    var variant: MothershipMark.Variant = .sky
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var disc: CGFloat = 1
    @State private var drop: CGFloat = 0
    @MainActor private static var played = false

    var body: some View {
        MothershipMark(variant: variant, size: size, discProgress: disc, archDrop: drop)
            .onAppear {
                guard !Self.played, !reduceMotion, !SnapshotMode.shared.active else { return }
                Self.played = true
                disc = 0
                drop = 2
                withAnimation(.easeOut(duration: 0.32)) { disc = 1 }
                withAnimation(.spring(response: 0.26, dampingFraction: 0.8).delay(0.3)) { drop = 0 }
            }
    }
}

/// Mark + `mothership` (lowercase, SF Pro Display Medium, tracking −3.5 %). The mark's
/// ink height is ~1.45 × the x-height; the gap is 0.4 × the mark's width.
struct MothershipLockup: View {
    var fontSize: CGFloat = 20
    var variant: MothershipMark.Variant = .sky

    var body: some View {
        // Visible mark height is 56/120 of its frame; x-height ≈ 0.52 em.
        let markSize = 1.45 * 0.52 * fontSize * 120 / 56
        // Visible width is 84/120 of the frame; the frame's 18/120 side insets are trimmed
        // below, so the spacing is the gap between ink edges.
        let gap = 0.4 * markSize * 84 / 120
        HStack(spacing: gap) {
            MothershipMark(variant: variant, size: markSize)
                .padding(.horizontal, -markSize * 18 / 120)
            Text("mothership")
                .font(.system(size: fontSize, weight: .medium))
                .tracking(-0.035 * fontSize)
                .foregroundStyle(Sky.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mothership")
    }
}

/// The app icon tile (§11): ink rounded rect, a top radial highlight and inner hairline,
/// the `.dark` mark at ~62 % of the width. Used for the About panel when unbundled.
struct AppIconTile: View {
    var size: CGFloat = 256

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2245, style: .continuous)
        ZStack {
            shape.fill(MothershipMark.hex(0x0D0E11))
            shape.fill(RadialGradient(colors: [.white.opacity(0.14), .white.opacity(0)], center: .top, startRadius: 0, endRadius: size * 0.7))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: max(1, size / 340))
            // Visible mark width is 84/120 of its frame: 0.62 / 0.7 ≈ 0.886 of the tile.
            MothershipMark(variant: .dark, size: size * 0.62 * 120 / 84)
        }
        .frame(width: size, height: size)
    }

    @MainActor
    static func image(size: CGFloat = 512) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconTile(size: size))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
