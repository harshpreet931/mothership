import ShipModel

// SystemProbe: Darwin process/file probes used by AgentKit. No subprocesses, no AppKit.
//
// - `ProcessTable`        one sysctl(KERN_PROC_ALL) snapshot with parent/child indexes
// - `ProcessInspector`    argv/env (KERN_PROCARGS2), cwd, CPU time, listening ports, open files
// - `ProcessExitWatcher`  kqueue EVFILT_PROC/NOTE_EXIT → AsyncStream<pid>
// - `FileSystemWatcher`   FSEvents (file-level) → AsyncStream<[FileChange]>
// - `HostAppResolver`     owning GUI app / multiplexer for a pid
// - `GitProbe`            repo root + branch from .git/HEAD (worktree-aware)

extension ProcessArguments {
    /// The Mothership surface this process was spawned in, from its inherited environment.
    public var mothershipSurface: SurfaceID? {
        SurfaceID(string: environment[ShipEnvironment.surfaceID])
    }

    public var mothershipWorkspace: WorkspaceID? {
        WorkspaceID(string: environment[ShipEnvironment.workspaceID])
    }
}
