import AppKit
import ShipModel
import ShipProtocol

/// A prompt held until its agent goes idle (⇧⏎ in the composer).
struct QueuedPrompt: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let surface: SurfaceID
}

/// Getting text to agents and shells: the composer, its queue, "Start a task…".
extension AppModel {
    /// ⏎ sends; ⇧⏎ (`queue`) holds the prompt until the agent is idle.
    func submitComposer(_ text: String, queue: Bool) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if composerBroadcast {
            for session in sessions where session.state.isLive {
                guard let surface = session.surface else { continue }
                if session.state.isWorking {
                    composerQueue.append(QueuedPrompt(text: prompt, surface: surface))
                } else {
                    deliver(prompt, to: surface)
                }
            }
            return
        }
        if let target = composerTarget, let surface = target.surface {
            if queue, target.state.isWorking {
                withAnimationIfAllowed { composerQueue.append(QueuedPrompt(text: prompt, surface: surface)) }
            } else {
                deliver(prompt, to: surface)
            }
            return
        }
        startTask(prompt, agent: composerAgent)
    }

    /// "Start a task…": the agent with the prompt, in a new workspace beside the current one.
    func startTask(_ prompt: String, agent: AgentKind) {
        let engine = self.engine
        let directory = focusedSurface?.terminal?.workingDirectory ?? selectedWorkspace?.currentDirectory
        Task { [weak self] in
            let command = await engine.launchCommand(agent, prompt: prompt)
            self?.createWorkspace(cwd: directory, command: command)
        }
    }

    /// Bracketed paste, then Enter.
    func deliver(_ text: String, to surface: SurfaceID) {
        guard let terminal = self.surface(surface)?.terminal else { return }
        terminal.paste(text: text)
        terminal.sendKey(.enter)
    }

    func queuedCount(for surface: SurfaceID?) -> Int {
        guard let surface else { return composerQueue.count }
        return composerQueue.filter { $0.surface == surface }.count
    }

    /// Sends the oldest queued prompt to each agent that just went idle.
    func flushComposerQueue() {
        guard !composerQueue.isEmpty else { return }
        var delivered: Set<SurfaceID> = []
        var remaining: [QueuedPrompt] = []
        for prompt in composerQueue {
            let session = sessions.first { $0.surface == prompt.surface && $0.state.isLive }
            let ready = session.map { !$0.state.isWorking && $0.pendingPermission == nil } ?? false
            if ready, !delivered.contains(prompt.surface) {
                deliver(prompt.text, to: prompt.surface)
                delivered.insert(prompt.surface)
            } else if session != nil {
                remaining.append(prompt)
            }
        }
        if remaining != composerQueue { composerQueue = remaining }
    }
}
