import Foundation
import Testing

@testable import SystemProbe

@Suite("kqueue vnode watcher")
struct VnodeWatcherTests {
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "vnode-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The next change for `path`, or nil after `timeout`.
    func next(_ watcher: VnodeWatcher, for path: String, timeout: Double = 3) async -> FileChange? {
        await withTaskGroup(of: FileChange?.self) { group in
            group.addTask {
                for await batch in watcher.changes {
                    if let change = batch.first(where: { $0.path == path }) { return change }
                }
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

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func reportsAppendsQuickly() async throws {
        let directory = try temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "t.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let watcher = VnodeWatcher()
        defer { watcher.close() }
        #expect(watcher.isHealthy)
        #expect(watcher.watch(file.path))
        let started = Date()
        let writer = Task {
            try? await Task.sleep(for: .milliseconds(50))
            try? append("{\"n\":1}\n", to: file)
        }
        let change = await next(watcher, for: file.path)
        _ = await writer.value
        #expect(change?.isModified == true)
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(watcher.watch("/nonexistent/\(UUID().uuidString)") == false)
    }

    @Test func deletionAndRotationUnwatch() async throws {
        let directory = try temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "t.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let watcher = VnodeWatcher()
        defer { watcher.close() }
        watcher.watch(file.path)
        let remover = Task {
            try? await Task.sleep(for: .milliseconds(50))
            try? FileManager.default.removeItem(at: file)
        }
        let change = await next(watcher, for: file.path)
        _ = await remover.value
        #expect(change?.isRemoved == true)
        #expect(!watcher.watchedPaths.contains(file.path))
        // A new file at the same path can be watched again (rotation).
        try Data("{}\n".utf8).write(to: file)
        #expect(watcher.watch(file.path))
    }

    @Test func directoryReportsNewEntries() async throws {
        let directory = try temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = VnodeWatcher()
        defer { watcher.close() }
        watcher.watch(directory.path)
        let creator = Task {
            try? await Task.sleep(for: .milliseconds(50))
            try? Data("{}\n".utf8).write(to: directory.appending(path: "new.jsonl"))
        }
        let change = await next(watcher, for: directory.path)
        _ = await creator.value
        #expect(change?.isDirectory == true)
    }
}
