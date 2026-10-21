import SwiftUI

/// Frosted glass (§4 `glass.fill` + blur 30 + top highlight). No border, no shadow.
/// The real material blurs the sky behind it; the tint carries the look on its own, which
/// is also what a `cacheDisplay` snapshot captures.
struct GlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .skySolidPanel))
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Sky.glassFill)
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

    func glassPanel(radius: CGFloat = Sky.radiusPanel) -> some View {
        glass(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    func glassCapsule() -> some View {
        glass(Capsule(style: .continuous))
    }

    /// Opaque content card (`bubble`), with the Day-only elevation.
    func contentCard(radius: CGFloat = Sky.radiusPane) -> some View {
        modifier(ContentCard(radius: radius))
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Sky.Font.label)
            .foregroundStyle(foreground)
            .padding(.horizontal, height * 0.5)
            .frame(height: height)
            .background(Capsule(style: .continuous).fill(Sky.pillSecondary))
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
                .foregroundStyle(active ? Sky.onInk : Sky.ink.opacity(0.82))
                .frame(width: size, height: size)
                .background {
                    if active {
                        Circle().fill(Sky.ink)
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

/// Glass capsule track (36 pt, padding 3) with a sliding ink selection.
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
                        .foregroundStyle(selected ? Sky.onInk : Sky.secondary)
                        .padding(.horizontal, 16)
                        .frame(width: segmentWidth, height: height - 6)
                        .background {
                            if selected {
                                Capsule(style: .continuous)
                                    .fill(Sky.ink)
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
