import AgentKit
import Darwin
import Foundation
import ShipModel
import SystemProbe

// mship-probe: print every agent session the engine sees on this machine.
//
//   swift run mship-probe            table of sessions + integration status + scan cost
//   swift run mship-probe --json     the same as JSON
//   swift run mship-probe --watch    stream updates and attention events (Ctrl-C to stop)
//   swift run mship-probe --bench 50 time 50 system-wide scans
//   --home <dir>                     read agent data from another home directory
//   --watch --app-like [--hidden]    also open a pane surface (1 s pane scans), like the app;
//                                    --hidden reports the app as in the background
//
// Read-only: it never installs integrations or writes to agent configs.

struct Options {
    var json = false
    var watch = false
    var bench: Int?
    var home: URL?
    var settle: Double = 1.5
    var titles = false
    var coldStart: Double?
    var latency: Int?
    var kqueue = true
    var appLike = false
    var hidden = false
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst()
    while let argument = arguments.popFirst() {
        switch argument {
        case "--json": options.json = true
        case "--watch", "-w": options.watch = true
        case "--bench": options.bench = arguments.popFirst().flatMap(Int.init) ?? 20
        case "--home": options.home = arguments.popFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
        case "--settle": options.settle = arguments.popFirst().flatMap(Double.init) ?? options.settle
        case "--titles": options.titles = true
        case "--latency": options.latency = arguments.popFirst().flatMap(Int.init) ?? 20
        case "--no-kqueue": options.kqueue = false
        case "--app-like": options.appLike = true
        case "--hidden": options.hidden = true
        case "--cold-start": options.coldStart = arguments.popFirst().flatMap(Double.init) ?? 6
        case "-h", "--help":
            print("usage: mship-probe [--json] [--watch [--app-like] [--hidden]] [--bench N] [--home DIR] [--settle SECONDS]")
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown option \(argument)\n".utf8))
            exit(2)
        }
    }
    return options
}

// MARK: Formatting

func pad(_ text: String, _ width: Int) -> String {
    let clipped = text.count > width ? String(text.prefix(max(1, width - 1))) + "…" : text
    return clipped + String(repeating: " ", count: max(0, width - clipped.count))
}

func shortPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func stateText(_ state: AgentState) -> String {
    switch state {
    case .starting: "starting"
    case .idle: "idle"
    case .working(let tool?): "working:\(tool)"
    case .working(nil): "working"
    case .needsInput(let reason): "needs:\(reason.rawValue)"
    case .error(let message): "error:\(message)"
    case .ended: "ended"
    }
}

func tokens(_ usage: TokenUsage) -> String {
    let total = usage.inputTokens + usage.outputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
    func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(value) / 1_000)
        default: "\(value)"
        }
    }
    guard total > 0 else { return "-" }
    var text = compact(total)
    if let context = usage.contextTokens, let window = usage.contextWindow, window > 0 {
        text += " ctx \(Int(Double(context) / Double(window) * 100))%"
    }
    return text
}

func cost(_ session: AgentSession, estimated: Bool) -> String {
    guard let value = session.usage.costUSD, value > 0 else { return "-" }
    return (estimated ? "~$" : "$") + String(format: "%.2f", value)
}

func printTable(_ sessions: [AgentSession], estimates: [AgentSessionKey: Bool]) {
    let header = [
        pad("KIND", 9), pad("PID", 6), pad("STATE", 16), pad("HOST", 18), pad("CWD", 34), pad("BRANCH", 16),
        pad("MODEL", 18), pad("TOKENS", 14), pad("COST", 8), pad("SUMMARY", 40), "TRANSCRIPT",
    ].joined(separator: " ")
    print(header)
    print(String(repeating: "─", count: min(header.count, 220)))
    for session in sessions {
        let host = session.surface != nil ? "Mothership" : (session.hostApp ?? "-")
        let row = [
            pad(session.kind.rawValue, 9), pad(session.pid.map(String.init) ?? "-", 6), pad(stateText(session.state), 16),
            pad(host, 18), pad(shortPath(session.cwd), 34), pad(session.branch ?? "-", 16), pad(session.model ?? "-", 18),
            pad(tokens(session.usage), 14), pad(cost(session, estimated: estimates[session.id] ?? true), 8),
            pad(session.summary ?? session.title ?? "-", 40),
            session.transcriptPath.map { ($0 as NSString).lastPathComponent } ?? "-",
        ].joined(separator: " ")
        print(row + (session.unread ? "  ●" : ""))
    }
}

func printIntegrations(_ statuses: [IntegrationStatus]) {
    print("\nIntegrations")
    for status in statuses {
        let location = status.executablePath.map(shortPath) ?? "not found"
        print("  \(pad(status.kind.displayName, 12)) \(pad(status.version ?? "?", 10)) \(pad(location, 44)) \(status.installed ? "✓" : "·") \(status.detail)")
    }
}

func milliseconds(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    return String(format: "%.2f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
}

func printMetrics(_ metrics: EngineMetrics) {
    print("\nScan cost: \(metrics.scans) scans, mean \(milliseconds(metrics.meanScanTime)), max \(milliseconds(metrics.maxScanTime)), last \(milliseconds(metrics.lastScanTime)); \(metrics.lastProcessCount) processes, \(metrics.lastCandidateCount) candidates, \(metrics.argvReads) argv reads total")
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

struct ProbeOutput: Encodable {
    var sessions: [AgentSession]
    var integrations: [IntegrationStatus]
    var scanMeanMilliseconds: Double
    var scans: Int
}

// MARK: Main

setvbuf(stdout, nil, _IOLBF, 0)
let options = parseOptions()
var configuration = AgentEngineConfiguration.standard
if let home = options.home { configuration.homeDirectory = home }
let engine = AgentEngine(configuration: configuration)

if let rounds = options.latency {
    // Transcript write → `updates()` emission, on a synthetic session in a scratch home.
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "mship-latency-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let pid = getpid()
    let sessionID = "1a7e2c70-0000-4000-8000-00000000000a"
    let cwd = "/work/latency"
    let transcript = home.appending(path: ".claude/projects/-work-latency/\(sessionID).jsonl")
    try? FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: home.appending(path: ".claude/sessions"), withIntermediateDirectories: true)
    let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    func line(prompt: Bool, n: Int) -> String {
        let stamp = Date().formatted(iso)
        if prompt {
            return #"{"type":"user","message":{"role":"user","content":"step \#(n)"},"timestamp":"\#(stamp)","cwd":"\#(cwd)","sessionId":"\#(sessionID)"}"# + "\n"
        }
        return #"{"type":"assistant","message":{"id":"m\#(n)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"done \#(n)"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"\#(stamp)","sessionId":"\#(sessionID)"}"# + "\n"
    }
    try? Data(line(prompt: false, n: 0).utf8).write(to: transcript)
    let millis = Int(Date().timeIntervalSince1970 * 1000)
    try? Data(#"{"pid":\#(pid),"sessionId":"\#(sessionID)","cwd":"\#(cwd)","status":"idle","nameSource":"derived","updatedAt":\#(millis),"statusUpdatedAt":\#(millis)}"#.utf8)
        .write(to: home.appending(path: ".claude/sessions/\(pid).json"))
    var configuration = AgentEngineConfiguration.isolated(home: home)
    configuration.transcriptWatching = true
    configuration.processScanning = true
    configuration.vnodeWatching = options.kqueue
    let started = UInt64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000_000)
    let snapshot = ProcessSnapshot(pid: pid, ppid: 1, comm: "claude", startMicros: started)
    let observed = ObservedProcess(snapshot: snapshot, arguments: ProcessArguments(executablePath: "/x/claude/versions/2.1.306", arguments: ["claude"]), cwd: cwd)
    let binding = ClaudeAdapter().bindSession(observed, context: BindingContext(home: home, table: ProcessTable(processes: [snapshot])))
    let root = RootProcess(kind: .claude, process: observed, binding: binding)
    configuration.processProvider = { _ in [root] }
    let probeEngine = AgentEngine(configuration: configuration)
    let key = AgentSessionKey(kind: .claude, sessionID: sessionID)
    let observations = Observations()
    let stream = probeEngine.updates()
    let consumer = Task {
        for await update in stream {
            if case .sessions(let sessions) = update, let session = sessions.first(where: { $0.id == key }) {
                await observations.record(session.state)
            }
        }
    }
    await probeEngine.start()
    try? await Task.sleep(for: .seconds(1))
    var samples: [Double] = []
    for round in 1...rounds {
        let prompt = round % 2 == 1
        let expected: AgentState = prompt ? .working(tool: nil) : .idle
        let mark = await observations.count
        let handle = try? FileHandle(forWritingTo: transcript)
        _ = try? handle?.seekToEnd()
        let written = Date()
        try? handle?.write(contentsOf: Data(line(prompt: prompt, n: round).utf8))
        try? handle?.close()
        if let seen = await observations.wait(for: expected, after: mark, timeout: 5) {
            samples.append(seen.timeIntervalSince(written) * 1000)
        }
        try? await Task.sleep(for: .milliseconds(150))
    }
    consumer.cancel()
    await probeEngine.stop()
    let sorted = samples.sorted()
    func percentile(_ p: Double) -> Double { sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
    let mode = options.kqueue ? "kqueue" : "polling (\(configuration.transcriptPollInterval)s)"
    print(String(format: "latency (%@), %d/%d writes observed: min %.1f ms, median %.1f ms, p95 %.1f ms, max %.1f ms", mode, samples.count, rounds, sorted.first ?? .nan, percentile(0.5), percentile(0.95), sorted.last ?? .nan))
    exit(0)
}

if let count = options.bench {
    // Warm-up: the first scan reads argv for every candidate and loads live transcripts.
    let cpuWarm = cpuSeconds()
    let clock = ContinuousClock()
    var started = clock.now
    await engine.scanNow(systemWide: true)
    let cold = clock.now - started
    let coldCPU = cpuSeconds() - cpuWarm
    let warm = await engine.metrics
    let cpuBefore = cpuSeconds()
    started = clock.now
    for _ in 0..<count { await engine.scanNow(systemWide: true) }
    let elapsed = clock.now - started
    let cpu = (cpuSeconds() - cpuBefore) / Double(count) * 1000
    let metrics = await engine.metrics
    print("cold scan (argv + transcript load): wall \(milliseconds(cold)), CPU \(String(format: "%.1f", coldCPU * 1000)) ms, \(warm.argvReads) argv reads")
    print("\(count) warm system-wide scans: wall \(milliseconds(elapsed / count)) each, CPU \(String(format: "%.2f", cpu)) ms/scan; scanner mean \(milliseconds((metrics.totalScanTime - warm.totalScanTime) / count)), max \(milliseconds(metrics.maxScanTime)); \(metrics.lastProcessCount) processes, \(metrics.lastCandidateCount) candidates, \(metrics.argvReads - warm.argvReads) new argv reads")
    print(String(format: "→ at one system scan / 4 s: ~%.3f%% of one core", cpu / 4000 * 100))
    let tableCPU = cpuSeconds()
    for _ in 0..<count { _ = try? ProcessTable.capture() }
    print(String(format: "  of which sysctl(KERN_PROC_ALL) + table build: %.2f ms", (cpuSeconds() - tableCPU) / Double(count) * 1000))
    exit(0)
}

if let window = options.coldStart {
    // How fast does each session reach the state it settles in? Sample every 20 ms from start().
    let clock = ContinuousClock()
    let begin = clock.now
    let sampler = Task {
        var samples: [(Duration, [AgentSessionKey: String])] = []
        while !Task.isCancelled {
            let sessions = await engine.sessions()
            samples.append((clock.now - begin, Dictionary(sessions.map { ($0.id, stateText($0.state)) }, uniquingKeysWith: { a, _ in a })))
            try? await Task.sleep(for: .milliseconds(20))
        }
        return samples
    }
    await engine.start()
    let ready = clock.now - begin
    try? await Task.sleep(for: .seconds(window))
    sampler.cancel()
    let samples = await sampler.value
    let finalSessions = await engine.sessions()
    print("start() returned after \(milliseconds(ready)); sampled \(samples.count) snapshots over \(Int(window)) s")
    var worst = Duration.zero
    for session in finalSessions where session.state.isLive {
        let final = stateText(session.state)
        let firstSeen = samples.first { $0.1[session.id] != nil }?.0
        // Earliest time after which the state matched the settled one in every later sample.
        var settledAt: Duration?
        for (time, states) in samples.reversed() {
            if states[session.id] == final { settledAt = time } else { break }
        }
        let firstCorrect = samples.first { $0.1[session.id] == final }?.0
        if let settledAt { worst = max(worst, settledAt) }
        let label = session.cwd.isEmpty ? session.id.description : shortPath(session.cwd)
        print("  \(pad(session.kind.rawValue, 7)) \(pad(session.pid.map(String.init) ?? "-", 6)) \(pad(label, 36)) \(pad(final, 16)) seen \(firstSeen.map(milliseconds) ?? "-"), first correct \(firstCorrect.map(milliseconds) ?? "-"), settled \(settledAt.map(milliseconds) ?? "changed late")")
    }
    print("worst settle time: \(milliseconds(worst))")
    if let history = await engine.metrics.initialHistoryLoad { print("full history (titles, totals) loaded in background after \(milliseconds(history))") }
    exit(0)
}

await engine.start()
await engine.waitUntilReady()
try? await Task.sleep(for: .seconds(options.settle))
let sessions = await engine.sessions()
let integrations = await engine.integrationStatuses()
var estimates: [AgentSessionKey: Bool] = [:]
for session in sessions { estimates[session.id] = await engine.costIsEstimated(session.id) }
let metrics = await engine.metrics

if options.titles {
    // Titles and summaries only (no prompt bodies), for before/after comparisons.
    for session in sessions {
        print("\(pad(session.kind.rawValue, 8)) \(pad(session.pid.map(String.init) ?? "-", 6)) \(pad(shortPath(session.cwd), 36)) \(pad(stateText(session.state), 16)) title: \(session.title ?? "-")")
        print(String(repeating: " ", count: 69) + "summary: \(session.summary ?? "-")")
    }
    exit(0)
}

if options.json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let output = ProbeOutput(
        sessions: sessions, integrations: integrations,
        scanMeanMilliseconds: Double(metrics.meanScanTime.components.attoseconds) / 1e15 + Double(metrics.meanScanTime.components.seconds) * 1000,
        scans: metrics.scans
    )
    if let data = try? encoder.encode(output) { print(String(decoding: data, as: UTF8.self)) }
    if !options.watch { exit(0) }
} else {
    printTable(sessions, estimates: estimates)
    printIntegrations(integrations)
    printMetrics(metrics)
    let watched = await engine.metrics.watchedPaths
    let fsevents = await engine.transcriptPolling ? "FSEvents unavailable on this host" : "FSEvents"
    print("Transcripts: \(fsevents); kqueue watching \(watched) paths; safety poll every \(watched > 0 ? configuration.safetyPollInterval : configuration.transcriptPollInterval)s")
    for error in engine.manifestErrors { print("manifest: \(error)") }
}

guard options.watch else { exit(0) }

print("\nWatching… (Ctrl-C to stop)")
if options.appLike {
    // What the app adds on top of this tool: an open pane, so the engine scans its own
    // process tree every second, plus a subscriber on updates() (below).
    await engine.surfaceOpened(SurfaceID(), workspace: WorkspaceID(), cwd: FileManager.default.currentDirectoryPath)
}
if options.hidden { await engine.setAppActive(false) }
let cpuStart = cpuSeconds()
let watchStart = Date()
signal(SIGINT) { _ in exit(0) }
Task {
    while true {
        try? await Task.sleep(for: .seconds(30))
        let used = cpuSeconds() - cpuStart
        let wall = Date().timeIntervalSince(watchStart)
        let metrics = await engine.metrics
        print(String(format: "[cpu] %.3f%% of one core over %.0fs (%.1f ms CPU); %d scans, mean scan %@", used / wall * 100, wall, used * 1000, metrics.scans, milliseconds(metrics.meanScanTime)))
    }
}
var lastStates: [AgentSessionKey: String] = [:]
for session in sessions { lastStates[session.id] = stateText(session.state) }
for await update in engine.updates() {
    let stamp = Date().formatted(date: .omitted, time: .standard)
    switch update {
    case .sessions(let sessions):
        for session in sessions {
            let state = stateText(session.state)
            if lastStates[session.id] != state {
                print("\(stamp) \(session.kind.rawValue) \(session.pid.map(String.init) ?? "-") \(lastStates[session.id] ?? "new") → \(state)  \(session.summary ?? "")")
                lastStates[session.id] = state
            }
        }
    case .attention(let event):
        print("\(stamp) [attention] \(event.title): \(event.body)\(event.shouldNotify ? "" : " (silent)")")
    case .permissionResolved(let id):
        print("\(stamp) [permission resolved] \(id)")
    case .integrations(let statuses):
        print("\(stamp) [integrations] " + statuses.map { "\($0.kind.rawValue)=\($0.installed ? "installed" : "no")" }.joined(separator: " "))
    }
}

/// State changes seen on `updates()`, with arrival times.
actor Observations {
    private var seen: [(AgentState, Date)] = []
    var count: Int { seen.count }

    func record(_ state: AgentState) {
        if seen.last?.0 != state { seen.append((state, Date())) }
    }

    func wait(for state: AgentState, after mark: Int, timeout: Double) async -> Date? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = seen.dropFirst(mark).first(where: { $0.0 == state }) { return hit.1 }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }
}
