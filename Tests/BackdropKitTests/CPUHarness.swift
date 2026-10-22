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
    /// `BACKDROP_CPU_AB=1`: alternate the 30 fps cap off and on for each scene (2 rounds) and
    /// compare WindowServer's share.
    nonisolated static let abTest = ProcessInfo.processInfo.environment["BACKDROP_CPU_AB"] == "1"

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

    /// `BACKDROP_CPU_ONLY` is a comma-separated list of name fragments.
    static func matches(_ name: String) -> Bool {
        guard let only else { return true }
        return only.split(separator: ",").contains { name.contains($0) }
    }

    static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.25))) }
    }

    static var scenes: [(name: String, scene: Scene?)] {
        var list: [(String, Scene?)] = [("baseline: gradient only", SampleScenes.single(SampleScenes.night, ""))]
        // Earth and the retro sun are the moon and sun renderers with other art.
        list += SampleScenes.perKind.filter { !["moon-earth", "sun-retro"].contains($0.name) }.map { ("kind: \($0.name)", $0.scene) }
        list += SampleScenes.combos.map { ("combo: \($0.name)", $0.scene) }
        for id in ["mothership-sky", "aurora", "synthwave", "monsoon", "sakura", "ember", "first-snow"] {
            guard let theme = ThemeLibrary.theme(id: id) else { continue }
            list.append(("built-in: \(id)", ThemeLibrary.scene(for: theme, sunAltitude: id == "mothership-sky" ? -20 : 30)))
        }
        return list
    }

    @Test(.enabled(if: seconds != nil)) func measure() throws {
        let seconds = try #require(Self.seconds)
        // Out of the user's way: a small borderless window in the bottom-right corner, never
        // activating the process (Core Animation only runs for windows on screen, so it can't
        // be offscreen), shown only while measuring.
        NSApplication.shared.setActivationPolicy(.accessory)
        let frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 8, y: screen.minY + 8))
        }
        let view = BackdropView(frame: frame)
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            view.apply(nil, transition: 0)
            window.orderOut(nil)
            window.close()
        }
        let windowServer = Self.windowServerPID()
        var lines = ["scene\tapp CPU %\tWindowServer CPU %\tlayers\tvisible"]
        if Self.abTest {
            lines = ["scene\tcap\tWindowServer CPU % (2 rounds)\tapp CPU %"]
            for (name, scene) in Self.scenes where Self.matches(name) {
                var results: [Bool: [Double]] = [:], app: [Bool: [Double]] = [:]
                for _ in 0 ..< 2 {
                    for capped in [false, true] {
                        Timing.ambientFrameRate = capped ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30) : .default
                        view.apply(nil, transition: 0)
                        view.apply(scene, transition: 0)
                        Self.pump(3)
                        let cpu = Self.processCPU(), server = windowServer.flatMap(Self.psCPU), start = Date()
                        Self.pump(seconds)
                        let elapsed = Date().timeIntervalSince(start)
                        app[capped, default: []].append((Self.processCPU() - cpu) / elapsed * 100)
                        if let server, let pid = windowServer, let after = Self.psCPU(pid) {
                            results[capped, default: []].append((after - server) / elapsed * 100)
                        }
                    }
                }
                for capped in [false, true] {
                    let line = [name, capped ? "30 fps" : "display", (results[capped] ?? []).map { String(format: "%.1f", $0) }.joined(separator: " / "),
                                (app[capped] ?? []).map { String(format: "%.2f", $0) }.joined(separator: " / ")].joined(separator: "\t")
                    print(line)
                    lines.append(line)
                }
            }
            Timing.ambientFrameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            if let report = Self.report { try lines.joined(separator: "\n").appending("\n").write(toFile: report, atomically: true, encoding: .utf8) }
            return
        }
        for (name, scene) in Self.scenes where Self.matches(name) {
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
