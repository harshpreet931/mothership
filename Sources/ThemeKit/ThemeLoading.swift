import Foundation
import Synchronization

/// User themes from a directory, JSON export, and a watcher for hot reload.
public enum ThemeLoading {
    /// Larger files aren't themes.
    static let maximumFileSize = 512 * 1024

    public static func load(userDirectory: URL, builtIn: [Theme]) -> (themes: [Theme], problems: [String: [ThemeIssue]]) {
        var themes = builtIn
        var problems: [String: [ThemeIssue]] = [:]
        let builtInIDs = Set(builtIn.map(\.id))
        var userIDs: [String: String] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil) else {
            return (themes, problems)
        }
        for file in files.filter({ $0.pathExtension.lowercased() == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard let data = try? Data(contentsOf: file) else {
                problems[name] = [ThemeIssue(.error, "couldn't read the file")]
                continue
            }
            guard data.count <= maximumFileSize else {
                problems[name] = [ThemeIssue(.error, "the file is \(data.count / 1024) KB; themes are at most \(maximumFileSize / 1024) KB")]
                continue
            }
            let theme: Theme
            do {
                theme = try JSONDecoder().decode(Theme.self, from: data)
            } catch {
                problems[name] = [ThemeIssue(.error, describe(error))]
                continue
            }
            if builtInIDs.contains(theme.id) {
                problems[name] = [ThemeIssue(.error, "“\(theme.id)” is a built-in theme's id; give your theme its own id")]
                continue
            }
            if let other = userIDs[theme.id] {
                problems[name] = [ThemeIssue(.error, "“\(theme.id)” is already used by \(other)")]
                continue
            }
            let issues = ThemeValidation.validate(theme, asBuiltIn: false)
            if !issues.isEmpty { problems[name] = issues }
            guard !issues.contains(where: { $0.severity == .error }) else { continue }
            userIDs[theme.id] = name
            themes.append(theme)
        }
        return (themes, problems)
    }

    /// Pretty-printed, keys sorted: the same theme always exports the same bytes.
    public static func export(_ theme: Theme) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(theme)) ?? Data()
    }

    /// A decoding error in theme-author terms: where, and what was expected.
    static func describe(_ error: any Error) -> String {
        func path(_ codingPath: [any CodingKey]) -> String {
            let text = codingPath.map { key in key.intValue.map { "[\($0)]" } ?? "." + key.stringValue }.joined()
            return text.hasPrefix(".") ? String(text.dropFirst()) : (text.isEmpty ? "the top level" : text)
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            let parent = path(context.codingPath)
            return "missing “\(key.stringValue)”" + (context.codingPath.isEmpty ? "" : " in \(parent)")
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        case DecodingError.dataCorrupted(let context):
            if context.codingPath.isEmpty { return "not valid JSON" }
            return "\(path(context.codingPath)): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }
}

/// Reports changes to a theme directory (files added, removed, renamed or saved), coalesced
/// over `latency`, so the app can reload themes while someone edits one. kqueue through
/// `DispatchSource`: the directory itself (entries come and go) and each `*.json` in it (saved
/// in place).
public final class ThemeDirectoryWatcher: Sendable {
    public let directory: URL
    private let queue: DispatchQueue
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let state = Mutex(State())

    private struct State {
        var directorySource: (any DispatchSourceFileSystemObject)?
        var fileSources: [String: any DispatchSourceFileSystemObject] = [:]
        /// Bumped by every event; a scheduled report fires only if it's still the latest.
        var generation = 0
    }

    public init(directory: URL, queue: DispatchQueue = .main, latency: TimeInterval = 0.25, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.queue = queue
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    /// False when the directory can't be opened (create it first).
    @discardableResult
    public func start() -> Bool {
        stop()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .link, .attrib, .extend], queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.rescanFiles()
            self?.schedule()
        }
        source.setCancelHandler { close(descriptor) }
        state.withLock { $0.directorySource = source }
        source.resume()
        rescanFiles()
        return true
    }

    public func stop() {
        let (directorySource, fileSources) = state.withLock { state in
            defer {
                state.directorySource = nil
                state.fileSources = [:]
                state.generation += 1
            }
            return (state.directorySource, Array(state.fileSources.values))
        }
        directorySource?.cancel()
        for source in fileSources { source.cancel() }
    }

    /// Paths currently watched for in-place saves.
    public var watchedFiles: [String] { state.withLock { $0.fileSources.keys.sorted() } }

    private func rescanFiles() {
        let files = Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".json") }
                .map { directory.appending(path: $0).path }
        )
        let (stale, missing) = state.withLock { state -> ([any DispatchSourceFileSystemObject], [String]) in
            guard state.directorySource != nil else { return ([], []) }
            let stale = state.fileSources.filter { !files.contains($0.key) }
            for key in stale.keys { state.fileSources[key] = nil }
            return (Array(stale.values), files.filter { state.fileSources[$0] == nil }.sorted())
        }
        for source in stale { source.cancel() }
        for path in missing {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue
            )
            // The handler holds its source until the source is cancelled (Dispatch then drops it).
            source.setEventHandler { [weak self] in
                guard let self else { return }
                // Deleted or replaced (an atomic save): forget it; the rescan watches the new file.
                if !source.data.isDisjoint(with: [.delete, .rename]) { self.dropFileSource(path) }
                self.schedule()
            }
            source.setCancelHandler { close(descriptor) }
            let added = state.withLock { state -> Bool in
                guard state.directorySource != nil, state.fileSources[path] == nil else { return false }
                state.fileSources[path] = source
                return true
            }
            if added {
                source.resume()
            } else {
                source.resume()
                source.cancel()
            }
        }
    }

    private func dropFileSource(_ path: String) {
        let source = state.withLock { $0.fileSources.removeValue(forKey: path) }
        source?.cancel()
    }

    private func schedule() {
        let generation = state.withLock { state in
            state.generation += 1
            return state.generation
        }
        queue.asyncAfter(deadline: .now() + latency) { [weak self] in
            guard let self, self.state.withLock({ $0.generation == generation && $0.directorySource != nil }) else { return }
            // A replaced file (atomic save) has a new inode: watch the new one.
            self.rescanFiles()
            self.onChange()
        }
    }
}
