import Foundation

/// A UUID-backed identifier, distinct per `Tag` so a `SurfaceID` can't be passed where a
/// `WorkspaceID` is expected. Encodes as a bare UUID string.
public struct Identifier<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public init?(string: String?) {
        guard let string, let uuid = UUID(uuidString: string) else { return nil }
        self.rawValue = uuid
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}

public enum WorkspaceTag {}
public enum SurfaceTag {}
public enum PermissionRequestTag {}

/// One vertical tab.
public typealias WorkspaceID = Identifier<WorkspaceTag>
/// One pane leaf (terminal, browser, …). Exported to shells as `MOTHERSHIP_SURFACE_ID`.
public typealias SurfaceID = Identifier<SurfaceTag>
public typealias PermissionRequestID = Identifier<PermissionRequestTag>
