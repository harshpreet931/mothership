import ShipModel
import SwiftUI
import UniformTypeIdentifiers

/// The floating glass sidebar (§5): vertical tabs with a sliding selection. A task's runs
/// fold under the task (`TaskSidebarGroup`).
struct SidebarView: View {
    let model: AppModel
    @State private var dragging: WorkspaceID?
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(SidebarEntry.entries(for: model)) { entry in
                        switch entry {
                        case .workspace(let workspace, let index):
                            WorkspaceRow(
                                workspace: workspace, index: index, model: model,
                                isSelected: model.screen == .workspaces && workspace.id == model.selectedWorkspace?.id,
                                selectionNamespace: selection
                            )
                            .opacity(dragging == workspace.id ? 0.4 : 1)
                            .onDrag {
                                dragging = workspace.id
                                return NSItemProvider(object: workspace.id.description as NSString)
                            }
                            .onDrop(of: [.text], delegate: WorkspaceDropDelegate(target: workspace.id, model: model, dragging: $dragging))
                        case .task(let task, let runs):
                            TaskSidebarGroup(task: task, runs: runs, model: model, selectionNamespace: selection)
                        }
                    }
                }
                .padding(8)
                .animation(Sky.spring, value: model.workspaces.map(\.id))
                .animation(Sky.spring, value: model.collapsedTasks)
            }
            .scrollIndicators(.never)
            .onContinuousHover { _ in
                if dragging != nil, NSEvent.pressedMouseButtons == 0 { dragging = nil }
            }
            HStack(spacing: 4) {
                footerButton("plus", "Workspace", "New workspace (⌘T)") { model.createWorkspace() }
                footerButton("sparkles", "Task", "New task (⌘N)") { model.presentNewTask() }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel()
    }

    private func footerButton(_ symbol: String, _ title: String, _ help: String, action: @escaping () -> Void) -> some View {
        FooterButton(symbol: symbol, title: title, help: help, action: action)
    }
}

private struct FooterButton: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Sky.ink : Sky.secondary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Sky.ink.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in withAnimation(Sky.hover) { hovering = inside } }
    }
}

/// Moves the dragged row as it passes over others (live reorder).
struct WorkspaceDropDelegate: DropDelegate {
    let target: WorkspaceID
    let model: AppModel
    @Binding var dragging: WorkspaceID?

    func dropEntered(info _: DropInfo) {
        guard let dragging, dragging != target,
              let destination = model.workspaces.firstIndex(where: { $0.id == target }) else { return }
        withAnimationIfAllowed { model.moveWorkspace(dragging, to: destination) }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
