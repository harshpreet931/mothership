import Darwin
import Foundation

/// mtime, size and type from a single `stat`. Foundation's `attributesOfItem` goes through
/// CFURL resource properties and builds a dictionary (roughly 10× the cost), and these checks
/// run every few seconds for every status file, transcript and watched directory.
struct FileStamp: Equatable, Sendable {
    var modified: Date
    var size: Int
    var isDirectory: Bool

    static func of(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let time = info.st_mtimespec
        return FileStamp(
            modified: Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000),
            size: Int(info.st_size),
            isDirectory: info.st_mode & S_IFMT == S_IFDIR
        )
    }
}
