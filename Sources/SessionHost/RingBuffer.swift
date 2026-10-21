import Foundation

/// The last `capacity` bytes of a session's output, addressed by absolute stream offset (the
/// count of bytes the session has ever produced), so a client can ask for "everything since
/// offset N" after a reconnect.
public struct OutputRingBuffer: Sendable {
    public let capacity: Int
    private var storage: [UInt8]
    /// Index of the oldest byte in `storage`.
    private var head = 0
    public private(set) var count = 0
    /// Total bytes ever appended.
    public private(set) var endOffset: UInt64 = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = [UInt8](repeating: 0, count: capacity)
    }

    /// Offset of the oldest byte still held.
    public var startOffset: UInt64 { endOffset - UInt64(count) }
    /// Older output has been overwritten.
    public var hasWrapped: Bool { startOffset > 0 }

    public mutating func append(_ data: Data) {
        data.withUnsafeBytes { append($0) }
    }

    public mutating func append(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        endOffset += UInt64(bytes.count)
        var source = bytes
        if source.count >= capacity {
            // Only the tail survives.
            source = UnsafeRawBufferPointer(rebasing: source[(source.count - capacity)...])
            storage.withUnsafeMutableBytes { $0.copyMemory(from: source) }
            head = 0
            count = capacity
            return
        }
        var tail = (head + count) % capacity
        var remaining = source[...]
        storage.withUnsafeMutableBytes { target in
            while !remaining.isEmpty {
                let chunk = min(remaining.count, capacity - tail)
                let slice = remaining.prefix(chunk)
                UnsafeMutableRawBufferPointer(rebasing: target[tail..<(tail + chunk)]).copyMemory(from: UnsafeRawBufferPointer(rebasing: slice))
                remaining = remaining.dropFirst(chunk)
                tail = (tail + chunk) % capacity
            }
        }
        let overflow = count + source.count - capacity
        if overflow > 0 {
            head = (head + overflow) % capacity
            count = capacity
        } else {
            count += source.count
        }
    }

    /// Bytes from `offset` (clamped to what's held) to the end.
    public func bytes(from offset: UInt64) -> Data {
        let from = max(offset, startOffset)
        guard from < endOffset else { return Data() }
        let skip = Int(from - startOffset)
        let length = count - skip
        var result = Data(count: length)
        result.withUnsafeMutableBytes { target in
            storage.withUnsafeBytes { source in
                let begin = (head + skip) % capacity
                let first = min(length, capacity - begin)
                UnsafeMutableRawBufferPointer(rebasing: target[0..<first]).copyMemory(from: UnsafeRawBufferPointer(rebasing: source[begin..<(begin + first)]))
                if first < length {
                    UnsafeMutableRawBufferPointer(rebasing: target[first..<length]).copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<(length - first)]))
                }
            }
        }
        return result
    }

    /// What to replay to a client that has everything before `offset`. When that's older
    /// than the buffer (a fresh client, or one that fell behind), the replay starts at a line
    /// boundary so it doesn't begin mid escape sequence or mid UTF-8 character.
    public func replay(from offset: UInt64) -> (data: Data, startOffset: UInt64) {
        if offset >= startOffset, offset > 0 || !hasWrapped {
            return (bytes(from: offset), max(offset, startOffset))
        }
        var data = bytes(from: startOffset)
        var start = startOffset
        if hasWrapped, let newline = data.firstIndex(of: 0x0A), newline - data.startIndex < 64 * 1024 {
            let cut = newline - data.startIndex + 1
            data = data.subdata(in: (data.startIndex + cut)..<data.endIndex)
            start += UInt64(cut)
        }
        return (data, start)
    }
}
