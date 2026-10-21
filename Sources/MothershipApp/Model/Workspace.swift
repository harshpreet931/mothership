import AppKit
import Observation
import ShipModel
import TerminalEngine

/// One pane leaf: a terminal or a browser.
@MainActor
@Observable
final class PaneSurface: Identifiable {
    let id: SurfaceID
    let kind: SurfaceKind
    let workspaceID: WorkspaceID
    /// Live cwd for terminals (OSC 7), the starting directory until the shell reports one.
    var cwd: String?
    var title: String?
    /// Browser surfaces.
    var url: String?
    /// The agent session last seen in this pane (persisted for resume).
    var lastAgentSession: AgentSessionKey?
    /// Set on restore when the pane hosted an agent; drives the resume banner.
    var resumeOffer: AgentSessionKey?
    /// OSC 9;4 progress, shown as a hairline at the top of the pane.
    var progress: Double?

    @ObservationIgnored var terminal: TerminalSurfaceController?
    @ObservationIgnored var browserView: NSView?

    init(id: SurfaceID = SurfaceID(), kind: SurfaceKind, workspaceID: WorkspaceID, cwd: String?, url: String? = nil) {
        self.id = id
        self.kind = kind
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.url = url
    }

    /// The OSC title when it says something; shells' default `user@host:path` titles
    /// just repeat what the header already shows.
    var meaningfulTitle: String? {
        guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        if let at = title.firstIndex(of: "@"), title[at...].contains(":"), !title.contains(" ") { return nil }
        if let cwd, title == cwd || title == PathDisplay.abbreviated(cwd) { return nil }
        return title
    }

    /// The view hosted in the pane.
    var contentView: NSView? {
        terminal?.view ?? browserView
    }

    var descriptor: SurfaceDescriptor {
        SurfaceDescriptor(
            id: id, kind: kind, cwd: terminal?.workingDirectory ?? cwd, title: title, url: url,
            lastAgentSession: lastAgentSession
        )
    }
}

/// One vertical tab: a pane tree of surfaces.
@MainActor
@Observable
final class Workspace: Identifiable {
    let id: WorkspaceID
    var name: String
    var hasCustomName: Bool
    var colorHex: String?
    var isPinned: Bool
    /// Where new panes start when no other cwd applies.
    var rootDirectory: String
    var layout: PaneNode {
        didSet {
            if !layout.hasSameStructure(as: oldValue) { structureVersion += 1 }
        }
    }
    /// Bumped only when panes are added/removed/rearranged, not on divider drags.
    private(set) var structureVersion = 0
    var surfaces: [SurfaceID: PaneSurface] = [:]
    var focusedSurfaceID: SurfaceID?
    var zoomedSurfaceID: SurfaceID?
    var git: GitInfo?
    /// Cwd of the focused terminal (what the sidebar shows).
    var currentDirectory: String

    init(
        id: WorkspaceID = WorkspaceID(), name: String, hasCustomName: Bool = false, colorHex: String? = nil,
        isPinned: Bool = false, rootDirectory: String, layout: PaneNode
    ) {
        self.id = id
        self.name = name
        self.hasCustomName = hasCustomName
        self.colorHex = colorHex
        self.isPinned = isPinned
        self.rootDirectory = rootDirectory
        self.layout = layout
        self.currentDirectory = rootDirectory
    }

    /// Leaves in visual order (left→right, top→bottom).
    var orderedSurfaces: [PaneSurface] {
        layout.surfaceIDs.compactMap { surfaces[$0] }
    }

    var focusedSurface: PaneSurface? {
        focusedSurfaceID.flatMap { surfaces[$0] } ?? orderedSurfaces.first
    }

    /// Surfaces currently laid out on screen when this workspace is selected.
    var visibleSurfaceIDs: [SurfaceID] {
        if let zoomedSurfaceID, surfaces[zoomedSurfaceID] != nil { return [zoomedSurfaceID] }
        return layout.surfaceIDs
    }

    var accentColor: NSColor? {
        colorHex.flatMap(NSColor.init(hex:))
    }

    var snapshot: WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: id, name: name, hasCustomName: hasCustomName, colorHex: colorHex, isPinned: isPinned,
            rootDirectory: rootDirectory, layout: layout,
            surfaces: layout.surfaceIDs.compactMap { surfaces[$0]?.descriptor },
            focusedSurface: focusedSurfaceID
        )
    }

    /// Re-reads git info for the current directory and refreshes the automatic name.
    func refreshGit() {
        let info = GitInfo.read(at: currentDirectory)
        if info != git { git = info }
        if !hasCustomName {
            let auto = info?.repoName ?? PathDisplay.folderName(currentDirectory)
            if auto != name { name = auto }
        }
    }
}
