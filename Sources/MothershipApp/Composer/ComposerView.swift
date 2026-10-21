import AppKit
import ShipModel
import SwiftUI

/// The bottom composer (§6): a slim centered pill ("Message Claude ⌘L") floating over the
/// bottom gutter until clicked or ⌘L, then a field that talks to the focused pane's agent
/// or starts a task. Esc, or leaving it empty, folds it back.
struct ComposerView: View {
    let model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var hovering = false
    /// "Start in" (＋ menu): the folder for the next task, else `taskDirectory()`.
    @State private var taskFolder: String?

    private static let agents: [AgentKind] = [.claude, .codex, .opencode, .gemini]

    var body: some View {
        ZStack {
            if model.isComposerExpanded {
                field
                    .transition(.opacity)
            } else {
                pill
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.composerFocusRequest) { focused = true }
        .onChange(of: focused) { _, isFocused in
            // Clicking away from an empty composer folds it.
            if !isFocused, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.closeComposer(refocusPane: false)
            }
        }
    }

    private var pill: some View {
        Button { model.openComposer() } label: {
            HStack(spacing: 8) {
                AgentMark(kind: model.composerTarget?.kind ?? model.composerAgent, size: 12, color: Sky.secondary)
                Text(placeholder)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Sky.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let queued = model.queuedCount(for: model.composerTarget?.surface)
                if queued > 0 {
                    Text(verbatim: String(queued) + " queued")
                        .font(Sky.Font.meta)
                        .foregroundStyle(Sky.secondary)
                        .fixedSize()
                }
                Text("⌘L")
                    .font(Sky.Font.meta)
                    .foregroundStyle(Sky.tertiary)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ComposerSurface())
            .overlay(Capsule().fill(Sky.ink.opacity(hovering ? 0.05 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Sky.hover) { self.hovering = hovering } }
        .help("Message the focused agent, or start a task (⌘L)")
        .accessibilityLabel(placeholder)
    }

    private var field: some View {
        let target = model.composerTarget
        let queued = model.queuedCount(for: target?.surface)
        return HStack(spacing: 10) {
            AgentMark(kind: target?.kind ?? model.composerAgent, size: 14, color: Sky.secondary)
                .opacity(model.composerBroadcast ? 0.4 : 1)
            TextField(placeholder, text: $text, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Sky.ink)
                .focused($focused)
                .onSubmit { send(queue: false) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    send(queue: true)
                    return .handled
                }
                .onExitCommand {
                    focused = false
                    model.closeComposer()
                }
                .onAppear { DispatchQueue.main.async { focused = true } }
            if queued > 0 {
                Text(verbatim: String(queued) + " queued")
                    .font(Sky.Font.meta)
                    .foregroundStyle(Sky.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Sky.recess))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .help("Sent when the agent finishes its current turn")
            }
            Menu {
                Section("Start tasks with") {
                    ForEach(Self.agents, id: \.self) { kind in
                        Button {
                            model.composerAgent = kind
                        } label: {
                            if model.composerAgent == kind {
                                Label(kind.displayName, systemImage: "checkmark")
                            } else {
                                Text(kind.displayName)
                            }
                        }
                    }
                }
                if startsTask {
                    Menu("Start in") {
                        let current = taskFolder ?? model.taskDirectory()
                        ForEach(model.recentProjects.prefix(8)) { project in
                            Button {
                                taskFolder = project.path
                            } label: {
                                if current == project.path {
                                    Label(project.name, systemImage: "checkmark")
                                } else {
                                    Text(project.name)
                                }
                            }
                            .help(project.displayPath)
                        }
                        Divider()
                        Button("Choose Folder…") {
                            Task {
                                if let folder = await model.chooseFolder(message: "Where should the next task run?") { taskFolder = folder }
                            }
                        }
                    }
                }
                Divider()
                Toggle("Broadcast to all agents", isOn: Binding(get: { model.composerBroadcast }, set: { model.composerBroadcast = $0 }))
                if let selection = model.focusedSurface?.terminal?.selectedText, !selection.isEmpty {
                    Button("Attach terminal selection") { text += (text.isEmpty ? "" : "\n") + selection }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Sky.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Agent, attachments, broadcast")
            Button(action: dictate) {
                Image(systemName: "mic")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Sky.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dictate")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ComposerSurface())
        .animation(Sky.spring, value: queued)
    }

    /// Nothing to talk to: ⏎ starts a task in a new workspace.
    private var startsTask: Bool { model.composerTarget == nil && !model.composerBroadcast }

    private var placeholder: String {
        if startsTask, let folder = taskFolder {
            return "Start a task in " + (folder as NSString).lastPathComponent + "…"
        }
        return model.composerPlaceholder
    }

    private func send(queue: Bool) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard startsTask else {
            model.submitComposer(prompt, queue: queue)
            text = ""
            return
        }
        let agent = model.composerAgent
        if let folder = taskFolder ?? model.taskDirectory() {
            model.startTask(prompt, agent: agent, directory: folder)
            text = ""
            taskFolder = nil
            model.closeComposer(refocusPane: false)
            return
        }
        // No project to start in: ask, and keep the text if the panel is cancelled.
        Task {
            guard let folder = await model.chooseFolder(message: "Where should \(agent.displayName) work on this task?") else { return }
            model.startTask(prompt, agent: agent, directory: folder)
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt { text = "" }
            model.closeComposer(refocusPane: false)
        }
    }

    private func dictate() {
        focused = true
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }
}

/// Opaque bubble capsule with a hairline and a soft shadow: it floats over the cards'
/// bottom margin, so it must read on terminal and sky alike.
private struct ComposerSurface: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Capsule(style: .continuous)
            .fill(Sky.bubble)
            .overlay(Capsule(style: .continuous).strokeBorder(Sky.cardStroke, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.1), radius: 10, y: 4)
    }
}
