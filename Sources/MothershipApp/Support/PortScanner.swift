import Darwin
import ShipModel
import SystemProbe

/// Finds dev servers started from Mothership's shells: TCP sockets in LISTEN state owned by
/// any process descending from this app, attributed to a workspace by the nearest
/// ancestor (or the process itself) whose environment carries `MOTHERSHIP_WORKSPACE_ID`.
///
/// Walks only our own process tree (`proc_listchildpids`), never the ~1000-row system
/// table, so an idle scan is a handful of libproc calls. Owner lookups (argv/env reads)
/// are cached per pid and name.
actor PortScanner {
    private struct OwnerKey: Hashable {
        var pid: Int32
        var name: String
    }

    private struct Owner {
        var workspace: WorkspaceID?
        var surface: SurfaceID?
    }

    private let appPID: Int32
    private var owners: [OwnerKey: Owner] = [:]

    /// `rootPID` is this app unless a debug override points the scan at another tree.
    init(rootPID: Int32 = getpid()) {
        appPID = rootPID
    }

    func scan() -> [ListeningPort] {
        var parent: [Int32: Int32] = [:]
        var descendants: [Int32] = []
        var queue = [appPID]
        while let pid = queue.popLast(), descendants.count < 4096 {
            for child in ProcessInspector.childPIDs(of: pid) where child != appPID && parent[child] == nil {
                parent[child] = pid
                descendants.append(child)
                queue.append(child)
            }
        }
        let listening = ProcessInspector.listeningTCPPorts(pids: descendants)
        let live = Set(descendants)
        owners = owners.filter { live.contains($0.key.pid) }
        guard !listening.isEmpty else { return [] }

        var byPort: [Int: ListeningPort] = [:]
        for (pid, ports) in listening {
            let name = ProcessInspector.name(pid: pid) ?? "process"
            let owner = owner(of: pid, parent: parent)
            for port in ports {
                let candidate = ListeningPort(
                    port: Int(port), process: name, workspaceID: owner.workspace, surfaceID: owner.surface
                )
                // A socket shared by a parent and its workers is listed once, for the
                // process that has a workspace (or the first one seen).
                if let existing = byPort[candidate.port], existing.workspaceID != nil || owner.workspace == nil { continue }
                byPort[candidate.port] = candidate
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    private func owner(of pid: Int32, parent: [Int32: Int32]) -> Owner {
        var current: Int32? = pid
        while let candidate = current, candidate != appPID {
            if let owner = environmentOwner(of: candidate), owner.workspace != nil { return owner }
            current = parent[candidate]
        }
        return Owner()
    }

    private func environmentOwner(of pid: Int32) -> Owner? {
        guard let name = ProcessInspector.name(pid: pid) else { return nil }
        let key = OwnerKey(pid: pid, name: name)
        if let cached = owners[key] { return cached }
        let args = ProcessInspector.arguments(pid: pid)
        let owner = Owner(workspace: args?.mothershipWorkspace, surface: args?.mothershipSurface)
        owners[key] = owner
        return owner
    }
}
