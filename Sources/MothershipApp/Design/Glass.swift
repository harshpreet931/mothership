import SwiftUI

/// Frosted glass (§4 `glass.fill` + blur 30 + top highlight). No border, no shadow.
/// The real material blurs the sky behind it; the tint carries the look on its own, which
/// is also what a `cacheDisplay` snapshot captures.
struct GlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    /// Overlays that sit above busy content (palette, toasts) use a denser tint (§9 scrim).
    var dense = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                let tint = dense ? Sky.glassDense : Sky.glassFill
                // Light glass over a dark sky (a light terminal at night) would read as grey;
                // it gets more white so it stays glass.
                let lift = scheme == .light && SkyContext.shared.skyIsDark
                if reduceTransparency {
                    shape.fill(Color(nsColor: .skySolidPanel))
                } else {
                    if SnapshotMode.shared.active {
                        shape.fill(tint)
                    } else {
                        // The material whitens a little on its own; together they land on
                        // the spec's tint.
                        shape.fill(.ultraThinMaterial)
                        shape.fill(tint.opacity(0.75))
                    }
                    if lift { shape.fill(Color.white.opacity(0.28)) }
                    // Top inner hairline: light catching the edge of the glass.
                    shape.strokeBorder(
                        LinearGradient(colors: [Sky.glassHighlight, Sky.glassHighlight.opacity(0)], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)),
                        lineWidth: 1
                    )
                }
                if contrast == .increased {
                    shape.strokeBorder(Sky.ink.opacity(0.3), lineWidth: 1)
                }
            }
        }
    }
}

extension View {
    func glass<S: InsettableShape>(_ shape: S) -> some View {
        modifier(GlassBackground(shape: shape))
    }

    func glassPanel(radius: CGFloat = Sky.radiusPanel, dense: Bool = false) -> some View {
        modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), dense: dense))
    }

    func glassCapsule() -> some View {
        glass(Capsule(style: .continuous))
    }

    /// Opaque overlay surface (palette, menus over terminal text): `bubble` with a
    /// hairline and a soft shadow, so nothing busy shows through.
    func solidPanel(radius: CGFloat = Sky.radiusPanel) -> some View {
        modifier(SolidPanel(radius: radius))
    }

    /// Opaque content card (`bubble`), with the Day-only elevation.
    func contentCard(radius: CGFloat = Sky.radiusPane) -> some View {
        modifier(ContentCard(radius: radius))
    }
}

struct SolidPanel: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape.fill(Sky.bubble)
                .overlay(shape.strokeBorder(Sky.cardStroke, lineWidth: 1))
                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.16), radius: 24, y: 12)
        }
    }
}

struct ContentCard: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Sky.bubble)
                .shadow(color: scheme == .light ? Sky.ink.opacity(0.08) : .clear, radius: 12, y: 8)
        }
    }
}

// MARK: Buttons (§6: capsules and circles only)

/// Primary: solid ink capsule.
struct InkCapsuleStyle: ButtonStyle {
    var height: CGFloat = 28
    var font: Font = Sky.Font.label

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(Sky.onInk)
            .padding(.horizontal, height * 0.5)
            .frame(height: height)
            .background(Capsule(style: .continuous).fill(Sky.ink))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(Capsule())
    }
}

/// Secondary: Hark's white "Connect" pill.
struct SecondaryPillStyle: ButtonStyle {
    var height: CGFloat = 28
    var foreground: Color = Sky.ink
    /// `pill.secondary` by default; a recess when the pill sits on a white card.
    var fill: Color = Sky.pillSecondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Sky.Font.label)
            .foregroundStyle(foreground)
            .padding(.horizontal, height * 0.5)
            .frame(height: height)
            .background(Capsule(style: .continuous).fill(fill))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Ghost: text only, a glass wash on hover.
struct GhostPillStyle: ButtonStyle {
    var height: CGFloat = 28
    var foreground: Color = Sky.secondary

    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration, height: height, foreground: foreground)
    }

    private struct GhostBody: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let foreground: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Sky.Font.label)
                .foregroundStyle(foreground)
                .padding(.horizontal, height * 0.45)
                .frame(height: height)
                .background(Capsule(style: .continuous).fill(Sky.ink.opacity(hovering ? 0.06 : 0)))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Capsule())
                .onHover { hovering in withAnimation(Sky.hover) { self.hovering = hovering } }
        }
    }
}

/// A 32 or 44 pt glass circle holding one symbol.
struct CircleButton: View {
    let symbol: String
    var size: CGFloat = 32
    var label: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(active ? Sky.onSegment : Sky.ink.opacity(0.82))
                .frame(width: size, height: size)
                .background {
                    if active {
                        Circle().fill(Sky.segment).overlay(Circle().strokeBorder(Sky.segmentStroke, lineWidth: 1))
                    } else {
                        Circle().fill(Color.clear).glass(Circle())
                            .overlay(Circle().fill(Sky.ink.opacity(hovering ? 0.05 : 0)))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Sky.hover) { self.hovering = hovering } }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Glass capsule track (36 pt, padding 3) with a sliding selection (ink by day, frost at night).
struct SegmentedPill<Value: Hashable>: View {
    let items: [(value: Value, title: String)]
    @Binding var selection: Value
    var height: CGFloat = 36
    var segmentWidth: CGFloat? = nil
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    withAnimation(Sky.spring) { selection = item.value }
                } label: {
                    Text(item.title)
                        .font(Sky.Font.label)
                        .foregroundStyle(selected ? Sky.onSegment : Sky.secondary)
                        .padding(.horizontal, 16)
                        .frame(width: segmentWidth, height: height - 6)
                        .background {
                            if selected {
                                Capsule(style: .continuous)
                                    .fill(Sky.segment)
                                    .overlay(Capsule(style: .continuous).strokeBorder(Sky.segmentStroke, lineWidth: 1))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .glassCapsule()
    }
}

/// Sky's switch: a filled track when on (ink by day, calm blue at night), a recessed one
/// when off, and a white knob either way. Drawn by SwiftUI so on and off never look alike.
struct SkySwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) { configuration.isOn.toggle() }
        } label: {
            Capsule(style: .continuous)
                .fill(on ? Sky.accentToggle : Sky.ink.opacity(0.14))
                .frame(width: 38, height: 22)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "On" : "Off")
    }
}

extension EnvironmentValues {
    /// The sky's own light or dark, for text drawn straight on it (set by the screen layer).
    @Entry var skyColorScheme: ColorScheme?
}

/// Text drawn straight on the sky (Home's clock and greeting, page titles, footnotes
/// between panels) takes the sky's light or dark, not the chrome's: ink on a bright day,
/// white at night, whatever the terminal's tone.
struct OnSkyText: ViewModifier {
    @Environment(\.skyColorScheme) private var scheme

    func body(content: Content) -> some View {
        if let scheme {
            content.environment(\.colorScheme, scheme)
        } else {
            content
        }
    }
}

extension View {
    func onSkyText() -> some View {
        modifier(OnSkyText())
    }
}

/// The sky's light or dark for chrome that needs it (glass over a mismatched sky). Set by
/// the root view as the sun moves.
@MainActor
@Observable
final class SkyContext {
    static let shared = SkyContext()
    var skyIsDark = true
    private init() {}
}

/// The selection surface for rows and chips: a white card lifted by a soft shadow in light
/// tone, frosted white with a hairline in dark tone.
struct SelectionFill<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape.fill(Sky.selection)
            .overlay(shape.strokeBorder(Sky.selectionStroke, lineWidth: 1))
            .shadow(color: Sky.selectionShadow, radius: 6, y: 2)
    }
}

/// Fades a scroll view's content out over its bottom edge instead of cutting it off.
struct BottomFade: ViewModifier {
    var height: CGFloat = 28

    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
            }
        }
    }
}

extension View {
    func bottomFade(_ height: CGFloat = 28) -> some View {
        modifier(BottomFade(height: height))
    }
}

/// Small chip of mono metadata on a recessed surface.
struct MetaChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Sky.Font.meta)
            .foregroundStyle(Sky.ink.opacity(0.82))
            .lineLimit(2)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Sky.radiusChip, style: .continuous).fill(Sky.recess))
    }
}
