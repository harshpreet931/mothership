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
        case agent(AgentSession)
        case workspace
    }

    struct Action: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        var shortcut: String?
        let perform: @MainActor () -> Void
    }

    let id: String
    let section: Section
    let title: String
    var subtitle: String?
    let icon: Icon
    var shortcut: String?
    let perform: @MainActor () -> Void
    /// Secondary actions (⌘K on a selected row).
    var actions: [Action] = []
}

/// Subsequence matching with bonuses for word starts and runs, so "spr" finds
/// "Split Right" and "mosh" finds "mothership". Returns the matched character offsets.
enum FuzzyMatcher {
    static func match(_ query: String, in candidate: String) -> (score: Int, indices: [Int])? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return (0, []) }
        let haystack = Array(candidate.lowercased())
        var score = 0
        var index = 0
        var last = -2
        var run = 0
        var indices: [Int] = []
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
            indices.append(position)
            index += 1
        }
        guard index == needle.count else { return nil }
        if candidate.lowercased().hasPrefix(String(needle)) { score += 15 }
        return (score - haystack.count / 6, indices)
    }

    static func score(_ query: String, item: PaletteItem) -> Int? {
        let title = match(query, in: item.title).map { $0.score * 2 }
        let subtitle = item.subtitle.flatMap { match(query, in: $0)?.score }
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
    @State private var actionsFor: PaletteItem.ID?
    @State private var actionSelection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let results = filtered
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
            HStack(alignment: .top, spacing: 10) {
                panel(results)
                if let item = results.first(where: { $0.id == actionsFor }), !item.actions.isEmpty {
                    actionsPanel(item)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(.top, 96)
            .animation(Sky.spring, value: actionsFor)
        }
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    private func panel(_ results: [PaletteItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Sky.tertiary)
                TextField("Search actions, workspaces, agents", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .foregroundStyle(Sky.ink)
                    .focused($fieldFocused)
                    .onSubmit { runSelection(results) }
                    .onChange(of: query) {
                        selection = 0
                        actionsFor = nil
                    }
                    .onKeyPress(.downArrow) { move(1, results); return .handled }
                    .onKeyPress(.upArrow) { move(-1, results); return .handled }
                    .onKeyPress(.escape) {
                        if actionsFor != nil { actionsFor = nil } else { onDismiss() }
                        return .handled
                    }
                    .onKeyPress(keys: ["k"], phases: .down) { press in
                        guard press.modifiers.contains(.command), results.indices.contains(selection) else { return .ignored }
                        let item = results[selection]
                        actionsFor = actionsFor == item.id || item.actions.isEmpty ? nil : item.id
                        actionSelection = 0
                        return .handled
                    }
                    .onKeyPress(keys: ["n", "p"], phases: .down) { press in
                        guard press.modifiers.contains(.control) else { return .ignored }
                        move(press.key == "n" ? 1 : -1, results)
                        return .handled
                    }
            }
            .padding(.horizontal, 22)
            .frame(height: 62)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if results.isEmpty {
                            Text("No results for “\(query)”")
                                .font(.system(size: 14))
                                .foregroundStyle(Sky.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 26)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || results[index - 1].section != item.section {
                                Text(item.section.title)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Sky.tertiary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, index == 0 ? 2 : 12)
                                    .padding(.bottom, 4)
                            }
                            PaletteRow(item: item, query: query, selected: index == selection, showsActions: actionsFor == item.id)
                                .id(item.id)
                                .onTapGesture {
                                    selection = index
                                    runSelection(results)
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
                .scrollIndicators(.never)
                .onChange(of: selection) {
                    guard results.indices.contains(selection) else { return }
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(results[selection].id) }
                }
            }
            HStack(spacing: 16) {
                hint("↩", "Open")
                hint("⌘K", "Actions")
                hint("esc", "Close")
                Spacer()
            }
            .padding(.horizontal, 22)
            .frame(height: 36)
        }
        .frame(width: 640)
        .glassPanel(dense: true)
    }

    private func actionsPanel(_ item: PaletteItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Sky.tertiary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(Array(item.actions.enumerated()), id: \.element.id) { index, action in
                Button {
                    onDismiss()
                    DispatchQueue.main.async { action.perform() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: action.symbol).font(.system(size: 12)).frame(width: 18)
                        Text(action.title).font(.system(size: 13))
                        Spacer()
                        if let shortcut = action.shortcut {
                            Text(shortcut).font(Sky.Font.meta).foregroundStyle(index == actionSelection ? Sky.onInk.opacity(0.7) : Sky.tertiary)
                        }
                    }
                    .foregroundStyle(index == actionSelection ? Sky.onInk : Sky.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Capsule().fill(index == actionSelection ? Sky.ink : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .frame(width: 250)
        .glassPanel(dense: true)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(Sky.Font.meta).foregroundStyle(Sky.secondary)
            Text(label).font(.system(size: 11.5)).foregroundStyle(Sky.tertiary)
        }
    }

    private func move(_ delta: Int, _ results: [PaletteItem]) {
        if let id = actionsFor, let item = results.first(where: { $0.id == id }) {
            actionSelection = min(max(actionSelection + delta, 0), max(item.actions.count - 1, 0))
            return
        }
        selection = min(max(selection + delta, 0), max(results.count - 1, 0))
    }

    private var allItems: [PaletteItem] {
        var items: [PaletteItem] = []
        let local = model.sessions.filter { $0.surface != nil && $0.state.isLive }.sorted { $0.sidebarPriority < $1.sidebarPriority }
        for session in local {
            guard let surface = session.surface else { continue }
            let workspaceName = model.workspace(containing: surface)?.name ?? ""
            var actions: [PaletteItem.Action] = [
                .init(title: "Focus pane", symbol: "rectangle.inset.filled", shortcut: "↩") { [model] in model.focusSurface(surface) },
            ]
            if let request = session.pendingPermission {
                actions.append(.init(title: "Allow \(request.toolName)", symbol: "checkmark") { [model] in model.resolvePermission(request, decision: .allow) })
                actions.append(.init(title: "Deny", symbol: "xmark") { [model] in model.resolvePermission(request, decision: .deny(reason: nil)) })
            }
            actions.append(.init(title: "Copy session ID", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id.sessionID, forType: .string)
            })
            items.append(PaletteItem(
                id: "agent:\(session.id)", section: .agents,
                title: session.title ?? session.kind.displayName,
                subtitle: [session.kind.shortName, session.state.label, workspaceName].joined(separator: " · "),
                icon: .agent(session), perform: { [model] in model.focusSurface(surface) }, actions: actions
            ))
        }
        for (index, workspace) in model.workspaces.enumerated() {
            let id = workspace.id
            items.append(PaletteItem(
                id: "workspace:\(workspace.id)", section: .workspaces, title: workspace.name,
                subtitle: PathDisplay.abbreviated(workspace.currentDirectory) + (model.branch(of: workspace).map { " · \($0)" } ?? ""),
                icon: .workspace, shortcut: index < 9 ? "⌘\(index + 1)" : nil,
                perform: { [model] in model.selectWorkspace(id) },
                actions: [
                    .init(title: "Open", symbol: "arrow.right", shortcut: "↩") { [model] in model.selectWorkspace(id) },
                    .init(title: "Rename…", symbol: "pencil") { [model] in
                        model.selectWorkspace(id)
                        model.renamingWorkspaceID = id
                    },
                    .init(title: workspace.isPinned ? "Unpin" : "Pin", symbol: "pin") { [model] in model.togglePin(id) },
                    .init(title: "Close", symbol: "xmark") { [model] in model.closeWorkspace(id) },
                ]
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

    private func runSelection(_ results: [PaletteItem]) {
        if let id = actionsFor, let item = results.first(where: { $0.id == id }), item.actions.indices.contains(actionSelection) {
            let action = item.actions[actionSelection]
            onDismiss()
            DispatchQueue.main.async { action.perform() }
            return
        }
        guard results.indices.contains(selection) else { return }
        let item = results[selection]
        onDismiss()
        DispatchQueue.main.async { item.perform() }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let query: String
    let selected: Bool
    let showsActions: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                highlighted(item.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(Sky.Font.meta)
                        .foregroundStyle(selected ? Sky.onInk.opacity(0.6) : Sky.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if case .agent(let session) = item.icon, session.needsYou {
                StatusDot(color: Sky.attention)
            }
            if selected, !item.actions.isEmpty {
                Text("⌘K").font(Sky.Font.meta).foregroundStyle(Sky.onInk.opacity(0.55))
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(Sky.Font.meta)
                    .foregroundStyle(selected ? Sky.onInk.opacity(0.7) : Sky.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: item.subtitle == nil ? 38 : 46)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Sky.ink : .clear))
        .contentShape(Rectangle())
    }

    /// Matched characters in ink (or onInk when selected), the rest secondary.
    private func highlighted(_ text: String) -> Text {
        let strong = selected ? Sky.onInk : Sky.ink
        let soft = selected ? Sky.onInk.opacity(0.72) : Sky.ink.opacity(0.72)
        guard !query.isEmpty, let match = FuzzyMatcher.match(query, in: text), !match.indices.isEmpty else {
            return Text(text).foregroundColor(strong)
        }
        let matched = Set(match.indices)
        var result = AttributedString()
        for (offset, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            piece.foregroundColor = matched.contains(offset) ? strong : soft
            if matched.contains(offset) { piece.font = .system(size: 14, weight: .semibold) }
            result += piece
        }
        return Text(result)
    }

    @ViewBuilder private var icon: some View {
        let color = selected ? Sky.onInk : Sky.ink.opacity(0.75)
        switch item.icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 13)).foregroundStyle(color)
        case .agent(let session):
            AgentMark(kind: session.kind, size: 15, color: session.needsYou ? Sky.attention : color)
        case .workspace:
            Image(systemName: "square.on.square").font(.system(size: 13)).foregroundStyle(color)
        }
    }
}
