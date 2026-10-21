import ShipModel
import SwiftUI

/// Simple monochrome marks that read as each agent without shipping brand artwork:
/// a spark (Claude), a six-link knot (Codex), brackets (OpenCode), a four-point sparkle
/// (Gemini).
struct AgentMarkShape: Shape {
    let kind: AgentKind

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        switch kind {
        case .claude:
            var path = Path()
            let rays = 10
            for index in 0 ..< rays {
                let angle = Double(index) / Double(rays) * 2 * .pi + 0.18
                let length = index.isMultiple(of: 2) ? 0.47 : 0.38
                path.move(to: CGPoint(x: c.x + cos(angle) * s * 0.07, y: c.y + sin(angle) * s * 0.07))
                path.addLine(to: CGPoint(x: c.x + cos(angle) * s * length, y: c.y + sin(angle) * s * length))
            }
            return path.strokedPath(StrokeStyle(lineWidth: s * 0.11, lineCap: .round))
        case .codex:
            var path = Path()
            for index in 0 ..< 6 {
                let angle = Double(index) * .pi / 3
                let link = Path(roundedRect: CGRect(x: -s * 0.12, y: -s * 0.27, width: s * 0.24, height: s * 0.42), cornerRadius: s * 0.12)
                let transform = CGAffineTransform(translationX: c.x, y: c.y)
                    .rotated(by: angle)
                    .translatedBy(x: s * 0.14, y: -s * 0.04)
                path.addPath(link, transform: transform)
            }
            return path.strokedPath(StrokeStyle(lineWidth: s * 0.075, lineJoin: .round))
        case .opencode:
            var path = Path()
            let top = c.y - s * 0.34, bottom = c.y + s * 0.34
            path.move(to: CGPoint(x: c.x - s * 0.12, y: top))
            path.addLine(to: CGPoint(x: c.x - s * 0.3, y: top))
            path.addLine(to: CGPoint(x: c.x - s * 0.3, y: bottom))
            path.addLine(to: CGPoint(x: c.x - s * 0.12, y: bottom))
            path.move(to: CGPoint(x: c.x + s * 0.12, y: top))
            path.addLine(to: CGPoint(x: c.x + s * 0.3, y: top))
            path.addLine(to: CGPoint(x: c.x + s * 0.3, y: bottom))
            path.addLine(to: CGPoint(x: c.x + s * 0.12, y: bottom))
            return path.strokedPath(StrokeStyle(lineWidth: s * 0.11, lineCap: .round, lineJoin: .round))
        case .gemini:
            var path = Path()
            let r = s * 0.48
            path.move(to: CGPoint(x: c.x, y: c.y - r))
            path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
            path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
            path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
            path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
            return path
        default:
            return Path(ellipseIn: CGRect(x: c.x - s * 0.3, y: c.y - s * 0.3, width: s * 0.6, height: s * 0.6))
                .strokedPath(StrokeStyle(lineWidth: s * 0.1))
        }
    }
}

struct AgentMark: View {
    let kind: AgentKind
    var size: CGFloat = 14
    var color: Color = Sky.ink

    var body: some View {
        AgentMarkShape(kind: kind)
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityLabel(kind.displayName)
    }
}

/// A mark plus its state overlay (§6 Agent glyphs).
struct AgentStatusGlyph: View {
    let kind: AgentKind
    let state: AgentState
    var unread = false
    var hasPermission = false
    var size: CGFloat = 14
    var color: Color = Sky.ink

    private var needsYou: Bool { state.isNeedsInput || hasPermission }

    var body: some View {
        AgentMark(kind: kind, size: size, color: needsYou ? Sky.attention : color)
            .overlay {
                if state.isWorking {
                    WorkingArc(color: color)
                        .frame(width: size + 7, height: size + 7)
                }
            }
            .overlay(alignment: .topTrailing) {
                Group {
                    if needsYou {
                        HaloDot(color: Sky.attention)
                    } else if case .error = state {
                        StatusDot(color: Sky.danger)
                    } else if unread, state == .idle {
                        StatusDot(color: color)
                    }
                }
                .offset(x: 3, y: -3)
            }
            .frame(width: size + 7, height: size + 7)
            .help(state.label)
    }
}

/// Slow rotating arc: 2 s per turn, 1.5 pt (frozen under Reduce Motion).
struct WorkingArc: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// Amber dot with the attention pulse: 1.8 s, scale 1 → 1.35, opacity 0.5 → 0.
struct HaloDot: View {
    let color: Color
    var size: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(color)
                    .frame(width: size * 2.2, height: size * 2.2)
                    .scaleEffect(pulse ? 1.35 : 1)
                    .opacity(pulse ? 0 : 0.5)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

extension AgentState {
    var isNeedsInput: Bool {
        if case .needsInput = self { return true }
        return false
    }

    var isWorking: Bool {
        switch self {
        case .working, .starting: true
        default: false
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .starting: "Starting"
        case .idle: "Idle"
        case .working(let tool): tool.map { "Working · \($0)" } ?? "Working"
        case .needsInput(.permission): "Needs permission"
        case .needsInput(.question): "Waiting for you"
        case .needsInput: "Needs input"
        case .error(let message): "Error · \(message)"
        case .ended: "Ended"
        }
    }

    /// Short word for chips: "working", "needs you", "done", "error".
    var shortLabel: String {
        switch self {
        case .starting, .working: "working"
        case .needsInput: "needs you"
        case .idle: "done"
        case .error: "error"
        case .ended: "ended"
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

    var needsYou: Bool { state.needsAttention && !state.isError || pendingPermission != nil }

    /// Sort key: held permissions first, then what needs eyes, newest first.
    var sidebarPriority: (Int, Double) {
        (pendingPermission != nil ? -1 : state.urgency, -lastActivity.timeIntervalSince1970)
    }
}
