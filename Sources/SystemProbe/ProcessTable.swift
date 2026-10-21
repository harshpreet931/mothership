import Darwin
import Foundation

/// A process identity that survives pid reuse: the pid plus its start time.
public struct ProcessIdentity: Hashable, Sendable, CustomStringConvertible {
    public var pid: Int32
    /// Start time in microseconds since 1970 (from `p_starttime`).
    public var startMicros: UInt64

    public init(pid: Int32, startMicros: UInt64) {
        self.pid = pid
        self.startMicros = startMicros
    }

    public var description: String { "\(pid)@\(startMicros)" }
}

/// One row of the kernel process table (`sysctl(KERN_PROC_ALL)`).
public struct ProcessSnapshot: Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    /// Foreground process group of the controlling terminal (`kp_eproc.e_tpgid`), or 0.
    public var tpgid: Int32
    public var uid: UInt32
    /// Up to 16 bytes of the executable name (`p_comm`).
    public var comm: String
    public var startMicros: UInt64
    /// Controlling terminal device, nil when the process has none.
    public var tty: Int32?
    /// `p_stat == SZOMB`.
    public var isZombie: Bool

    public init(
        pid: Int32, ppid: Int32, pgid: Int32 = 0, tpgid: Int32 = 0, uid: UInt32 = 0, comm: String,
        startMicros: UInt64 = 0, tty: Int32? = nil, isZombie: Bool = false
    ) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.tpgid = tpgid
        self.uid = uid
        self.comm = comm
        self.startMicros = startMicros
        self.tty = tty
        self.isZombie = isZombie
    }

    public var identity: ProcessIdentity { ProcessIdentity(pid: pid, startMicros: startMicros) }
    public var startTime: Date { Date(timeIntervalSince1970: Double(startMicros) / 1_000_000) }
    /// True when this process leads the terminal's foreground process group.
    public var isForegroundGroupLeader: Bool { tpgid != 0 && pgid == tpgid && pid == pgid }
}

public enum ProbeError: Error, Sendable, Equatable {
    case sysctlFailed(Int32)
}

/// An immutable snapshot of every process on the machine, with parent/child indexes.
public struct ProcessTable: Sendable {
    public let processes: [Int32: ProcessSnapshot]
    public let children: [Int32: [Int32]]
    public let capturedAt: Date

    public init(processes: [ProcessSnapshot], capturedAt: Date = Date()) {
        var byPID: [Int32: ProcessSnapshot] = [:]
        byPID.reserveCapacity(processes.count)
        var children: [Int32: [Int32]] = [:]
        for process in processes {
            byPID[process.pid] = process
            if process.ppid != process.pid {
                children[process.ppid, default: []].append(process.pid)
            }
        }
        self.processes = byPID
        self.children = children
        self.capturedAt = capturedAt
    }

    /// One `sysctl(KERN_PROC_ALL)` call. Costs well under a millisecond for ~1000 processes.
    public static func capture() throws -> ProcessTable {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
                throw ProbeError.sysctlFailed(errno)
            }
            // Processes can appear between the two calls; leave headroom and retry on ENOMEM.
            let capacity = size / stride + 32
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            size = capacity * stride
            let result = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue }
                throw ProbeError.sysctlFailed(errno)
            }
            let count = size / stride
            var snapshots: [ProcessSnapshot] = []
            snapshots.reserveCapacity(count)
            for index in 0..<count {
                snapshots.append(ProcessSnapshot(kinfo: buffer[index]))
            }
            return ProcessTable(processes: snapshots)
        }
        throw ProbeError.sysctlFailed(ENOMEM)
    }

    public subscript(pid: Int32) -> ProcessSnapshot? { processes[pid] }

    /// Ancestors nearest-first, excluding the process itself and stopping before launchd/kernel.
    public func ancestors(of pid: Int32) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var seen: Set<Int32> = [pid]
        var current = processes[pid]?.ppid
        while let next = current, next > 1, !seen.contains(next), let process = processes[next] {
            result.append(process)
            seen.insert(next)
            current = process.ppid
        }
        return result
    }

    public func isDescendant(_ pid: Int32, of ancestor: Int32) -> Bool {
        ancestors(of: pid).contains { $0.pid == ancestor }
    }

    /// Every descendant, breadth-first.
    public func descendants(of pid: Int32) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var queue = children[pid] ?? []
        var seen: Set<Int32> = [pid]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard seen.insert(next).inserted, let process = processes[next] else { continue }
            result.append(process)
            queue.append(contentsOf: children[next] ?? [])
        }
        return result
    }

    /// What's running in the foreground of the terminal that `shellPID` belongs to: the
    /// leader of the tty's foreground process group, or the shell itself when idle.
    public func foregroundProcess(forShell shellPID: Int32) -> ProcessSnapshot? {
        guard let shell = processes[shellPID] else { return nil }
        guard shell.tpgid > 0 else { return shell }
        if let leader = processes[shell.tpgid] { return leader }
        return processes.values.first { $0.pgid == shell.tpgid }
    }
}

extension ProcessSnapshot {
    init(kinfo: kinfo_proc) {
        var info = kinfo
        let start = info.kp_proc.p_un.__p_starttime
        let micros = UInt64(max(0, start.tv_sec)) * 1_000_000 + UInt64(max(0, Int64(start.tv_usec)))
        let comm = withUnsafeBytes(of: &info.kp_proc.p_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let tdev = info.kp_eproc.e_tdev
        self.init(
            pid: info.kp_proc.p_pid,
            ppid: info.kp_eproc.e_ppid,
            pgid: info.kp_eproc.e_pgid,
            tpgid: info.kp_eproc.e_tpgid,
            uid: info.kp_eproc.e_ucred.cr_uid,
            comm: comm,
            startMicros: micros,
            tty: tdev == -1 ? nil : tdev,
            isZombie: info.kp_proc.p_stat == SZOMB
        )
    }
}
