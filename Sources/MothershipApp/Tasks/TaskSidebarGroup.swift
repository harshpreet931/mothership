import GitKit
import ShipModel
import SwiftUI

/// One entry in the sidebar: a plain workspace, or a task whose runs are grouped.
enum SidebarEntry: Identifiable {
    case workspace(Workspace, index: Int)
    case task(AgentTask, runs: [(run: TaskRun, workspace: Workspace)])

    var id: String {
        switch self {
        case .workspace(let workspace, _): "w:" + workspace.id.description
        case .task(let task, _): "t:" + task.id.uuidString
        }
    }

    /// Workspaces in order, each task's runs folded into the task at its first run.
    @MainActor
    static func entries(for model: AppModel) -> [SidebarEntry] {
        var entries: [SidebarEntry] = []
        var emitted: Set<UUID> = []
        for (index, workspace) in model.workspaces.enumerated() {
            guard let task = model.task(for: workspace.id) else {
                entries.append(.workspace(workspace, index: index))
                continue
            }
            guard !emitted.contains(task.id) else { continue }
            emitted.insert(task.id)
            let runs = task.runs.compactMap { run in model.workspace(id: run.workspaceID).map { (run: run, workspace: $0) } }
            entries.append(.task(task, runs: runs))
        }
        return entries
    }
}

/// A task in the sidebar: a slim header (title, run count, overall state) over its runs,
/// each indented with its agent, branch, diff stat and state. The header folds the group.
struct TaskSidebarGroup: View {
    let task: AgentTask
    let runs: [(run: TaskRun, workspace: Workspace)]
    let model: AppModel
    let selectionNamespace: Namespace.ID
    @State private var hovering = false

    private var collapsed: Bool { model.collapsedTasks.contains(task.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if !collapsed {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(runs, id: \.run.id) { item in
                        TaskRunRow(
                            task: task, run: item.run, workspace: item.workspace, model: model,
                            isSelected: model.screen == .workspaces && model.selectedWorkspaceID == item.workspace.id,
                            selectionNamespace: selectionNamespace
                        )
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    // A hairline guide ties the runs to their task.
                    Rectangle().fill(Sky.ink.opacity(0.1)).frame(width: 1).padding(.leading, 17).padding(.vertical, 6)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var header: some View {
        let phase = model.phase(of: task)
        let comparing = model.screen == .compare && model.compareTaskID == task.id
        return HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Sky.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 10)
            Text(task.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(comparing ? Sky.ink : Sky.ink.opacity(0.86))
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering, task.runs.count > 1 {
                Button { model.openCompare(task.id) } label: {
                    Text("Compare")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Sky.ink.opacity(0.8))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Sky.ink.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            } else {
                Text(verbatim: task.runs.count == 1 ? "1 run" : String(task.runs.count) + " runs")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Sky.tertiary)
                TaskPhaseMark(phase: phase)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Sky.ink.opacity(comparing ? 0.08 : (hovering ? 0.04 : 0)))
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Sky.hover) { hovering = inside } }
        .onTapGesture {
            withAnimationIfAllowed {
                if collapsed { model.collapsedTasks.remove(task.id) } else { model.collapsedTasks.insert(task.id) }
            }
        }
        .contextMenu {
            if task.runs.count > 1 { Button("Compare Runs") { model.openCompare(task.id) } }
            Button(collapsed ? "Expand" : "Collapse") {
                if collapsed { model.collapsedTasks.remove(task.id) } else { model.collapsedTasks.insert(task.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(task.runs.count) runs, \(phase.label)")
        .accessibilityAddTraits(.isButton)
    }
}

/// One run under its task: agent glyph, agent, `+12 −3`; branch · state below.
struct TaskRunRow: View {
    let task: AgentTask
    let run: TaskRun
    let workspace: Workspace
    let model: AppModel
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    @State private var hovering = false

    var body: some View {
        let session = model.session(for: run)
        let phase = model.phase(of: run)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if let session {
                    AgentStatusGlyph(
                        kind: session.kind, state: session.state, unread: session.unread,
                        hasPermission: session.pendingPermission != nil, size: 12, color: primary
                    )
                } else {
                    AgentMark(kind: run.agent, size: 12, color: primary).frame(width: 19, height: 19)
                }
                Text(run.agent.shortName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                if phase == .kept {
                    Text("kept")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? Sky.onSelection : Sky.onInk)
                        .padding(.horizontal, 6)
                        .frame(height: 15)
                        .background(Capsule().fill(isSelected ? Sky.onSelection.opacity(0.2) : Sky.ink))
                }
                Spacer(minLength: 4)
                if let diff = run.diff, !diff.isEmpty {
                    DiffStatText(insertions: diff.insertions, deletions: diff.deletions, onSelection: isSelected)
                }
            }
            HStack(spacing: 0) {
                Text(run.branch.hasPrefix("mship/") ? String(run.branch.dropFirst(6)) : run.branch)
                    .truncationMode(.head)
                    .layoutPriority(-1)
                Text("  ·  ")
                Text(phase.label)
                    .foregroundStyle(phase == .needsYou ? Sky.attention : (phase == .failed ? Sky.danger : tertiary))
                    .fixedSize()
                if let status = model.pullRequest(for: workspace.id) {
                    Spacer(minLength: 6)
                    PullRequestChip(status: status, onSelection: isSelected) {
                        model.openPullRequest(status, in: workspace.id)
                    }
                }
            }
            .font(Sky.Font.meta)
            .foregroundStyle(tertiary)
            .lineLimit(1)
            .padding(.leading, 26)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            if isSelected {
                SelectionFill(shape: shape)
                    .matchedGeometryEffect(id: "selection", in: selectionNamespace)
            } else if hovering {
                shape.fill(Sky.ink.opacity(0.06))
            }
        }
        .opacity(run.outcome == .discarded ? 0.45 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { inside in withAnimation(Sky.hover) { hovering = inside } }
        .onTapGesture { withAnimationIfAllowed { model.selectWorkspace(workspace.id) } }
        .contextMenu {
            Button("View Diff") { model.openDiff(run.id) }
            if task.runs.count > 1 { Button("Compare Runs") { model.openCompare(task.id) } }
            Divider()
            Button("Copy Branch Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.branch, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.agent.displayName) run, \(phase.label), branch \(run.branch)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var primary: Color { isSelected ? Sky.onSelection : Sky.ink }
    private var tertiary: Color { isSelected ? Sky.onSelection.opacity(0.6) : Sky.tertiary }
}

/// `+12 −3` in mono: additions in ink, deletions a step quieter (one hue in the chrome).
struct DiffStatText: View {
    let insertions: Int
    let deletions: Int
    var onSelection = false
    var size: CGFloat = 10.5

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+" + String(insertions))
                .foregroundStyle(onSelection ? Sky.onSelection.opacity(0.9) : Sky.ink.opacity(0.75))
            Text(verbatim: "−" + String(deletions))
                .foregroundStyle(onSelection ? Sky.onSelection.opacity(0.55) : Sky.tertiary)
        }
        .font(.system(size: size, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .fixedSize()
        .accessibilityLabel("\(insertions) added, \(deletions) removed")
    }
}

/// A task's overall state as one small mark.
struct TaskPhaseMark: View {
    let phase: TaskPhase

    var body: some View {
        Group {
            switch phase {
            case .needsYou: HaloDot(color: Sky.attention, size: 6)
            case .working: WorkingArc(color: Sky.ink).frame(width: 11, height: 11)
            case .failed: StatusDot(color: Sky.danger)
            case .done: Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Sky.ink.opacity(0.7))
            case .kept: Image(systemName: "checkmark.seal.fill").font(.system(size: 10)).foregroundStyle(Sky.ink.opacity(0.8))
            }
        }
        .frame(width: 12, height: 12)
        .help(phase.label)
    }
}
