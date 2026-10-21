import ShipModel
import SwiftUI

/// Fanned glass toasts for what you didn't see (§6 Attention stack). Hover fans them out;
/// click jumps to the pane; Esc (while hovering) dismisses the top one.
struct AttentionStack: View {
    let model: AppModel
    @Binding var hovering: Bool

    var body: some View {
        VStack(alignment: .trailing) {
            if !model.toasts.isEmpty {
                FannedStack(items: model.toasts) { toast in
                    ToastCard(model: model, toast: toast)
                } plate: {
                    Color.clear.glassPanel(radius: 20, dense: true)
                }
                .onHover { hovering = $0 }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: 344)
        .animation(Sky.spring, value: model.toasts.map(\.id))
    }
}

struct ToastCard: View {
    let model: AppModel
    let toast: AttentionToast

    var body: some View {
        let session = toast.event.session.flatMap { key in model.sessions.first { $0.id == key } }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let session {
                    AgentStatusGlyph(kind: session.kind, state: session.state, unread: session.unread, hasPermission: session.pendingPermission != nil, size: 13)
                } else {
                    Image(systemName: "bell").font(.system(size: 12)).foregroundStyle(Sky.ink.opacity(0.7)).frame(width: 20)
                }
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
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Sky.tertiary).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            if case .permission(let request) = toast.event.kind {
                PermissionMorph(request: request, resolved: nil, compact: true) { request, decision in
                    model.resolvePermission(request, decision: decision)
                }
            } else {
                Text(toast.event.body)
                    .font(Sky.Font.body)
                    .foregroundStyle(kindColor)
                    .lineLimit(3)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .glassPanel(radius: 20, dense: true)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { model.openToast(toast) }
    }

    private var kindColor: Color {
        switch toast.event.kind {
        case .failed: Sky.danger
        default: Sky.ink.opacity(0.82)
        }
    }
}
