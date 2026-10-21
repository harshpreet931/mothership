import Foundation
import ShipModel

/// Keeps a stable copy of the bundled `mship` at `ShipPaths.cliShim`, which agent hook
/// configs point at, so moving or updating the app never breaks installed hooks.
enum CLIShim {
    /// Copies `Contents/MacOS/mship` over the shim when missing or different (size or
    /// mtime). Returns the shim's directory, or nil when no bundled CLI was found.
    @discardableResult
    static func installIfNeeded(fileManager: FileManager = .default) -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let bundled = executable.deletingLastPathComponent().appending(path: "mship")
        let destination = ShipPaths.cliShim
        guard fileManager.isExecutableFile(atPath: bundled.path) else {
            return fileManager.isExecutableFile(atPath: destination.path) ? destination.deletingLastPathComponent() : nil
        }
        do {
            let source = try fileManager.attributesOfItem(atPath: bundled.path)
            let existing = try? fileManager.attributesOfItem(atPath: destination.path)
            let sourceSize = (source[.size] as? NSNumber)?.int64Value
            let sourceDate = source[.modificationDate] as? Date
            let upToDate = existing.map { attributes in
                (attributes[.size] as? NSNumber)?.int64Value == sourceSize
                    && (attributes[.modificationDate] as? Date) == sourceDate
            } ?? false
            if !upToDate {
                let directory = destination.deletingLastPathComponent()
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                // Copy beside the target, then swap, so a hook running mid-update never
                // sees a half-written binary.
                let staging = directory.appending(path: ".mship-\(UUID().uuidString)")
                try fileManager.copyItem(at: bundled, to: staging)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o755, .modificationDate: sourceDate ?? Date()], ofItemAtPath: staging.path
                )
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
                } else {
                    try fileManager.moveItem(at: staging, to: destination)
                }
            }
            return destination.deletingLastPathComponent()
        } catch {
            NSLog("Mothership: couldn't install mship shim: %@", String(describing: error))
            return nil
        }
    }

    /// Environment for shells: `PATH` with the shim directory first.
    static func shellEnvironment(shimDirectory: URL?) -> [String: String] {
        guard let shimDirectory else { return [:] }
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let parts = current.split(separator: ":").map(String.init).filter { $0 != shimDirectory.path }
        return ["PATH": ([shimDirectory.path] + parts).joined(separator: ":")]
    }
}
