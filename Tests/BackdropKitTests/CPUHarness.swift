import AppKit
import Foundation
import Testing
import ThemeKit
@testable import BackdropKit

/// Debug harness: shows each scene in a real window and measures this process's CPU (user +
/// system) over a window of time after a warm-up, plus WindowServer's CPU over the same
/// window (system-wide, so only indicative). Opt in:
///
///     BACKDROP_CPU_SECONDS=30 BACKDROP_CPU_REPORT=/path/report.tsv swift test --filter CPUHarness
///
/// `BACKDROP_CPU_ONLY=aurora` limits it to names containing that text.
@MainActor
@Suite(.serialized) struct CPUHarness {
    nonisolated static let seconds = ProcessInfo.processInfo.environment["BACKDROP_CPU_SECONDS"].flatMap(Double.init)
    nonisolated static let report = ProcessInfo.processInfo.environment["BACKDROP_CPU_REPORT"]
    nonisolated static let only = ProcessInfo.processInfo.environment["BACKDROP_CPU_ONLY"]

    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// `ps` CPU time of a process, in seconds.
    static func psCPU(_ pid: String) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "time=", "-p", pid]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // [[dd-]hh:]mm:ss.cc
        let parts = text.split(separator: ":").map { Double($0) ?? 0 }
        return parts.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }

    static func windowServerPID() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "WindowServer"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").first.map(String.init)
    }

    static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.25))) }
    }

    static var scenes: [(name: String, scene: Scene?)] {
        var list: [(String, Scene?)] = [("baseline: gradient only", SampleScenes.single(SampleScenes.night, ""))]
        list += SampleScenes.perKind.map { ("kind: \($0.name)", $0.scene) }
        list += SampleScenes.combos.map { ("combo: \($0.name)", $0.scene) }
        for id in ["mothership-sky", "aurora", "nebula", "synthwave", "monsoon", "sakura", "firefly-forest", "ember", "deep-sea", "first-snow", "digital-rain"] {
            guard let theme = ThemeLibrary.theme(id: id) else { continue }
            list.append(("built-in: \(id)", ThemeLibrary.scene(for: theme, sunAltitude: id == "mothership-sky" ? -20 : 30)))
        }
        return list
    }

    @Test(.enabled(if: seconds != nil)) func measure() throws {
        let seconds = try #require(Self.seconds)
        NSApplication.shared.setActivationPolicy(.accessory)
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 750)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "BackdropKit CPU harness"
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.maxX - window.frame.width - 20, y: screen.minY + 20))
        }
        let view = BackdropView(frame: frame)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let windowServer = Self.windowServerPID()
        var lines = ["scene\tapp CPU %\tWindowServer CPU %\tlayers\tvisible"]
        for (name, scene) in Self.scenes where Self.only.map({ name.contains($0) }) ?? true {
            view.apply(scene, transition: 0)
            Self.pump(4)
            let cpu = Self.processCPU(), server = windowServer.flatMap(Self.psCPU), start = Date()
            Self.pump(seconds)
            let elapsed = Date().timeIntervalSince(start)
            let app = (Self.processCPU() - cpu) / elapsed * 100
            var serverPercent: Double?
            if let server, let pid = windowServer, let after = Self.psCPU(pid) { serverPercent = (after - server) / elapsed * 100 }
            let visible = window.occlusionState.contains(.visible)
            let serverText = serverPercent.map { String(format: "%.1f", $0) } ?? "?"
            let line = [name, String(format: "%.2f", app), serverText, String(view.layerCount), String(visible)].joined(separator: "\t")
            print(line)
            lines.append(line)
        }
        if let report = Self.report {
            try lines.joined(separator: "\n").appending("\n").write(toFile: report, atomically: true, encoding: .utf8)
        }
    }
}
