import ShipModel
import SwiftUI
import UniformTypeIdentifiers

/// The floating glass sidebar (§5): vertical tabs with a sliding ink selection.
struct SidebarView: View {
    let model: AppModel
    @State private var dragging: WorkspaceID?
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, workspace in
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
                    }
                }
                .padding(8)
                .animation(Sky.spring, value: model.workspaces.map(\.id))
            }
            .scrollIndicators(.never)
            .onContinuousHover { _ in
                if dragging != nil, NSEvent.pressedMouseButtons == 0 { dragging = nil }
            }
            Button {
                model.createWorkspace()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("New workspace").font(.system(size: 13))
                    Spacer()
                    Text("⌘T").font(Sky.Font.meta).foregroundStyle(Sky.tertiary)
                }
                .foregroundStyle(Sky.secondary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel()
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
