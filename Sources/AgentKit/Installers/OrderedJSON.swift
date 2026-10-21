import Foundation

/// JSON that keeps key order and the original text of numbers and strings, so editing one
/// part of a user's config file leaves every other byte as it was (modulo indentation).
indirect enum OrderedJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The literal as written (`86400`, `1.5e3`).
    case number(String)
    /// Decoded value plus the raw literal (with quotes) when parsed from text.
    case string(String, raw: String?)
    case array([OrderedJSON])
    case object([(key: String, value: OrderedJSON)])

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b || Double(a) == Double(b)
        case (.string(let a, _), .string(let b, _)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    static func string(_ value: String) -> OrderedJSON { .string(value, raw: nil) }
    static func int(_ value: Int) -> OrderedJSON { .number(String(value)) }

    var stringValue: String? {
        if case .string(let value, _) = self { return value }
        return nil
    }

    var arrayValue: [OrderedJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [(key: String, value: OrderedJSON)]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> OrderedJSON? {
        objectValue?.first { $0.key == key }?.value
    }

    /// Set (replace in place, or append) a key on an object. No-op on non-objects.
    mutating func set(_ key: String, _ value: OrderedJSON?) {
        guard case .object(var pairs) = self else { return }
        if let index = pairs.firstIndex(where: { $0.key == key }) {
            if let value { pairs[index].value = value } else { pairs.remove(at: index) }
        } else if let value {
            pairs.append((key, value))
        }
        self = .object(pairs)
    }

    // MARK: Serialization (JSON.stringify(value, null, 2) style)

    func serialized(indent: String = "  ") -> String {
        var output = ""
        write(into: &output, level: 0, indent: indent)
        return output
    }

    private func write(into output: inout String, level: Int, indent: String) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let literal): output += literal
        case .string(let value, let raw): output += raw ?? Self.quote(value)
        case .array(let items):
            if items.isEmpty { output += "[]"; return }
            output += "[\n"
            for (index, item) in items.enumerated() {
                output += String(repeating: indent, count: level + 1)
                item.write(into: &output, level: level + 1, indent: indent)
                output += index == items.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: indent, count: level) + "]"
        case .object(let pairs):
            if pairs.isEmpty { output += "{}"; return }
            output += "{\n"
            for (index, pair) in pairs.enumerated() {
                output += String(repeating: indent, count: level + 1) + Self.quote(pair.key) + ": "
                pair.value.write(into: &output, level: level + 1, indent: indent)
                output += index == pairs.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: indent, count: level) + "}"
        }
    }

    static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    // MARK: Parsing

    struct ParseError: Error, CustomStringConvertible {
        var offset: Int
        var message: String
        var description: String { "JSON parse error at byte \(offset): \(message)" }
    }

    static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseError(offset: parser.index, message: "trailing characters") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func error(_ message: String) -> ParseError { ParseError(offset: index, message: message) }

        mutating func parseValue(depth: Int) throws -> OrderedJSON {
            guard depth < 256 else { throw error("nesting too deep") }
            guard index < bytes.count else { throw error("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""):
                let start = index
                let value = try parseString()
                return .string(value, raw: String(decoding: bytes[start..<index], as: UTF8.self))
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            default: return try parseNumber()
            }
        }

        mutating func literal(_ word: String, _ value: OrderedJSON) throws -> OrderedJSON {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw error("invalid literal")
            }
            index += expected.count
            return value
        }

        mutating func parseNumber() throws -> OrderedJSON {
            let start = index
            let allowed = Set("+-0123456789.eE".utf8)
            while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
            let literal = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !literal.isEmpty, Double(literal) != nil else { throw error("invalid number") }
            return .number(literal)
        }

        mutating func parseString() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var chunkStart = index
            func flush(_ end: Int) {
                if end > chunkStart { scalars.append(contentsOf: String(decoding: bytes[chunkStart..<end], as: UTF8.self).unicodeScalars) }
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    flush(index)
                    index += 1
                    return String(scalars)
                }
                if byte == UInt8(ascii: "\\") {
                    flush(index)
                    index += 1
                    guard index < bytes.count else { break }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800..<0xDC00).contains(code), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                            bytes[index + 1] == UInt8(ascii: "u")
                        {
                            index += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default:
                        throw error("invalid escape")
                    }
                    chunkStart = index
                    continue
                }
                index += 1
            }
            throw error("unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw error("invalid unicode escape")
            }
            index += 4
            return value
        }

        mutating func parseArray(depth: Int) throws -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw error("expected , or ]")
            }
        }

        mutating func parseObject(depth: Int) throws -> OrderedJSON {
            index += 1
            var pairs: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(pairs)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected key") }
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected :") }
                index += 1
                skipWhitespace()
                pairs.append((key, try parseValue(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                throw error("expected , or }")
            }
        }
    }
}
