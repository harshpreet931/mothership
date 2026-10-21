import AppKit
import Foundation
import ShipModel
import ShipProtocol
import SystemProbe

/// A folder offered by "Start a task" and New Workspace menus.
struct RecentProject: Identifiable, Equatable {
    var id: String { path }
    let path: String
    /// Folder name (repo roots are what's usually listed).
    var name: String { (path as NSString).lastPathComponent }
    /// `~/code/app`, for a subtitle.
    var displayPath: String { PathDisplay.abbreviated(path) }
}

/// Workspace names, project folders and the quit check. The decisions themselves are pure
/// (`WorkspaceNaming`, `ProjectFolders`, `QuitSummary` in ShipProtocol, unit-tested there).
extension AppModel {
    // MARK: Names

    /// Recomputes every automatic workspace name: the live agent's title, else the repo or
    /// folder name, de-duplicated with " 2", " 3" (older workspaces keep the plain name).
    /// Custom names are never touched.
    func refreshWorkspaceNames() {
        let ordered = workspaces.sorted { $0.sequence < $1.sequence }
        let entries = ordered.map { workspace in
            WorkspaceNaming.Entry(base: workspace.hasCustomName ? workspace.name : automaticBaseName(for: workspace), isCustom: workspace.hasCustomName)
        }
        for (workspace, name) in zip(ordered, WorkspaceNaming.uniqueNames(entries)) where !workspace.hasCustomName {
            if workspace.name != name { workspace.name = name }
        }
    }

    private func automaticBaseName(for workspace: Workspace) -> String {
        let title = sessions(in: workspace).lazy.compactMap { $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        if title != nil || workspace.currentDirectory != workspace.restoredDirectory {
            workspace.restoredName = nil
            workspace.restoredDirectory = nil
        }
        if title == nil, let restored = workspace.restoredName { return restored }
        return WorkspaceNaming.baseName(
            directory: workspace.currentDirectory, repoName: workspace.namingRepoName, agentTitle: title, home: PathDisplay.home
        )
    }

    /// Wires a new or restored workspace into automatic naming.
    func adoptForNaming(_ workspace: Workspace) {
        workspace.onNamingInputsChanged = { [weak self] in self?.refreshWorkspaceNames() }
    }

    // MARK: Project folders

    /// Folders agents worked in, folders the user chose, and open workspaces' projects; most
    /// recent first, never `$HOME`. For the composer's ＋ menu and New Workspace menus.
    var recentProjects: [RecentProject] {
        recentProjectPaths.map(RecentProject.init(path:))
    }

    var recentProjectPaths: [String] {
        let now = Date()
        var candidates = Self.loadChosenFolders()
        candidates += sessions.map { ProjectFolders.Candidate(path: $0.repoRoot ?? $0.cwd, lastUsed: $0.lastActivity) }
        candidates += workspaces.map { ProjectFolders.Candidate(path: $0.git?.root ?? $0.currentDirectory, lastUsed: now.addingTimeInterval(-60)) }
        return ProjectFolders.recent(candidates, home: PathDisplay.home) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Where "Start a task" and ⌘T go: the focused workspace's folder when it's a project,
    /// else the most recent project. Nil means ask (never default an agent to `$HOME`).
    func taskDirectory() -> String? {
        let focused = focusedSurface?.terminal?.workingDirectory ?? focusedSurface?.cwd ?? selectedWorkspace?.currentDirectory
        return ProjectFolders.taskDirectory(focused: focused, recent: recentProjectPaths, home: PathDisplay.home)
    }

    /// Shows an open panel for a folder (a sheet on the main window when there is one) and
    /// remembers the choice in the recent list. Nil when cancelled.
    func chooseFolder(message: String = "Choose a project folder") async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        panel.directoryURL = URL(fileURLWithPath: recentProjectPaths.first.map { ($0 as NSString).deletingLastPathComponent } ?? PathDisplay.home)
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let path = panel.url?.path else { return nil }
        noteProjectUsed(path)
        return path
    }

    /// "Choose Folder…" (⌘O): a new workspace in the chosen folder.
    func openFolderAsWorkspace() {
        Task { [weak self] in
            guard let self, let path = await self.chooseFolder(message: "Open a folder as a new workspace") else { return }
            self.createWorkspace(cwd: path)
        }
    }

    /// Remembers a folder for the recent list (stored under the support directory).
    func noteProjectUsed(_ path: String) {
        guard ProjectFolders.isProject(path, home: PathDisplay.home) else { return }
        var chosen = Self.loadChosenFolders().filter { $0.path != path }
        chosen.insert(ProjectFolders.Candidate(path: path, lastUsed: Date()), at: 0)
        Self.saveChosenFolders(Array(chosen.prefix(20)))
    }

    private static var chosenFoldersURL: URL { ShipPaths.supportDirectory.appending(path: "recent-folders.json") }

    private struct StoredFolder: Codable {
        var path: String
        var lastUsed: Date
    }

    private static func loadChosenFolders() -> [ProjectFolders.Candidate] {
        guard let data = try? Data(contentsOf: chosenFoldersURL),
              let stored = try? JSONDecoder.ship.decode([StoredFolder].self, from: data) else { return [] }
        return stored.map { ProjectFolders.Candidate(path: $0.path, lastUsed: $0.lastUsed) }
    }

    private static func saveChosenFolders(_ folders: [ProjectFolders.Candidate]) {
        let stored = folders.map { StoredFolder(path: $0.path, lastUsed: $0.lastUsed) }
        guard let data = try? JSONEncoder.ship.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: chosenFoldersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: chosenFoldersURL, options: .atomic)
    }

    // MARK: Quit

    /// What would stop if the app quit now: live agent sessions in panes, and panes whose
    /// foreground process is something other than an idle shell.
    func runningWork() -> (agents: Int, commands: Int) {
        let surfaceIDs = Set(workspaces.flatMap { $0.surfaces.keys })
        let agentSurfaces = Set(sessions.filter { $0.state.isLive }.compactMap(\.surface).filter(surfaceIDs.contains))
        guard let table = try? ProcessTable.capture() else { return (agentSurfaces.count, 0) }
        var commandSurfaces: Set<SurfaceID> = []
        var unattributed = 0
        for process in table.descendants(of: getpid()) where process.tty != nil && process.isForegroundGroupLeader && !process.isZombie {
            guard !Self.shellNames.contains(process.comm) else { continue }
            let surface = ProcessInspector.arguments(pid: process.pid)?.environment[ShipEnvironment.surfaceID].flatMap { SurfaceID(string: $0) }
            if let surface {
                if surfaceIDs.contains(surface), !agentSurfaces.contains(surface) { commandSurfaces.insert(surface) }
            } else {
                unattributed += 1
            }
        }
        return (agentSurfaces.count, commandSurfaces.count + unattributed)
    }

    private static let shellNames: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "-fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "login",
    ]

    /// Asks before quitting while agents or commands run. True means quit.
    func confirmQuit() -> Bool {
        let work = runningWork()
        guard let sentence = QuitSummary.sentence(agents: work.agents, commands: work.commands) else { return true }
        NSLog("Mothership: asking before quit: %@", sentence)
        let alert = NSAlert()
        alert.messageText = "Quit Mothership?"
        alert.informativeText = sentence + " Quitting stops them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApp.activate()
        let quit = alert.runModal() == .alertFirstButtonReturn
        NSLog("Mothership: quit %@", quit ? "confirmed" : "cancelled")
        return quit
    }
}
