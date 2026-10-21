import ShipModel
import SwiftUI

/// The assistant's opaque white bubble (Hark's reply).
struct AssistantBubble: View {
    let text: String
    var lineLimit: Int? = 4

    var body: some View {
        Text(Self.inlineMarkdown(text))
            .font(Sky.Font.body)
            .foregroundStyle(Sky.ink)
            .lineLimit(lineLimit)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Sky.bubble))
    }

    /// Agents answer in Markdown; render **bold**, *italic* and `code` inline, keep the rest.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// The user's frosted pill.
struct UserPill: View {
    let text: String
    var lineLimit: Int? = 2

    var body: some View {
        Text(text)
            .font(Sky.Font.body)
            .foregroundStyle(Sky.ink.opacity(0.88))
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Sky.bubbleUser))
    }
}

/// Last prompt (right, frosted) over last reply (left, white): a conversation's tail.
struct BubbleTail: View {
    let session: AgentSession
    var replyLines = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prompt = session.lastUserPrompt {
                HStack {
                    Spacer(minLength: 36)
                    UserPill(text: prompt)
                }
            }
            if let reply = session.lastAssistantMessage ?? session.summary {
                HStack {
                    AssistantBubble(text: reply, lineLimit: replyLines)
                        .shimmer(session.state.isWorking && session.lastAssistantMessage == nil)
                    Spacer(minLength: 36)
                }
            }
        }
    }
}

/// Fanned stack: the top card in full, up to two more peeking behind; hover fans them out.
struct FannedStack<Item: Identifiable, Card: View, Plate: View>: View {
    let items: [Item]
    let card: (Item) -> Card
    /// What peeks out behind the top card at rest: just the card's surface.
    let plate: () -> Plate
    @State private var fanned = false

    var body: some View {
        let visible = Array(items.prefix(3))
        Group {
            if fanned, visible.count > 1 {
                // Hover fans the stack out into every card, newest on top.
                VStack(spacing: 8) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        card(item)
                            .rotationEffect(.degrees(index == 0 ? 0 : (index.isMultiple(of: 2) ? 0.8 : -0.8)))
                            .transition(.asymmetric(insertion: .offset(y: -12).combined(with: .opacity), removal: .opacity))
                    }
                }
            } else if let top = visible.first {
                card(top)
                    // Plates take the top card's exact size (a background is proposed its
                    // owner's frame), shrink toward their bottom edge and peek out below.
                    .background {
                        ZStack {
                            ForEach(Array(visible.indices.dropFirst().reversed()), id: \.self) { index in
                                plate()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .scaleEffect(1 - CGFloat(index) * 0.05, anchor: .bottom)
                                    .rotationEffect(.degrees(index.isMultiple(of: 2) ? 1.6 : -1.6), anchor: .center)
                                    .offset(y: CGFloat(index) * 8)
                                    .opacity(1 - Double(index) * 0.18)
                            }
                        }
                    }
                    .padding(.bottom, CGFloat(max(visible.count - 1, 0)) * 8)
            }
        }
        .onHover { hovering in withAnimationIfAllowed { fanned = hovering } }
    }
}

/// The permission ask: a white bubble card with the tool line, the command on a recessed
/// chip, and Deny / Allow. After a decision it collapses into ✓ (or ✕).
struct PermissionMorph: View {
    let request: PermissionRequest?
    let resolved: PermissionDecisionKind?
    var compact = false
    let onDecide: (PermissionRequest, PermissionDecision) -> Void

    var body: some View {
        Group {
            if let resolved {
                HStack(spacing: 6) {
                    Image(systemName: resolved == .allowed ? "checkmark" : "xmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text(resolved == .allowed ? "Allowed" : "Denied")
                        .font(Sky.Font.label)
                }
                .foregroundStyle(Sky.ink.opacity(0.7))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Sky.bubble))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if let request {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Sky.attention).frame(width: 6, height: 6)
                        Text("\(request.toolName) wants to run")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Sky.ink)
                        Spacer(minLength: 0)
                    }
                    MetaChip(text: request.summary)
                        .help(request.detail ?? request.summary)
                    HStack(spacing: 6) {
                        Button { onDecide(request, .deny(reason: nil)) } label: {
                            Text("Deny").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryPillStyle(height: compact ? 26 : 28, fill: Sky.recess))
                        Button { onDecide(request, .allow) } label: {
                            Text("Allow").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InkCapsuleStyle(height: compact ? 26 : 28))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Sky.bubble))
                .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .top).combined(with: .opacity), removal: .scale(scale: 0.6).combined(with: .opacity)))
            }
        }
    }
}

/// A light sweep across text while an agent works (calmer than a spinner).
struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content.overlay {
            if active, !reduceMotion {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, Color.white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(40, geometry.size.width * 0.4))
                        .offset(x: phase * geometry.size.width)
                }
                .mask(content)
                .allowsHitTesting(false)
                .onAppear {
                    withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) { phase = 1.2 }
                }
            }
        }
    }
}

extension View {
    func shimmer(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

/// Thin context-window bar in meta style.
struct ContextBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Sky.ink.opacity(0.1))
                Capsule()
                    .fill(fraction > 0.85 ? Sky.attention : Sky.ink.opacity(0.7))
                    .frame(width: max(3, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

enum Format {
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 10000...: "\(count / 1000)k"
        case 1000...: String(format: "%.1fk", Double(count) / 1000)
        default: "\(count)"
        }
    }

    static func cost(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
        default: return "\(seconds / 86400)d"
        }
    }
}
