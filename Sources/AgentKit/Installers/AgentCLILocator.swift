import Foundation
import Synchronization

/// Finds agent CLIs on this machine and their versions. Prefers reading versions from the
/// install layout (Claude's `versions/<x.y.z>` symlink target, an npm `package.json`) and
/// only falls back to running `<cli> --version` (cached per binary + mtime).
public final class AgentCLILocator: Sendable {
    public let searchPaths: [String]
    private let cache = Mutex<[String: String?]>([:])
    private let allowExecution: Bool

    /// `environmentPath` is `$PATH`; well-known install dirs are appended because apps launched
    /// from Finder get a minimal PATH.
    public init(home: URL, environmentPath: String? = ProcessInfo.processInfo.environment["PATH"], allowExecution: Bool = true) {
        let homePath = home.path
        var paths = (environmentPath ?? "").split(separator: ":").map(String.init)
        paths += [
            "\(homePath)/.local/bin", "\(homePath)/.opencode/bin", "\(homePath)/.npm-global/bin", "\(homePath)/.bun/bin",
            "\(homePath)/.volta/bin", "\(homePath)/.claude/local", "\(homePath)/.cargo/bin", "\(homePath)/go/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        ]
        var seen: Set<String> = []
        self.searchPaths = paths.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.allowExecution = allowExecution
    }

    public func locate(_ names: [String]) -> String? {
        let fileManager = FileManager.default
        for directory in searchPaths {
            for name in names {
                let candidate = (directory as NSString).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    public func version(of path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: resolved)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(resolved)#\(mtime)"
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let version = Self.versionFromLayout(resolved) ?? (allowExecution ? Self.versionFromExecution(path) : nil)
        cache.withLock { $0[key] = version }
        return version
    }

    static func versionFromLayout(_ resolved: String) -> String? {
        // ~/.local/share/claude/versions/2.1.306
        for component in (resolved as NSString).pathComponents.reversed() where isSemver(component) {
            return component
        }
        // npm: …/node_modules/@openai/codex/bin/codex.js → …/@openai/codex/package.json
        var directory = (resolved as NSString).deletingLastPathComponent
        for _ in 0..<5 {
            let manifest = (directory as NSString).appendingPathComponent("package.json")
            if let data = FileManager.default.contents(atPath: manifest), let json = JSONNode.parse(data),
                let version = json["version"].text, json["name"].text != nil
            {
                return version
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func isSemver(_ text: String) -> Bool {
        let core = text.split(separator: "-").first.map(String.init) ?? text
        let parts = core.split(separator: ".")
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func versionFromExecution(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return firstSemver(in: output)
    }

    static func firstSemver(in text: String) -> String? {
        guard let regex = RegexCache.regex("\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.]+)?"),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }
}
