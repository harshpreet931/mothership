import Foundation
import SQLite3
import ShipModel

/// One OpenCode session as read from `opencode.db` (v2 schema: `session_v2` + `session_message`,
/// falling back to the 1.x `session` + `message` tables).
public struct OpenCodeSessionRow: Sendable, Equatable {
    public var id: String
    public var directory: String
    public var title: String?
    public var parentID: String?
    public var model: String?
    public var usage: TokenUsage
    public var cost: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var archived: Bool
    public var idleOutcome: String?
    public var idleAt: Date?
    /// Derived from the newest messages.
    public var state: AgentState?
    public var lastUserText: String?
    public var lastAssistantText: String?
    public var currentTool: String?

    public init(
        id: String, directory: String, title: String? = nil, parentID: String? = nil, model: String? = nil,
        usage: TokenUsage = .zero, cost: Double = 0, createdAt: Date, updatedAt: Date, archived: Bool = false,
        idleOutcome: String? = nil, idleAt: Date? = nil, state: AgentState? = nil, lastUserText: String? = nil,
        lastAssistantText: String? = nil, currentTool: String? = nil
    ) {
        self.id = id
        self.directory = directory
        self.title = title
        self.parentID = parentID
        self.model = model
        self.usage = usage
        self.cost = cost
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
        self.idleOutcome = idleOutcome
        self.idleAt = idleAt
        self.state = state
        self.lastUserText = lastUserText
        self.lastAssistantText = lastAssistantText
        self.currentTool = currentTool
    }
}

/// Read-only access to OpenCode's SQLite database. Opens with `mode=ro` +
/// `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`, never writes, tolerates WAL and busy locks,
/// and treats schema mismatches as "no data".
final class OpenCodeDatabase {
    private var db: OpaquePointer?
    let path: String
    private var schema: Schema?

    enum Schema { case v2, v1 }

    init(path: String) { self.path = path }

    deinit { close() }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        schema = nil
    }

    private func open() -> OpaquePointer? {
        if let db { return db }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var handle: OpaquePointer?
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = "file:\(escaped)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close_v2(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 200)
        db = handle
        schema = detectSchema()
        return handle
    }

    private func detectSchema() -> Schema? {
        let tables = Set(query("SELECT name FROM sqlite_master WHERE type='table'") { $0.string(0) }.compactMap { $0 })
        if tables.contains("session_v2"), tables.contains("session_message") { return .v2 }
        if tables.contains("session"), tables.contains("message") { return .v1 }
        return nil
    }

    /// Sessions updated after `since` (milliseconds), newest last. Child (subagent) sessions included.
    func sessions(updatedAfter since: Date, directory: String? = nil, limit: Int = 200) -> [OpenCodeSessionRow] {
        guard open() != nil, let schema else { return [] }
        let table = schema == .v2 ? "session_v2" : "session"
        let idleColumns = schema == .v2 ? "time_idle, idle_outcome" : "NULL, NULL"
        var sql = """
            SELECT id, directory, title, parent_id, model, tokens_input, tokens_output, tokens_reasoning,
                   tokens_cache_read, tokens_cache_write, cost, time_created, time_updated, time_archived, \(idleColumns)
            FROM \(table) WHERE time_updated > ?
            """
        if directory != nil { sql += " AND directory = ?" }
        sql += " ORDER BY time_updated DESC LIMIT \(limit)"
        let sinceMillis = Int64(since.timeIntervalSince1970 * 1000)
        var rows = query(sql, bind: { statement in
            sqlite3_bind_int64(statement, 1, sinceMillis)
            if let directory { sqlite3_bind_text(statement, 2, directory, -1, sqliteTransient) }
        }) { row -> OpenCodeSessionRow? in
            guard let id = row.string(0), let dir = row.string(1) else { return nil }
            let modelJSON = row.string(4).flatMap(JSONNode.parse)
            let model = modelJSON?["id"].text ?? row.string(4).flatMap { $0.hasPrefix("{") ? nil : $0 }
            let usage = TokenUsage(
                inputTokens: Int(row.int(5)), outputTokens: Int(row.int(6) + row.int(7)),
                cacheReadTokens: Int(row.int(8)), cacheWriteTokens: Int(row.int(9))
            )
            return OpenCodeSessionRow(
                id: id, directory: dir, title: row.string(2), parentID: row.string(3), model: model, usage: usage,
                cost: row.double(10), createdAt: Self.date(row.int(11)), updatedAt: Self.date(row.int(12)),
                archived: !row.isNull(13), idleOutcome: row.string(15), idleAt: row.isNull(14) ? nil : Self.date(row.int(14))
            )
        }.compactMap { $0 }
        for index in rows.indices where schema == .v2 {
            enrich(&rows[index])
        }
        return rows.reversed()
    }

    /// Fill state / last texts from the newest few messages.
    private func enrich(_ row: inout OpenCodeSessionRow) {
        let messages = query(
            "SELECT type, data FROM session_message WHERE session_id = ? ORDER BY seq DESC LIMIT 12",
            bind: { sqlite3_bind_text($0, 1, row.id, -1, sqliteTransient) }
        ) { statement -> (String, JSONNode)? in
            guard let type = statement.string(0), let data = statement.string(1), let json = JSONNode.parse(data) else { return nil }
            return (type, json)
        }.compactMap { $0 }
        for (type, json) in messages {
            switch type {
            case "user":
                if row.lastUserText == nil { row.lastUserText = json["text"].text }
            case "assistant":
                if row.lastAssistantText == nil {
                    row.lastAssistantText = json["content"].array?.reversed().first { $0["type"].string == "text" }?["text"].text
                }
            default:
                break
            }
        }
        guard let (type, json) = messages.first else { return }
        switch type {
        case "user", "synthetic":
            row.state = .working(tool: nil)
        case "assistant":
            if json["error"].exists {
                let name = json["error"]["name"].text ?? ""
                row.state = name == "MessageAbortedError" ? .idle : .error(json["error"]["data"]["message"].text ?? name)
            } else if json["time"]["completed"].exists {
                let finish = json["finish"].string
                row.state = finish == "tool-calls" ? .working(tool: nil) : .idle
            } else {
                let tool = json["content"].array?.last { $0["type"].string == "tool" }
                if let tool, tool["state"]["status"].string != "completed" {
                    row.currentTool = tool["name"].text
                    row.state = .working(tool: tool["name"].text.map(OpenCodeAdapter.toolDisplayName))
                } else {
                    row.state = .working(tool: nil)
                }
            }
        case "idle":
            let outcome = json["outcome"].string ?? "succeeded"
            row.state = outcome == "succeeded" || outcome == "aborted" || outcome == "cancelled" ? .idle : .error(outcome)
        case "compaction":
            row.state = .working(tool: "Compacting")
        default:
            break
        }
    }

    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    // MARK: SQLite plumbing

    struct Row {
        let statement: OpaquePointer
        func string(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL, let text = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: text)
        }
        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
    }

    private func query<T>(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }, map: (Row) -> T) -> [T] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return []
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        var results: [T] = []
        while true {
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else { break }
            results.append(map(Row(statement: statement)))
        }
        return results
    }
}

/// SQLITE_TRANSIENT: SQLite copies bound strings.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
