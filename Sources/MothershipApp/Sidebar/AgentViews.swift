import ShipModel
import SwiftUI

/// The agent's mark: its symbol on a soft tile of its color.
struct AgentGlyph: View {
    let kind: AgentKind
    var size: CGFloat = 16

    var body: some View {
        let color = Palette.agentColor(kind)
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color.opacity(0.18))
            .overlay {
                Image(systemName: Palette.agentSymbol(kind))
                    .font(.system(size: size * 0.56, weight: .bold))
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
            .accessibilityLabel(kind.displayName)
    }
}

/// State treatment: spinner while working, pulsing orange when it needs you, green when
/// it finished unseen, red on error.
struct AgentStateIndicator: View {
    let state: AgentState
    let unread: Bool
    var tint: Color = .secondary

    var body: some View {
        switch state {
        case .working, .starting:
            Spinner(color: tint)
                .frame(width: 9, height: 9)
                .help("Working")
        case .needsInput:
            PulsingDot(color: Palette.attention)
                .help("Needs your input")
        case .error(let message):
            Dot(color: Palette.failure)
                .help(message)
        case .idle where unread:
            Dot(color: Palette.success)
                .help("Finished")
        case .idle, .ended:
            EmptyView()
        }
    }
}

struct Dot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background {
                Circle()
                    .fill(color.opacity(0.45))
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 0.9)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

struct Spinner: View {
    let color: Color
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.82)
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { rotation = 360 }
            }
    }
}

/// A light sweep across text while an agent works.
struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.65), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: max(40, geometry.size.width * 0.45))
                    .offset(x: phase * geometry.size.width)
                }
                .mask(content)
                .allowsHitTesting(false)
                .onAppear {
                    withAnimation(.linear(duration: 1.9).repeatForever(autoreverses: false)) { phase = 1.2 }
                }
            }
        }
    }
}

extension View {
    func shimmer(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

/// Compact capsule for one session: glyph + state.
struct AgentBadge: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 4) {
            AgentGlyph(kind: session.kind, size: 15)
            AgentStateIndicator(state: session.state, unread: session.unread, tint: Palette.agentColor(session.kind))
        }
        .padding(.leading, 2)
        .padding(.trailing, hasIndicator ? 5 : 2)
        .padding(.vertical, 2)
        .background(Palette.agentColor(session.kind).opacity(0.10), in: Capsule())
        .help(helpText)
    }

    private var hasIndicator: Bool {
        switch session.state {
        case .idle: session.unread
        case .ended: false
        default: true
        }
    }

    private var helpText: String {
        "\(session.kind.displayName) — \(session.state.label)" + (session.title.map { "\n\($0)" } ?? "")
    }
}

/// Inline Allow / Deny for a held permission hook.
struct PermissionCard: View {
    let request: PermissionRequest
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.attention)
                Text("\(request.toolName) needs approval")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            Text(request.summary)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Palette.codeWell, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .help(request.detail ?? request.summary)
            HStack(spacing: 6) {
                Button(action: onDeny) {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle())
                Button(action: onAllow) {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: Palette.attention, foreground: Color.black.opacity(0.85)))
            }
        }
        .padding(8)
        .background(Palette.attention.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.attention.opacity(0.28), lineWidth: 1)
        }
    }
}

extension AgentState {
    var label: String {
        switch self {
        case .starting: "Starting"
        case .idle: "Idle"
        case .working(let tool): tool.map { "Working · \($0)" } ?? "Working"
        case .needsInput(.permission): "Waiting for permission"
        case .needsInput(.question): "Waiting for your answer"
        case .needsInput: "Needs input"
        case .error(let message): "Error · \(message)"
        case .ended: "Ended"
        }
    }

    /// Lower sorts first: what deserves eyes.
    var urgency: Int {
        switch self {
        case .needsInput: 0
        case .error: 1
        case .working, .starting: 2
        case .idle: 3
        case .ended: 4
        }
    }
}

extension AgentSession {
    /// The one line under a workspace: what it's doing or what it last said.
    var displayLine: String? {
        let text = summary ?? lastAssistantMessage ?? title
        return text?.replacingOccurrences(of: "\n", with: " ")
    }
}
