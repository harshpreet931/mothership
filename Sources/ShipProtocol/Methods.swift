import Foundation
import ShipModel

/// Every method the control socket understands. `mship` subcommands and MCP tools map onto these.
public enum ControlMethod: String, Sendable, CaseIterable {
    case ping
    /// params: `HookEnvelope` → result: `HookReply`
    case hook
    /// params: `NotifyParams` → result: `OKResult`
    case notify
    /// params: `StatusParams` → result: `StatusResult`
    case status

    /// params: `NewWorkspaceParams` → result: `SurfaceResult`
    case workspaceNew = "workspace.new"
    /// params: `SplitParams` → result: `SurfaceResult`
    case surfaceSplit = "surface.split"
    /// params: `SurfaceTarget` → result: `OKResult`
    case surfaceFocus = "surface.focus"
    /// params: `SendTextParams` → result: `OKResult`. Pasted (bracketed), not typed.
    case surfaceSendText = "surface.sendText"
    /// params: `ReadScreenParams` → result: `ReadScreenResult`
    case surfaceReadScreen = "surface.readScreen"

    /// params: `BrowserOpenParams` → result: `SurfaceResult`
    case browserOpen = "browser.open"
    /// params: `BrowserTarget` → result: `BrowserSnapshotResult`
    case browserSnapshot = "browser.snapshot"
    /// params: `BrowserElementParams` → result: `OKResult`
    case browserClick = "browser.click"
    /// params: `BrowserFillParams` → result: `OKResult`
    case browserFill = "browser.fill"
    /// params: `BrowserEvalParams` → result: `JSONValue` (the script's return value)
    case browserEval = "browser.eval"
    /// params: `BrowserTarget` → result: `BrowserConsoleResult`
    case browserConsole = "browser.console"
    /// params: `BrowserTarget` → result: `BrowserScreenshotResult`
    case browserScreenshot = "browser.screenshot"
}

public struct OKResult: Sendable, Codable, Equatable {
    public var ok: Bool
    public init(ok: Bool = true) { self.ok = ok }
}

/// Most calls target "the caller's own surface" when `surface` is nil: the server resolves
/// it from the peer's `MOTHERSHIP_SURFACE_ID` (sent by the CLI) or process ancestry.
public struct SurfaceTarget: Sendable, Codable, Equatable {
    public var surface: SurfaceID?
    public init(surface: SurfaceID? = nil) { self.surface = surface }
}

public struct SurfaceResult: Sendable, Codable, Equatable {
    public var surface: SurfaceID
    public var workspace: WorkspaceID
    public init(surface: SurfaceID, workspace: WorkspaceID) {
        self.surface = surface
        self.workspace = workspace
    }
}

public struct NotifyParams: Sendable, Codable, Equatable {
    public var title: String
    public var body: String
    public var surface: SurfaceID?
    public init(title: String, body: String, surface: SurfaceID? = nil) {
        self.title = title
        self.body = body
        self.surface = surface
    }
}

public struct StatusParams: Sendable, Codable, Equatable {
    public var includeExternal: Bool
    public init(includeExternal: Bool = true) { self.includeExternal = includeExternal }
}

public struct WorkspaceSummary: Sendable, Codable, Equatable {
    public var id: WorkspaceID
    public var name: String
    public var rootDirectory: String
    public var surfaces: [SurfaceID]
    public init(id: WorkspaceID, name: String, rootDirectory: String, surfaces: [SurfaceID]) {
        self.id = id
        self.name = name
        self.rootDirectory = rootDirectory
        self.surfaces = surfaces
    }
}

public struct StatusResult: Sendable, Codable, Equatable {
    public var workspaces: [WorkspaceSummary]
    public var sessions: [AgentSession]
    public init(workspaces: [WorkspaceSummary], sessions: [AgentSession]) {
        self.workspaces = workspaces
        self.sessions = sessions
    }
}

public struct NewWorkspaceParams: Sendable, Codable, Equatable {
    public var name: String?
    public var cwd: String?
    /// Run instead of the login shell's first prompt, e.g. `claude "fix the tests"`.
    public var command: String?
    public var focus: Bool
    public init(name: String? = nil, cwd: String? = nil, command: String? = nil, focus: Bool = true) {
        self.name = name
        self.cwd = cwd
        self.command = command
        self.focus = focus
    }
}

public enum SplitDirection: String, Sendable, Codable {
    case right, down, left, up
}

public struct SplitParams: Sendable, Codable, Equatable {
    public var surface: SurfaceID?
    public var direction: SplitDirection
    public var kind: SurfaceKind
    public var cwd: String?
    public var command: String?
    public var url: String?
    public var focus: Bool
    public init(
        surface: SurfaceID? = nil, direction: SplitDirection = .right, kind: SurfaceKind = .terminal,
        cwd: String? = nil, command: String? = nil, url: String? = nil, focus: Bool = false
    ) {
        self.surface = surface
        self.direction = direction
        self.kind = kind
        self.cwd = cwd
        self.command = command
        self.url = url
        self.focus = focus
    }
}

public struct SendTextParams: Sendable, Codable, Equatable {
    public var surface: SurfaceID
    public var text: String
    /// Press Enter after pasting.
    public var submit: Bool
    public init(surface: SurfaceID, text: String, submit: Bool = false) {
        self.surface = surface
        self.text = text
        self.submit = submit
    }
}

public struct ReadScreenParams: Sendable, Codable, Equatable {
    public var surface: SurfaceID?
    /// Lines of scrollback above the viewport to include.
    public var scrollbackLines: Int
    public init(surface: SurfaceID? = nil, scrollbackLines: Int = 0) {
        self.surface = surface
        self.scrollbackLines = scrollbackLines
    }
}

public struct ReadScreenResult: Sendable, Codable, Equatable {
    public var text: String
    public init(text: String) { self.text = text }
}

public enum BrowserPlacement: String, Sendable, Codable {
    /// Split next to the caller's surface (reuses an existing browser pane in the workspace if any).
    case split
    case newWorkspace
    /// Navigate the workspace's existing browser pane, or split if none.
    case reuse
}

public struct BrowserOpenParams: Sendable, Codable, Equatable {
    public var url: String
    public var surface: SurfaceID?
    public var placement: BrowserPlacement
    public init(url: String, surface: SurfaceID? = nil, placement: BrowserPlacement = .reuse) {
        self.url = url
        self.surface = surface
        self.placement = placement
    }
}

/// Targets a browser surface; nil means "the browser pane in the caller's workspace".
public struct BrowserTarget: Sendable, Codable, Equatable {
    public var browser: SurfaceID?
    public init(browser: SurfaceID? = nil) { self.browser = browser }
}

public struct BrowserElementParams: Sendable, Codable, Equatable {
    public var browser: SurfaceID?
    /// A ref from the latest snapshot (e.g. "e12") or a CSS selector.
    public var ref: String
    public init(browser: SurfaceID? = nil, ref: String) {
        self.browser = browser
        self.ref = ref
    }
}

public struct BrowserFillParams: Sendable, Codable, Equatable {
    public var browser: SurfaceID?
    public var ref: String
    public var text: String
    public var submit: Bool
    public init(browser: SurfaceID? = nil, ref: String, text: String, submit: Bool = false) {
        self.browser = browser
        self.ref = ref
        self.text = text
        self.submit = submit
    }
}

public struct BrowserEvalParams: Sendable, Codable, Equatable {
    public var browser: SurfaceID?
    public var script: String
    public init(browser: SurfaceID? = nil, script: String) {
        self.browser = browser
        self.script = script
    }
}

public struct BrowserSnapshotResult: Sendable, Codable, Equatable {
    public var url: String
    public var title: String
    /// Indented outline of the page's interactive/landmark elements with refs, e.g.
    /// `- button "Sign in" [ref=e12]`.
    public var outline: String
    public init(url: String, title: String, outline: String) {
        self.url = url
        self.title = title
        self.outline = outline
    }
}

public struct BrowserConsoleEntry: Sendable, Codable, Equatable {
    public var level: String
    public var message: String
    public var date: Date
    public init(level: String, message: String, date: Date) {
        self.level = level
        self.message = message
        self.date = date
    }
}

public struct BrowserConsoleResult: Sendable, Codable, Equatable {
    public var entries: [BrowserConsoleEntry]
    public init(entries: [BrowserConsoleEntry]) { self.entries = entries }
}

public struct BrowserScreenshotResult: Sendable, Codable, Equatable {
    /// Absolute path of the PNG written to a temp directory.
    public var path: String
    public init(path: String) { self.path = path }
}
