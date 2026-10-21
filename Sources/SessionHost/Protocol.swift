import Foundation

/// The session protocol between the app (client) and `mshipd` (host). See
/// docs/agents/sessions.md for the full exchange.
public enum SessionProtocol {
    /// Bumped on any incompatible change. The hello/welcome exchange itself never changes
    /// shape, so a mismatch is always detectable.
    public static let version: UInt16 = 1

    public enum Kind: UInt8, Sendable {
        // Client → host
        case hello = 0x01
        case open = 0x10
        case input = 0x21
        case resize = 0x22
        case flow = 0x23
        case detach = 0x24
        case close = 0x25
        case signal = 0x26
        case list = 0x40
        case shutdown = 0x50
        // Host → client
        case welcome = 0x02
        case opened = 0x11
        case replayEnd = 0x12
        case output = 0x20
        case exited = 0x30
        case sessions = 0x41
        case error = 0x7F
    }
}

// MARK: - Control payloads (JSON)

public struct HelloMessage: Codable, Sendable, Equatable {
    public var version: UInt16
    public var client: String
    public var pid: Int32

    public init(version: UInt16 = SessionProtocol.version, client: String, pid: Int32 = getpid()) {
        self.version = version
        self.client = client
        self.pid = pid
    }
}

public struct WelcomeMessage: Codable, Sendable, Equatable {
    public var version: UInt16
    public var pid: Int32
    public var sessionCount: Int

    public init(version: UInt16 = SessionProtocol.version, pid: Int32, sessionCount: Int) {
        self.version = version
        self.pid = pid
        self.sessionCount = sessionCount
    }
}

/// How to start a session's process. The client computes everything (shell, login argv,
/// startup wrapper, environment with shell integration); the host only spawns it.
public struct SpawnSpec: Codable, Sendable, Equatable {
    /// Absolute path of the program.
    public var executable: String
    /// Full argv, `argv[0]` included (a leading "-" makes a login shell).
    public var arguments: [String]
    /// The complete environment (not merged with the host's own).
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String?) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public struct OpenRequest: Codable, Sendable, Equatable {
    public var requestID: UInt32
    public var session: UUID
    /// Attach to the session if it's alive. A relaunched app reattaches its saved panes this way.
    public var attachIfExists: Bool
    /// Start the session when it doesn't exist (nil: fail instead).
    public var spawn: SpawnSpec?
    public var columns: UInt16
    public var rows: UInt16
    /// Replay output from this byte offset (what the client already has); 0 replays the
    /// whole buffer. A reconnect within one app run passes its last offset.
    public var fromOffset: UInt64

    public init(
        requestID: UInt32, session: UUID, attachIfExists: Bool, spawn: SpawnSpec?, columns: UInt16, rows: UInt16,
        fromOffset: UInt64 = 0
    ) {
        self.requestID = requestID
        self.session = session
        self.attachIfExists = attachIfExists
        self.spawn = spawn
        self.columns = columns
        self.rows = rows
        self.fromOffset = fromOffset
    }
}

public struct OpenedMessage: Codable, Sendable, Equatable {
    public var requestID: UInt32
    public var session: UUID
    /// True when this open started the process; false when it reattached to a live one.
    public var created: Bool
    public var pid: Int32
    /// Bytes of output the session has produced so far.
    public var outputOffset: UInt64

    public init(requestID: UInt32, session: UUID, created: Bool, pid: Int32, outputOffset: UInt64) {
        self.requestID = requestID
        self.session = session
        self.created = created
        self.pid = pid
        self.outputOffset = outputOffset
    }
}

public struct ExitedMessage: Codable, Sendable, Equatable {
    public var session: UUID
    /// `waitpid` status, decoded.
    public var exitCode: Int32
    public var signal: Int32?

    public init(session: UUID, exitCode: Int32, signal: Int32?) {
        self.session = session
        self.exitCode = exitCode
        self.signal = signal
    }
}

public struct SessionInfo: Codable, Sendable, Equatable {
    public var session: UUID
    public var pid: Int32
    public var workingDirectory: String?
    public var columns: UInt16
    public var rows: UInt16
    public var outputOffset: UInt64
    public var bufferedBytes: Int
    public var attachedClients: Int
    public var createdAt: Date

    public init(
        session: UUID, pid: Int32, workingDirectory: String?, columns: UInt16, rows: UInt16, outputOffset: UInt64,
        bufferedBytes: Int, attachedClients: Int, createdAt: Date
    ) {
        self.session = session
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
        self.outputOffset = outputOffset
        self.bufferedBytes = bufferedBytes
        self.attachedClients = attachedClients
        self.createdAt = createdAt
    }
}

public struct ListRequest: Codable, Sendable, Equatable {
    public var requestID: UInt32
    public init(requestID: UInt32) { self.requestID = requestID }
}

public struct SessionsMessage: Codable, Sendable, Equatable {
    public var requestID: UInt32
    public var sessions: [SessionInfo]
    public init(requestID: UInt32, sessions: [SessionInfo]) {
        self.requestID = requestID
        self.sessions = sessions
    }
}

public struct ErrorMessage: Codable, Sendable, Equatable, Error {
    public enum Code: String, Codable, Sendable {
        case notFound, spawnFailed, badRequest, versionMismatch
    }

    public var requestID: UInt32?
    public var session: UUID?
    public var code: Code
    public var message: String

    public init(requestID: UInt32?, session: UUID?, code: Code, message: String) {
        self.requestID = requestID
        self.session = session
        self.code = code
        self.message = message
    }
}

// MARK: - Typed messages

/// Every message, decoded. Binary frames for the hot path, JSON for the rest.
public enum SessionMessage: Equatable, Sendable {
    case hello(HelloMessage)
    case welcome(WelcomeMessage)
    case open(OpenRequest)
    case opened(OpenedMessage)
    /// Output from `offset` (the session's byte count before these bytes).
    case output(session: UUID, offset: UInt64, data: Data)
    /// Replay done; live output follows. `suffix` re-asserts terminal modes whose switch
    /// scrolled out of the buffer; feed it to the terminal (it isn't part of the stream's offsets).
    case replayEnd(session: UUID, suffix: Data)
    case input(session: UUID, data: Data)
    case resize(session: UUID, columns: UInt16, rows: UInt16, widthPixels: UInt32, heightPixels: UInt32)
    /// Client-side backpressure: stop or resume reading the PTY.
    case flow(session: UUID, paused: Bool)
    case detach(session: UUID)
    case close(session: UUID)
    case signal(session: UUID, signal: Int32)
    case exited(ExitedMessage)
    case list(ListRequest)
    case sessions(SessionsMessage)
    case shutdown
    case error(ErrorMessage)

    public var frame: Frame {
        switch self {
        case .hello(let message): json(.hello, message)
        case .welcome(let message): json(.welcome, message)
        case .open(let message): json(.open, message)
        case .opened(let message): json(.opened, message)
        case .exited(let message): json(.exited, message)
        case .list(let message): json(.list, message)
        case .sessions(let message): json(.sessions, message)
        case .error(let message): json(.error, message)
        case .shutdown: Frame(type: SessionProtocol.Kind.shutdown.rawValue)
        case .output(let session, let offset, let data):
            binary(.output, session) { payload in
                payload.appendBigEndian(offset)
                payload.append(data)
            }
        case .replayEnd(let session, let suffix): binary(.replayEnd, session) { $0.append(suffix) }
        case .input(let session, let data): binary(.input, session) { $0.append(data) }
        case .resize(let session, let columns, let rows, let width, let height):
            binary(.resize, session) { payload in
                payload.appendBigEndian(columns)
                payload.appendBigEndian(rows)
                payload.appendBigEndian(width)
                payload.appendBigEndian(height)
            }
        case .flow(let session, let paused): binary(.flow, session) { $0.append(paused ? 1 : 0) }
        case .detach(let session): binary(.detach, session) { _ in }
        case .close(let session): binary(.close, session) { _ in }
        case .signal(let session, let signal): binary(.signal, session) { $0.appendBigEndian(signal) }
        }
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case unknownType(UInt8)
        case malformed(UInt8)
    }

    /// Decodes a frame. Unknown types throw `unknownType` so callers can skip them.
    public init(frame: Frame) throws(DecodeError) {
        guard let kind = SessionProtocol.Kind(rawValue: frame.type) else { throw .unknownType(frame.type) }
        let payload = frame.payload
        func decode<T: Decodable>(_: T.Type) throws(DecodeError) -> T {
            do { return try Self.decoder.decode(T.self, from: payload) } catch { throw .malformed(frame.type) }
        }
        func session() throws(DecodeError) -> UUID {
            guard let id = UUID(bytes: payload) else { throw .malformed(frame.type) }
            return id
        }
        let body = payload.count > 16 ? payload.subdata(in: (payload.startIndex + 16)..<payload.endIndex) : Data()
        switch kind {
        case .hello: self = .hello(try decode(HelloMessage.self))
        case .welcome: self = .welcome(try decode(WelcomeMessage.self))
        case .open: self = .open(try decode(OpenRequest.self))
        case .opened: self = .opened(try decode(OpenedMessage.self))
        case .exited: self = .exited(try decode(ExitedMessage.self))
        case .list: self = .list(try decode(ListRequest.self))
        case .sessions: self = .sessions(try decode(SessionsMessage.self))
        case .error: self = .error(try decode(ErrorMessage.self))
        case .shutdown: self = .shutdown
        case .output:
            let id = try session()
            guard let offset = body.readBigEndian(UInt64.self, at: 0) else { throw .malformed(frame.type) }
            self = .output(session: id, offset: offset, data: body.count > 8 ? body.subdata(in: (body.startIndex + 8)..<body.endIndex) : Data())
        case .replayEnd: self = .replayEnd(session: try session(), suffix: body)
        case .input: self = .input(session: try session(), data: body)
        case .resize:
            let id = try session()
            guard let columns = body.readBigEndian(UInt16.self, at: 0), let rows = body.readBigEndian(UInt16.self, at: 2),
                  let width = body.readBigEndian(UInt32.self, at: 4), let height = body.readBigEndian(UInt32.self, at: 8)
            else { throw .malformed(frame.type) }
            self = .resize(session: id, columns: columns, rows: rows, widthPixels: width, heightPixels: height)
        case .flow:
            let id = try session()
            guard let flag = body.first else { throw .malformed(frame.type) }
            self = .flow(session: id, paused: flag != 0)
        case .detach: self = .detach(session: try session())
        case .close: self = .close(session: try session())
        case .signal:
            let id = try session()
            guard let signal = body.readBigEndian(Int32.self, at: 0) else { throw .malformed(frame.type) }
            self = .signal(session: id, signal: signal)
        }
    }

    private func json(_ kind: SessionProtocol.Kind, _ value: some Encodable) -> Frame {
        Frame(type: kind.rawValue, payload: (try? Self.encoder.encode(value)) ?? Data("{}".utf8))
    }

    private func binary(_ kind: SessionProtocol.Kind, _ session: UUID, _ body: (inout Data) -> Void) -> Frame {
        var payload = session.bytes
        body(&payload)
        return Frame(type: kind.rawValue, payload: payload)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
