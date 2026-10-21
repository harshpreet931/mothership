import Foundation

/// One message on the session socket.
///
/// Wire format: a 4-byte big-endian length `n`, then `n` bytes: a 1-byte type and the payload.
/// Hot-path frames (output, input) carry raw bytes after a 16-byte session UUID; control
/// frames carry JSON. The length prefix keeps the stream binary-safe (terminal output is
/// arbitrary bytes) and lets either side skip types it doesn't know.
public struct Frame: Equatable, Sendable {
    public var type: UInt8
    public var payload: Data

    public init(type: UInt8, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    /// Frames larger than this are a protocol error (output is chunked well below it).
    public static let maxLength = 32 * 1024 * 1024

    public var encoded: Data {
        var data = Data(capacity: 5 + payload.count)
        let length = UInt32(1 + payload.count)
        data.append(UInt8(length >> 24))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(type)
        data.append(payload)
        return data
    }
}

public enum FrameError: Error, Equatable, Sendable {
    case tooLarge(Int)
    case empty
}

/// Incremental decoder: feed it bytes as they arrive, take whole frames out.
public struct FrameDecoder: Sendable {
    private var buffer = Data()
    private var start = 0

    public init() {}

    public var bufferedByteCount: Int { buffer.count - start }

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    public mutating func append(_ bytes: UnsafeRawBufferPointer) {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete frame, nil when more bytes are needed.
    public mutating func next() throws(FrameError) -> Frame? {
        let available = buffer.count - start
        guard available >= 4 else { compact(); return nil }
        let base = buffer.startIndex + start
        let length = Int(buffer[base]) << 24 | Int(buffer[base + 1]) << 16 | Int(buffer[base + 2]) << 8 | Int(buffer[base + 3])
        guard length > 0 else { throw .empty }
        guard length <= Frame.maxLength else { throw .tooLarge(length) }
        guard available >= 4 + length else { compact(); return nil }
        let type = buffer[base + 4]
        let payload = buffer.subdata(in: (base + 5)..<(base + 4 + length))
        start += 4 + length
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        }
        return Frame(type: type, payload: payload)
    }

    /// Drops consumed bytes once they're most of the buffer (amortized O(1)).
    private mutating func compact() {
        if start > 0, start * 2 >= buffer.count {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + start))
            start = 0
        }
    }
}

extension UUID {
    /// The 16 raw bytes, for binary frames.
    var bytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    init?(bytes data: Data) {
        guard data.count >= 16 else { return nil }
        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { target in
            data.prefix(16).withUnsafeBytes { source in target.copyMemory(from: source) }
        }
        self.init(uuid: raw)
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return nil }
        var value = T.zero
        Swift.withUnsafeMutableBytes(of: &value) { target in
            self[(startIndex + offset)..<(startIndex + offset + size)].withUnsafeBytes { target.copyMemory(from: $0) }
        }
        return T(bigEndian: value)
    }
}
