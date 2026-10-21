import Foundation
import Synchronization

/// Finds the GUI app (or multiplexer) that owns a process by walking its ancestors.
public final class HostAppResolver: Sendable {
    /// Bundle ids whose marketing name differs from the bundle's file name.
    static let knownBundles: [String: String] = [
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.microsoft.VSCodeInsiders": "Visual Studio Code - Insiders",
        "com.googlecode.iterm2": "iTerm2",
        "com.apple.Terminal": "Terminal",
        "com.mitchellh.ghostty": "Ghostty",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "dev.warp.Warp-Stable": "Warp",
        "net.kovidgoyal.kitty": "kitty",
        "org.alacritty": "Alacritty",
        "dev.zed.Zed": "Zed",
        "com.exafunction.windsurf": "Windsurf",
        "com.mothership.app": "Mothership",
    ]

    /// Ancestors by `comm` that are a host in their own right (no GUI app above them).
    static let multiplexers: [String: String] = [
        "tmux": "tmux", "screen": "screen", "zellij": "zellij", "sshd": "SSH", "sshd-session": "SSH",
    ]

    private let names = Mutex<[String: String]>([:])
    private let executablePath: @Sendable (Int32) -> String?

    public init(executablePath: @escaping @Sendable (Int32) -> String? = { ProcessInspector.executablePath(pid: $0) }) {
        self.executablePath = executablePath
    }

    /// The host for `pid`: the outermost `*.app` among its ancestors, or a multiplexer
    /// ("tmux") when one sits between the process and launchd.
    public func hostApp(for pid: Int32, in table: ProcessTable) -> String? {
        var multiplexer: String?
        for ancestor in table.ancestors(of: pid) {
            if multiplexer == nil, let name = Self.multiplexers[ancestor.comm] {
                multiplexer = name
            }
            guard let path = executablePath(ancestor.pid), let app = Self.outermostAppBundle(in: path) else {
                continue
            }
            // A multiplexer between the agent and the app wins: the app only hosts the client.
            return multiplexer ?? displayName(forBundle: app)
        }
        return multiplexer
    }

    /// `/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/…` →
    /// `/Applications/Visual Studio Code.app`.
    public static func outermostAppBundle(in path: String) -> String? {
        if let range = path.range(of: ".app/") {
            return String(path[..<range.lowerBound]) + ".app"
        }
        return path.hasSuffix(".app") ? path : nil
    }

    func displayName(forBundle bundlePath: String) -> String {
        if let cached = names.withLock({ $0[bundlePath] }) { return cached }
        let fallback = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        var name = fallback
        let plist = URL(fileURLWithPath: bundlePath).appending(path: "Contents/Info.plist")
        if let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let identifier = info["CFBundleIdentifier"] as? String,
            let known = Self.knownBundles[identifier]
        {
            name = known
        }
        names.withLock { $0[bundlePath] = name }
        return name
    }
}
