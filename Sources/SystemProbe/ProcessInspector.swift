import Darwin
import Foundation
import Synchronization

/// argv, environment and executable path of a process (`KERN_PROCARGS2`).
public struct ProcessArguments: Sendable, Equatable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(executablePath: String, arguments: [String], environment: [String: String] = [:]) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }

    public var executableName: String { (executablePath as NSString).lastPathComponent }
    public var argv0Name: String { arguments.first.map { ($0 as NSString).lastPathComponent } ?? "" }
}

/// Stateless libproc / sysctl readers. Every call is a syscall or two; none shells out.
public enum ProcessInspector {
    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }()

    /// argv + env + exec path. Nil for processes owned by other users, zombies, or races.
    public static func arguments(pid: Int32) -> ProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argMax
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Parses the `KERN_PROCARGS2` layout: `int argc`, exec path, NUL padding, argv[argc], env…
    static func parseProcArgs(_ bytes: [UInt8]) -> ProcessArguments? {
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0, argc < 100_000 else { return nil }
        var index = 4
        func readString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let string = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return string
        }
        guard let execPath = readString() else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard let argument = readString() else { break }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while index < bytes.count {
            guard let entry = readString(), !entry.isEmpty else { break }
            if let equals = entry.firstIndex(of: "=") {
                environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
        }
        return ProcessArguments(executablePath: execPath, arguments: arguments, environment: environment)
    }

    /// Direct children of a process (`proc_listchildpids`), without a full process-table read.
    public static func childPIDs(of pid: Int32) -> [Int32] {
        var capacity = 32
        for _ in 0..<4 {
            var buffer = [Int32](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes { raw in
                proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
            }
            guard count >= 0 else { return [] }
            if Int(count) < capacity { return Array(buffer.prefix(Int(count))) }
            capacity *= 4
        }
        return []
    }

    /// Every descendant pid of `root`, breadth-first, via `proc_listchildpids` (a handful of
    /// libproc calls for an app's own shells instead of a ~1000-row sysctl).
    public static func descendantPIDs(of root: Int32, limit: Int = 4096) -> [Int32] {
        var result: [Int32] = []
        var queue = childPIDs(of: root)
        var seen: Set<Int32> = [root]
        while !queue.isEmpty, result.count < limit {
            let pid = queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            queue += childPIDs(of: pid)
        }
        return result
    }

    /// The process name (`proc_name`, the exec'd binary's name): changes on `exec`, which keeps the pid.
    public static func name(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `proc_pidpath`: cheaper than `arguments(pid:)` when only the binary matters.
    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Current working directory via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
    public static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let expected = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, expected)
        guard size == expected else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// User + system CPU time in nanoseconds (`proc_pid_rusage`).
    public static func cpuTimeNanos(pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        // rusage times are in mach absolute-time units on Apple silicon.
        return machToNanos(info.ri_user_time &+ info.ri_system_time)
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    static func machToNanos(_ ticks: UInt64) -> UInt64 {
        if timebase.numer == timebase.denom { return ticks }
        return ticks.multipliedReportingOverflow(by: timebase.numer).partialValue / timebase.denom
    }

    private static func fileDescriptors(pid: Int32) -> [proc_fdinfo] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Leave room for descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return [] }
        return Array(fds.prefix(Int(filled) / stride))
    }

    /// TCP ports in LISTEN state owned by each pid (`PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO`).
    public static func listeningTCPPorts(pids: some Sequence<Int32>) -> [Int32: [UInt16]] {
        var result: [Int32: [UInt16]] = [:]
        for pid in pids {
            var ports: Set<UInt16> = []
            for fd in fileDescriptors(pid: pid) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let expected = Int32(MemoryLayout<socket_fdinfo>.size)
                let size = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, expected)
                guard size == expected else { continue }
                let socket = info.psi
                guard socket.soi_kind == Int32(SOCKINFO_TCP),
                    socket.soi_family == AF_INET || socket.soi_family == AF_INET6
                else { continue }
                let tcp = socket.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                let port = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)
                ports.insert(UInt16(bigEndian: port))
            }
            if !ports.isEmpty { result[pid] = ports.sorted() }
        }
        return result
    }

    /// Paths of regular files the process holds open, optionally filtered.
    public static func openFilePaths(pid: Int32, where include: (String) -> Bool = { _ in true }) -> [String] {
        var paths: [String] = []
        for fd in fileDescriptors(pid: pid) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let expected = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            let size = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, expected)
            guard size == expected else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty, include(path) { paths.append(path) }
        }
        return paths
    }
}

/// Caches `KERN_PROCARGS2` results per process identity, so argv is read once per process
/// (failed reads are cached too: other users' processes stay unreadable).
public final class ProcessArgumentsCache: Sendable {
    /// pid + start time survive `exec`; the command name doesn't, so it's part of the key.
    struct Key: Hashable {
        var identity: ProcessIdentity
        var comm: String
    }

    private let storage = Mutex<[Key: ProcessArguments?]>([:])
    private let reader: @Sendable (Int32) -> ProcessArguments?

    public init(reader: @escaping @Sendable (Int32) -> ProcessArguments? = { ProcessInspector.arguments(pid: $0) }) {
        self.reader = reader
    }

    /// Cached argv, reading it on first request unless `readIfMissing` is false.
    public func arguments(for process: ProcessSnapshot, readIfMissing: Bool = true) -> ProcessArguments? {
        let key = Key(identity: process.identity, comm: process.comm)
        if let cached = storage.withLock({ $0[key] }) { return cached }
        guard readIfMissing else { return nil }
        let arguments = reader(process.pid)
        storage.withLock { $0[key] = .some(arguments) }
        return arguments
    }

    public func isCached(_ process: ProcessSnapshot) -> Bool {
        storage.withLock { $0[Key(identity: process.identity, comm: process.comm)] != nil }
    }

    /// Drop entries for processes that are gone.
    public func retain(only live: Set<ProcessIdentity>) {
        storage.withLock { cache in
            cache = cache.filter { live.contains($0.key.identity) }
        }
    }

    public var count: Int { storage.withLock { $0.count } }
}
