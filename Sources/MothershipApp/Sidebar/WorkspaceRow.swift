import ShipModel
import SwiftUI

struct WorkspaceRow: View {
    let workspace: Workspace
    let index: Int
    let model: AppModel
    let isSelected: Bool

    @State private var hovering = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let sessions = model.sessions(in: workspace)
        let primary = sessions.min { $0.sidebarPriority < $1.sidebarPriority }
        HStack(alignment: .top, spacing: 0) {
            accentBar
            VStack(alignment: .leading, spacing: 3) {
                titleLine(sessions: sessions)
                locationLine(fallbackBranch: model.branch(of: workspace))
                if let primary, let line = primary.displayLine {
                    summaryLine(primary, text: line)
                }
                if let request = sessions.compactMap(\.pendingPermission).first {
                    PermissionCard(
                        request: request,
                        onAllow: { model.resolvePermission(request, decision: .allow) },
                        onDeny: { model.resolvePermission(request, decision: .deny(reason: nil)) }
                    )
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { model.selectWorkspace(workspace.id) }
        .contextMenu { contextMenu }
        .animation(.snappy(duration: 0.22), value: sessions.map(\.pendingPermission?.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(workspace.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Pieces

    /// Always takes its space so names line up whether or not a row has a color.
    private var accentBar: some View {
        Capsule()
            .fill(workspace.accentColor.map { Color(nsColor: $0) } ?? .clear)
            .frame(width: 3)
            .padding(.vertical, 10)
            .padding(.leading, 3)
    }

    private func titleLine(sessions: [AgentSession]) -> some View {
        HStack(spacing: 6) {
            if workspace.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(45))
            }
            if model.renamingWorkspaceID == workspace.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($renameFocused)
                    .onSubmit { model.rename(workspace.id, to: draftName) }
                    .onExitCommand { model.renamingWorkspaceID = nil }
                    .onAppear {
                        draftName = workspace.name
                        renameFocused = true
                    }
                    .onChange(of: renameFocused) { _, focused in
                        // Clicking away commits, like Finder.
                        if !focused, model.renamingWorkspaceID == workspace.id {
                            model.rename(workspace.id, to: draftName)
                        }
                    }
            } else {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(isSelected ? 1 : 0.88))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering, index < 9, sessions.isEmpty || !isSelected {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 3) {
                ForEach(sessions.prefix(4)) { session in
                    AgentBadge(session: session)
                }
                if sessions.count > 4 {
                    Text("+\(sessions.count - 4)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 19)
    }

    private func locationLine(fallbackBranch: String?) -> some View {
        HStack(spacing: 5) {
            Text(PathDisplay.short(workspace.currentDirectory))
                .lineLimit(1)
                .truncationMode(.head)
            if let branch = workspace.git?.branch ?? fallbackBranch {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text(branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
                .layoutPriority(-1)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.tertiary)
    }

    private func summaryLine(_ session: AgentSession, text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(session.state.isNeedsInput ? AnyShapeStyle(Palette.attention) : AnyShapeStyle(.secondary))
            .lineLimit(2)
            .shimmer(session.state.isWorking)
            .padding(.top, 1)
            .help(session.lastAssistantMessage ?? text)
    }

    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if isSelected {
            shape
                .fill(Color.primary.opacity(0.085))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        } else if hovering {
            shape.fill(Color.primary.opacity(0.04))
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var contextMenu: some View {
        Button("Rename…") {
            model.selectWorkspace(workspace.id)
            model.renamingWorkspaceID = workspace.id
        }
        Button(workspace.isPinned ? "Unpin" : "Pin") { model.togglePin(workspace.id) }
        Menu("Color") {
            Button("None") { model.setColor(workspace.id, hex: nil) }
            Divider()
            ForEach(Palette.workspaceColors, id: \.hex) { option in
                Button {
                    model.setColor(workspace.id, hex: option.hex)
                } label: {
                    Label {
                        Text(option.name)
                    } icon: {
                        Image(nsImage: Self.swatch(option.hex))
                    }
                }
            }
        }
        Divider()
        Button("New Workspace Here") { model.createWorkspace(cwd: workspace.currentDirectory) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workspace.currentDirectory, forType: .string)
        }
        Divider()
        Button("Close Workspace", role: .destructive) { model.closeWorkspace(workspace.id) }
    }

    private static func swatch(_ hex: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            (NSColor(hex: hex) ?? .gray).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }
}

extension AgentSession {
    /// Sort key for the one session a row summarizes: held permissions first, then
    /// whatever needs eyes, newest activity breaking ties.
    var sidebarPriority: (Int, Double) {
        (pendingPermission != nil ? -1 : state.urgency, -lastActivity.timeIntervalSince1970)
    }
}
