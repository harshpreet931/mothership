import Foundation
import ShipModel

/// Where `mshipd` listens: `sessions.sock` next to the control socket, with the same
/// fallback to a short per-user temp path when the support directory is too deep for
/// `sockaddr_un` (scratch `MOTHERSHIP_HOME`s in QA).
public enum SessionHostPaths {
    public static let socketName = "sessions.sock"

    public static func socket(forSupportDirectory directory: String) -> String {
        let control = ShipPaths.socketPath(forSupportDirectory: directory)
        if control.hasSuffix("/control.sock") {
            return String(control.dropLast("control.sock".count)) + socketName
        }
        // The temp fallback (`…/mship-<hash>.sock`): derive a sibling name from it.
        return String(control.dropLast(".sock".count)) + "-sessions.sock"
    }

    /// For this process's support directory (`$MOTHERSHIP_HOME` aware).
    public static var socket: String { socket(forSupportDirectory: ShipPaths.supportDirectory.path) }

    /// The daemon's log, next to the socket's directory in the support folder.
    public static func logFile(forSupportDirectory directory: String) -> String {
        directory + "/mshipd.log"
    }
}
