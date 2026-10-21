import Darwin
import Foundation

/// Incremental JSON-lines reader: remembers a byte offset, returns only complete new lines,
/// keeps a trailing partial line until its newline arrives, and starts over when the file
/// is truncated or replaced (different inode).
public struct JSONLTailer: Sendable {
    public let path: String
    /// Bytes consumed so far, including the buffered partial line.
    public private(set) var offset: UInt64
    public private(set) var inode: UInt64?
    private var partial = Data()

    public init(path: String, offset: UInt64 = 0, inode: UInt64? = nil) {
        self.path = path
        self.offset = offset
        self.inode = inode
    }

    /// Offset of the end of the last complete line (what to persist across launches).
    public var committedOffset: UInt64 { offset - UInt64(partial.count) }

    public struct Read: Sendable {
        public var lines: [Data]
        /// The file was truncated or replaced and reading restarted from the beginning.
        public var didReset: Bool
        /// More data than `maxBytes` is waiting.
        public var hasMore: Bool
    }

    public mutating func read(maxBytes: Int = 16 << 20) -> Read {
        var info = stat()
        guard stat(path, &info) == 0 else { return Read(lines: [], didReset: false, hasMore: false) }
        let currentInode = UInt64(info.st_ino)
        let size = UInt64(max(0, info.st_size))
        var didReset = false
        if let inode, inode != currentInode {
            offset = 0
            partial.removeAll()
            didReset = true
        } else if size < offset {
            offset = 0
            partial.removeAll()
            didReset = true
        }
        inode = currentInode
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else {
            return Read(lines: [], didReset: didReset, hasMore: false)
        }
        defer { try? handle.close() }
        let wanted = Int(min(size - offset, UInt64(maxBytes)))
        let chunk: Data
        do {
            try handle.seek(toOffset: offset)
            chunk = try handle.read(upToCount: wanted) ?? Data()
        } catch {
            return Read(lines: [], didReset: didReset, hasMore: false)
        }
        offset += UInt64(chunk.count)
        var buffer = partial
        buffer.append(chunk)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            var line = buffer[start..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            start = buffer.index(after: newline)
        }
        partial = Data(buffer[start...])
        return Read(lines: lines, didReset: didReset, hasMore: offset < size)
    }

    /// Skip to `position`, discarding the (probably partial) line it lands in.
    public mutating func seek(toLineAfter position: UInt64) {
        offset = position
        partial.removeAll()
        guard position > 0, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: position)
        var skipped: UInt64 = 0
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                skipped += UInt64(chunk.distance(from: chunk.startIndex, to: newline) + 1)
                offset = position + skipped
                return
            }
            skipped += UInt64(chunk.count)
        }
        offset = position + skipped
    }
}

extension Data {
    /// Whether any of the byte patterns occurs (cheap prefilter before JSON parsing).
    func containsAny(_ patterns: [Data]) -> Bool {
        patterns.contains { range(of: $0) != nil }
    }
}
