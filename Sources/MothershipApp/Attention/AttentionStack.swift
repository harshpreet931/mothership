import ShipModel
import SwiftUI

/// What you didn't see, docked in the top bar's right side (§6 Attention stack) so it
/// never covers a terminal: one compact pill for the newest event (+N for the rest) that
/// slides in, and on hover opens into up to three full cards. Click jumps to the pane; Esc
/// (while hovering) dismisses the top one. Toasts expire on their own (see AppModel).
struct ToastDock: View {
    let model: AppModel
    @Binding var hovering: Bool
    /// Room between the centered pill and the search pill.
    let maxWidth: CGFloat

    var body: some View {
        let toasts = model.toasts
        VStack(alignment: .trailing, spacing: 8) {
            if hovering, !toasts.isEmpty {
                ForEach(toasts) { toast in
                    ToastCard(model: model, toast: toast)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            } else if let first = toasts.first {
                ToastPill(model: model, toast: first, others: toasts.count - 1)
                    .frame(maxWidth: maxWidth, alignment: .trailing)
                    .id(first.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
        }
        // Room for the cards' shadow inside the host.
        .padding(.bottom, hovering ? 24 : 0)
        .padding(.leading, hovering ? 24 : 0)
        .onHover { inside in
            withAnimationIfAllowed { hovering = inside }
            model.toastsHeld = inside
        }
        .animation(Sky.spring, value: toasts.map(\.id))
    }
}

/// One line: glyph, title, what happened, +N.
struct ToastPill: View {
    let model: AppModel
    let toast: AttentionToast
    let others: Int

    var body: some View {
        let session = toast.event.session.flatMap { key in model.sessions.first { $0.id == key } }
        HStack(spacing: 8) {
            ToastGlyph(session: session, size: 12)
            Text(toast.event.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Sky.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(toast.statusWord)
                .font(Sky.Font.meta)
                .foregroundStyle(toast.statusColor)
                .lineLimit(1)
                .fixedSize()
            if others > 0 {
                Text(verbatim: "+" + String(others))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Sky.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(Sky.recess))
                    .fixedSize()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 32)
        .background(Capsule(style: .continuous).fill(Sky.bubble))
        .overlay(Capsule(style: .continuous).strokeBorder(Sky.cardStroke, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { model.openToast(toast) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The full card: opaque bubble surface with a soft shadow, Markdown flattened to one
/// calm paragraph, Allow/Deny for permission requests.
struct ToastCard: View {
    let model: AppModel
    let toast: AttentionToast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let session = toast.event.session.flatMap { key in model.sessions.first { $0.id == key } }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToastGlyph(session: session, size: 13)
                Text(toast.event.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Sky.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(toast.event.date.formatted(.dateTime.hour().minute()))
                    .font(Sky.Font.meta)
                    .foregroundStyle(Sky.tertiary)
                Button {
                    model.dismissToast(toast.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Sky.secondary).frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            if case .permission(let request) = toast.event.kind {
                PermissionMorph(request: request, resolved: nil, compact: true) { request, decision in
                    model.resolvePermission(request, decision: decision)
                }
            } else {
                let text = ToastText.render(toast.event.body)
                if !text.characters.isEmpty {
                    Text(text)
                        .font(Sky.Font.body)
                        .foregroundStyle(toast.event.kind == .failed ? Sky.danger : Sky.ink.opacity(0.82))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: Sky.radiusPane, style: .continuous)
            shape.fill(Sky.bubble)
                .overlay(shape.strokeBorder(Sky.cardStroke, lineWidth: 1))
                .shadow(color: .black.opacity(scheme == .dark ? 0.38 : 0.14), radius: 16, y: 8)
        }
        .contentShape(RoundedRectangle(cornerRadius: Sky.radiusPane, style: .continuous))
        .onTapGesture { model.openToast(toast) }
    }
}

private struct ToastGlyph: View {
    let session: AgentSession?
    let size: CGFloat

    var body: some View {
        if let session {
            AgentStatusGlyph(kind: session.kind, state: session.state, unread: session.unread, hasPermission: session.pendingPermission != nil, size: size)
        } else {
            Image(systemName: "bell").font(.system(size: size - 1)).foregroundStyle(Sky.ink.opacity(0.7)).frame(width: size + 6)
        }
    }
}

extension AttentionToast {
    var statusWord: String {
        switch event.kind {
        case .permission(let request): "wants \(request.toolName)"
        case .needsInput: "needs you"
        case .finished: "done"
        case .failed: "failed"
        case .notification: ToastText.plainFirstLine(event.body)
        }
    }

    @MainActor var statusColor: Color {
        switch event.kind {
        case .permission, .needsInput: Sky.attention
        case .failed: Sky.danger
        case .finished, .notification: Sky.secondary
        }
    }
}

/// Agents write Markdown; a toast shows one calm paragraph of it.
enum ToastText {
    /// Block syntax dropped (headings, quotes, bullets, fences), inline styles kept, at
    /// most `maxLines` source lines joined into one paragraph.
    static func render(_ body: String, maxLines: Int = 4) -> AttributedString {
        let text = flatten(body, maxLines: maxLines)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// The first line as plain text, for the pill (≤ 48 characters).
    static func plainFirstLine(_ body: String) -> String {
        let text = String(render(body, maxLines: 1).characters)
        return text.count > 48 ? String(text.prefix(47)) + "…" : text
    }

    static func flatten(_ body: String, maxLines: Int) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence {
                line = stripBlockMarker(line)
            }
            guard !line.isEmpty else { continue }
            lines.append(line)
            if lines.count >= maxLines { break }
        }
        // Lines become sentences: "## Done" + "- Tests pass" → "Done. Tests pass".
        let terminators: Set<Character> = [".", "!", "?", ":", ";", ",", "…"]
        return lines.enumerated().map { index, line in
            guard index < lines.count - 1, let last = line.last, !terminators.contains(last) else { return line }
            return line + "."
        }.joined(separator: " ")
    }

    private static func stripBlockMarker(_ line: String) -> String {
        var text = Substring(line)
        while let first = text.first, first == "#" || first == ">" { text = text.dropFirst() }
        text = text.drop { $0 == " " }
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where text.hasPrefix(marker) {
            text = text.dropFirst(marker.count)
            break
        }
        if let dot = text.firstIndex(of: "."), text[..<dot].allSatisfy(\.isNumber), !text[..<dot].isEmpty,
           text[text.index(after: dot)...].hasPrefix(" ") {
            text = text[text.index(dot, offsetBy: 2)...]
        }
        if text.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { return "" }
        return String(text)
    }
}
