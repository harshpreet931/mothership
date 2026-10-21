import Darwin
import Foundation
import Synchronization

/// Exit status and output of one command.
public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data = Data(), stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    /// The first non-empty stderr line, for error messages.
    public var errorLine: String {
        stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}

public enum CommandError: Error, Equatable, LocalizedError, Sendable {
    case launchFailed(command: String, reason: String)
    case timedOut(command: String, seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let command, let reason): "Couldn't run \(command): \(reason)"
        case .timedOut(let command, let seconds): "\(command) didn't finish within \(seconds) s"
        }
    }
}

/// Runs an executable to completion. A protocol so tests can stand in for `gh` (and anything
/// that must never touch the network or a real GitHub account).
public protocol CommandRunning: Sendable {
    func run(
        _ executable: String, _ arguments: [String], directory: String?, environment: [String: String], timeout: Duration
    ) async throws -> CommandResult
}

/// `Foundation.Process` with a timeout: on expiry the command gets SIGTERM, then SIGKILL.
public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(
        _ executable: String, _ arguments: [String], directory: String?, environment: [String: String], timeout: Duration
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try Self.runBlocking(executable, arguments, directory: directory, environment: environment, timeout: timeout)
                })
            }
        }
    }

    /// Collects one pipe's bytes on a reader thread.
    private final class Sink: Sendable {
        private let storage = Mutex(Data())
        func set(_ data: Data) { storage.withLock { $0 = data } }
        var data: Data { storage.withLock { $0 } }
    }

    private final class Flag: Sendable {
        private let storage = Mutex(false)
        func raise() { storage.withLock { $0 = true } }
        var isRaised: Bool { storage.withLock { $0 } }
    }

    static func runBlocking(
        _ executable: String, _ arguments: [String], directory: String?, environment: [String: String], timeout: Duration
    ) throws -> CommandResult {
        let name = (executable as NSString).lastPathComponent
        let command = ([name] + arguments.prefix(2)).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(command: command, reason: error.localizedDescription)
        }
        let pid = process.processIdentifier
        let stdout = Sink()
        let stderr = Sink()
        let readers = DispatchGroup()
        for (pipe, sink) in [(stdoutPipe, stdout), (stderrPipe, stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                sink.set(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }
        let expired = Flag()
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let watchdog = DispatchWorkItem {
            expired.raise()
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(pid, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        // A grandchild that inherited the pipes (an ssh, a credential helper) can't hang us.
        _ = readers.wait(timeout: .now() + 5)
        if expired.isRaised { throw CommandError.timedOut(command: command, seconds: Int(seconds.rounded())) }
        return CommandResult(
            status: process.terminationStatus, stdout: stdout.data, stderr: String(decoding: stderr.data, as: UTF8.self)
        )
    }
}

/// Finds command-line tools the way a login shell would, without spawning one: the app's
/// own PATH is launchd's minimal one, so Homebrew and `~/.local/bin` are added.
public enum ExecutableLocator {
    public static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (inherited + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func find(_ name: String) -> String? {
        for directory in searchDirectories {
            let path = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// PATH for child processes (git hooks and helpers, `gh` calling `git`).
    public static var searchPath: String { searchDirectories.joined(separator: ":") }
}
