import Darwin
import Foundation
import ShipModel
import ShipProtocol

/// Exit statuses, documented in `mship help`.
enum ExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let notRunning: Int32 = 3
}

/// Why a command stopped early. `main` prints usage errors with a hint and exits 2.
enum CLIFailure: Error {
    case usage(String, command: String?)
    /// The message (if any) was already printed.
    case exit(Int32)
}

func usageError(_ message: String, command: String? = nil) -> CLIFailure { .usage(message, command: command) }

/// Hand-rolled argv parsing: flags may appear anywhere before `--`; everything after `--` is
/// passed through untouched (it's usually a command line).
struct Arguments {
    private(set) var items: [String]
    /// Everything after a bare `--`.
    let trailing: [String]
    let hasTrailing: Bool
    let command: String

    init(_ arguments: [String], command: String) {
        self.command = command
        if let separator = arguments.firstIndex(of: "--") {
            items = Array(arguments[..<separator])
            trailing = Array(arguments[(separator + 1)...])
            hasTrailing = true
        } else {
            items = arguments
            trailing = []
            hasTrailing = false
        }
    }

    /// True if any of `names` was present (all occurrences are consumed).
    mutating func flag(_ names: String...) -> Bool {
        let before = items.count
        items.removeAll { names.contains($0) }
        return items.count != before
    }

    /// `--name value` or `--name=value`. The last occurrence wins.
    mutating func option(_ names: String...) throws(CLIFailure) -> String? {
        var value: String?
        var index = 0
        while index < items.count {
            let item = items[index]
            if names.contains(item) {
                guard index + 1 < items.count else { throw usageError("\(item) needs a value", command: command) }
                value = items[index + 1]
                items.removeSubrange(index...(index + 1))
                continue
            }
            if let name = names.first(where: { item.hasPrefix($0 + "=") }) {
                value = String(item.dropFirst(name.count + 1))
                items.remove(at: index)
                continue
            }
            index += 1
        }
        return value
    }

    /// Every occurrence of a repeatable `--name value`, in order.
    mutating func options(_ name: String) throws(CLIFailure) -> [String] {
        var values: [String] = []
        var index = 0
        while index < items.count {
            if items[index] == name {
                guard index + 1 < items.count else { throw usageError("\(name) needs a value", command: command) }
                values.append(items[index + 1])
                items.removeSubrange(index...(index + 1))
            } else if items[index].hasPrefix(name + "=") {
                values.append(String(items[index].dropFirst(name.count + 1)))
                items.remove(at: index)
            } else {
                index += 1
            }
        }
        return values
    }

    mutating func intOption(_ names: String...) throws(CLIFailure) -> Int? {
        var value: String?
        for name in names where value == nil { value = try option(name) }
        guard let value else { return nil }
        guard let number = Int(value), number >= 0 else { throw usageError("\(names[0]) needs a non-negative number", command: command) }
        return number
    }

    /// Remaining positional arguments; rejects unknown flags.
    func positionals() throws(CLIFailure) -> [String] {
        if let unknown = items.first(where: { $0.hasPrefix("-") && $0 != "-" && Double($0) == nil }) {
            throw usageError("unknown option \(unknown)", command: command)
        }
        return items
    }

    /// The command line after `--`: one argument is taken as a shell string verbatim; several
    /// are shell-quoted and joined (so `-- claude "fix the tests"` survives intact).
    var trailingCommand: String? {
        guard !trailing.isEmpty else { return nil }
        if trailing.count == 1 { return trailing[0] }
        return trailing.map(shellQuote).joined(separator: " ")
    }
}

func shellQuote(_ word: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
    if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Output

enum Output {
    static func write(_ text: String, to fd: Int32 = STDOUT_FILENO) {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + offset, raw.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    static func line(_ text: String) { write(text + "\n") }

    static func error(_ text: String) { write("mship: \(text)\n", to: STDERR_FILENO) }

    static var stdoutIsTerminal: Bool { isatty(STDOUT_FILENO) == 1 }

    static var useColor: Bool {
        stdoutIsTerminal && getenv("NO_COLOR") == nil && getenv("TERM").map { String(cString: $0) } != "dumb"
    }

    static var terminalWidth: Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        if let columns = getenv("COLUMNS").flatMap({ Int(String(cString: $0)) }), columns > 0 { return columns }
        return 100
    }
}

/// ANSI styling that disappears when color is off.
struct Style {
    let enabled: Bool

    func apply(_ text: String, _ codes: String) -> String { enabled ? "\u{1B}[\(codes)m\(text)\u{1B}[0m" : text }
    func bold(_ text: String) -> String { apply(text, "1") }
    func dim(_ text: String) -> String { apply(text, "2") }
    func red(_ text: String) -> String { apply(text, "31") }
    func green(_ text: String) -> String { apply(text, "32") }
    func yellow(_ text: String) -> String { apply(text, "33") }
    func blue(_ text: String) -> String { apply(text, "34") }
    func magenta(_ text: String) -> String { apply(text, "35") }
    func cyan(_ text: String) -> String { apply(text, "36") }
    func orange(_ text: String) -> String { apply(text, "38;5;208") }
}

// MARK: - Input

enum Input {
    /// Reads stdin to EOF. Gives up after `idle` without new bytes (an inherited pipe that
    /// nobody writes or closes must never hang an agent hook) or `total` overall.
    static func readAll(idle: Duration = .milliseconds(500), total: Duration = .seconds(5)) -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let start = ContinuousClock.now
        while true {
            let elapsed = ContinuousClock.now - start
            if elapsed >= total { break }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let wait = min(idle, total - elapsed)
            let millis = Int32(clamping: wait.components.seconds * 1000 + wait.components.attoseconds / 1_000_000_000_000_000)
            let ready = poll(&descriptor, 1, max(1, millis))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: chunk[0..<count])
            } else if count < 0 && (errno == EINTR || errno == EAGAIN) {
                continue
            } else {
                break  // EOF or error
            }
        }
        return data
    }

    static var stdinIsTerminal: Bool { isatty(STDIN_FILENO) == 1 }
}

// MARK: - Calling the app

/// The socket every command talks to: `$MOTHERSHIP_SOCKET`, else the default location.
var socketPath: String { ControlSocketLocation.resolve() }

/// Calls the app, printing a message and throwing the exit code on failure.
func callApp<R: Decodable>(
    _ method: ControlMethod, _ params: some Encodable, as type: R.Type = R.self, timeout: Duration = .seconds(30)
) throws(CLIFailure) -> R {
    let client = ControlClient(socketPath: socketPath)
    defer { client.close() }
    do throws(ControlClientError) {
        return try client.call(method, params, as: R.self, timeout: timeout)
    } catch {
        switch error {
        case .appNotRunning:
            Output.error("Mothership isn't running. Open the app first (looked for \(socketPath)).")
            throw .exit(ExitCode.notRunning)
        case .server(let rpc):
            Output.error(rpc.message)
        default:
            Output.error(error.description)
        }
        throw .exit(ExitCode.failure)
    }
}

/// Parses a surface id argument.
func parseSurface(_ raw: String, command: String) throws(CLIFailure) -> SurfaceID {
    guard let id = SurfaceID(string: raw.trimmingCharacters(in: .whitespaces)) else {
        throw usageError("'\(raw)' isn't a surface id (expected a UUID like those printed by `mship split`)", command: command)
    }
    return id
}

var currentDirectory: String? {
    guard let raw = getcwd(nil, 0) else { return nil }
    defer { free(raw) }
    return String(cString: raw)
}

func expandTilde(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    return NSHomeDirectory() + path.dropFirst()
}

/// Makes a user-supplied directory absolute (the app's cwd isn't ours).
func absolutePath(_ path: String) -> String {
    let expanded = expandTilde(path)
    if expanded.hasPrefix("/") { return expanded }
    return URL(fileURLWithPath: expanded, relativeTo: currentDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) })
        .standardizedFileURL.path
}
