import Darwin
import ShipModel
import SystemProbe

/// Finds dev servers started from Mothership's shells: TCP sockets in LISTEN state owned by
/// any process descending from this app, attributed to a workspace by the nearest
/// ancestor (or the process itself) whose environment carries `MOTHERSHIP_WORKSPACE_ID`.
///
/// One `sysctl` for the process table plus `proc_pidinfo` on our own descendants only, so a
/// scan costs a few milliseconds; argv/env reads are cached per process identity.
actor PortScanner {
    private let arguments = ProcessArgumentsCache()
    private let appPID: Int32

    /// `rootPID` is this app unless a debug override points the scan at another tree.
    init(rootPID: Int32 = getpid()) {
        appPID = rootPID
    }

    func scan() -> [ListeningPort] {
        guard let table = try? ProcessTable.capture() else { return [] }
        let descendants = table.descendants(of: appPID)
        arguments.retain(only: Set(descendants.map(\.identity)))
        let listening = ProcessInspector.listeningTCPPorts(pids: descendants.map(\.pid))

        var byPort: [Int: ListeningPort] = [:]
        for (pid, ports) in listening {
            guard let process = table[pid] else { continue }
            let (workspace, surface) = owner(of: process, in: table)
            for port in ports {
                let candidate = ListeningPort(port: Int(port), process: process.comm, workspaceID: workspace, surfaceID: surface)
                // A socket shared by a parent and its workers is listed once, for the
                // process that has a workspace (or the first one seen).
                if let existing = byPort[candidate.port], existing.workspaceID != nil || workspace == nil { continue }
                byPort[candidate.port] = candidate
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    private func owner(of process: ProcessSnapshot, in table: ProcessTable) -> (WorkspaceID?, SurfaceID?) {
        let chain = [process] + table.ancestors(of: process.pid).prefix { $0.pid != appPID }
        for candidate in chain {
            guard let args = arguments.arguments(for: candidate), let workspace = args.mothershipWorkspace else { continue }
            return (workspace, args.mothershipSurface)
        }
        return (nil, nil)
    }
}
