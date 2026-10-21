import Darwin
import Foundation
import Synchronization
import Testing
@testable import SessionHost

// MARK: - Framing

@Suite("Framing")
struct FramingTests {
    @Test func roundTripsAcrossArbitrarySplits() throws {
        let frames = [
            Frame(type: 0x20, payload: Data((0..<1000).map { UInt8($0 % 256) })),
            Frame(type: 0x01),
            Frame(type: 0x7F, payload: Data("{\"x\":1}".utf8)),
        ]
        let stream = frames.reduce(Data()) { $0 + $1.encoded }
        for split in [1, 2, 3, 5, 7, 64, stream.count] {
            var decoder = FrameDecoder()
            var decoded: [Frame] = []
            var index = 0
            while index < stream.count {
                let upper = min(index + split, stream.count)
                decoder.append(stream.subdata(in: index..<upper))
                while let frame = try decoder.next() { decoded.append(frame) }
                index = upper
            }
            #expect(decoded == frames, "split \(split)")
            #expect(decoder.bufferedByteCount == 0)
        }
    }

    @Test func bigFramesThroughVaryingReads() throws {
        var frames: [Frame] = []
        var stream = Data()
        for index in 0..<200 {
            let size = [65_536 + 24, 17, 300_000, 1, 65_536 * 3][index % 5]
            let frame = Frame(type: 0x20, payload: Data(repeating: UInt8(index % 251), count: size))
            frames.append(frame)
            stream.append(frame.encoded)
        }
        var decoder = FrameDecoder()
        var decoded: [Frame] = []
        var index = 0
        var reads = [262_144, 5, 70_000, 1, 131_072, 999]
        while index < stream.count {
            let size = reads.removeFirst()
            reads.append(size)
            let upper = min(index + size, stream.count)
            decoder.append(stream.subdata(in: index..<upper))
            while let frame = try decoder.next() { decoded.append(frame) }
            index = upper
        }
        #expect(decoded.count == frames.count)
        #expect(decoded == frames)
    }

    @Test func rejectsOversizeAndEmptyFrames() {
        var decoder = FrameDecoder()
        decoder.append(Data([0x7F, 0xFF, 0xFF, 0xFF, 0x01]))
        #expect(throws: FrameError.tooLarge(0x7FFF_FFFF)) { try decoder.next() }
        var empty = FrameDecoder()
        empty.append(Data([0, 0, 0, 0]))
        #expect(throws: FrameError.empty) { try empty.next() }
    }

    @Test func messagesRoundTrip() throws {
        let id = UUID()
        let messages: [SessionMessage] = [
            .hello(HelloMessage(client: "test", pid: 42)),
            .welcome(WelcomeMessage(pid: 7, sessionCount: 3)),
            .open(OpenRequest(
                requestID: 9, session: id, attachIfExists: true,
                spawn: SpawnSpec(executable: "/bin/zsh", arguments: ["-zsh"], environment: ["A": "b"], workingDirectory: "/tmp"),
                columns: 120, rows: 40, fromOffset: 77
            )),
            .opened(OpenedMessage(requestID: 9, session: id, created: false, pid: 5, outputOffset: 1234)),
            .output(session: id, offset: 1 << 40, data: Data([0x1B, 0x5B, 0x63, 0x00, 0xFF])),
            .replayEnd(session: id, suffix: Data("\u{1B}[?1h".utf8)),
            .input(session: id, data: Data("ls\r".utf8)),
            .resize(session: id, columns: 300, rows: 90, widthPixels: 2400, heightPixels: 1600),
            .flow(session: id, paused: true),
            .detach(session: id),
            .close(session: id),
            .signal(session: id, signal: SIGINT),
            .exited(ExitedMessage(session: id, exitCode: 130, signal: 2)),
            .list(ListRequest(requestID: 3)),
            .shutdown,
            .error(ErrorMessage(requestID: 1, session: id, code: .notFound, message: "gone")),
        ]
        for message in messages {
            var decoder = FrameDecoder()
            decoder.append(message.frame.encoded)
            let frame = try #require(try decoder.next())
            #expect(try SessionMessage(frame: frame) == message)
        }
        #expect(throws: SessionMessage.DecodeError.unknownType(0x66)) { try SessionMessage(frame: Frame(type: 0x66)) }
        #expect(throws: SessionMessage.DecodeError.malformed(0x20)) { try SessionMessage(frame: Frame(type: 0x20, payload: Data([1, 2]))) }
    }

    @Test func socketPathsSitNextToTheControlSocket() {
        #expect(SessionHostPaths.socket(forSupportDirectory: "/Users/u/Library/Application Support/Mothership") == "/Users/u/Library/Application Support/Mothership/sessions.sock")
        let deep = "/private/tmp/" + String(repeating: "scratch-", count: 12) + "home"
        let path = SessionHostPaths.socket(forSupportDirectory: deep)
        #expect(path.utf8.count < 104)
        #expect(path.hasSuffix("-sessions.sock"))
        #expect(path == SessionHostPaths.socket(forSupportDirectory: deep))
    }
}

// MARK: - Ring buffer

@Suite("Ring buffer")
struct RingBufferTests {
    @Test func keepsTheNewestBytesWithAbsoluteOffsets() {
        var ring = OutputRingBuffer(capacity: 10)
        ring.append(Data("hello".utf8))
        #expect(ring.bytes(from: 0) == Data("hello".utf8))
        #expect(!ring.hasWrapped)
        ring.append(Data(" world!".utf8))  // 12 bytes total, capacity 10
        #expect(ring.endOffset == 12)
        #expect(ring.startOffset == 2)
        #expect(ring.bytes(from: 0) == Data("llo world!".utf8))
        #expect(ring.bytes(from: 7) == Data("orld!".utf8))
        #expect(ring.bytes(from: 12).isEmpty)
        ring.append(Data(String(repeating: "z", count: 25).utf8))  // larger than capacity
        #expect(ring.bytes(from: 0) == Data(String(repeating: "z", count: 10).utf8))
        #expect(ring.endOffset == 37)
    }

    @Test func wrapsCorrectlyAcrossManySmallWrites() {
        var ring = OutputRingBuffer(capacity: 97)
        var reference = Data()
        for index in 0..<1000 {
            let chunk = Data((0..<(index % 13 + 1)).map { UInt8(($0 + index) % 251) })
            ring.append(chunk)
            reference.append(chunk)
        }
        #expect(ring.bytes(from: 0) == reference.suffix(97))
        #expect(ring.endOffset == UInt64(reference.count))
    }

    @Test func replayStartsAtALineBoundaryOnceWrapped() {
        var ring = OutputRingBuffer(capacity: 16)
        ring.append(Data("\u{1B}[31mfirst line\nsecond\nthird\n".utf8))
        let replay = ring.replay(from: 0)
        #expect(!replay.data.isEmpty)
        #expect(replay.data.first != 0x1B)  // never starts mid-sequence
        #expect(String(decoding: replay.data, as: UTF8.self).hasSuffix("third\n"))
        #expect(replay.startOffset > ring.startOffset)
        // A client that already has a prefix gets exactly the rest.
        #expect(ring.replay(from: ring.endOffset - 3).data == Data("rd\n".utf8))
    }
}

// MARK: - Mode tracker

@Suite("Mode tracker")
struct ModeTrackerTests {
    @Test func followsPrivateModesAcrossChunkBoundaries() {
        var tracker = TerminalModeTracker()
        let stream = Data("\u{1B}[?1049h\u{1B}[?1h\u{1B}=\u{1B}[?1000;1006h\u{1B}[?25l text \u{1B}[?2004h".utf8)
        for byte in stream { tracker.feed(Data([byte])) }  // one byte at a time
        #expect(tracker.isAlternateScreen)
        #expect(tracker.alternateScreenEnteredAt == 0)
        #expect(tracker.enabled == [1, 1000, 1006, 2004])
        #expect(tracker.cursorHidden)
        #expect(tracker.applicationKeypad)
        tracker.feed(Data("\u{1B}[?1000l\u{1B}[?1049l\u{1B}>\u{1B}[?25h".utf8))
        #expect(!tracker.isAlternateScreen)
        #expect(tracker.enabled == [1, 1006, 2004])
        #expect(!tracker.cursorHidden)
        #expect(!tracker.applicationKeypad)
        tracker.feed(Data("\u{1B}c".utf8))  // RIS
        #expect(tracker.enabled.isEmpty)
    }

    @Test func restoreReEntersTheAlternateScreenOnlyWhenItScrolledOut() {
        var tracker = TerminalModeTracker()
        tracker.feed(Data("prompt$ vim\n\u{1B}[?1049h\u{1B}[?1h".utf8))
        let enteredAt = try? #require(tracker.alternateScreenEnteredAt)
        #expect(enteredAt == 12)
        // The replay still holds the switch: just re-assert key modes.
        #expect(tracker.restoreSequence(replayStart: 0) == Data("\u{1B}[?1h".utf8))
        // The switch is gone from the replay: enter the alternate screen again.
        #expect(tracker.restoreSequence(replayStart: 100) == Data("\u{1B}[?1049h\u{1B}[?1h".utf8))
        #expect(TerminalModeTracker().restoreSequence(replayStart: 100).isEmpty)
    }

    @Test func ignoresNonPrivateAndOtherSequences() {
        var tracker = TerminalModeTracker()
        tracker.feed(Data("\u{1B}[4h\u{1B}[1;31m\u{1B}[?2026$p\u{1B}]0;title\u{07}".utf8))
        #expect(tracker.enabled.isEmpty)
        #expect(!tracker.isAlternateScreen)
    }
}

// MARK: - Host end to end

/// The built `mshipd` (the PTY trampoline). `swift test` builds every product.
let mshipdBinary: String? = {
    let fileManager = FileManager.default
    var candidates = Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent().appending(path: "mshipd").path }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    candidates.append(root.appending(path: ".build/debug/mshipd").path)
    return candidates.first { fileManager.isExecutableFile(atPath: $0) }
}()

/// Collects one session's events.
final class EventLog: Sendable {
    /// Output is kept to the last MB (floods only check the end) plus a running count.
    private let state = Mutex<(output: Data, total: Int, replayEnded: Bool, exited: ExitedMessage?, disconnected: Bool)>((Data(), 0, false, nil, false))

    var handler: @Sendable (SessionEvent) -> Void {
        { [self] event in
            state.withLock { state in
                switch event {
                case .output(_, let data):
                    state.total += data.count
                    state.output.append(data)
                    if state.output.count > 2 * 1024 * 1024 { state.output = state.output.suffix(1024 * 1024) }
                case .replayEnd(let suffix):
                    state.output.append(suffix)
                    state.total += suffix.count
                    state.replayEnded = true
                case .exited(let exited): state.exited = exited
                case .disconnected: state.disconnected = true
                }
            }
        }
    }

    var text: String { state.withLock { String(decoding: $0.output, as: UTF8.self) } }
    var byteCount: Int { state.withLock { $0.total } }
    var exited: ExitedMessage? { state.withLock { $0.exited } }
    var replayEnded: Bool { state.withLock { $0.replayEnded } }
    var disconnected: Bool { state.withLock { $0.disconnected } }

    func waitFor(_ timeout: Double = 5, _ condition: (EventLog) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(self) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(self)
    }
}

func shellSpec(_ script: String) -> SpawnSpec {
    SpawnSpec(
        executable: "/bin/sh", arguments: ["/bin/sh", "-c", script],
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "TERM": "xterm-256color", "LANG": "en_US.UTF-8"],
        workingDirectory: "/tmp"
    )
}

/// A host on a fresh socket, stopped afterwards.
func withHost(
    capacity: Int = 1024 * 1024, idleExit: Duration? = nil, log: @escaping @Sendable (String) -> Void = { _ in },
    _ body: (SessionHostServer, String) async throws -> Void
) async throws {
    let trampoline = try #require(mshipdBinary, "mshipd isn't built")
    let path = "/tmp/mshipd-t-\(UUID().uuidString.prefix(8)).sock"
    let server = SessionHostServer(configuration: .init(socketPath: path, trampoline: trampoline, bufferCapacity: capacity, idleExit: idleExit, log: log))
    try server.start()
    do {
        try await body(server, path)
    } catch {
        server.stop()
        throw error
    }
    server.stop()
}

@Suite("Session host", .serialized)
struct SessionHostEndToEndTests {
    @Test func createEchoReattachAndClose() async throws {
        try await withHost { server, path in
            let client = try SessionHostClient.connect(socketPath: path, client: "test")
            #expect(client.welcome.version == SessionProtocol.version)
            #expect(client.welcome.pid == getpid())

            let id = UUID()
            let log = EventLog()
            client.setHandler(for: id, log.handler)
            let opened = try await client.open(session: id, attachIfExists: true, spawn: shellSpec("echo hello-from-host; stty -echo; exec cat"), columns: 80, rows: 24)
            #expect(opened.created)
            #expect(opened.pid > 0)
            #expect(await log.waitFor { $0.text.contains("hello-from-host") })
            client.input(Data("typed-line\n".utf8), to: id)
            #expect(await log.waitFor { $0.text.contains("typed-line") })

            // Detach (the app quits); the session keeps running and buffering.
            client.detach(id)
            client.close()
            try await Task.sleep(for: .milliseconds(100))
            #expect(server.sessionCount == 1)

            // A new app instance reattaches: the replay carries everything so far.
            let second = try SessionHostClient.connect(socketPath: path, client: "test-2")
            #expect(second.welcome.sessionCount == 1)
            let replayed = EventLog()
            second.setHandler(for: id, replayed.handler)
            let reattached = try await second.open(session: id, attachIfExists: true, spawn: nil, columns: 80, rows: 24)
            #expect(!reattached.created)
            #expect(reattached.pid == opened.pid)
            #expect(await replayed.waitFor { $0.replayEnded })
            #expect(replayed.text.contains("hello-from-host"))
            #expect(replayed.text.contains("typed-line"))
            // Live output still flows after the replay.
            second.input(Data("after-reattach\n".utf8), to: id)
            #expect(await replayed.waitFor { $0.text.contains("after-reattach") })

            let listed = try await second.list()
            #expect(listed.map(\.session) == [id])
            #expect(listed.first?.attachedClients == 1)

            second.closeSession(id)
            #expect(await waitUntil { server.sessionCount == 0 })
            second.close()
        }
    }

    @Test func reconnectReplaysOnlyWhatWasMissed() async throws {
        try await withHost { _, path in
            let client = try SessionHostClient.connect(socketPath: path)
            let id = UUID()
            let log = EventLog()
            client.setHandler(for: id, log.handler)
            _ = try await client.open(session: id, attachIfExists: false, spawn: shellSpec("echo one; sleep 0.3; echo two; exec sleep 30"), columns: 80, rows: 24)
            #expect(await log.waitFor { $0.text.contains("one") })
            let have = UInt64(log.byteCount)
            client.detach(id)
            try await Task.sleep(for: .milliseconds(500))
            let rest = EventLog()
            client.setHandler(for: id, rest.handler)
            let opened = try await client.open(session: id, attachIfExists: true, spawn: nil, columns: 80, rows: 24, fromOffset: have)
            #expect(!opened.created)
            #expect(await rest.waitFor { $0.replayEnded })
            #expect(rest.text.contains("two"))
            #expect(!rest.text.contains("one"))
            client.closeSession(id)
        }
    }

    @Test func attachToAMissingSessionWithoutSpawnFails() async throws {
        try await withHost { _, path in
            let client = try SessionHostClient.connect(socketPath: path)
            await #expect(throws: SessionHostClientError.self) {
                _ = try await client.open(session: UUID(), attachIfExists: true, spawn: nil, columns: 80, rows: 24)
            }
        }
    }

    @Test func resizeDeliversSIGWINCHWithTheNewSize() async throws {
        try await withHost { _, path in
            let client = try SessionHostClient.connect(socketPath: path)
            let id = UUID()
            let log = EventLog()
            client.setHandler(for: id, log.handler)
            _ = try await client.open(
                session: id, attachIfExists: false,
                spawn: shellSpec("trap 'echo size=$(stty size)' WINCH; echo ready; while :; do sleep 0.05; done"),
                columns: 80, rows: 24
            )
            #expect(await log.waitFor { $0.text.contains("ready") })
            client.resize(id, columns: 132, rows: 41)
            #expect(await log.waitFor { $0.text.contains("size=41 132") }, "\(log.text)")
            client.closeSession(id)
        }
    }

    @Test func programExitIsReportedWithItsStatus() async throws {
        try await withHost { server, path in
            let client = try SessionHostClient.connect(socketPath: path)
            let id = UUID()
            let log = EventLog()
            client.setHandler(for: id, log.handler)
            _ = try await client.open(session: id, attachIfExists: false, spawn: shellSpec("echo bye; exit 3"), columns: 80, rows: 24)
            #expect(await log.waitFor { $0.exited != nil })
            #expect(log.exited?.exitCode == 3)
            #expect(log.text.contains("bye"))
            #expect(await waitUntil { server.sessionCount == 0 })
        }
    }

    @Test func closingHangsUpTheWholeProcessGroup() async throws {
        try await withHost { server, path in
            let client = try SessionHostClient.connect(socketPath: path)
            let id = UUID()
            let log = EventLog()
            client.setHandler(for: id, log.handler)
            let opened = try await client.open(session: id, attachIfExists: false, spawn: shellSpec("sleep 300"), columns: 80, rows: 24)
            try await Task.sleep(for: .milliseconds(200))
            client.closeSession(id)
            #expect(await waitUntil { server.sessionCount == 0 })
            #expect(kill(opened.pid, 0) != 0)
        }
    }

    @Test func childIsASessionLeaderWithAControllingTerminal() async throws {
        try await withHost { _, path in
            let client = try SessionHostClient.connect(socketPath: path)
            let id = UUID()
            let log = EventLog()
            client.setHandler(for: id, log.handler)
            let opened = try await client.open(
                session: id, attachIfExists: false,
                spawn: shellSpec(#"set -- $(ps -o pid=,sess=,tpgid= -p $$); tty >/dev/null && echo ctty=yes; [ "$1" = "$3" ] && echo fg=yes; sleep 5"#),
                columns: 80, rows: 24
            )
            #expect(await log.waitFor { $0.text.contains("fg=yes") }, "\(log.text)")
            #expect(log.text.contains("ctty=yes"))
            #expect(getsid(opened.pid) == opened.pid)
            client.closeSession(id)
        }
    }

    @Test func idleHostExitsAfterLastSessionAndClient() async throws {
        let exited = Mutex(false)
        try await withHost(idleExit: .milliseconds(300)) { server, path in
            server.onExit = { exited.withLock { $0 = true } }
            let client = try SessionHostClient.connect(socketPath: path)
            let id = UUID()
            client.setHandler(for: id, EventLog().handler)
            _ = try await client.open(session: id, attachIfExists: false, spawn: shellSpec("exit 0"), columns: 80, rows: 24)
            try await Task.sleep(for: .milliseconds(600))
            #expect(!exited.withLock { $0 })  // a client is still attached
            client.close()
            #expect(await waitUntil(timeout: 3) { exited.withLock { $0 } })
        }
    }

    @Test func slowClientsPauseThePTYInsteadOfBufferingForever() async throws {
        let hostLog = Mutex<[String]>([])
        try await withHost(capacity: 64 * 1024, log: { line in hostLog.withLock { $0.append(line) } }) { _, path in
            let client = try SessionHostClient.connect(socketPath: path)
            let id = UUID()
            let log = EventLog()
            client.setHandler(for: id, log.handler)
            _ = try await client.open(session: id, attachIfExists: false, spawn: shellSpec("yes flood | head -c 3000000; echo; echo done-flood"), columns: 80, rows: 24)
            client.setPaused(true, session: id)
            try await Task.sleep(for: .milliseconds(300))
            let whilePaused = log.byteCount
            try await Task.sleep(for: .milliseconds(300))
            #expect(log.byteCount - whilePaused < 512 * 1024, "kept streaming while paused")
            client.setPaused(false, session: id)
            let finished = await log.waitFor(20) { $0.text.contains("done-flood") }
            #expect(finished, "received \(log.byteCount) bytes; host: \(hostLog.withLock { $0.suffix(6) })")
            client.closeSession(id)
        }
    }

    // MARK: Performance

    @Test func echoLatencyThroughTheHost() async throws {
        // Baseline: write to a PTY master and read the line discipline's echo directly.
        var master: Int32 = -1
        var slave: Int32 = -1
        #expect(openpty(&master, &slave, nil, nil, nil) == 0)
        var direct: [Double] = []
        var byte: UInt8 = 0
        for _ in 0..<300 {
            var key: UInt8 = 0x61
            let start = DispatchTime.now().uptimeNanoseconds
            _ = write(master, &key, 1)
            _ = read(master, &byte, 1)
            direct.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        close(master)
        close(slave)

        try await withHost { _, path in
            let client = try SessionHostClient.connect(socketPath: path)
            let id = UUID()
            // The handler stamps the echo and signals; the measuring thread sleeps on the
            // semaphore (spinning on a lock the handler needs would measure the lock instead).
            let echoed = DispatchSemaphore(value: 0)
            let stamp = Atomic<UInt64>(0)
            client.setHandler(for: id) { event in
                guard case .output(_, let data) = event, data.contains(0x61) else { return }
                stamp.store(DispatchTime.now().uptimeNanoseconds, ordering: .sequentiallyConsistent)
                echoed.signal()
            }
            _ = try await client.open(session: id, attachIfExists: false, spawn: shellSpec("exec sleep 60"), columns: 80, rows: 24)
            try await Task.sleep(for: .milliseconds(200))
            let viaHost: [Double] = try await offPool {
                var samples: [Double] = []
                for _ in 0..<300 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    client.input(Data([0x61]), to: id)
                    guard echoed.wait(timeout: .now() + 1) == .success else { continue }
                    samples.append(Double(stamp.load(ordering: .sequentiallyConsistent) - start) / 1000)
                    usleep(500)
                }
                return samples
            }
            client.closeSession(id)
            func percentile(_ values: [Double], _ p: Double) -> Double {
                let sorted = values.sorted()
                return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
            }
            let extraP50 = percentile(viaHost, 0.5) - percentile(direct, 0.5)
            let extraP95 = percentile(viaHost, 0.95) - percentile(direct, 0.95)
            print("""
                echo latency (µs): direct PTY p50 \(String(format: "%.1f", percentile(direct, 0.5))) p95 \(String(format: "%.1f", percentile(direct, 0.95))); \
                via mshipd p50 \(String(format: "%.1f", percentile(viaHost, 0.5))) p95 \(String(format: "%.1f", percentile(viaHost, 0.95))); \
                extra p50 \(String(format: "%.1f", extraP50)) p95 \(String(format: "%.1f", extraP95))
                """)
            #expect(viaHost.count > 250)
            #expect(percentile(viaHost, 0.95) < 1000, "p95 through the host must stay under 1 ms")
        }
    }

    @Test func throughput() async throws {
        let workload = "head -c 50000000 /dev/zero | tr '\\0' 'x'; echo; echo end-of-stream"
        // Baseline: the same output read straight off a PTY.
        let trampoline = try #require(mshipdBinary)
        let spawned = try PTYSpawner.spawn(shellSpec(workload), columns: 200, rows: 50, trampoline: trampoline)
        let directSeconds: Double = try await offPool {
            let start = Date()
            var tail = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while Date().timeIntervalSince(start) < 60 {
                var descriptor = pollfd(fd: spawned.master, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 1000) > 0 else { continue }
                let count = buffer.withUnsafeMutableBytes { read(spawned.master, $0.baseAddress, $0.count) }
                if count > 0 {
                    tail.append(contentsOf: buffer[0..<count])
                    if tail.count > 4096 { tail = tail.suffix(1024) }
                    if String(decoding: tail, as: UTF8.self).contains("end-of-stream") { break }
                } else if count < 0, errno == EAGAIN || errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            return Date().timeIntervalSince(start)
        }
        kill(-spawned.pid, SIGKILL)
        close(spawned.master)
        try await withHost { _, path in
            let client = try SessionHostClient.connect(socketPath: path)
            let id = UUID()
            let log = EventLog()
            client.setHandler(for: id, log.handler)
            let start = Date()
            _ = try await client.open(session: id, attachIfExists: false, spawn: shellSpec(workload), columns: 200, rows: 50)
            #expect(await log.waitFor(60) { $0.text.hasSuffix("end-of-stream\r\n") })
            let seconds = Date().timeIntervalSince(start)
            print("throughput, 50 MB: direct PTY \(String(format: "%.0f", 50 / directSeconds)) MB/s; through mshipd \(String(format: "%.0f", 50 / seconds)) MB/s")
            client.closeSession(id)
        }
    }
}

func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Runs blocking work on a GCD thread, off the cooperative pool.
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInteractive).async { continuation.resume(with: Result { try body() }) }
    }
}
