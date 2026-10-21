import Darwin
import Foundation
import ShipModel

/// `ShipPaths.socket.path` without `FileManager.homeDirectoryForCurrentUser`, which costs
/// ~1.2 ms on first use: a fifth of the `mship hook` budget, paid by every hook fired from a
/// terminal outside Mothership (where `MOTHERSHIP_SOCKET` isn't set). Same answer, same
/// overrides; anything unusual defers to `ShipPaths`.
public enum ControlSocketLocation {
    public static func resolve() -> String {
        if let socket = environment(ShipEnvironment.socket) {
            return socket.hasPrefix("/") ? socket : ShipPaths.socket.path
        }
        if let home = environment("MOTHERSHIP_HOME") {
            return home.hasPrefix("/") ? join(home, "control.sock") : ShipPaths.socket.path
        }
        if let home = environment("HOME"), home.hasPrefix("/") {
            return join(home, "Library/Application Support/Mothership/control.sock")
        }
        return ShipPaths.socket.path
    }

    private static func environment(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    private static func join(_ directory: String, _ component: String) -> String {
        var directory = directory
        while directory.count > 1 && directory.hasSuffix("/") { directory.removeLast() }
        return directory == "/" ? "/" + component : directory + "/" + component
    }
}

extension HookEnvelope {
    /// The envelope as wire JSON, built by hand. Decodes exactly like `JSONValue(encoding:)`
    /// but skips Foundation's ISO-8601 formatter setup (~0.5 ms), which matters on the hook path.
    public var wireJSON: JSONValue {
        var object: [String: JSONValue] = [
            "agent": .string(agent.rawValue),
            "event": .string(event),
            "payload": .string(payload.base64EncodedString()),
            "sentAt": .string(Self.iso8601(sentAt)),
        ]
        if let surface { object["surface"] = .string(surface.description) }
        if let workspace { object["workspace"] = .string(workspace.description) }
        if let agentPID { object["agentPID"] = .number(Double(agentPID)) }
        if let cwd { object["cwd"] = .string(cwd) }
        return .object(object)
    }

    /// `yyyy-MM-ddTHH:mm:ssZ`, matching `JSONEncoder.DateEncodingStrategy.iso8601`.
    static func iso8601(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        func pad(_ value: Int32, _ width: Int) -> String {
            let digits = String(value)
            return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
        }
        return pad(parts.tm_year + 1900, 4) + "-" + pad(parts.tm_mon + 1, 2) + "-" + pad(parts.tm_mday, 2) + "T"
            + pad(parts.tm_hour, 2) + ":" + pad(parts.tm_min, 2) + ":" + pad(parts.tm_sec, 2) + "Z"
    }
}
