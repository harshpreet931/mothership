import AppKit
import ShipModel
import SwiftUI

/// The bottom capsule (§6 Composer): talks to the focused pane's agent, or starts a task.
struct ComposerView: View {
    let model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private static let agents: [AgentKind] = [.claude, .codex, .opencode, .gemini]

    var body: some View {
        let target = model.composerTarget
        let queued = model.queuedCount(for: target?.surface)
        HStack(spacing: 10) {
            AgentMark(kind: target?.kind ?? model.composerAgent, size: 15, color: Sky.secondary)
                .opacity(model.composerBroadcast ? 0.4 : 1)
            TextField(model.composerPlaceholder, text: $text, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
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
                    if let surface = model.focusedSurface?.id { model.requestFocus(surface) }
                }
            if queued > 0 {
                Text("\(queued) queued")
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
                Divider()
                Toggle("Broadcast to all agents", isOn: Binding(get: { model.composerBroadcast }, set: { model.composerBroadcast = $0 }))
                if let selection = model.focusedSurface?.terminal?.selectedText, !selection.isEmpty {
                    Button("Attach terminal selection") { text += (text.isEmpty ? "" : "\n") + selection }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .regular))
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
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Sky.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dictate")
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 44)
        .glassCapsule()
        .frame(maxWidth: 720)
        .animation(Sky.spring, value: queued)
        .onChange(of: model.composerFocusRequest) { focused = true }
    }

    private func send(queue: Bool) {
        let prompt = text
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.submitComposer(prompt, queue: queue)
        text = ""
    }

    private func dictate() {
        focused = true
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }
}
