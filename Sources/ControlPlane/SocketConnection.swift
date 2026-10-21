import Darwin
import Dispatch
import Foundation
import ShipProtocol

/// One accepted client socket: newline framing, concurrent request dispatch, buffered writes.
///
/// Every request runs in its own `Task`, so a `hook` call held for minutes never delays a
/// `ping` sent after it on the same connection. Responses are written in completion order
/// (JSON-RPC clients match them by id).
///
/// EOF from the client means it's gone (the CLI never half-closes): in-flight *requests* are
/// cancelled so a held permission hook learns its agent was interrupted. Notifications are
/// left to finish, since fire-and-forget senders close right after writing.
final class SocketConnection: @unchecked Sendable {
    // @unchecked: every mutable property below is only read or written on `queue`.

    let fd: Int32
    let peer: ControlPeer
    private let queue: DispatchQueue
    private let processor: RequestProcessor
    private let onClose: @Sendable (ObjectIdentifier) -> Void

    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var writeSourceActive = false
    private var liveSources = 0

    private var inbox: [UInt8] = []
    private var scannedUpTo = 0
    private var discardingOversizeLine = false
    private var outbox = Data()
    private var outboxOffset = 0

    private var requests: [Int: Task<Void, Never>] = [:]
    private var notificationsInFlight = 0
    private var nextToken = 0
    private var readClosed = false
    private var closed = false
    private var fdReleased = false

    private static let readChunk = 64 * 1024
    /// Bytes read per readiness event before yielding, so one chatty client can't hog the queue.
    private static let readBudget = 1024 * 1024

    init(fd: Int32, peer: ControlPeer, processor: RequestProcessor, onClose: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.fd = fd
        self.peer = peer
        self.processor = processor
        self.onClose = onClose
        self.queue = DispatchQueue(label: "mothership.control.connection.\(fd)")
    }

    func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            // Strong on purpose: the connection must outlive its sources so the fd gets closed.
            // The cycle ends when the source is cancelled and drops its handlers.
            source.setCancelHandler { self.sourceCancelled() }
            readSource = source
            liveSources += 1
            source.resume()
        }
    }

    /// Closes the connection and cancels its in-flight requests. Blocks until done.
    func shutdownNow() {
        queue.sync { close() }
    }

    // MARK: Reading

    private func readAvailable() {
        guard !closed, !readClosed else { return }
        var chunk = [UInt8](repeating: 0, count: Self.readChunk)
        var budget = Self.readBudget
        while budget > 0 {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                budget -= count
                ingest(chunk[0..<count])
                if closed { return }
                continue
            }
            if count == 0 {
                endOfInput()
                return
            }
            switch errno {
            case EINTR: continue
            case EAGAIN: return
            default:
                close()
                return
            }
        }
    }

    private func ingest(_ bytes: ArraySlice<UInt8>) {
        var bytes = bytes
        if discardingOversizeLine {
            guard let newline = bytes.firstIndex(of: 0x0A) else { return }
            discardingOversizeLine = false
            bytes = bytes[(newline + 1)...]
        }
        inbox.append(contentsOf: bytes)

        var lineStart = 0
        var searchFrom = scannedUpTo
        while let newline = inbox[searchFrom...].firstIndex(of: 0x0A) {
            if newline - lineStart > processor.maxLineBytes {
                enqueue(RequestProcessor.oversizeResponse(limit: processor.maxLineBytes))
            } else {
                dispatch(Data(inbox[lineStart..<newline]))
            }
            lineStart = newline + 1
            searchFrom = lineStart
        }
        if lineStart > 0 { inbox.removeSubrange(0..<lineStart) }
        scannedUpTo = inbox.count

        // An unterminated line already over the limit: reject now, drop the rest of it as it arrives.
        if inbox.count > processor.maxLineBytes {
            enqueue(RequestProcessor.oversizeResponse(limit: processor.maxLineBytes))
            inbox = []
            scannedUpTo = 0
            discardingOversizeLine = true
        }
    }

    private func dispatch(_ line: Data) {
        let token = nextToken
        nextToken += 1
        let processor = processor
        let peer = peer
        switch processor.parse(line) {
        case .ignore:
            return
        case .reply(let response):
            enqueue(RequestProcessor.encode(response))
        case .notification(let request):
            notificationsInFlight += 1
            Task {
                await processor.runNotification(request, peer: peer)
                self.finished(token: token, notification: true, response: nil)
            }
        case .call(let request):
            requests[token] = Task {
                let response = await processor.run(request, peer: peer)
                self.finished(token: token, notification: false, response: RequestProcessor.encode(response))
            }
        case .batch(let items):
            requests[token] = Task {
                let response = await processor.runBatch(items, peer: peer)
                self.finished(token: token, notification: false, response: response)
            }
        }
    }

    private func finished(token: Int, notification: Bool, response: Data?) {
        queue.async { [self] in
            if notification {
                notificationsInFlight -= 1
            } else {
                requests[token] = nil
            }
            if let response { enqueue(response) }
            closeIfDrained()
        }
    }

    private func endOfInput() {
        readClosed = true
        readSource?.cancel()
        for task in requests.values { task.cancel() }
        closeIfDrained()
    }

    // MARK: Writing

    private func enqueue(_ data: Data) {
        guard !closed else { return }
        outbox.append(data)
        flush()
    }

    private func flush() {
        while outboxOffset < outbox.count {
            let written = outbox.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + outboxOffset, raw.count - outboxOffset)
            }
            if written > 0 {
                outboxOffset += written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && errno == EAGAIN {
                armWriteSource()
                return
            }
            close()  // EPIPE / ECONNRESET: the client is gone.
            return
        }
        outbox = Data()
        outboxOffset = 0
        if writeSourceActive {
            writeSource?.suspend()
            writeSourceActive = false
        }
        closeIfDrained()
    }

    private func armWriteSource() {
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.flush() }
            source.setCancelHandler { self.sourceCancelled() }
            writeSource = source
            liveSources += 1
        }
        if !writeSourceActive {
            writeSource?.resume()
            writeSourceActive = true
        }
    }

    // MARK: Closing

    private func closeIfDrained() {
        if readClosed && requests.isEmpty && notificationsInFlight == 0 && outboxOffset >= outbox.count {
            close()
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        for task in requests.values { task.cancel() }
        if let readSource, !readSource.isCancelled { readSource.cancel() }
        if let writeSource {
            // A suspended source must be resumed before it can be cancelled and released.
            if !writeSourceActive { writeSource.resume() }
            writeSourceActive = true
            writeSource.cancel()
        }
        releaseDescriptorIfIdle()
        onClose(ObjectIdentifier(self))
    }

    private func sourceCancelled() {
        liveSources -= 1
        releaseDescriptorIfIdle()
    }

    /// The fd may only be closed once no dispatch source still monitors it.
    private func releaseDescriptorIfIdle() {
        guard closed, liveSources == 0, !fdReleased else { return }
        fdReleased = true
        Darwin.close(fd)
    }
}
