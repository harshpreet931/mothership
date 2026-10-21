import Foundation
import ShipModel

/// Reads and writes `AppSnapshot` at `ShipPaths.stateFile` (JSON, atomic replace).
struct StateStore: Sendable {
    var url: URL = ShipPaths.stateFile

    func load() -> AppSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(AppSnapshot.self, from: data),
              snapshot.version <= AppSnapshot.currentVersion
        else {
            // Keep an unreadable file for inspection instead of overwriting it silently.
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable"))
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: AppSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            NSLog("Mothership: failed to save state: %@", String(describing: error))
        }
    }
}
