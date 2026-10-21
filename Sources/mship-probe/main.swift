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
//
// Read-only: it never installs integrations or writes to agent configs.

struct Options {
    var json = false
    var watch = false
    var bench: Int?
    var home: URL?
    var settle: Double = 1.5
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
        case "-h", "--help":
            print("usage: mship-probe [--json] [--watch] [--bench N] [--home DIR] [--settle SECONDS]")
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

await engine.start()
await engine.waitUntilReady()
try? await Task.sleep(for: .seconds(options.settle))
let sessions = await engine.sessions()
let integrations = await engine.integrationStatuses()
var estimates: [AgentSessionKey: Bool] = [:]
for session in sessions { estimates[session.id] = await engine.costIsEstimated(session.id) }
let metrics = await engine.metrics

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
    for error in engine.manifestErrors { print("manifest: \(error)") }
}

guard options.watch else { exit(0) }

print("\nWatching… (Ctrl-C to stop)")
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
