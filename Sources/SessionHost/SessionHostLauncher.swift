import Darwin
import Foundation

/// Finds or starts `mshipd`.
///
/// The daemon is started fully detached so nothing that happens to the app (quit, crash,
/// `kill -9`) reaches it: the app spawns `mshipd --launch`, which spawns the real host
/// (`--serve`) as a new session (`setsid`) and exits at once. The app reaps that short-lived
/// middle process, and the host is reparented to launchd, so the app never leaves a zombie.
public enum SessionHostLauncher {
    public enum LaunchError: Error, CustomStringConvertible {
        case missingDaemon(String)
        case spawnFailed(Int32)
        case didNotStart(String)

        public var description: String {
            switch self {
            case .missingDaemon(let path): "mshipd not found at \(path)"
            case .spawnFailed(let code): "couldn't start mshipd: \(String(cString: strerror(code)))"
            case .didNotStart(let detail): "mshipd didn't start: \(detail)"
            }
        }
    }

    /// Environment the daemon itself runs with. Sessions get their own complete environment
    /// from the app, so this is only what the host process needs.
    public static func daemonEnvironment(from environment: [String: String]) -> [String: String] {
        let keep = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "MOTHERSHIP_HOME", "SHELL"]
        return environment.filter { keep.contains($0.key) }
    }

    /// Connects to a running host, or starts one and connects. `daemonPath` is the `mshipd`
    /// executable (inside the app bundle next to the app's binary).
    public static func connectOrLaunch(
        socketPath: String, daemonPath: String, logPath: String, environment: [String: String],
        client: String = "Mothership", timeout: Duration = .seconds(3)
    ) throws -> SessionHostClient {
        if let existing = try? SessionHostClient.connect(socketPath: socketPath, client: client) { return existing }
        try launch(socketPath: socketPath, daemonPath: daemonPath, logPath: logPath, environment: environment)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var lastError: SessionHostClientError = .notRunning
        while ContinuousClock.now < deadline {
            do {
                return try SessionHostClient.connect(socketPath: socketPath, client: client)
            } catch {
                lastError = error
                usleep(10_000)
            }
        }
        throw LaunchError.didNotStart("\(lastError) (see \(logPath))")
    }

    /// Starts the daemon detached and returns once the launcher process has exited.
    public static func launch(socketPath: String, daemonPath: String, logPath: String, environment: [String: String]) throws {
        guard FileManager.default.isExecutableFile(atPath: daemonPath) else { throw LaunchError.missingDaemon(daemonPath) }
        let arguments = [daemonPath, "--launch", "--socket", socketPath, "--log", logPath]
        let pid = try spawnDetached(daemonPath, arguments: arguments, environment: daemonEnvironment(from: environment), logPath: logPath)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    /// `posix_spawn` as a new session, stdin from /dev/null, stdout/stderr appended to the log,
    /// every other descriptor closed.
    public static func spawnDetached(_ path: String, arguments: [String], environment: [String: String], logPath: String) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = Int32(POSIX_SPAWN_SETSID) | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attr, Int16(truncatingIfNeeded: flags))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        try? FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var pid: pid_t = 0
        let envp = environment.map { "\($0.key)=\($0.value)" }
        let result = PTYSpawner.withCStrings(arguments) { argv in
            PTYSpawner.withCStrings(envp) { env in posix_spawn(&pid, path, &actions, &attr, argv, env) }
        }
        guard result == 0 else { throw LaunchError.spawnFailed(result) }
        return pid
    }
}
