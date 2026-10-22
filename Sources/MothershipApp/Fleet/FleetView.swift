import ShipModel
import SwiftUI

enum FleetFilter: String, CaseIterable, Hashable {
    case all, needsYou, working, done, elsewhere

    var title: String {
        switch self {
        case .all: "All"
        case .needsYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        case .elsewhere: "Elsewhere"
        }
    }

    func includes(_ session: AgentSession) -> Bool {
        switch self {
        case .all: true
        case .needsYou: session.needsYou || session.state.isError
        case .working: session.state.isWorking
        case .done: session.state == .idle
        case .elsewhere: session.surface == nil
        }
    }
}

/// Every session, in and out of the app (§6 Fleet).
struct FleetView: View {
    let model: AppModel
    @State private var filter: FleetFilter = .all

    var body: some View {
        let live = model.sessions.filter { $0.state.isLive }.sorted { $0.sidebarPriority < $1.sidebarPriority }
        let shown = live.filter(filter.includes)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SegmentedPill(
                    items: FleetFilter.allCases.map { ($0, title(for: $0, in: live)) },
                    selection: $filter, height: 32
                )
                Spacer()
            }
            if shown.isEmpty {
                VStack(spacing: 14) {
                    Text(filter == .all ? "No agents yet." : "Nothing here.")
                        .onSkyText()
                        .font(Sky.Font.serifL)
                        .foregroundStyle(Sky.ink)
                    Button("Start a task") { model.presentNewTask() }
                        .buttonStyle(InkCapsuleStyle(height: 32))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FleetGrid(model: model, sessions: shown)
            }
        }
    }

    private func title(for filter: FleetFilter, in sessions: [AgentSession]) -> String {
        let count = sessions.filter(filter.includes).count
        return filter == .all || count == 0 ? filter.title : "\(filter.title) \(count)"
    }
}

/// A fixed-column grid (cards ≥ 320 pt wide): every row starts at the same top and its
/// cards share the tallest card's height. No insertion animation, so streaming session
/// updates can never leave a card mid-flight.
struct FleetGrid: View {
    let model: AppModel
    let sessions: [AgentSession]
    static let spacing: CGFloat = 12
    static let minimumCardWidth: CGFloat = 320

    var body: some View {
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width + Self.spacing) / (Self.minimumCardWidth + Self.spacing)))
            let rows = stride(from: 0, to: sessions.count, by: columns).map { Array(sessions[$0 ..< min($0 + columns, sessions.count)]) }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(rows, id: \.first?.id) { row in
                        HStack(alignment: .top, spacing: Self.spacing) {
                            ForEach(row) { session in
                                FleetCard(model: model, session: session)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            }
                            // Keep the last row's cards the same width as the rows above.
                            ForEach(0 ..< (columns - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The last row scrolls clear of the composer pill.
                .padding(.bottom, 48)
                .transaction { $0.animation = nil }
            }
            .scrollIndicators(.never)
            .bottomFade()
        }
    }
}

/// Header, bubble tail, inline permission, meta footer.
struct FleetCard: View {
    let model: AppModel
    let session: AgentSession
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            BubbleTail(session: session, replyLines: 4)
            if session.pendingPermission != nil || model.recentlyResolved[session.id] != nil {
                PermissionMorph(request: session.pendingPermission, resolved: model.recentlyResolved[session.id]) { request, decision in
                    model.resolvePermission(request, decision: decision)
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel(radius: 22)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Sky.ink.opacity(hovering ? 0.03 : 0))
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onHover { hovering in withAnimation(Sky.hover) { self.hovering = hovering } }
        .onTapGesture {
            if let surface = session.surface { model.focusSurface(surface) } else { HostApp.reveal(session.hostApp) }
        }
        .animation(Sky.spring, value: session.pendingPermission?.id)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentStatusGlyph(kind: session.kind, state: session.state, unread: session.unread, hasPermission: session.pendingPermission != nil, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title ?? session.kind.displayName)
                    .font(Sky.Font.title)
                    .foregroundStyle(Sky.ink)
                    .lineLimit(1)
                Text(place)
                    .font(Sky.Font.meta)
                    .foregroundStyle(Sky.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.state.shortLabel)
                    .font(Sky.Font.label)
                    .foregroundStyle(session.needsYou ? Sky.attention : session.state.isError ? Sky.danger : Sky.secondary)
                Text(Format.elapsed(since: session.startedAt))
                    .font(Sky.Font.meta)
                    .foregroundStyle(Sky.tertiary)
            }
        }
    }

    private var place: String {
        if let surface = session.surface, let workspace = model.workspace(containing: surface) {
            return [session.kind.shortName, workspace.name, session.branch].compactMap { $0 }.joined(separator: " · ")
        }
        return [session.kind.shortName, session.hostApp ?? "elsewhere", PathDisplay.short(session.cwd)].joined(separator: " · ")
    }

    private var footer: some View {
        let usage = session.usage
        let context = usage.contextWindow.flatMap { window in usage.contextTokens.map { Double($0) / Double(max(window, 1)) } }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(Format.tokens(usage.inputTokens + usage.outputTokens)) tokens")
                if let cost = usage.costUSD { Text(Format.cost(cost)) }
                Spacer(minLength: 0)
                if let model = session.model { Text(model).lineLimit(1) }
            }
            .font(Sky.Font.meta)
            .foregroundStyle(Sky.tertiary)
            if let context {
                HStack(spacing: 8) {
                    ContextBar(fraction: context)
                    Text("\(Int(context * 100))% context")
                        .font(Sky.Font.meta)
                        .foregroundStyle(Sky.tertiary)
                        .fixedSize()
                }
            }
        }
    }
}
