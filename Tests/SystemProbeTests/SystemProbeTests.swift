import Darwin
import Foundation
import Testing

@testable import SystemProbe

@Suite("Process table")
struct ProcessTableTests {
    @Test func capturesSelf() throws {
        let table = try ProcessTable.capture()
        let me = try #require(table[getpid()])
        #expect(me.ppid == getppid())
        #expect(me.uid == getuid())
        #expect(!me.comm.isEmpty)
        #expect(me.startTime < Date())
        #expect(table.descendants(of: getppid()).contains { $0.pid == getpid() })
        #expect(table.isDescendant(getpid(), of: getppid()))
        #expect(table.processes.count > 10)
    }

    @Test func ancestorsAndForeground() {
        let table = ProcessTable(processes: [
            ProcessSnapshot(pid: 10, ppid: 1, pgid: 10, comm: "Terminal"),
            ProcessSnapshot(pid: 11, ppid: 10, pgid: 11, tpgid: 12, comm: "zsh"),
            ProcessSnapshot(pid: 12, ppid: 11, pgid: 12, tpgid: 12, comm: "claude"),
            ProcessSnapshot(pid: 13, ppid: 12, pgid: 12, tpgid: 12, comm: "node"),
        ])
        #expect(table.ancestors(of: 13).map(\.pid) == [12, 11, 10])
        #expect(table.descendants(of: 10).map(\.pid) == [11, 12, 13])
        #expect(table.foregroundProcess(forShell: 11)?.pid == 12)
        #expect(table[12]?.isForegroundGroupLeader == true)
        #expect(table[13]?.isForegroundGroupLeader == false)
    }

    @Test func cyclesDoNotHang() {
        let table = ProcessTable(processes: [
            ProcessSnapshot(pid: 20, ppid: 21, comm: "a"),
            ProcessSnapshot(pid: 21, ppid: 20, comm: "b"),
        ])
        #expect(table.ancestors(of: 20).map(\.pid) == [21])
    }
}

@Suite("Process inspector")
struct ProcessInspectorTests {
    @Test func readsOwnArgumentsAndEnvironment() throws {
        let arguments = try #require(ProcessInspector.arguments(pid: getpid()))
        #expect(arguments.arguments == CommandLine.arguments)
        #expect(arguments.environment["PATH"] == ProcessInfo.processInfo.environment["PATH"])
        #expect(!arguments.executablePath.isEmpty)
        #expect(ProcessInspector.executablePath(pid: getpid()) != nil)
    }

    @Test func parsesProcArgsLayout() throws {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { bytes += $0 }
        bytes += Array("/usr/bin/tool".utf8) + [0, 0, 0]
        bytes += Array("tool".utf8) + [0] + Array("--flag".utf8) + [0]
        bytes += Array("A=1".utf8) + [0] + Array("MOTHERSHIP_SURFACE_ID=x=y".utf8) + [0, 0]
        let parsed = try #require(ProcessInspector.parseProcArgs(bytes))
        #expect(parsed.executablePath == "/usr/bin/tool")
        #expect(parsed.arguments == ["tool", "--flag"])
        #expect(parsed.environment == ["A": "1", "MOTHERSHIP_SURFACE_ID": "x=y"])
        #expect(ProcessInspector.parseProcArgs([1, 0]) == nil)
    }

    @Test func childAndDescendantPIDs() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate() }
        let pid = process.processIdentifier
        #expect(ProcessInspector.childPIDs(of: getpid()).contains(pid))
        #expect(ProcessInspector.descendantPIDs(of: getpid()).contains(pid))
        #expect(ProcessInspector.descendantPIDs(of: pid).isEmpty)
        #expect(ProcessInspector.name(pid: pid) == "sleep")
        #expect(ProcessInspector.name(pid: 999_999) == nil)
        #expect(ProcessInspector.childPIDs(of: 999_999).isEmpty)
    }

    @Test func workingDirectoryAndCPU() throws {
        let cwd = try #require(ProcessInspector.workingDirectory(pid: getpid()))
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == expected)
        let cpu = try #require(ProcessInspector.cpuTimeNanos(pid: getpid()))
        #expect(cpu > 0)
        #expect(ProcessInspector.arguments(pid: 999_999) == nil)
        #expect(ProcessInspector.workingDirectory(pid: 999_999) == nil)
    }

    @Test func findsListeningPort() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(fd, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        let ports = ProcessInspector.listeningTCPPorts(pids: [getpid()])
        #expect(ports[getpid()]?.contains(port) == true)
    }

    @Test func listsOpenFiles() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "open-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let paths = ProcessInspector.openFilePaths(pid: getpid()) { $0.hasSuffix(url.lastPathComponent) }
        #expect(paths.count == 1)
    }

    @Test func argumentsCacheReadsOnce() {
        final class Counter: @unchecked Sendable {
            // Only touched from the single-threaded test body.
            var reads = 0
        }
        let counter = Counter()
        let cache = ProcessArgumentsCache { pid in
            counter.reads += 1
            return pid == 1 ? nil : ProcessArguments(executablePath: "/bin/x", arguments: ["x"])
        }
        let process = ProcessSnapshot(pid: 7, ppid: 1, comm: "x", startMicros: 5)
        _ = cache.arguments(for: process)
        _ = cache.arguments(for: process)
        let failing = ProcessSnapshot(pid: 1, ppid: 0, comm: "launchd", startMicros: 1)
        _ = cache.arguments(for: failing)
        _ = cache.arguments(for: failing)
        #expect(counter.reads == 2)
        #expect(cache.arguments(for: ProcessSnapshot(pid: 7, ppid: 1, comm: "x", startMicros: 6), readIfMissing: false) == nil)
        cache.retain(only: [])
        #expect(cache.count == 0)
    }
}

@Suite("Watchers")
struct WatcherTests {
    @Test func exitWatcherReportsExit() async throws {
        let watcher = ProcessExitWatcher()
        defer { watcher.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.2"]
        try process.run()
        let pid = process.processIdentifier
        watcher.watch(pid)
        #expect(watcher.watchedPIDs.contains(pid))
        let exited = await firstValue(of: watcher.exits, timeout: 5)
        #expect(exited == pid)
        #expect(watcher.watchedPIDs.isEmpty)
    }

    @Test func exitWatcherReportsAlreadyDeadProcess() async throws {
        let watcher = ProcessExitWatcher()
        defer { watcher.close() }
        watcher.watch(999_998)
        #expect(await firstValue(of: watcher.exits, timeout: 2) == 999_998)
    }

    @Test(.enabled(if: FileSystemWatcher.isAvailable, "FSEvents can't register a client in this environment"))
    func fileWatcherSeesWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "fsevents-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = FileSystemWatcher(paths: [directory.path], latency: 0.05)
        defer { watcher.finish() }
        #expect(watcher.start())
        let file = directory.appending(path: "transcript.jsonl")
        let writer = Task {
            for index in 0..<20 {
                try? Data("{\"n\":\(index)}\n".utf8).write(to: file)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { writer.cancel() }
        let target = file.resolvingSymlinksInPath().path
        let found = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await batch in watcher.changes where batch.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == target }) {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(found)
    }

    @Test func fileWatcherWithoutPathsDoesNotStart() {
        let watcher = FileSystemWatcher(paths: ["/nonexistent/\(UUID().uuidString)"])
        #expect(watcher.start() == false)
        watcher.finish()
    }

    func firstValue(of stream: AsyncStream<Int32>, timeout: Double) async -> Int32? {
        await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                for await value in stream { return value }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

@Suite("Host app")
struct HostAppTests {
    @Test func outermostBundle() {
        #expect(HostAppResolver.outermostAppBundle(in: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper") == "/Applications/Visual Studio Code.app")
        #expect(HostAppResolver.outermostAppBundle(in: "/usr/bin/login") == nil)
    }

    @Test func resolvesThroughAncestors() {
        let paths: [Int32: String] = [
            2: "/Applications/FakeTerm.app/Contents/MacOS/FakeTerm", 3: "/usr/bin/login", 4: "/bin/zsh", 5: "/Users/u/.local/bin/claude",
            10: "/opt/homebrew/bin/tmux", 11: "/bin/zsh", 12: "/Users/u/.local/bin/claude",
            20: "/Applications/FakeGhost.app/Contents/MacOS/ghost", 21: "/usr/bin/login", 22: "/bin/zsh", 23: "/opt/homebrew/bin/tmux", 24: "/opt/homebrew/bin/codex",
        ]
        let table = ProcessTable(processes: [
            ProcessSnapshot(pid: 2, ppid: 1, comm: "iTerm2"), ProcessSnapshot(pid: 3, ppid: 2, comm: "login"),
            ProcessSnapshot(pid: 4, ppid: 3, comm: "zsh"), ProcessSnapshot(pid: 5, ppid: 4, comm: "claude"),
            ProcessSnapshot(pid: 10, ppid: 1, comm: "tmux"), ProcessSnapshot(pid: 11, ppid: 10, comm: "zsh"),
            ProcessSnapshot(pid: 12, ppid: 11, comm: "claude"),
            ProcessSnapshot(pid: 20, ppid: 1, comm: "ghostty"), ProcessSnapshot(pid: 21, ppid: 20, comm: "login"),
            ProcessSnapshot(pid: 22, ppid: 21, comm: "zsh"), ProcessSnapshot(pid: 23, ppid: 22, comm: "tmux"),
            ProcessSnapshot(pid: 24, ppid: 23, comm: "codex"),
        ])
        let resolver = HostAppResolver { paths[$0] }
        #expect(resolver.hostApp(for: 5, in: table) == "FakeTerm")
        #expect(resolver.hostApp(for: 12, in: table) == "tmux")
        #expect(resolver.hostApp(for: 24, in: table) == "tmux")
        #expect(resolver.hostApp(for: 4, in: table) == "FakeTerm")
    }

    /// A bundle's name comes from its identifier, whatever its folder is called.
    @Test func resolvesNameFromBundleIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hostapp-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ name: String, identifier: String) throws -> String {
            let contents = root.appending(path: "\(name).app/Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
            try plist.write(to: contents.appending(path: "Info.plist"))
            return root.appending(path: "\(name).app").path
        }
        let resolver = HostAppResolver()
        #expect(resolver.displayName(forBundle: try bundle("Code", identifier: "com.microsoft.VSCode")) == "Visual Studio Code")
        #expect(resolver.displayName(forBundle: try bundle("Mystery Tool", identifier: "com.example.unknown")) == "Mystery Tool")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Visual Studio Code.app"), "VS Code not installed"))
    func resolvesRealVSCodeNameWhenInstalled() {
        #expect(HostAppResolver().displayName(forBundle: "/Applications/Visual Studio Code.app") == "Visual Studio Code")
    }
}

@Suite("Git")
struct GitProbeTests {
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "git-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func branchFromHEAD() throws {
        let repo = try temp()
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/feature/login\n".utf8).write(to: repo.appending(path: ".git/HEAD"))
        let nested = repo.appending(path: "Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let info = try #require(GitProbe.info(forDirectory: nested.path))
        #expect(info.repoRoot == repo.path)
        #expect(info.branch == "feature/login")
        #expect(info.isLinkedWorktree == false)
    }

    @Test func detachedHEAD() throws {
        let repo = try temp()
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        try Data("3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a\n".utf8).write(to: repo.appending(path: ".git/HEAD"))
        let info = try #require(GitProbe.info(forDirectory: repo.path))
        #expect(info.branch == nil)
        #expect(info.detachedCommit == "3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a")
    }

    @Test func linkedWorktree() throws {
        let base = try temp()
        defer { try? FileManager.default.removeItem(at: base) }
        let gitDir = base.appending(path: "main/.git/worktrees/task-1")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("ref: refs/heads/task-1\n".utf8).write(to: gitDir.appending(path: "HEAD"))
        let worktree = base.appending(path: "main.worktrees/task-1")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: ../../main/.git/worktrees/task-1\n".utf8).write(to: worktree.appending(path: ".git"))
        let info = try #require(GitProbe.info(forDirectory: worktree.path))
        #expect(info.repoRoot == worktree.path)
        #expect(info.branch == "task-1")
        #expect(info.isLinkedWorktree)
        #expect(info.gitDirectory == gitDir.standardizedFileURL.path)
    }

    @Test func notARepo() {
        #expect(GitProbe.info(forDirectory: "/") == nil || GitProbe.info(forDirectory: "/")?.repoRoot == "/")
        #expect(GitProbe.parseHEAD("ref: refs/remotes/origin/main").branch == "refs/remotes/origin/main")
    }
}
