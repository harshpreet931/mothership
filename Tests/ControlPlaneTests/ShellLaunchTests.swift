import Darwin
import Foundation
import Testing
import ShipProtocol

/// Runs a shell command line in a real pty (`script(1)`), the way Ghostty runs a pane's
/// command (`/bin/sh -c`), feeding `input` chunks with pauses so the shells see keystrokes.
/// Everything runs against a scratch HOME/ZDOTDIR; the user's dotfiles are never read.
private func runInPTY(
    _ commandLine: String, environment: [String: String], input: [(delay: Double, bytes: String)], timeout: Double = 20
) async throws -> String {
    try await offPool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", commandLine]
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        let collected = OutputBox()
        let reader = DispatchQueue(label: "pty-reader")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            collected.data = stdout.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        try process.run()
        for chunk in input {
            usleep(useconds_t(chunk.delay * 1_000_000))
            stdin.fileHandleForWriting.write(Data(chunk.bytes.utf8))
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        try? stdin.fileHandleForWriting.close()
        _ = done.wait(timeout: .now() + 5)
        return String(decoding: collected.data, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
    }
}

private final class OutputBox: @unchecked Sendable {
    // @unchecked: written once by the reader queue, read after the semaphore.
    var data = Data()
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// A scratch HOME with a ZDOTDIR and a fake Ghostty integration dir that behaves like the real
/// one: it restores the user's ZDOTDIR from GHOSTTY_ZSH_ZDOTDIR and records that it ran.
private struct ShellSandbox {
    let root: URL
    var home: URL { root.appending(path: "home") }
    var zdot: URL { root.appending(path: "zdot") }
    var integration: URL { root.appending(path: "resources/shell-integration/zsh") }
    var bashIntegration: URL { root.appending(path: "resources/shell-integration/bash") }
    var resources: URL { root.appending(path: "resources") }

    init() throws {
        root = URL(fileURLWithPath: "/tmp/mship-shell-\(UUID().uuidString.prefix(8))")
        let fm = FileManager.default
        for dir in [home, zdot, integration, bashIntegration] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try "echo rc-loaded\nPROMPT='T> '\n".write(to: zdot.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        try """
            typeset -g GHOSTTY_ZSH_INTEGRATION_DIR="${${(%):-%x}:A:h}"
            if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+set}" ]]; then ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"; unset GHOSTTY_ZSH_ZDOTDIR; else unset ZDOTDIR; fi
            [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"
            echo integration-loaded

            """.write(to: integration.appending(path: ".zshenv"), atomically: true, encoding: .utf8)
        try """
            set +o posix
            unset GHOSTTY_BASH_INJECT
            echo bash-integration-loaded
            PS1='B> '

            """.write(to: bashIntegration.appending(path: "ghostty.bash"), atomically: true, encoding: .utf8)
    }

    func environment(shell: String, command: String, extra: [String: String] = [:]) -> [String: String] {
        var env = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "TERM": "xterm-256color", "SHELL": shell,
            "LANG": "en_US.UTF-8", "MOTHERSHIP_SURFACE_ID": "surface-123",
        ]
        env.merge(ShellLaunch.environment(running: command)) { _, new in new }
        env.merge(extra) { _, new in new }
        return env
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Shell launch", .serialized)
struct ShellLaunchTests {
    @Test func quoting() {
        #expect(ShellLaunch.quote("/bin/zsh") == "/bin/zsh")
        #expect(ShellLaunch.quote("it's") == #"'it'\''s'"#)
        #expect(ShellLaunch.quote("a b") == "'a b'")
        #expect(ShellLaunch.quote("") == "''")
        #expect(ShellLaunch.quote("$HOME;rm -rf /") == "'$HOME;rm -rf /'")
    }

    @Test func families() {
        #expect(ShellLaunch.family(of: "/bin/zsh") == .zsh)
        #expect(ShellLaunch.family(of: "-zsh") == .zsh)
        #expect(ShellLaunch.family(of: "/opt/homebrew/bin/bash") == .bash)
        #expect(ShellLaunch.family(of: "/bin/sh") == .posix)
        #expect(ShellLaunch.family(of: "/usr/local/bin/fish") == .fish)
        #expect(ShellLaunch.family(of: "/opt/homebrew/bin/nu") == .unsupported)
        #expect(ShellLaunch.command(shell: "/opt/homebrew/bin/nu") == nil)
    }

    @Test func zshRunsCommandOnceThenStaysInteractiveWithIntegration() async throws {
        let sandbox = try ShellSandbox()
        defer { sandbox.remove() }
        let command = try #require(ShellLaunch.command(shell: "/bin/zsh"))
        let env = sandbox.environment(
            shell: "/bin/zsh", command: #"echo "ran $((20+1))"; echo "cmd=${MOTHERSHIP_STARTUP_COMMAND-unset}""#,
            extra: ["ZDOTDIR": sandbox.integration.path, "GHOSTTY_ZSH_ZDOTDIR": sandbox.zdot.path]
        )
        let output = try await runInPTY(command, environment: env, input: [
            (1.5, "echo alive-$((40+2)) sid=$MOTHERSHIP_SURFACE_ID zdot=${ZDOTDIR:t}\n"),
            (0.8, "exit\n"),
        ])
        #expect(occurrences(of: "ran 21", in: output) == 1, "\(output)")
        #expect(output.contains("cmd=unset"), "\(output)")
        // The command's shell and the interactive one both loaded the integration and the rc.
        #expect(occurrences(of: "integration-loaded", in: output) == 2, "\(output)")
        #expect(occurrences(of: "rc-loaded", in: output) == 2, "\(output)")
        #expect(output.contains("alive-42 sid=surface-123 zdot=zdot"), "\(output)")
    }

    @Test func ctrlCStopsTheCommandAndLeavesAShell() async throws {
        let sandbox = try ShellSandbox()
        defer { sandbox.remove() }
        let command = try #require(ShellLaunch.command(shell: "/bin/zsh"))
        let env = sandbox.environment(
            shell: "/bin/zsh", command: "sleep 30 && echo not-reached",
            extra: ["ZDOTDIR": sandbox.integration.path, "GHOSTTY_ZSH_ZDOTDIR": sandbox.zdot.path]
        )
        let started = Date()
        let output = try await runInPTY(command, environment: env, input: [
            (1.5, "\u{03}"),
            (1.0, "echo alive-$((40+2))\n"),
            (0.8, "exit\n"),
        ])
        #expect(Date().timeIntervalSince(started) < 15)
        #expect(output.contains("alive-42"), "\(output)")
        #expect(!output.contains("not-reached"), "\(output)")
    }

    /// Agent detection (and the quit prompt) find what runs in a pane via the terminal's
    /// foreground process group, so the command must lead it, not hide behind the wrapper.
    @Test func commandLeadsTheForegroundProcessGroup() async throws {
        let sandbox = try ShellSandbox()
        defer { sandbox.remove() }
        let command = try #require(ShellLaunch.command(shell: "/bin/zsh"))
        let probe = #"sh -c 'set -- $(ps -o pid=,pgid=,tpgid= -p $$); [ "$1" = "$2" ] && [ "$2" = "$3" ] && echo fg-leader=yes || echo fg-leader=no'"#
        let env = sandbox.environment(shell: "/bin/zsh", command: probe, extra: ["ZDOTDIR": sandbox.zdot.path])
        let output = try await runInPTY(command, environment: env, input: [(1.5, "exit\n")])
        #expect(output.contains("fg-leader=yes"), "\(output)")
    }

    @Test func aBrokenCommandStillLeavesAShell() async throws {
        let sandbox = try ShellSandbox()
        defer { sandbox.remove() }
        let command = try #require(ShellLaunch.command(shell: "/bin/zsh"))
        let env = sandbox.environment(
            shell: "/bin/zsh", command: #"echo "unterminated"#,
            extra: ["ZDOTDIR": sandbox.integration.path, "GHOSTTY_ZSH_ZDOTDIR": sandbox.zdot.path]
        )
        let output = try await runInPTY(command, environment: env, input: [(1.5, "echo alive-$((40+2))\n"), (0.8, "exit\n")])
        #expect(output.contains("alive-42"), "\(output)")
    }

    @Test func zshWithoutGhosttyIntegrationStillWorks() async throws {
        let sandbox = try ShellSandbox()
        defer { sandbox.remove() }
        let command = try #require(ShellLaunch.command(shell: "/bin/zsh"))
        let env = sandbox.environment(shell: "/bin/zsh", command: "echo plain-$((1+1))", extra: ["ZDOTDIR": sandbox.zdot.path])
        let output = try await runInPTY(command, environment: env, input: [(1.5, "echo alive-$((40+2))\n"), (0.8, "exit\n")])
        #expect(occurrences(of: "plain-2", in: output) == 1, "\(output)")
        #expect(occurrences(of: "rc-loaded", in: output) == 2, "\(output)")
        #expect(output.contains("alive-42"), "\(output)")
    }

    /// Ghostty injects bash integration only for bash 4+ (macOS's /bin/bash is 3.2); the
    /// wrapper does the same. Either way the pane ends up in a working interactive bash.
    @Test(arguments: ["/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"])
    func bashRunsCommandThenStaysInteractive(_ bash: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: bash) else { return }
        let sandbox = try ShellSandbox()
        defer { sandbox.remove() }
        let command = try #require(ShellLaunch.command(shell: bash))
        let env = sandbox.environment(
            shell: bash, command: "echo bash-ran-$((2+3)) major=${BASH_VERSINFO[0]}",
            extra: ["GHOSTTY_RESOURCES_DIR": sandbox.resources.path]
        )
        let output = try await runInPTY(command, environment: env, input: [(1.5, "echo alive-$((40+2))\n"), (0.8, "exit\n")])
        #expect(occurrences(of: "bash-ran-5", in: output) == 1, "\(output)")
        #expect(output.contains("alive-42"), "\(output)")
        let major = output.firstMatch(of: /major=(\d+)/).flatMap { Int($0.1) } ?? 0
        #expect(output.contains("bash-integration-loaded") == (major >= 4), "\(output)")
    }
}
