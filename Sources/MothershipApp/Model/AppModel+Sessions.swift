import AppKit
import Foundation
import SessionHost
import ShipModel
import ShipProtocol
import TerminalEngine

/// Persistent sessions: `mshipd` owns pane PTYs so shells and agents keep running when
/// Mothership quits or crashes, and the next launch reattaches them with their screen.
/// See docs/agents/sessions.md.
extension AppModel {
    /// Settings → General: "Keep sessions running when Mothership quits". Default on.
    static let keepSessionsAliveKey = "sessions.keepAlive"

    /// `MOTHERSHIP_KEEP_SESSIONS=0|1` overrides it for one run (QA) without touching the
    /// stored preference.
    var keepsSessionsAlive: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["MOTHERSHIP_DEMO"] == "1" { return false }  // demo panes are throwaway
        if let override = environment["MOTHERSHIP_KEEP_SESSIONS"] { return override != "0" }
        return PreferenceStore.defaults.object(forKey: Self.keepSessionsAliveKey) as? Bool ?? true
    }

    /// Whether this quit ends pane processes (persistence off, or "Quit and End All Sessions").
    var quitEndsSessions: Bool { endSessionsOnQuit || !keepsSessionsAlive }

    /// At launch, before restoring panes: connect to (or start) the session host. With
    /// persistence off, sessions left by an earlier run are ended instead, as quitting would
    /// have ended them.
    func startSessionHost() {
        guard keepsSessionsAlive else {
            endLeftoverSessions()
            return
        }
        connectSessionHost()
    }

    /// The host for a new pane, nil to run it under the app.
    func persistentSessionHost() -> SessionHostClient? {
        guard keepsSessionsAlive else { return nil }
        if let sessionHost, sessionHost.isConnected { return sessionHost }
        return isReconnectingSessionHost ? nil : connectSessionHost()
    }

    @discardableResult
    func connectSessionHost() -> SessionHostClient? {
        let support = ShipPaths.supportDirectory.path
        let socket = SessionHostPaths.socket(forSupportDirectory: support)
        let log = SessionHostPaths.logFile(forSupportDirectory: support)
        guard let daemon = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "mshipd").path else { return nil }
        let environment = ProcessInfo.processInfo.environment
        do {
            var client = try SessionHostLauncher.connectOrLaunch(socketPath: socket, daemonPath: daemon, logPath: log, environment: environment)
            if client.welcome.version != SessionProtocol.version {
                guard client.welcome.sessionCount == 0 else {
                    NSLog(
                        "Mothership: mshipd (pid %d) speaks protocol %d, not %d, and holds %d session(s); keeping it running. New panes run without persistence until it exits.",
                        client.welcome.pid, Int(client.welcome.version), Int(SessionProtocol.version), client.welcome.sessionCount
                    )
                    client.close()
                    return nil
                }
                NSLog("Mothership: restarting idle mshipd (protocol %d → %d)", Int(client.welcome.version), Int(SessionProtocol.version))
                client.shutdownHost()
                client.close()
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline, (try? SessionHostClient.connect(socketPath: socket))?.close() != nil { usleep(20_000) }
                client = try SessionHostLauncher.connectOrLaunch(socketPath: socket, daemonPath: daemon, logPath: log, environment: environment)
            }
            install(client)
            return client
        } catch {
            NSLog("Mothership: session host unavailable (%@); panes run under the app", "\(error)")
            return nil
        }
    }

    private func install(_ client: SessionHostClient) {
        sessionHost = client
        let owner = WeakModel(self)
        client.setDisconnectHandler {
            DispatchQueue.main.async { MainActor.assumeIsolated { owner.model?.sessionHostDisconnected() } }
        }
        paneHostPIDs = [getpid(), client.welcome.pid]
    }

    /// Wires a new pane into persistence: a reattached session needs no resume offer (its agent
    /// is still running); a lost host triggers one reconnect for every pane.
    func configurePersistence(of terminal: TerminalSurfaceController, surface: PaneSurface) {
        terminal.onSessionOpened = { [weak surface] reattached in
            if reattached { surface?.resumeOffer = nil }
        }
        terminal.onHostDisconnected = { [weak self] in self?.sessionHostDisconnected() }
    }

    /// `mshipd` went away (crashed or was killed). Its sessions died with it; start a new
    /// host and give every persistent pane a fresh shell under its existing screen.
    func sessionHostDisconnected() {
        guard !isReconnectingSessionHost else { return }
        sessionHost = nil
        paneHostPIDs = [getpid()]
        isReconnectingSessionHost = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            isReconnectingSessionHost = false
            guard keepsSessionsAlive, let client = connectSessionHost() else { return }
            for workspace in workspaces {
                for surface in workspace.surfaces.values where surface.terminal?.isPersistent == true {
                    surface.terminal?.reconnect(to: client)
                }
            }
        }
    }

    /// Quitting: persistent panes detach (the host keeps them running) unless this quit ends
    /// sessions; exec panes always end.
    func releaseTerminalsForQuit() {
        let end = quitEndsSessions
        for workspace in workspaces {
            for surface in workspace.surfaces.values {
                if end { surface.terminal?.terminate() } else { surface.terminal?.detach() }
            }
        }
    }

    private func endLeftoverSessions() {
        let socket = SessionHostPaths.socket(forSupportDirectory: ShipPaths.supportDirectory.path)
        guard let client = try? SessionHostClient.connect(socketPath: socket) else { return }
        if client.welcome.sessionCount > 0 {
            NSLog("Mothership: keep-alive is off; ending %d session(s) left in mshipd", client.welcome.sessionCount)
            client.shutdownHost()
        }
        client.close()
    }

    /// ⌥⌘Q: quit and end every pane's process, asking first while agents or commands run.
    func quitAndEndAllSessions() {
        let work = runningWork()
        if let sentence = QuitSummary.sentence(agents: work.agents, commands: work.commands) {
            let alert = NSAlert()
            alert.messageText = "Quit and end all sessions?"
            alert.informativeText = sentence + " Ending sessions stops them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "End Sessions and Quit")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            NSLog("Mothership: asking before ending sessions: %@", sentence)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        endSessionsOnQuit = true
        NSApp.terminate(nil)
    }

    /// True when quitting now would stop nothing: every pane lives in the session host and
    /// this quit leaves them running.
    var quitKeepsEverythingRunning: Bool {
        guard !quitEndsSessions else { return false }
        return workspaces.allSatisfy { workspace in
            workspace.surfaces.values.allSatisfy { $0.terminal == nil || $0.terminal?.isPersistent == true }
        }
    }
}

/// A weak model reference the host's disconnect handler can carry to the main actor.
private final class WeakModel: @unchecked Sendable {
    // @unchecked: `model` is only read on the main actor (the handler hops there first).
    weak var model: AppModel?
    @MainActor init(_ model: AppModel) { self.model = model }
}
