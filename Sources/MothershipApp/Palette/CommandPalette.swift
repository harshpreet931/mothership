import ShipModel
import SwiftUI

struct PaletteItem: Identifiable {
    enum Section: Int, Comparable {
        case agents, workspaces, actions

        var title: String {
            switch self {
            case .agents: "Agents"
            case .workspaces: "Workspaces"
            case .actions: "Actions"
            }
        }

        static func < (lhs: Section, rhs: Section) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Icon {
        case symbol(String)
        case agent(AgentKind)
        case color(String?)
    }

    let id: String
    let section: Section
    let title: String
    var subtitle: String?
    let icon: Icon
    var shortcut: String?
    var trailingState: AgentSession?
    let perform: @MainActor () -> Void
}

/// Subsequence matching with bonuses for word starts and runs, so "spr" finds
/// "Split Right" and "mosh" finds "mothership".
enum FuzzyMatcher {
    static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate.lowercased())
        var score = 0
        var index = 0
        var last = -2
        var run = 0
        for (position, character) in haystack.enumerated() where index < needle.count {
            guard character == needle[index] else { continue }
            var bonus = 1
            if position == 0 || " -_/.:·".contains(haystack[position - 1]) { bonus += 8 }
            if last == position - 1 {
                run += 1
                bonus += 4 * run
            } else {
                run = 0
            }
            score += bonus
            last = position
            index += 1
        }
        guard index == needle.count else { return nil }
        if candidate.lowercased().hasPrefix(String(needle)) { score += 15 }
        return score - haystack.count / 6
    }

    static func score(_ query: String, item: PaletteItem) -> Int? {
        let title = score(query, in: item.title).map { $0 * 2 }
        let subtitle = item.subtitle.flatMap { score(query, in: $0) }
        switch (title, subtitle) {
        case (nil, nil): return nil
        case (let t?, nil): return t
        case (nil, let s?): return s
        case (let t?, let s?): return max(t, s)
        }
    }
}

struct CommandPaletteView: View {
    let model: AppModel
    let actions: [PaletteItem]
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let results = filtered
        ZStack(alignment: .top) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
            VStack(spacing: 0) {
                searchField(results: results)
                Divider().opacity(0.6)
                resultList(results)
                footer
            }
            .frame(width: 620)
            // A tinted backing keeps results legible over busy terminal text behind the glass.
            .background(
                Color(nsColor: .windowBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
            .padding(.top, 84)
        }
        .onAppear {
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private func searchField(results: [PaletteItem]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search actions, workspaces, agents…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($fieldFocused)
                .onSubmit { run(results) }
                .onChange(of: query) { selection = 0 }
                .onKeyPress(.downArrow) {
                    selection = min(selection + 1, max(results.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(selection - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onKeyPress(keys: ["n", "p"], phases: .down) { press in
                    guard press.modifiers.contains(.control) else { return .ignored }
                    selection = press.key == "n" ? min(selection + 1, max(results.count - 1, 0)) : max(selection - 1, 0)
                    return .handled
                }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private func resultList(_ results: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if results.isEmpty {
                        Text("No matches")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        if query.isEmpty, index == 0 || results[index - 1].section != item.section {
                            Text(item.section.title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, index == 0 ? 4 : 10)
                                .padding(.bottom, 3)
                        }
                        PaletteRow(item: item, selected: index == selection)
                            .id(item.id)
                            .onTapGesture {
                                selection = index
                                run(results)
                            }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) {
                guard results.indices.contains(selection) else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(results[selection].id) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "navigate")
            hint("↩", "open")
            hint("esc", "close")
            Spacer()
            Text("Mothership")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(Color.primary.opacity(0.035))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10.5))
        }
        .foregroundStyle(.secondary)
    }

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []
        let local = model.sessions.filter { $0.surface != nil && $0.state != .ended }
            .sorted { $0.sidebarPriority < $1.sidebarPriority }
        for session in local {
            guard let surface = session.surface else { continue }
            let workspaceName = model.workspace(containing: surface)?.name ?? ""
            items.append(PaletteItem(
                id: "agent:\(session.id)", section: .agents,
                title: session.title ?? session.kind.displayName,
                subtitle: [session.kind.displayName, session.state.label, workspaceName].joined(separator: " · "),
                icon: .agent(session.kind), trailingState: session,
                perform: { [model] in model.focusSurface(surface) }
            ))
        }
        for (index, workspace) in model.workspaces.enumerated() {
            items.append(PaletteItem(
                id: "workspace:\(workspace.id)", section: .workspaces, title: workspace.name,
                subtitle: PathDisplay.abbreviated(workspace.currentDirectory) + (workspace.git?.branch.map { " · \($0)" } ?? ""),
                icon: .color(workspace.colorHex), shortcut: index < 9 ? "⌘\(index + 1)" : nil,
                perform: { [model] in model.selectWorkspace(workspace.id) }
            ))
        }
        return items + actions
    }

    private var filtered: [PaletteItem] {
        let items = allItems
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return items.sorted { $0.section < $1.section }
        }
        return items
            .compactMap { item in FuzzyMatcher.score(query, item: item).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private func run(_ results: [PaletteItem]) {
        guard results.indices.contains(selection) else { return }
        let item = results[selection]
        onDismiss()
        DispatchQueue.main.async { item.perform() }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            icon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let session = item.trailingState {
                AgentStateIndicator(state: session.state, unread: session.unread, tint: Palette.agentColor(session.kind))
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: item.subtitle == nil ? 34 : 42)
        .background(
            selected ? Palette.accent.opacity(0.22) : .clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item.icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        case .agent(let kind):
            AgentGlyph(kind: kind, size: 20)
        case .color(let hex):
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hex.flatMap { NSColor(hex: $0) }.map { Color(nsColor: $0) }?.opacity(0.85) ?? Color.primary.opacity(0.1))
                .overlay {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hex == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                }
                .frame(width: 20, height: 20)
        }
    }
}
