import Foundation

public enum SplitAxis: String, Sendable, Codable {
    /// Children side by side.
    case horizontal
    /// Children stacked.
    case vertical
}

public enum SurfaceKind: String, Sendable, Codable {
    case terminal
    case browser
}

/// What's needed to recreate a pane after relaunch.
public struct SurfaceDescriptor: Identifiable, Sendable, Codable, Equatable {
    public let id: SurfaceID
    public var kind: SurfaceKind
    public var cwd: String?
    public var title: String?
    /// Browser surfaces.
    public var url: String?
    /// The agent session last seen in this pane, offered for resume on relaunch.
    public var lastAgentSession: AgentSessionKey?

    public init(
        id: SurfaceID = SurfaceID(), kind: SurfaceKind, cwd: String? = nil, title: String? = nil,
        url: String? = nil, lastAgentSession: AgentSessionKey? = nil
    ) {
        self.id = id
        self.kind = kind
        self.cwd = cwd
        self.title = title
        self.url = url
        self.lastAgentSession = lastAgentSession
    }
}

public indirect enum PaneNode: Sendable, Codable, Equatable {
    case leaf(SurfaceID)
    /// `fractions` has one entry per child and sums to 1.
    case split(axis: SplitAxis, fractions: [Double], children: [PaneNode])

    public var surfaceIDs: [SurfaceID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, let children): children.flatMap(\.surfaceIDs)
        }
    }
}

/// One vertical tab.
public struct WorkspaceSnapshot: Identifiable, Sendable, Codable, Equatable {
    public let id: WorkspaceID
    public var name: String
    /// True once the user renamed it; otherwise the app may auto-name it.
    public var hasCustomName: Bool
    public var colorHex: String?
    public var isPinned: Bool
    public var rootDirectory: String
    public var layout: PaneNode
    public var surfaces: [SurfaceDescriptor]
    public var focusedSurface: SurfaceID?

    public init(
        id: WorkspaceID = WorkspaceID(), name: String, hasCustomName: Bool = false,
        colorHex: String? = nil, isPinned: Bool = false, rootDirectory: String, layout: PaneNode,
        surfaces: [SurfaceDescriptor], focusedSurface: SurfaceID? = nil
    ) {
        self.id = id
        self.name = name
        self.hasCustomName = hasCustomName
        self.colorHex = colorHex
        self.isPinned = isPinned
        self.rootDirectory = rootDirectory
        self.layout = layout
        self.surfaces = surfaces
        self.focusedSurface = focusedSurface
    }
}

public struct WindowSnapshot: Sendable, Codable, Equatable {
    public var frame: [Double]?
    public var sidebarWidth: Double?
    public var workspaces: [WorkspaceSnapshot]
    public var selectedWorkspace: WorkspaceID?

    public init(frame: [Double]? = nil, sidebarWidth: Double? = nil, workspaces: [WorkspaceSnapshot], selectedWorkspace: WorkspaceID?) {
        self.frame = frame
        self.sidebarWidth = sidebarWidth
        self.workspaces = workspaces
        self.selectedWorkspace = selectedWorkspace
    }
}

public struct AppSnapshot: Sendable, Codable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var windows: [WindowSnapshot]

    public init(windows: [WindowSnapshot]) {
        self.version = Self.currentVersion
        self.windows = windows
    }
}
