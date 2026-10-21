import Foundation

/// A forgiving read-only view over `JSONSerialization` output. Every accessor returns nil on
/// a type mismatch instead of throwing, so decoders never crash on unexpected input.
struct JSONNode {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    static func parse(_ data: Data) -> JSONNode? {
        guard !data.isEmpty, let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSONNode(value)
    }

    static func parse(_ string: String) -> JSONNode? { parse(Data(string.utf8)) }

    subscript(key: String) -> JSONNode { JSONNode((raw as? [String: Any])?[key]) }

    subscript(index: Int) -> JSONNode {
        guard let array = raw as? [Any], array.indices.contains(index) else { return JSONNode(nil) }
        return JSONNode(array[index])
    }

    var exists: Bool { raw != nil && !(raw is NSNull) }
    var object: [String: Any]? { raw as? [String: Any] }
    var array: [JSONNode]? { (raw as? [Any])?.map(JSONNode.init) }

    var string: String? {
        if let string = raw as? String { return string }
        return nil
    }

    /// A non-empty string after trimming.
    var text: String? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }

    var number: NSNumber? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    var int: Int? {
        if let number { return number.intValue }
        if let string, let value = Int(string) { return value }
        return nil
    }

    var double: Double? {
        if let number { return number.doubleValue }
        if let string, let value = Double(string) { return value }
        return nil
    }

    var bool: Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Compact or pretty JSON text of this node.
    func serialized(pretty: Bool = false) -> String? {
        guard let raw, JSONSerialization.isValidJSONObject(raw) else {
            if let string { return string }
            if let number { return number.stringValue }
            return nil
        }
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: options) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Timestamps as ISO-8601 strings (with or without fractional seconds) or epoch numbers
    /// (seconds or milliseconds).
    var date: Date? {
        if let string {
            return JSONNode.parseISODate(string)
        }
        if let value = double {
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        }
        return nil
    }

    static func parseISODate(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? fractional.parse(string)
    }
}
