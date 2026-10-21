import ShipModel
import SwiftUI
import UniformTypeIdentifiers

/// Vertical tabs: one row per workspace, the fleet summary underneath.
struct SidebarView: View {
    let model: AppModel
    @State private var dragging: WorkspaceID?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical) {
                LazyVStack(spacing: 3) {
                    ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        WorkspaceRow(
                            workspace: workspace, index: index, model: model,
                            isSelected: workspace.id == model.selectedWorkspace?.id
                        )
                        .opacity(dragging == workspace.id ? 0.45 : 1)
                        .onDrag {
                            dragging = workspace.id
                            return NSItemProvider(object: workspace.id.description as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: WorkspaceDropDelegate(target: workspace.id, model: model, dragging: $dragging)
                        )
                    }
                    newWorkspaceButton
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .animation(.snappy(duration: 0.25), value: model.workspaces.map(\.id))
            }
            .scrollIndicators(.never)
            FleetFooter(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The header row shares the titlebar with the window buttons.
        .ignoresSafeArea(edges: .top)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Spacer()
            Button {
                model.createWorkspace()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("New Workspace (⌘T)")
        }
        .padding(.horizontal, 10)
        .frame(height: ContentViewController.headerHeight)
        .padding(.bottom, ContentViewController.topGap)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
    }

    private var newWorkspaceButton: some View {
        Button {
            model.createWorkspace()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("New Workspace")
                    .font(.system(size: 12))
                Spacer()
                Text("⌘T")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
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
        withAnimation(.snappy(duration: 0.2)) {
            model.moveWorkspace(dragging, to: destination)
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// "3 working · 1 needs you · 2 elsewhere", opening the fleet popover.
struct FleetFooter: View {
    let model: AppModel
    @State private var showingFleet = false

    var body: some View {
        let live = model.sessions.filter { $0.state != .ended }
        let working = live.filter(\.state.isWorking).count
        let needsYou = live.filter { $0.state.needsAttention || $0.pendingPermission != nil }.count
        let elsewhere = model.externalSessions.count

        Button {
            showingFleet.toggle()
        } label: {
            HStack(spacing: 8) {
                if live.isEmpty {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 10))
                    Text("No agents running")
                } else {
                    stat(working, "working", color: Palette.accent, spinner: working > 0)
                    if needsYou > 0 { stat(needsYou, needsYou == 1 ? "needs you" : "need you", color: Palette.attention) }
                    if elsewhere > 0 {
                        Text("\(elsewhere) elsewhere")
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5).monospacedDigit())
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.horizontal, 10)
        }
        .popover(isPresented: $showingFleet, arrowEdge: .top) {
            FleetPopover(model: model)
        }
        .help("Agents on this Mac")
    }

    private func stat(_ count: Int, _ label: String, color: Color, spinner: Bool = false) -> some View {
        HStack(spacing: 4) {
            if spinner {
                Spinner(color: color).frame(width: 8, height: 8)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text("\(count) \(label)")
        }
        // Counts matter more than "elsewhere", which truncates first.
        .fixedSize()
    }
}

struct FleetPopover: View {
    let model: AppModel

    var body: some View {
        let external = model.externalSessions.sorted { $0.sidebarPriority < $1.sidebarPriority }
        let local = model.sessions.filter { $0.surface != nil && $0.state != .ended }.sorted { $0.sidebarPriority < $1.sidebarPriority }
        VStack(alignment: .leading, spacing: 0) {
            Text("Fleet")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    section("Elsewhere on this Mac", sessions: external, external: true)
                    if !local.isEmpty {
                        section("In Mothership", sessions: local, external: false)
                    }
                    if external.isEmpty && local.isEmpty {
                        Text("No agent sessions detected.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: 420)
    }

    @ViewBuilder
    private func section(_ title: String, sessions: [AgentSession], external: Bool) -> some View {
        if !sessions.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(sessions) { session in
                FleetRow(session: session, external: external) {
                    if let surface = session.surface { model.focusSurface(surface) }
                }
            }
        }
    }
}

private struct FleetRow: View {
    let session: AgentSession
    let external: Bool
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            AgentGlyph(kind: session.kind, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title ?? session.kind.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    AgentStateIndicator(state: session.state, unread: session.unread, tint: Palette.agentColor(session.kind))
                    Spacer(minLength: 0)
                    Text(session.state.label)
                        .font(.system(size: 10))
                        .foregroundStyle(session.state.isNeedsInput ? AnyShapeStyle(Palette.attention) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
                if let line = session.displayLine {
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if external {
                        Image(systemName: "macwindow")
                        Text(session.hostApp ?? "Unknown app")
                        Text("·")
                    }
                    Text(PathDisplay.short(session.cwd))
                        .truncationMode(.head)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovering && !external ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !external { onOpen() } }
    }
}
