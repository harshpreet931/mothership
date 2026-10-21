import Darwin
import Dispatch
import Foundation
import SessionHost
import ShipModel

// mshipd: Mothership's session host. Owns pane PTYs so shells and agents outlive the app.
//
//   mshipd --serve --socket PATH [--log PATH] [--idle-exit SECONDS]   run the host (foreground)
//   mshipd --launch --socket PATH [--log PATH]                        start --serve detached, exit
//   mshipd --list --socket PATH                                       print a running host's sessions
//   mshipd --exec-child EXECUTABLE CWD ARGV0 [ARGS…]                  internal: PTY trampoline

let arguments = Array(CommandLine.arguments.dropFirst())

// The trampoline runs first and touches nothing else: it's the session's process-to-be.
if arguments.first == PTYSpawner.childFlag {
    PTYSpawner.runChild(arguments)
}

func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let socketPath = value("--socket") ?? SessionHostPaths.socket
let logPath = value("--log")
let executable: String = {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return CommandLine.arguments[0] }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL.path
}()

if arguments.contains("--launch") {
    // Double spawn: the host becomes its own session, parented by launchd once we exit.
    var serve = [executable, "--serve", "--socket", socketPath]
    if let logPath { serve += ["--log", logPath] }
    if let idle = value("--idle-exit") { serve += ["--idle-exit", idle] }
    do {
        _ = try SessionHostLauncher.spawnDetached(
            executable, arguments: serve, environment: ProcessInfo.processInfo.environment,
            logPath: logPath ?? "/dev/null"
        )
        exit(0)
    } catch {
        fputs("mshipd: \(error)\n", stderr)
        exit(1)
    }
}

// Diagnostics: what a running host holds.
if arguments.contains("--list") {
    do {
        let client = try SessionHostClient.connect(socketPath: socketPath, client: "mshipd --list")
        let done = DispatchSemaphore(value: 0)
        // Detached: top-level code is main-actor isolated, and the main thread waits below.
        Task.detached {
            defer { done.signal() }
            guard let sessions = try? await client.list() else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let body: [String: AnyEncodable] = [
                "pid": AnyEncodable(client.welcome.pid), "version": AnyEncodable(client.welcome.version),
                "sessions": AnyEncodable(sessions),
            ]
            if let data = try? encoder.encode(body) { print(String(decoding: data, as: UTF8.self)) }
        }
        if done.wait(timeout: .now() + 3) == .timedOut {
            fputs("mshipd: no answer from \(socketPath)\n", stderr)
            exit(1)
        }
        exit(0)
    } catch {
        fputs("mshipd: not running on \(socketPath)\n", stderr)
        exit(3)
    }
}

guard arguments.contains("--serve") else {
    fputs("usage: mshipd --serve --socket PATH [--log PATH] [--idle-exit SECONDS]\n", stderr)
    exit(2)
}

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)

let log: @Sendable (String) -> Void = { message in
    let line = "\(ISO8601DateFormatter().string(from: Date())) mshipd[\(getpid())] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

let idleSeconds = value("--idle-exit").flatMap(Double.init) ?? 10
let server = SessionHostServer(configuration: SessionHostServer.Configuration(
    socketPath: socketPath, trampoline: executable,
    idleExit: idleSeconds > 0 ? .milliseconds(Int(idleSeconds * 1000)) : nil, log: log
))
server.onExit = {
    log("exiting")
    exit(0)
}

// SIGTERM ends every session (the PTYs close with the process anyway; this reaps cleanly).
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
terminate.setEventHandler {
    log("SIGTERM: stopping")
    server.stop()
    exit(0)
}
terminate.resume()

do {
    try server.start()
} catch {
    log("\(error)")
    // Another host already serves this socket: that's success for whoever launched us.
    if case .alreadyRunning = error { exit(0) }
    exit(1)
}
dispatchMain()

/// Type-erased Encodable for the --list output.
struct AnyEncodable: Encodable, @unchecked Sendable {
    // @unchecked: wraps immutable values for one encode on one thread.
    private let encodeValue: (any Encoder) throws -> Void
    init(_ value: some Encodable) { encodeValue = value.encode }
    func encode(to encoder: any Encoder) throws { try encodeValue(encoder) }
}
