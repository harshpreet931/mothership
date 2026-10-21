import Darwin
import Foundation
import Testing
@testable import ControlPlane
import ShipModel
import ShipProtocol

/// Starts a server on a fresh temp socket and stops it when `body` returns.
func withServer(
    _ router: ControlRouter = ControlRouter(), maxLineBytes: Int = ControlServer.defaultMaxLineBytes,
    _ body: (ControlServer, String) async throws -> Void
) async throws {
    let path = tempSocketPath()
    let server = ControlServer(socketPath: path, handler: router, maxLineBytes: maxLineBytes)
    try await server.start()
    do {
        try await body(server, path)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

@Suite("ControlServer")
struct ControlServerTests {
    @Test func clientRoundTrip() async throws {
        let router = ControlRouter()
        let received = Box<NotifyParams>()
        router.on(.notify) { (params: NotifyParams, _) in
            await received.set(params)
            return OKResult()
        }
        try await withServer(router) { _, path in
            let client = ControlClient(socketPath: path, caller: CallerContext())
            let ok: OKResult = try await client.callAsync(.notify, NotifyParams(title: "Build done", body: "All green"))
            #expect(ok.ok)
            #expect(await received.value == NotifyParams(title: "Build done", body: "All green"))

            let pong: PingResult = try await client.callAsync(.ping, OKResult())
            #expect(pong.pid == getpid())
            #expect(pong.version == ShipInfo.version)
        }
    }

    @Test func socketFileIsPrivateAndRemovedOnStop() async throws {
        let path = tempSocketPath()
        let server = ControlServer(socketPath: path, handler: ControlRouter())
        try await server.start()
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        await server.stop()
        #expect(lstat(path, &info) != 0)
    }

    @Test func createsMissingParentDirectory() async throws {
        let directory = "/tmp/mship-d-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/nested/c.sock"
        let server = ControlServer(socketPath: path, handler: ControlRouter())
        try await server.start()
        let pong: PingResult = try await ControlClient(socketPath: path).callAsync(.ping, OKResult())
        #expect(pong.ok)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory + "/nested")
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        await server.stop()
    }

    @Test func heldHookDoesNotBlockPingOnSameOrOtherConnection() async throws {
        let router = ControlRouter()
        let gate = Gate()
        router.on(.hook) { (hook: HookEnvelope, _) async -> HookReply in
            await gate.wait()
            return HookReply(stdout: "decided \(hook.event)", exitCode: 0)
        }
        try await withServer(router) { _, path in
            let connection = try RawConnection(path: path)
            let hook = try JSONValue(encoding: HookEnvelope(agent: .claude, event: "PermissionRequest", payload: Data("{}".utf8)))
            connection.sendLine(request(1, "hook", hook))
            connection.sendLine(request(2, "ping"))

            // The ping on the same connection answers while the hook is held.
            let first = try #require(await connection.next())
            #expect(first.idInt == 2)
            #expect(first["result"]?["ok"]?.boolValue == true)

            // And so does a different connection.
            let started = ContinuousClock.now
            let pong: PingResult = try await ControlClient(socketPath: path).callAsync(.ping, OKResult(), timeout: .seconds(1))
            #expect(pong.ok)
            #expect(ContinuousClock.now - started < .milliseconds(500))

            await gate.open()
            let second = try #require(await connection.next())
            #expect(second.idInt == 1)
            let reply = try #require(second["result"]).decode(HookReply.self)
            #expect(reply.stdout == "decided PermissionRequest")
        }
    }

    @Test func notificationsRunButGetNoResponse() async throws {
        let router = ControlRouter()
        let counter = Counter()
        router.on("test.note") { (_: JSONValue, _) in
            await counter.increment()
            return OKResult()
        }
        try await withServer(router) { _, path in
            let connection = try RawConnection(path: path)
            connection.sendLine(line(["jsonrpc": "2.0", "method": "test.note", "params": .object([:])]))
            connection.sendLine(request(7, "ping"))
            let response = try #require(await connection.next())
            #expect(response.idInt == 7)
            #expect(await eventually { await counter.value == 1 })
            #expect(await connection.nextLine(timeout: 0.2) == nil)

            // A notification to an unknown method is silently dropped too.
            connection.sendLine(line(["jsonrpc": "2.0", "method": "nope"]))
            #expect(await connection.nextLine(timeout: 0.2) == nil)
        }
    }

    @Test func malformedLinesGetErrorsAndConnectionSurvives() async throws {
        try await withServer { _, path in
            let connection = try RawConnection(path: path)
            connection.sendLine("{this is not json")
            let parseError = try #require(await connection.next())
            #expect(parseError.errorCode == -32700)
            #expect(parseError["id"] == .null)

            connection.sendLine(#"{"jsonrpc":"2.0","id":5}"#)
            let invalid = try #require(await connection.next())
            #expect(invalid.errorCode == -32600)
            #expect(invalid.idInt == 5)

            connection.sendLine(#"{"jsonrpc":"1.0","id":6,"method":"ping"}"#)
            #expect(await connection.next()?.errorCode == -32600)

            connection.sendLine("")  // blank lines are ignored
            connection.sendLine(request(9, "ping") + "\r")  // CRLF tolerated
            let pong = try #require(await connection.next())
            #expect(pong.idInt == 9)
            #expect(pong["error"] == nil)
        }
    }

    @Test func oversizeLinesAreRejectedAndConnectionSurvives() async throws {
        try await withServer(maxLineBytes: 1024) { _, path in
            let connection = try RawConnection(path: path)
            let padding = String(repeating: "x", count: 4000)
            // Arrives complete in one write.
            connection.sendLine(request(1, "ping", .object(["pad": .string(padding)])))
            let rejected = try #require(await connection.next())
            #expect(rejected.errorCode == -32600)
            #expect(rejected["error"]?["message"]?.stringValue?.contains("limit") == true)

            connection.sendLine(request(2, "ping"))
            #expect(await connection.next()?.idInt == 2)

            // Arrives in pieces: rejected as soon as it passes the limit, the tail is discarded.
            connection.send(#"{"jsonrpc":"2.0","id":3,"method":"ping","params":{"pad":""#)
            connection.send(padding)
            #expect(await connection.next()?.errorCode == -32600)
            connection.send(padding + "\"}}\n")
            connection.sendLine(request(4, "ping"))
            let after = try #require(await connection.next())
            #expect(after.idInt == 4)
            #expect(after["error"] == nil)
        }
    }

    @Test func batchRequests() async throws {
        try await withServer { _, path in
            let connection = try RawConnection(path: path)
            connection.sendLine("[\(request(1, "ping")),\(line(["jsonrpc": "2.0", "method": "ping"])),\(request(2, "missing"))]")
            let batch = try #require(await connection.next()?.arrayValue)
            #expect(batch.count == 2)
            #expect(batch[0].idInt == 1)
            #expect(batch[1].errorCode == -32601)
            connection.sendLine("[]")
            #expect(await connection.next()?.errorCode == -32600)
        }
    }

    @Test func peerCredentialsArePopulated() async throws {
        let router = ControlRouter()
        let seen = Box<ControlPeer>()
        router.on("whoami") { (context: ControlContext) in
            await seen.set(context.peer)
            return OKResult()
        }
        try await withServer(router) { _, path in
            _ = try await ControlClient(socketPath: path).requestAsync("whoami")
            let peer = try #require(await seen.value)
            #expect(peer.pid == getpid())
            #expect(peer.uid == geteuid())
        }
    }

    @Test func callerContextTravelsWithParams() async throws {
        let router = ControlRouter()
        let seen = Box<ControlContext>()
        let params = Box<JSONValue>()
        router.onRaw("echo") { raw, context in
            await seen.set(context)
            await params.set(raw ?? .null)
            return raw ?? .null
        }
        try await withServer(router) { _, path in
            let caller = CallerContext(surface: SurfaceID(), workspace: WorkspaceID())
            _ = try await ControlClient(socketPath: path, caller: caller).requestAsync("echo", params: .object(["a": .number(1)]))
            #expect(await seen.value?.caller == caller)
            #expect(await params.value == .object(["a": .number(1)]))
        }
    }

    @Test func staleSocketIsReplaced() async throws {
        let path = tempSocketPath("stale")
        // Leave a socket file behind with nobody listening, as a crashed app would.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(UnixSocket.address(for: path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        Darwin.close(fd)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(throws: ControlClientError.appNotRunning(path: path)) {
            try ControlClient(socketPath: path).connect()
        }

        let server = ControlServer(socketPath: path, handler: ControlRouter())
        try await server.start()
        let pong: PingResult = try await ControlClient(socketPath: path).callAsync(.ping, OKResult())
        #expect(pong.ok)
        await server.stop()
    }

    @Test func refusesToStealALiveSocket() async throws {
        try await withServer { _, path in
            let intruder = ControlServer(socketPath: path, handler: ControlRouter())
            await #expect(throws: ControlServerError.addressInUse(path)) {
                try await intruder.start()
            }
            // The original keeps serving.
            let pong: PingResult = try await ControlClient(socketPath: path).callAsync(.ping, OKResult())
            #expect(pong.ok)
        }
    }

    @Test func neverDeletesANonSocketFile() async throws {
        let path = tempSocketPath("file")
        defer { unlink(path) }
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: path))
        let server = ControlServer(socketPath: path, handler: ControlRouter())
        await #expect(throws: ControlServerError.pathOccupied(path)) {
            try await server.start()
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep me")
    }

    @Test func rejectsOverlongSocketPath() async throws {
        let path = "/tmp/" + String(repeating: "a", count: 120) + ".sock"
        let server = ControlServer(socketPath: path, handler: ControlRouter())
        await #expect(throws: ControlServerError.socketPathTooLong(path)) {
            try await server.start()
        }
    }

    @Test func clientDisconnectCancelsInFlightRequest() async throws {
        let router = ControlRouter()
        let cancelled = Gate()
        let started = Gate()
        router.on("hold") { (_: ControlContext) async -> OKResult in
            await started.open()
            await withTaskCancellationHandler {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            } onCancel: {
                Task { await cancelled.open() }
            }
            return OKResult()
        }
        try await withServer(router) { server, path in
            do {
                let connection = try RawConnection(path: path)
                connection.sendLine(request(1, "hold"))
                await started.wait()
            }  // connection closed here
            await cancelled.wait()
            #expect(await eventually { await server.connectionCount == 0 })
        }
    }

    @Test func stopClosesConnectionsAndCanRestart() async throws {
        let path = tempSocketPath()
        let server = ControlServer(socketPath: path, handler: ControlRouter())
        try await server.start()
        let connection = try RawConnection(path: path)
        connection.sendLine(request(1, "ping"))
        #expect(await connection.next()?.idInt == 1)
        await server.stop()
        let stopped = ContinuousClock.now
        #expect(await connection.nextLine(timeout: 2) == nil)  // EOF, promptly (not a timeout)
        #expect(ContinuousClock.now - stopped < .milliseconds(500))
        try await server.start()
        let pong: PingResult = try await ControlClient(socketPath: path).callAsync(.ping, OKResult())
        #expect(pong.ok)
        await server.stop()
    }

    @Test func manyConcurrentClients() async throws {
        let router = ControlRouter()
        router.on("square") { (n: Int, _) in n * n }
        try await withServer(router) { _, path in
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for n in 0..<64 {
                    group.addTask {
                        let client = ControlClient(socketPath: path, caller: CallerContext())
                        let result = try await client.requestAsync("square", params: .number(Double(n)))
                        return result.intValue == n * n
                    }
                }
                for try await ok in group { #expect(ok) }
            }
        }
    }
}

@Suite("ControlClient")
struct ControlClientTests {
    @Test func missingSocketFailsFast() throws {
        let path = "/tmp/mship-none-\(UUID().uuidString.prefix(8)).sock"
        let client = ControlClient(socketPath: path)
        var best = Duration.seconds(1)
        for _ in 0..<20 {
            let start = ContinuousClock.now
            #expect(throws: ControlClientError.appNotRunning(path: path)) { try client.connect() }
            best = min(best, ContinuousClock.now - start)
        }
        #expect(best < .milliseconds(1))
    }

    @Test func timesOutWaitingForSlowHandler() async throws {
        let router = ControlRouter()
        router.on("slow") { (_: ControlContext) async -> OKResult in
            try? await Task.sleep(for: .seconds(3))
            return OKResult()
        }
        try await withServer(router) { _, path in
            let client = ControlClient(socketPath: path)
            let start = ContinuousClock.now
            await #expect(throws: ControlClientError.timedOut) {
                try await client.requestAsync("slow", timeout: .milliseconds(150))
            }
            #expect(ContinuousClock.now - start < .seconds(1))
            // The same client recovers on a fresh connection (no stale reply in the way).
            let pong: PingResult = try await client.callAsync(.ping, OKResult())
            #expect(pong.ok)
        }
    }

    @Test func cancelInterruptsABlockedCall() async throws {
        let router = ControlRouter()
        router.on("slow") { (_: ControlContext) async -> OKResult in
            try? await Task.sleep(for: .seconds(3))
            return OKResult()
        }
        try await withServer(router) { _, path in
            let client = ControlClient(socketPath: path)
            let task = Task { () throws(ControlClientError) -> JSONValue in
                try await client.requestAsync("slow", timeout: .seconds(10))
            }
            try await Task.sleep(for: .milliseconds(100))
            let start = ContinuousClock.now
            task.cancel()
            let result = await task.result
            #expect(throws: ControlClientError.cancelled) { try result.get() }
            #expect(ContinuousClock.now - start < .milliseconds(500))
        }
    }

    @Test func serverErrorsSurfaceAsRPCErrors() async throws {
        try await withServer { _, path in
            await #expect(throws: ControlClientError.server(.methodNotFound("nope"))) {
                try await ControlClient(socketPath: path).requestAsync("nope")
            }
        }
    }
}

@Suite("ControlRouter")
struct ControlRouterTests {
    struct Thing: Codable, Equatable { var name: String; var count: Int }
    struct Oops: LocalizedError { var errorDescription: String? { "The browser pane is gone" } }

    let peer = ControlPeer(pid: 1, uid: 501)

    @Test func decodesTypedParamsAndEncodesResults() async throws {
        let router = ControlRouter()
        router.on("thing.double") { (thing: Thing, _) in Thing(name: thing.name + thing.name, count: thing.count * 2) }
        let result = try await router.handle(method: "thing.double", params: .object(["name": "ab", "count": 2]), peer: peer)
        #expect(try result.decode(Thing.self) == Thing(name: "abab", count: 4))
    }

    @Test func unknownMethod() async {
        await #expect(throws: RPCError.methodNotFound("x.y")) {
            try await ControlRouter().handle(method: "x.y", params: nil, peer: peer)
        }
    }

    @Test func invalidParamsNameTheField() async {
        let router = ControlRouter()
        router.on("thing") { (thing: Thing, _) in thing }
        do throws(RPCError) {
            _ = try await router.handle(method: "thing", params: .object(["name": "a"]), peer: peer)
            Issue.record("expected an error")
        } catch {
            #expect(error.code == -32602)
            #expect(error.message.contains("count"))
        }
        do throws(RPCError) {
            _ = try await router.handle(method: "thing", params: .object(["name": "a", "count": "two"]), peer: peer)
            Issue.record("expected an error")
        } catch {
            #expect(error.code == -32602)
            #expect(error.message.contains("count"))
        }
    }

    @Test func handlerErrorsMapToCodes() async {
        let router = ControlRouter()
        router.on(.surfaceFocus) { (_: SurfaceTarget, _) throws(RPCError) -> OKResult in throw .notFound("No such surface") }
        router.on(.browserSnapshot) { (_: BrowserTarget, _) throws -> BrowserSnapshotResult in throw Oops() }
        router.on("cancelled") { (_: ControlContext) throws -> OKResult in throw CancellationError() }

        await #expect(throws: RPCError.notFound("No such surface")) {
            try await router.handle(method: "surface.focus", params: .object([:]), peer: peer)
        }
        await #expect(throws: RPCError.internalError("The browser pane is gone")) {
            try await router.handle(method: "browser.snapshot", params: .object([:]), peer: peer)
        }
        await #expect(throws: RPCError.cancelled()) {
            try await router.handle(method: "cancelled", params: nil, peer: peer)
        }
    }

    @Test func callerIsExtractedAndStripped() async throws {
        let router = ControlRouter()
        let seen = Box<ControlContext>()
        router.on(.status) { (params: JSONValue, context) in
            await seen.set(context)
            return params
        }
        let caller = CallerContext(surface: SurfaceID(), workspace: WorkspaceID())
        let params = JSONValue.object(["includeExternal": true]).attachingCaller(caller)
        let echoed = try await router.handle(method: "status", params: params, peer: peer)
        #expect(echoed == .object(["includeExternal": true]))
        #expect(await seen.value?.caller == caller)
        #expect(await seen.value?.peer == peer)
        #expect(await seen.value?.method == "status")
    }

    @Test func pingIsBuiltIn() async throws {
        let result = try await ControlRouter().handle(method: "ping", params: nil, peer: peer)
        #expect(try result.decode(PingResult.self).pid == getpid())
    }

    @Test func missingParamsDecodeAsEmptyObject() async throws {
        struct Options: Codable { var verbose: Bool? }
        let router = ControlRouter()
        router.on("opts") { (options: Options, _) in options.verbose ?? false }
        #expect(try await router.handle(method: "opts", params: nil, peer: peer) == .bool(false))
    }
}
