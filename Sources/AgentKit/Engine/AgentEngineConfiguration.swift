import Darwin
import Foundation
import ShipModel

/// Tunables for `AgentEngine`. `standard` uses the real home directory and `ShipPaths`;
/// tests pass a temp home and switch off scanning / watching.
public struct AgentEngineConfiguration: Sendable {
    /// Root for agent configs and transcripts (`~/.claude`, `~/.codex`, …).
    public var homeDirectory: URL
    /// Mothership's own state (install records).
    public var supportDirectory: URL
    /// The `mship` path written into hook configs.
    public var cliShimPath: String
    /// User manifests (`*.json`) for long-tail agents; nil to use only the embedded defaults.
    public var manifestsDirectory: URL?
    public var backupsDirectory: URL
    /// How long a PermissionRequest hook may be held before releasing to the TUI (§6).
    public var permissionHoldTimeout: TimeInterval
    /// Hold permission hooks for sessions outside Mothership (VS Code, iTerm…). When false
    /// those prompts go straight to the agent's own TUI.
    public var holdPermissionsForExternalSessions: Bool
    /// Tier-0 lease (§5.3).
    public var tier0Lease: TimeInterval
    /// Scan of processes under the app (only while surfaces are open).
    public var surfaceScanInterval: TimeInterval
    /// System-wide scan.
    public var systemScanInterval: TimeInterval
    /// Minimum spacing of `.sessions` updates (0.1 s → at most 10/s).
    public var updateInterval: TimeInterval
    public var endedSessionRetention: TimeInterval
    /// Sessions with no process (transcript-only) end after this much inactivity.
    public var transcriptOnlyIdleTimeout: TimeInterval
    public var integrationCheckInterval: TimeInterval
    /// Transcript polling period, used only when FSEvents is unavailable.
    public var transcriptPollInterval: TimeInterval
    public var processScanning: Bool
    public var transcriptWatching: Bool
    /// The app's pid; its descendants are scanned at `surfaceScanInterval`.
    public var appProcessID: Int32
    public var summarizer: any SessionSummarizer
    /// Allow running `<cli> --version` when the version can't be read from the install layout.
    public var probeCLIVersions: Bool

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        supportDirectory: URL = ShipPaths.supportDirectory,
        cliShimPath: String = ShipPaths.cliShim.path,
        manifestsDirectory: URL? = ShipPaths.agentManifests,
        backupsDirectory: URL = ShipPaths.backups,
        permissionHoldTimeout: TimeInterval = 600,
        holdPermissionsForExternalSessions: Bool = true,
        tier0Lease: TimeInterval = AgentReducer.defaultLease,
        surfaceScanInterval: TimeInterval = 1,
        systemScanInterval: TimeInterval = 4,
        updateInterval: TimeInterval = 0.1,
        endedSessionRetention: TimeInterval = 30 * 60,
        transcriptOnlyIdleTimeout: TimeInterval = 30 * 60,
        integrationCheckInterval: TimeInterval = 30,
        transcriptPollInterval: TimeInterval = 1,
        processScanning: Bool = true,
        transcriptWatching: Bool = true,
        appProcessID: Int32 = getpid(),
        summarizer: any SessionSummarizer = HeuristicSummarizer(),
        probeCLIVersions: Bool = true
    ) {
        self.homeDirectory = homeDirectory
        self.supportDirectory = supportDirectory
        self.cliShimPath = cliShimPath
        self.manifestsDirectory = manifestsDirectory
        self.backupsDirectory = backupsDirectory
        self.permissionHoldTimeout = permissionHoldTimeout
        self.holdPermissionsForExternalSessions = holdPermissionsForExternalSessions
        self.tier0Lease = tier0Lease
        self.surfaceScanInterval = surfaceScanInterval
        self.systemScanInterval = systemScanInterval
        self.updateInterval = updateInterval
        self.endedSessionRetention = endedSessionRetention
        self.transcriptOnlyIdleTimeout = transcriptOnlyIdleTimeout
        self.integrationCheckInterval = integrationCheckInterval
        self.transcriptPollInterval = transcriptPollInterval
        self.processScanning = processScanning
        self.transcriptWatching = transcriptWatching
        self.appProcessID = appProcessID
        self.summarizer = summarizer
        self.probeCLIVersions = probeCLIVersions
    }

    /// Production defaults: real home, `ShipPaths`, scanning and watching on.
    public static var standard: AgentEngineConfiguration { AgentEngineConfiguration() }

    /// Everything under `home`, no background work: for tests and previews.
    public static func isolated(home: URL) -> AgentEngineConfiguration {
        let support = home.appending(path: "Library/Application Support/Mothership", directoryHint: .isDirectory)
        return AgentEngineConfiguration(
            homeDirectory: home, supportDirectory: support, cliShimPath: support.appending(path: "bin/mship").path,
            manifestsDirectory: support.appending(path: "agents", directoryHint: .isDirectory),
            backupsDirectory: support.appending(path: "backups", directoryHint: .isDirectory),
            processScanning: false, transcriptWatching: false, probeCLIVersions: false
        )
    }
}

/// Counters for `mship-probe` and diagnostics.
public struct EngineMetrics: Sendable, Equatable {
    public var systemScans = 0
    public var surfaceScans = 0
    public var totalScanTime: Duration = .zero
    public var lastScanTime: Duration = .zero
    public var maxScanTime: Duration = .zero
    public var lastProcessCount = 0
    public var lastCandidateCount = 0
    public var argvReads = 0
    public var hooksHandled = 0
    public var signalsApplied = 0
    public var transcriptBatches = 0
    public var updatesPublished = 0
    /// How long the first scan's full transcript history took to load in the background.
    public var initialHistoryLoad: Duration?

    public var scans: Int { systemScans + surfaceScans }

    public var meanScanTime: Duration {
        scans == 0 ? .zero : totalScanTime / scans
    }

    mutating func record(_ result: ScanResult) {
        if result.scope == .system { systemScans += 1 } else { surfaceScans += 1 }
        totalScanTime += result.duration
        lastScanTime = result.duration
        maxScanTime = max(maxScanTime, result.duration)
        lastProcessCount = result.processCount
        lastCandidateCount = result.candidateCount
        argvReads += result.argvReads
    }
}
