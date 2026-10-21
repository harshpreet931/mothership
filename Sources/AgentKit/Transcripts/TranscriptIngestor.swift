import Foundation
import ShipModel
import SystemProbe

/// Turns transcript / state-file / database changes into signals. Owns the per-file tail
/// offsets and decoder state, so the engine actor never blocks on file I/O.
actor TranscriptIngestor {
    struct Source: Sendable {
        let adapter: any AgentAdapter
        let source: TranscriptSource
        let markers: [Data]?
    }

    struct Tail {
        var tailer: JSONLTailer
        var state: TranscriptDecodeState
        var lastRead: Date
    }

    let home: URL
    let sources: [Source]
    /// Cap for the first read of an existing file; older history is skipped.
    let maxInitialBytes: UInt64
    private var tails: [String: Tail] = [:]
    private var documents: [String: (modified: Date, size: Int)] = [:]
    private var documentStates: [String: TranscriptDecodeState] = [:]
    private var openCode: OpenCodeDatabase?
    private var openCodeCursor: Date
    private(set) var linesParsed = 0
    private(set) var linesSkipped = 0

    init(adapters: [any AgentAdapter], home: URL, maxInitialBytes: UInt64 = 32 << 20, now: Date = Date()) {
        self.home = home
        self.maxInitialBytes = maxInitialBytes
        self.openCodeCursor = now.addingTimeInterval(-15 * 60)
        var sources: [Source] = []
        for adapter in adapters {
            for source in adapter.transcriptSources(home: home) {
                sources.append(Source(adapter: adapter, source: source, markers: source.lineMarkers?.map { Data($0.utf8) }))
            }
        }
        self.sources = sources
    }

    /// Directories to hand to FSEvents.
    func watchRoots() -> [String] {
        var roots: [String] = []
        for entry in sources {
            let path = entry.source.format == .sqlite ? entry.source.root.deletingLastPathComponent().path : entry.source.root.path
            if !roots.contains(path) { roots.append(path) }
        }
        return roots
    }

    func source(for path: String) -> Source? {
        sources.first { $0.source.accepts(path) }
    }

    // MARK: Change handling

    func handle(_ changes: [FileChange]) -> [AgentSignal] {
        var signals: [AgentSignal] = []
        var pollDatabase = false
        var seen: Set<String> = []
        for change in changes where seen.insert(change.path).inserted {
            guard !change.isDirectory, let entry = source(for: change.path) else { continue }
            switch entry.source.format {
            case .jsonl:
                if !FileManager.default.fileExists(atPath: change.path) {
                    tails[change.path] = nil
                    continue
                }
                signals += readTail(change.path, entry: entry, fromStart: true)
            case .jsonDocument:
                signals += readDocument(change.path, entry: entry)
            case .sqlite:
                pollDatabase = true
            }
        }
        if pollDatabase { signals += pollOpenCode() }
        return signals
    }

    /// Start (or continue) tailing a transcript the engine learned about from a hook or binding.
    func track(path: String) -> [AgentSignal] {
        guard tails[path] == nil, let entry = source(for: path), FileManager.default.fileExists(atPath: path) else { return [] }
        switch entry.source.format {
        case .jsonl: return readTail(path, entry: entry, fromStart: true)
        case .jsonDocument: return readDocument(path, entry: entry)
        case .sqlite: return []
        }
    }

    func isTracking(_ path: String) -> Bool { tails[path] != nil }

    private func readTail(_ path: String, entry: Source, fromStart: Bool) -> [AgentSignal] {
        var tail: Tail
        if let existing = tails[path] {
            tail = existing
        } else {
            var tailer = JSONLTailer(path: path)
            var state = TranscriptDecodeState(isInitialLoad: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value, size > maxInitialBytes {
                tailer.seek(toLineAfter: size - maxInitialBytes)
                state.values["truncatedHistory"] = "1"
            }
            tail = Tail(tailer: tailer, state: state, lastRead: Date())
        }
        var signals: [AgentSignal] = []
        var rounds = 0
        repeat {
            let read = tail.tailer.read()
            if read.didReset {
                tail.state = TranscriptDecodeState(isInitialLoad: false)
            }
            for line in read.lines {
                if let markers = entry.markers, !line.containsAny(markers) {
                    linesSkipped += 1
                    continue
                }
                linesParsed += 1
                signals += entry.adapter.decodeTranscript(.line(path: path, data: line), state: &tail.state)
            }
            rounds += 1
            if !read.hasMore { break }
        } while rounds < 8
        tail.state.isInitialLoad = false
        tail.lastRead = Date()
        tails[path] = tail
        return signals
    }

    private func readDocument(_ path: String, entry: Source) -> [AgentSignal] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let modified = attributes[.modificationDate] as? Date,
            let size = (attributes[.size] as? NSNumber)?.intValue, size < 16 << 20
        else {
            documents[path] = nil
            documentStates[path] = nil
            return []
        }
        if let previous = documents[path], previous.modified == modified, previous.size == size { return [] }
        documents[path] = (modified, size)
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        var state = documentStates[path] ?? TranscriptDecodeState()
        let signals = entry.adapter.decodeTranscript(.document(path: path, data: data), state: &state)
        documentStates[path] = state
        return signals
    }

    // MARK: OpenCode

    private func openCodeDatabase() -> OpenCodeDatabase? {
        if let openCode { return openCode }
        guard let entry = sources.first(where: { $0.source.format == .sqlite }) else { return nil }
        let database = OpenCodeDatabase(path: entry.source.root.path)
        openCode = database
        return database
    }

    func pollOpenCode() -> [AgentSignal] {
        guard let database = openCodeDatabase(),
            let entry = sources.first(where: { $0.source.format == .sqlite })
        else { return [] }
        let rows = database.sessions(updatedAfter: openCodeCursor)
        var signals: [AgentSignal] = []
        var state = TranscriptDecodeState()
        for row in rows {
            openCodeCursor = max(openCodeCursor, row.updatedAt)
            signals += entry.adapter.decodeTranscript(.openCodeSession(row), state: &state)
        }
        return signals
    }

    func openCodeSessions(directory: String) -> [OpenCodeSessionRow] {
        guard let database = openCodeDatabase() else { return [] }
        return database.sessions(updatedAfter: Date().addingTimeInterval(-7 * 24 * 3600), directory: directory, limit: 5).reversed()
    }

    /// Drop tails idle for longer than `age`.
    func evict(olderThan age: TimeInterval, now: Date = Date()) {
        tails = tails.filter { now.timeIntervalSince($0.value.lastRead) < age }
        documents = documents.filter { now.timeIntervalSince($0.value.modified) < age }
        documentStates = documentStates.filter { documents[$0.key] != nil }
    }

    func close() {
        openCode?.close()
        openCode = nil
    }

    var trackedFileCount: Int { tails.count + documents.count }
}
