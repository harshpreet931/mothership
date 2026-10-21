import Darwin
import Foundation

/// Starts a program on a new pseudo-terminal.
///
/// No `fork()`: forking a multithreaded Swift process and running anything but async-signal-
/// safe calls before `exec` can deadlock on locks other threads held. Instead `posix_spawn`
/// starts this same binary in trampoline mode (`--exec-child`) as a new session
/// (`POSIX_SPAWN_SETSID`) with the PTY slave as stdin/stdout/stderr and every other fd
/// closed (`POSIX_SPAWN_CLOEXEC_DEFAULT`); the trampoline makes the slave its controlling
/// terminal (`TIOCSCTTY`), changes directory and `execve`s the real program. Signal
/// dispositions and the mask are reset, so the shell starts as a terminal would start it.
public enum PTYSpawner {
    public struct Spawned: Sendable {
        public var pid: pid_t
        /// Non-blocking, close-on-exec master side.
        public var master: Int32
    }

    public enum SpawnError: Error, CustomStringConvertible {
        case openpty(Int32)
        case spawn(Int32)

        public var description: String {
            switch self {
            case .openpty(let code): "openpty failed: \(String(cString: strerror(code)))"
            case .spawn(let code): "posix_spawn failed: \(String(cString: strerror(code)))"
            }
        }
    }

    public static let childFlag = "--exec-child"

    public static func spawn(_ spec: SpawnSpec, columns: UInt16, rows: UInt16, trampoline: String) throws(SpawnError) -> Spawned {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: max(rows, 1), ws_col: max(columns, 1), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw .openpty(errno) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        // UTF-8 aware line editing (backspace over multibyte characters), as terminals set it.
        var attributes = termios()
        if tcgetattr(slave, &attributes) == 0 {
            attributes.c_iflag |= tcflag_t(IUTF8)
            _ = tcsetattr(slave, TCSANOW, &attributes)
        }

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
        for target: Int32 in 0...2 { posix_spawn_file_actions_adddup2(&actions, slave, target) }

        let argv = [trampoline, childFlag, spec.executable, spec.workingDirectory ?? ""] + spec.arguments
        let envp = spec.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStrings(argv) { argvPointers in
            withCStrings(envp) { envPointers in
                posix_spawn(&pid, trampoline, &actions, &attr, argvPointers, envPointers)
            }
        }
        close(slave)
        guard result == 0 else {
            close(master)
            throw .spawn(result)
        }
        return Spawned(pid: pid, master: master)
    }

    /// The trampoline: `[--exec-child, executable, cwd, argv0, args…]`. Never returns.
    public static func runChild(_ arguments: [String]) -> Never {
        guard arguments.count >= 4, arguments[0] == childFlag else {
            fputs("mshipd: bad --exec-child arguments\n", stderr)
            _exit(126)
        }
        let executable = arguments[1]
        let directory = arguments[2]
        let argv = Array(arguments[3...])
        _ = ioctl(STDIN_FILENO, UInt(TIOCSCTTY), 0)
        if directory.isEmpty || chdir(directory) != 0 {
            if let home = getenv("HOME") { _ = chdir(home) }
        }
        withCStrings(argv) { pointers in
            _ = execve(executable, pointers, environ)
        }
        let message = "mshipd: couldn't run \(executable): \(String(cString: strerror(errno)))\r\n"
        fputs(message, stderr)
        _exit(127)
    }

    /// NUL-terminated `char *[]` for the duration of `body`.
    static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress) }
    }
}
