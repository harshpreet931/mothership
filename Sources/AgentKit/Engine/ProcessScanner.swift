import Darwin
import Foundation
import ShipModel
import SystemProbe
import Synchronization

/// An agent's root process as seen by one scan.
public struct RootProcess: Sendable {
    public var kind: AgentKind
    public var process: ObservedProcess
    public var surface: SurfaceID?
    public var workspace: WorkspaceID?
    public var hostApp: String?
    public var git: GitInfo?
    public var binding: SessionBinding?
    /// Share of one core used since the previous scan (nil on first sight).
    public var cpuFraction: Double?

    public var pid: Int32 { process.pid }

    public init(
        kind: AgentKind, process: ObservedProcess, surface: SurfaceID? = nil, workspace: WorkspaceID? = nil, hostApp: String? = nil,
        git: GitInfo? = nil, binding: SessionBinding? = nil, cpuFraction: Double? = nil
    ) {
        self.kind = kind
        self.process = process
        self.surface = surface
        self.workspace = workspace
        self.hostApp = hostApp
        self.git = git
        self.binding = binding
        self.cpuFraction = cpuFraction
    }
}

public enum ScanScope: Sendable, Equatable {
    /// Every process of the current user.
    case system
    /// Only descendants of these pids: the app's own shells, and panes hosted by `mshipd`.
    case descendants(of: [Int32])
}

public struct ScanResult: Sendable {
    public var scope: ScanScope
    public var roots: [RootProcess]
    /// pids alive at scan time (for exit checks of sessions in scope).
    public var alive: Set<Int32>
    public var scopePIDs: Set<Int32>
    public var processCount: Int
    public var candidateCount: Int
    public var argvReads: Int
    public var duration: Duration
    public var capturedAt: Date
}

/// OpenCode session lookups for binding, shared with `bindSession` closures.
final class OpenCodeLookup: Sendable {
    private let database: Mutex<OpenCodeDatabase>

    init(path: String) { database = Mutex(OpenCodeDatabase(path: path)) }

    func sessions(directory: String) -> [OpenCodeSessionRow] {
        database.withLock { $0.sessions(updatedAfter: Date().addingTimeInterval(-7 * 24 * 3600), directory: directory, limit: 5).reversed() }
    }
}

/// Finds agent root processes. Reads argv only for candidates (by `p_comm`) and caches it per
/// process identity; host app, git and bindings are cached too, so a steady-state scan is one
/// sysctl plus a handful of cheap libproc calls per live agent.
actor ProcessScanner {
    let adapters: [any AgentAdapter]
    let home: URL
    let uid = getuid()
    let ownPID = getpid()
    private let argumentsCache = ProcessArgumentsCache()
    private let hostResolver = HostAppResolver()
    private let openCode: OpenCodeLookup
    private var hosts: [ProcessIdentity: String?] = [:]
    private var bindings: [ProcessIdentity: SessionBinding] = [:]
    private var cwds: [ProcessIdentity: String] = [:]
    private var git: [String: (info: GitInfo?, at: Date)] = [:]
    private var cpu: [ProcessIdentity: (nanos: UInt64, at: Date)] = [:]
    /// `p_comm` → indexes of adapters interested in it (comm values repeat a lot: node, zsh…).
    private var candidateMemo: [String: [Int]] = [:]
    /// argv never changes for a process, so neither does "which adapter's root is this".
    private var matchMemo: [MemoKey: Int?] = [:]
    /// The app's descendants at the last surface scan (pid set from `proc_listchildpids`).
    private var lastDescendants: [Int32: String]?

    struct MemoKey: Hashable {
        var identity: ProcessIdentity
        var comm: String
    }
    /// Claude's per-pid status file is re-decoded only when its mtime changes.
    private var statusFileStamps: [ProcessIdentity: Date] = [:]
    private(set) var lastTable: ProcessTable?
    private var argvReads = 0

    private let claudeSessionsDirectory: String

    init(adapters: [any AgentAdapter], home: URL) {
        self.adapters = adapters
        self.home = home
        self.claudeSessionsDirectory = ClaudeAdapter.sessionsRoot(home).path
        self.openCode = OpenCodeLookup(path: OpenCodeAdapter.databasePath(home).path)
    }

    func scan(scope: ScanScope) -> ScanResult {
        let clock = ContinuousClock()
        let started = clock.now
        argvReads = 0
        guard let table = try? ProcessTable.capture() else {
            return ScanResult(scope: scope, roots: [], alive: [], scopePIDs: [], processCount: 0, candidateCount: 0, argvReads: 0, duration: .zero, capturedAt: Date())
        }
        lastTable = table
        let pool: [ProcessSnapshot]
        switch scope {
        case .system:
            pool = table.processes.values.filter { $0.uid == uid && !$0.isZombie && $0.pid != ownPID }
        case .descendants(let roots):
            var seen = Set<Int32>()
            pool = roots.flatMap { table.descendants(of: $0) }.filter { !$0.isZombie && seen.insert($0.pid).inserted }
        }
        var candidateCount = 0
        var matches: [Int32: (adapter: any AgentAdapter, process: ObservedProcess)] = [:]
        for snapshot in pool {
            let identity = MemoKey(identity: snapshot.identity, comm: snapshot.comm)
            if let memo = matchMemo[identity] {
                candidateCount += 1
                guard let index = memo, let arguments = argumentsCache.arguments(for: snapshot, readIfMissing: false) else { continue }
                matches[snapshot.pid] = (adapters[index], ObservedProcess(snapshot: snapshot, arguments: arguments))
                continue
            }
            let interested = candidateIndexes(for: snapshot.comm)
            guard !interested.isEmpty else { continue }
            candidateCount += 1
            guard let arguments = arguments(for: snapshot) else {
                matchMemo[identity] = .some(nil)
                continue
            }
            let observed = ObservedProcess(snapshot: snapshot, arguments: arguments)
            let index = observed.isOneShotQuery ? nil : interested.first { adapters[$0].matchesRoot(observed) }
            matchMemo[identity] = .some(index)
            if let index { matches[snapshot.pid] = (adapters[index], observed) }
        }
        // Keep only roots: an agent's MCP servers, plugins and wrapper children are excluded.
        var roots: [RootProcess] = []
        for pid in Self.excludingDescendants(Set(matches.keys), in: table) {
            guard let match = matches[pid] else { continue }
            roots.append(describe(match.process, adapter: match.adapter, table: table))
        }
        if scope == .system {
            let live = Set(table.processes.values.map(\.identity))
            argumentsCache.retain(only: live)
            hosts = hosts.filter { live.contains($0.key) }
            bindings = bindings.filter { live.contains($0.key) }
            cwds = cwds.filter { live.contains($0.key) }
            cpu = cpu.filter { live.contains($0.key) }
            statusFileStamps = statusFileStamps.filter { live.contains($0.key) }
            matchMemo = matchMemo.filter { live.contains($0.key.identity) }
        }
        let alive = Set(table.processes.keys)
        return ScanResult(
            scope: scope, roots: roots.sorted { $0.pid < $1.pid }, alive: alive, scopePIDs: Set(pool.map(\.pid)),
            processCount: table.processes.count, candidateCount: candidateCount, argvReads: argvReads,
            duration: clock.now - started, capturedAt: table.capturedAt
        )
    }

    /// Matched pids that have no matched ancestor: an agent's MCP servers, plugins, nested
    /// `claude -p` runs and wrapper children are not separate sessions.
    static func excludingDescendants(_ matched: Set<Int32>, in table: ProcessTable) -> [Int32] {
        matched.filter { pid in !table.ancestors(of: pid).contains { matched.contains($0.pid) } }.sorted()
    }

    /// Pure root selection over a table, for tests and tools: match with `adapters`, then drop descendants.
    static func roots(in table: ProcessTable, adapters: [any AgentAdapter], arguments: (ProcessSnapshot) -> ProcessArguments?) -> [(kind: AgentKind, pid: Int32)] {
        var matched: [Int32: AgentKind] = [:]
        for snapshot in table.processes.values {
            let interested = adapters.filter { $0.isCandidate(comm: snapshot.comm) }
            guard !interested.isEmpty, let argv = arguments(snapshot) else { continue }
            let observed = ObservedProcess(snapshot: snapshot, arguments: argv)
            if !observed.isOneShotQuery, let adapter = interested.first(where: { $0.matchesRoot(observed) }) { matched[snapshot.pid] = adapter.kind }
        }
        return excludingDescendants(Set(matched.keys), in: table).compactMap { pid in matched[pid].map { ($0, pid) } }
    }

    private func candidateIndexes(for comm: String) -> [Int] {
        if let indexes = candidateMemo[comm] { return indexes }
        let indexes = adapters.indices.filter { adapters[$0].isCandidate(comm: comm) }
        if candidateMemo.count > 4096 { candidateMemo.removeAll() }
        candidateMemo[comm] = indexes
        return indexes
    }

    private func arguments(for snapshot: ProcessSnapshot) -> ProcessArguments? {
        if !argumentsCache.isCached(snapshot) { argvReads += 1 }
        return argumentsCache.arguments(for: snapshot)
    }

    private func describe(_ process: ObservedProcess, adapter: any AgentAdapter, table: ProcessTable) -> RootProcess {
        let identity = process.snapshot.identity
        var observed = process
        if let cwd = ProcessInspector.workingDirectory(pid: process.pid) {
            cwds[identity] = cwd
            observed.cwd = cwd
        } else {
            observed.cwd = cwds[identity]
        }
        let surface = process.arguments.mothershipSurface
        var host: String?
        if surface == nil {
            if let cached = hosts[identity] {
                host = cached
            } else {
                host = hostResolver.hostApp(for: process.pid, in: table)
                hosts[identity] = host
            }
        }
        var gitInfo: GitInfo?
        if let cwd = observed.cwd {
            if let cached = git[cwd], Date().timeIntervalSince(cached.at) < 10 {
                gitInfo = cached.info
            } else {
                gitInfo = GitProbe.info(forDirectory: cwd)
                git[cwd] = (gitInfo, Date())
            }
        }
        // Claude's status file changes with /clear and /resume (re-read when its mtime moves);
        // other bindings are stable once found.
        var binding = bindings[identity]
        if adapter.kind == .claude {
            let stamp = FileStamp.of("\(claudeSessionsDirectory)/\(process.pid).json")?.modified ?? .distantPast
            if statusFileStamps[identity] != stamp {
                statusFileStamps[identity] = stamp
                binding = nil
            } else if binding != nil {
                // Unchanged: keep the binding but don't replay its status signals.
                binding?.signals = []
            }
        }
        if binding == nil {
            let lookup = openCode
            let context = BindingContext(home: home, table: table, openCodeSessions: { lookup.sessions(directory: $0) })
            binding = adapter.bindSession(observed, context: context)
            if let binding { bindings[identity] = binding }
        }
        var fraction: Double?
        if adapter.usesCPUHeuristic, let nanos = ProcessInspector.cpuTimeNanos(pid: process.pid) {
            let now = Date()
            if let previous = cpu[identity], now > previous.at {
                fraction = Double(nanos &- previous.nanos) / 1e9 / now.timeIntervalSince(previous.at)
            }
            cpu[identity] = (nanos, now)
        }
        return RootProcess(
            kind: adapter.kind, process: observed, surface: surface, workspace: process.arguments.mothershipWorkspace,
            hostApp: host, git: gitInfo, binding: binding, cpuFraction: fraction
        )
    }

    /// For a hook: the matched agent processes from `pid` upward, nearest first.
    func agentChain(from pid: Int32, kind: AgentKind) -> [RootProcess] {
        guard let adapter = adapters.first(where: { $0.kind == kind }) else { return [] }
        var table = lastTable
        if table?.processes[pid] == nil, let fresh = try? ProcessTable.capture() {
            table = fresh
            lastTable = fresh
        }
        guard let table, let start = table.processes[pid] else { return [] }
        var chain: [RootProcess] = []
        for snapshot in [start] + table.ancestors(of: pid) where adapter.isCandidate(comm: snapshot.comm) {
            guard let arguments = arguments(for: snapshot) else { continue }
            let observed = ObservedProcess(snapshot: snapshot, arguments: arguments)
            if adapter.matchesRoot(observed) { chain.append(describe(observed, adapter: adapter, table: table)) }
        }
        return chain
    }

    func openCodeSessions(directory: String) -> [OpenCodeSessionRow] { openCode.sessions(directory: directory) }

    /// Whether the app's process tree changed since the last check: a few libproc calls, so
    /// the per-second surface scan only reads the process table when something forked, exec'd
    /// (same pid, new name) or exited.
    func descendantsChanged(of roots: [Int32]) -> Bool {
        var current: [Int32: String] = [:]
        for root in roots {
            for child in ProcessInspector.descendantPIDs(of: root) where current[child] == nil {
                current[child] = ProcessInspector.name(pid: child) ?? ""
            }
        }
        defer { lastDescendants = current }
        return current != lastDescendants
    }

    var cachedArgumentCount: Int { argumentsCache.count }
}
