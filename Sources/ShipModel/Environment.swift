import Foundation

/// Environment variables Mothership injects into every shell it spawns.
public enum ShipEnvironment {
    public static let socket = "MOTHERSHIP_SOCKET"
    public static let surfaceID = "MOTHERSHIP_SURFACE_ID"
    public static let workspaceID = "MOTHERSHIP_WORKSPACE_ID"
    public static let version = "MOTHERSHIP_VERSION"

    public static func variables(surface: SurfaceID, workspace: WorkspaceID) -> [String: String] {
        [
            socket: ShipPaths.socket.path,
            surfaceID: surface.description,
            workspaceID: workspace.description,
            version: ShipInfo.version,
        ]
    }
}

public enum ShipInfo {
    public static let name = "Mothership"
    public static let bundleIdentifier = "com.mothership.app"
    public static let version = "0.1.0"
}

/// Well-known locations. Each can be overridden by environment for tests and dev builds.
public enum ShipPaths {
    /// `~/Library/Application Support/Mothership`, or `$MOTHERSHIP_HOME`.
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MOTHERSHIP_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Mothership", directoryHint: .isDirectory)
    }

    /// The control socket, or `$MOTHERSHIP_SOCKET` when set (shells inside Mothership always have it).
    public static var socket: URL {
        if let override = ProcessInfo.processInfo.environment[ShipEnvironment.socket], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return supportDirectory.appending(path: "control.sock")
    }

    /// A stable copy of the `mship` CLI that agent hook configs point at, so moving or
    /// updating the app never breaks installed hooks.
    public static var cliShim: URL { supportDirectory.appending(path: "bin/mship") }

    public static var stateFile: URL { supportDirectory.appending(path: "state.json") }
    public static var agentManifests: URL { supportDirectory.appending(path: "agents", directoryHint: .isDirectory) }
    public static var backups: URL { supportDirectory.appending(path: "backups", directoryHint: .isDirectory) }
}
