import ShipModel
import SwiftUI

/// One vertical tab (§6 Sidebar row). Selection is drawn by the sidebar (a sliding ink
/// pill); the row only switches its text to `onInk`.
struct WorkspaceRow: View {
    let workspace: Workspace
    let index: Int
    let model: AppModel
    let isSelected: Bool
    let selectionNamespace: Namespace.ID

    @State private var hovering = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let sessions = model.sessions(in: workspace)
        let primary = sessions.min { $0.sidebarPriority < $1.sidebarPriority }
        let pending = sessions.first { $0.pendingPermission != nil }
        let resolved = sessions.lazy.compactMap { session in model.recentlyResolved[session.id] }.first

        VStack(alignment: .leading, spacing: 3) {
            titleLine(sessions)
            metaLine(branch: model.branch(of: workspace))
            if let primary, let line = primary.displayLine, pending == nil {
                Text(line)
                    .font(.system(size: 12.5))
                    .foregroundStyle(primary.needsYou ? Sky.attention : secondaryText)
                    .lineLimit(1)
                    .shimmer(primary.state.isWorking && !isSelected)
            }
            if pending != nil || resolved != nil {
                PermissionMorph(request: pending?.pendingPermission, resolved: resolved, compact: true) { request, decision in
                    model.resolvePermission(request, decision: decision)
                }
                .padding(.top, 5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            if isSelected {
                shape.fill(Sky.ink).matchedGeometryEffect(id: "selection", in: selectionNamespace)
            } else if hovering {
                shape.fill(Sky.ink.opacity(0.06))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering in withAnimation(Sky.hover) { self.hovering = hovering } }
        .onTapGesture { withAnimationIfAllowed { model.selectWorkspace(workspace.id) } }
        .contextMenu { contextMenu }
        .animation(Sky.spring, value: pending?.pendingPermission?.id)
        .animation(Sky.spring, value: resolved)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(workspace.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var primaryText: Color { isSelected ? Sky.onInk : Sky.ink }
    private var secondaryText: Color { isSelected ? Sky.onInk.opacity(0.62) : Sky.secondary }
    private var tertiaryText: Color { isSelected ? Sky.onInk.opacity(0.45) : Sky.tertiary }

    private func titleLine(_ sessions: [AgentSession]) -> some View {
        HStack(spacing: 6) {
            if workspace.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tertiaryText)
                    .rotationEffect(.degrees(45))
            }
            if model.renamingWorkspaceID == workspace.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Sky.Font.title)
                    .foregroundStyle(primaryText)
                    .focused($renameFocused)
                    .onSubmit { model.rename(workspace.id, to: draftName) }
                    .onExitCommand { model.renamingWorkspaceID = nil }
                    .onAppear {
                        draftName = workspace.name
                        renameFocused = true
                    }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused, model.renamingWorkspaceID == workspace.id { model.rename(workspace.id, to: draftName) }
                    }
            } else {
                Text(workspace.name)
                    .font(Sky.Font.title)
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering, sessions.isEmpty, index < 9 {
                Text("⌘\(index + 1)")
                    .font(Sky.Font.meta)
                    .foregroundStyle(tertiaryText)
            }
            HStack(spacing: 2) {
                ForEach(sessions.prefix(3)) { session in
                    AgentStatusGlyph(
                        kind: session.kind, state: session.state, unread: session.unread,
                        hasPermission: session.pendingPermission != nil, size: 13, color: primaryText
                    )
                }
            }
        }
        .frame(minHeight: 20)
    }

    private func metaLine(branch: String?) -> some View {
        HStack(spacing: 0) {
            Text(PathDisplay.short(workspace.currentDirectory))
                .truncationMode(.head)
            if let branch {
                Text("  ·  ")
                Text("\(Image(systemName: "arrow.triangle.branch")) \(branch)")
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            let ports = model.ports(in: workspace)
            if !ports.isEmpty {
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    ForEach(ports.prefix(2)) { port in
                        Button {
                            model.openPort(port)
                        } label: {
                            Text(verbatim: ":" + String(port.port))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(secondaryText)
                                .padding(.horizontal, 5)
                                .frame(height: 16)
                                .background(Capsule().fill(isSelected ? Sky.onInk.opacity(0.14) : Sky.recess))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Open localhost:\(String(port.port)) (\(port.process)) beside this workspace")
                    }
                }
                .fixedSize()
            }
        }
        .font(Sky.Font.meta)
        .foregroundStyle(tertiaryText)
        .lineLimit(1)
    }

    @ViewBuilder private var contextMenu: some View {
        Button("Rename…") {
            model.selectWorkspace(workspace.id)
            model.renamingWorkspaceID = workspace.id
        }
        Button(workspace.isPinned ? "Unpin" : "Pin") { model.togglePin(workspace.id) }
        Divider()
        Button("New Workspace Here") { model.createWorkspace(cwd: workspace.currentDirectory) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workspace.currentDirectory, forType: .string)
        }
        Divider()
        Button("Close Workspace", role: .destructive) { model.closeWorkspace(workspace.id) }
    }
}
