import AppKit
import GitKit
import ShipModel
import SwiftUI

/// New Task (⌘N): one prompt, a repo and base, one or more agents. Two or more agents is
/// Best-of-N, each in its own worktree, compared side by side when they're done.
struct NewTaskOverlay: View {
    let model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if model.newTaskDraft?.isStarting != true { model.dismissNewTask() } }
            if model.newTaskDraft != nil {
                NewTaskSheet(model: model)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
    }
}

struct NewTaskSheet: View {
    let model: AppModel
    @FocusState private var promptFocused: Bool

    private var draft: NewTaskDraft {
        model.newTaskDraft ?? NewTaskDraft(prompt: "", repoRoot: nil, baseBranch: nil, agents: [], useWorktrees: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("New task")
                    .font(Sky.Font.serifL)
                    .foregroundStyle(Sky.ink)
                Spacer()
                Button { model.dismissNewTask() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Sky.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Sky.recess))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
            }
            promptField
            VStack(alignment: .leading, spacing: 12) {
                row("Repository") { repoPicker }
                row("Base") { basePicker }
                row("Agents") { agentChips }
                row("Isolation") { worktreesToggle }
            }
            footer
        }
        .padding(24)
        .frame(width: 640)
        .solidPanel()
        .onAppear { DispatchQueue.main.async { promptFocused = true } }
        .onExitCommand { if !draft.isStarting { model.dismissNewTask() } }
        .disabled(draft.isStarting)
        .animation(Sky.spring, value: draft.agents)
        .animation(Sky.spring, value: draft.error)
    }

    // MARK: Prompt

    private var promptField: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(get: { model.newTaskDraft?.prompt ?? "" }, set: { value in update { $0.prompt = value } }))
                .font(.system(size: 16))
                .foregroundStyle(Sky.ink)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($promptFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            if draft.prompt.isEmpty {
                Text("What should the agents do?")
                    .font(.system(size: 16))
                    .foregroundStyle(Sky.tertiary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 132)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Sky.recess))
    }

    // MARK: Rows

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Sky.tertiary)
                .frame(width: 84, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var repoPicker: some View {
        Menu {
            Section("Recent") {
                ForEach(model.recentProjects.prefix(10)) { project in
                    Button {
                        update {
                            $0.repoRoot = GitInfo.read(at: project.path)?.root ?? project.path
                            $0.baseBranch = nil
                        }
                    } label: {
                        if draft.repoRoot == project.path {
                            Label("\(project.name)  \(project.displayPath)", systemImage: "checkmark")
                        } else {
                            Text("\(project.name)  \(project.displayPath)")
                        }
                    }
                }
            }
            Divider()
            Button("Choose Folder…") {
                Task {
                    guard let folder = await model.chooseFolder(message: "Which repository is this task for?") else { return }
                    update {
                        $0.repoRoot = GitInfo.read(at: folder)?.root ?? folder
                        $0.baseBranch = nil
                    }
                }
            }
        } label: {
            PickerPill {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Sky.secondary)
                if let root = draft.repoRoot {
                    Text((root as NSString).lastPathComponent).foregroundStyle(Sky.ink)
                    Text(PathDisplay.abbreviated(root))
                        .font(Sky.Font.meta)
                        .foregroundStyle(Sky.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text("Choose a repository").foregroundStyle(Sky.secondary)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder private var basePicker: some View {
        if let root = draft.repoRoot {
            let branches = model.branches(in: root)
            Menu {
                Button {
                    update { $0.baseBranch = nil }
                } label: {
                    let title = "Current branch" + (branches.current.map { " (\($0))" } ?? "")
                    if draft.baseBranch == nil { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
                if !branches.all.isEmpty {
                    Divider()
                    ForEach(branches.all.prefix(14), id: \.self) { branch in
                        Button {
                            update { $0.baseBranch = branch }
                        } label: {
                            if draft.baseBranch == branch { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                        }
                    }
                }
            } label: {
                PickerPill {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Sky.secondary)
                    Text(draft.baseBranch ?? branches.current ?? "current branch")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Sky.ink)
                    if draft.baseBranch == nil {
                        Text("current").font(.system(size: 11.5)).foregroundStyle(Sky.tertiary)
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Text("Pick a repository first").font(.system(size: 12.5)).foregroundStyle(Sky.tertiary)
        }
    }

    private var agentChips: some View {
        let installed = model.installedTaskAgents
        return VStack(alignment: .leading, spacing: 8) {
            if installed.isEmpty {
                Text("No agent CLIs found on this Mac. Install Claude Code, Codex, OpenCode or Gemini CLI.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Sky.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(installed, id: \.self) { kind in
                        AgentChip(kind: kind, selected: draft.agents.contains(kind)) {
                            update { draft in
                                if let index = draft.agents.firstIndex(of: kind) {
                                    draft.agents.remove(at: index)
                                } else {
                                    draft.agents.append(kind)
                                }
                            }
                        }
                    }
                }
                Text(agentCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(Sky.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .id(draft.agents.count > 1)
            }
        }
    }

    private var agentCaption: String {
        switch draft.agents.count {
        case 0: return "Pick at least one agent."
        case 1: return "\(draft.agents[0].displayName) works on it in a new workspace."
        default: return "Best of \(draft.agents.count): each agent tries it in its own worktree. Compare the results and keep the best."
        }
    }

    private var worktreesToggle: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { draft.useWorktrees || draft.worktreesForced },
                set: { value in update { $0.useWorktrees = value } }
            ))
            .toggleStyle(SkySwitchStyle())
            // Forced on reads as on (not greyed out), it just can't be turned off.
            .allowsHitTesting(!draft.worktreesForced)
            .overlay(alignment: .bottomTrailing) {
                if draft.worktreesForced {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Sky.secondary)
                        .offset(x: 6, y: 4)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Separate worktrees")
                    .font(.system(size: 13))
                    .foregroundStyle(Sky.ink)
                Text(draft.worktreesForced
                    ? "Required when more than one agent works on the same task."
                    : (draft.useWorktrees ? "Your checkout stays untouched; the agent gets its own branch." : "The agent works directly in your checkout."))
                    .font(.system(size: 12))
                    .foregroundStyle(Sky.tertiary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = draft.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Sky.danger)
                    .lineLimit(2)
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
            Button("Cancel") { model.dismissNewTask() }
                .buttonStyle(GhostPillStyle(height: 32))
                .keyboardShortcut(.cancelAction)
            Button {
                model.submitNewTask()
            } label: {
                HStack(spacing: 8) {
                    if draft.isStarting {
                        ProgressView().controlSize(.mini).tint(Sky.onInk)
                    }
                    Text(draft.agents.count > 1 ? "Start \(draft.agents.count) agents" : "Start task")
                    Text("⌘⏎").font(Sky.Font.meta).opacity(0.6)
                }
            }
            .buttonStyle(InkCapsuleStyle(height: 32))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!draft.canStart)
            .opacity(draft.canStart || draft.isStarting ? 1 : 0.4)
        }
        .padding(.top, 4)
    }

    private func update(_ change: (inout NewTaskDraft) -> Void) {
        guard var draft = model.newTaskDraft else { return }
        change(&draft)
        draft.error = nil
        model.newTaskDraft = draft
    }
}

/// A capsule that opens a menu: icon, value, chevron.
private struct PickerPill<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            content
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Sky.tertiary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(Sky.ink.opacity(hovering ? 0.09 : 0.06)))
        .contentShape(Capsule())
        .onHover { inside in withAnimation(Sky.hover) { hovering = inside } }
    }
}

/// An agent to include; selected chips take the sky's selection.
private struct AgentChip: View {
    let kind: AgentKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                AgentMark(kind: kind, size: 13, color: selected ? Sky.onSelection : Sky.ink.opacity(0.8))
                Text(kind.shortName)
                    .font(Sky.Font.label)
                    .foregroundStyle(selected ? Sky.onSelection : Sky.ink.opacity(0.85))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                let shape = Capsule(style: .continuous)
                if selected {
                    SelectionFill(shape: shape)
                } else {
                    shape.fill(Sky.ink.opacity(hovering ? 0.09 : 0.05))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Sky.hover) { hovering = inside } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
