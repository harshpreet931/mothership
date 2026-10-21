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
        let titleMarkers: [Data]
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
    /// Bytes decoded from the start of a huge file (first prompt, early facts).
    let headBytes: UInt64
    private var tails: [String: Tail] = [:]
    private var documents: [String: (modified: Date, size: Int)] = [:]
    private var documentStates: [String: TranscriptDecodeState] = [:]
    private var openCode: OpenCodeDatabase?
    private var openCodeCursor: Date
    private var databaseStamp: Date?
    private(set) var linesParsed = 0
    private(set) var linesSkipped = 0

    init(adapters: [any AgentAdapter], home: URL, maxInitialBytes: UInt64 = 32 << 20, headBytes: UInt64 = 1 << 20, now: Date = Date()) {
        self.home = home
        self.maxInitialBytes = maxInitialBytes
        self.headBytes = headBytes
        self.openCodeCursor = now.addingTimeInterval(-15 * 60)
        var sources: [Source] = []
        for adapter in adapters {
            for source in adapter.transcriptSources(home: home) {
                sources.append(
                    Source(
                        adapter: adapter, source: source, markers: source.lineMarkers?.map { Data($0.utf8) },
                        titleMarkers: (source.titleMarkers ?? []).map { Data($0.utf8) }
                    )
                )
            }
        }
        self.sources = sources
    }

    /// Directories to hand to FSEvents (nested roots collapsed into their parent).
    func watchRoots() -> [String] {
        var roots: [String] = []
        for entry in sources {
            let path = entry.source.format == .sqlite ? entry.source.root.deletingLastPathComponent().path : entry.source.root.path
            if !roots.contains(path) { roots.append(path) }
        }
        return roots.filter { root in !roots.contains { $0 != root && root.hasPrefix($0 + "/") } }
    }

    /// Small index files to read at start (Codex thread names).
    func eagerFiles() -> [String] {
        sources.flatMap { $0.source.eagerFiles.map(\.path) }
    }

    /// The newest part of a transcript (default 256 KB), decoded with a throwaway state: the
    /// current state and latest facts, fast, before the full history is read.
    func peek(path: String, bytes: UInt64 = 256 << 10) -> [AgentSignal] {
        guard tails[path] == nil, let entry = source(for: path), entry.source.format == .jsonl,
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
        else { return [] }
        var tailer = JSONLTailer(path: path)
        if size > bytes { tailer.seek(toLineAfter: size - bytes) }
        var state = TranscriptDecodeState(isInitialLoad: true)
        var signals: [AgentSignal] = []
        for line in tailer.read(maxBytes: Int(bytes) + 4096).lines {
            if let markers = entry.markers, !line.containsAny(markers) { continue }
            signals += entry.adapter.decodeTranscript(.line(path: path, data: line), state: &state)
        }
        Self.markReplay(&signals)
        return signals
    }

    static func markReplay(_ signals: inout [AgentSignal]) {
        for index in signals.indices { signals[index].isReplay = true }
    }

    // MARK: Watching (kqueue)

    /// Paths worth watching whatever sessions are live: state directories, indexes, the OpenCode
    /// database and its WAL, and dated directories where new transcripts appear.
    func staticWatchPaths(now: Date = Date()) -> [String] {
        var paths: [String] = []
        for entry in sources {
            switch entry.source.format {
            case .jsonDocument:
                paths.append(entry.source.root.path)
            case .sqlite:
                let database = entry.source.root.path
                paths += [database, database + "-wal", entry.source.root.deletingLastPathComponent().path]
            case .jsonl:
                break
            }
            paths += entry.source.eagerFiles.map(\.path)
            paths += entry.source.watchDirectories(now).map(\.path)
        }
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    /// Files in `directory` that a source accepts and that changed since `since` (new
    /// transcripts after `/clear`, new rollouts, rewritten status files).
    func changedFiles(inDirectory directory: String, since: Date) -> [FileChange] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory), names.count < 4096 else { return [] }
        var changes: [FileChange] = []
        for name in names {
            let path = (directory as NSString).appendingPathComponent(name)
            guard source(for: path) != nil,
                let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                modified >= since
            else { continue }
            changes.append(FileChange(path: path, flags: 0))
        }
        return changes
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
            var prefix: [AgentSignal] = []
            if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value, size > maxInitialBytes {
                // Huge file: decode the head (first prompt, early facts), pick title records out
                // of the skipped middle without parsing it, then read the newest window.
                let windowStart = size - maxInitialBytes
                var head = JSONLTailer(path: path)
                let headLines = head.read(maxBytes: Int(min(headBytes, windowStart))).lines
                for line in headLines {
                    if let markers = entry.markers, !line.containsAny(markers) { continue }
                    prefix += entry.adapter.decodeTranscript(.line(path: path, data: line), state: &state)
                }
                if !entry.titleMarkers.isEmpty {
                    for line in Self.lines(in: path, from: head.committedOffset, to: windowStart, containing: entry.titleMarkers) {
                        prefix += entry.adapter.decodeTranscript(.line(path: path, data: line), state: &state)
                    }
                }
                tailer.seek(toLineAfter: windowStart)
                state.values["truncatedHistory"] = "1"
            }
            tail = Tail(tailer: tailer, state: state, lastRead: Date())
            tails[path] = tail
            Self.markReplay(&prefix)
            if !prefix.isEmpty {
                return prefix + readTail(path, entry: entry, fromStart: fromStart)
            }
        }
        var signals: [AgentSignal] = []
        var rounds = 0
        repeat {
            let read = tail.tailer.read()
            if read.didReset {
                tail.state = TranscriptDecodeState(isInitialLoad: false)
            }
            let replay = tail.state.isInitialLoad
            for line in read.lines {
                if let markers = entry.markers, !line.containsAny(markers) {
                    linesSkipped += 1
                    continue
                }
                linesParsed += 1
                var decoded = entry.adapter.decodeTranscript(.line(path: path, data: line), state: &tail.state)
                if replay { Self.markReplay(&decoded) }
                signals += decoded
            }
            rounds += 1
            if !read.hasMore { break }
        } while rounds < 8
        tail.state.isInitialLoad = false
        tail.lastRead = Date()
        tails[path] = tail
        return signals
    }

    /// Complete lines in `[from, to)` that contain any marker, found with `memmem` on raw bytes
    /// (no JSON parsing), in file order.
    static func lines(in path: String, from start: UInt64, to end: UInt64, containing markers: [Data], chunkSize: Int = 8 << 20) -> [Data] {
        guard end > start, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        var found: [Data] = []
        var offset = start
        var carry = Data()
        while offset < end {
            try? handle.seek(toOffset: offset)
            let wanted = Int(min(UInt64(chunkSize), end - offset))
            guard let chunk = try? handle.read(upToCount: wanted), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            var buffer = carry
            buffer.append(chunk)
            let lastNewline = buffer.lastIndex(of: 0x0A)
            let complete = lastNewline.map { buffer[buffer.startIndex..<$0] } ?? Data()
            carry = lastNewline.map { Data(buffer[buffer.index(after: $0)...]) } ?? buffer
            if carry.count > 4 << 20 { carry.removeAll() }
            var ranges: [Range<Int>] = []
            complete.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                for marker in markers {
                    marker.withUnsafeBytes { needle in
                        guard let needleBase = needle.baseAddress else { return }
                        var position = 0
                        while position < raw.count,
                            let hit = memmem(base + position, raw.count - position, needleBase, needle.count)
                        {
                            let index = base.distance(to: hit)
                            var lineStart = index
                            while lineStart > 0, raw[lineStart - 1] != 0x0A { lineStart -= 1 }
                            var lineEnd = index
                            while lineEnd < raw.count, raw[lineEnd] != 0x0A { lineEnd += 1 }
                            ranges.append(lineStart..<lineEnd)
                            position = lineEnd + 1
                        }
                    }
                }
            }
            let origin = complete.startIndex
            for range in Set(ranges).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                found.append(Data(complete[(origin + range.lowerBound)..<(origin + range.upperBound)]))
            }
        }
        return found
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
        let firstSight = documentStates[path] == nil
        var state = documentStates[path] ?? TranscriptDecodeState()
        var signals = entry.adapter.decodeTranscript(.document(path: path, data: data), state: &state)
        documentStates[path] = state
        if firstSight { Self.markReplay(&signals) }
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

    /// Drop tails idle for longer than `age` (except `keeping`); returns the evicted paths.
    @discardableResult
    func evict(olderThan age: TimeInterval, keeping: Set<String> = [], now: Date = Date()) -> Set<String> {
        var evicted: Set<String> = []
        for (path, tail) in tails where now.timeIntervalSince(tail.lastRead) >= age && !keeping.contains(path) {
            tails[path] = nil
            evicted.insert(path)
        }
        for (path, document) in documents where now.timeIntervalSince(document.modified) >= age && !keeping.contains(path) {
            documents[path] = nil
            documentStates[path] = nil
            evicted.insert(path)
        }
        return evicted
    }

    func close() {
        openCode?.close()
        openCode = nil
    }

    // MARK: Polling fallback (when FSEvents is unavailable)

    /// Stat-based change detection for what's already tracked, plus small state directories
    /// (Claude's per-pid status files) and the OpenCode database. A handful of `stat` calls.
    func pollForChanges() -> [AgentSignal] {
        let fileManager = FileManager.default
        var changes: [FileChange] = []
        for (path, tail) in tails {
            var info = stat()
            guard stat(path, &info) == 0 else { continue }
            if UInt64(max(0, info.st_size)) != tail.tailer.offset || UInt64(info.st_ino) != tail.tailer.inode {
                changes.append(FileChange(path: path, flags: 0))
            }
        }
        for path in documents.keys { changes.append(FileChange(path: path, flags: 0)) }
        for entry in sources where entry.source.format == .jsonDocument {
            // Only flat state directories are listed (Claude's sessions dir); trees are not walked.
            guard let names = try? fileManager.contentsOfDirectory(atPath: entry.source.root.path), names.count < 512 else { continue }
            for name in names {
                let path = entry.source.root.appending(path: name).path
                if documents[path] == nil, entry.source.accepts(path) { changes.append(FileChange(path: path, flags: 0)) }
            }
        }
        var signals = handle(changes.filter { !isDatabase($0.path) })
        if let database = sources.first(where: { $0.source.format == .sqlite })?.source.root.path {
            let stamp = [database, database + "-wal"].compactMap { (try? fileManager.attributesOfItem(atPath: $0)[.modificationDate]) as? Date }.max()
            if let stamp, stamp != databaseStamp {
                databaseStamp = stamp
                signals += pollOpenCode()
            }
        }
        return signals
    }

    private func isDatabase(_ path: String) -> Bool {
        sources.contains { $0.source.format == .sqlite && $0.source.accepts(path) }
    }

    var trackedFileCount: Int { tails.count + documents.count }
}
