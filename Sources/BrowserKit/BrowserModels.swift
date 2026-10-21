import Foundation
import ShipModel

// BrowserKit links only ShipModel, so it defines its own result types. Each one encodes to
// exactly the JSON of its ShipProtocol counterpart, so the app can return them straight from
// control-socket handlers:
//   BrowserSnapshot       ≙ BrowserSnapshotResult
//   BrowserConsoleMessage ≙ BrowserConsoleEntry
//   BrowserValue          ≙ JSONValue

/// The page as an indented outline with element refs, e.g. `- button "Sign in" [ref=e12]`.
public struct BrowserSnapshot: Sendable, Codable, Equatable {
    public var url: String
    public var title: String
    public var outline: String

    public init(url: String, title: String, outline: String) {
        self.url = url
        self.title = title
        self.outline = outline
    }
}

/// One captured console line. `level` is log, info, warn, error, debug, exception (uncaught),
/// rejection (unhandled promise) or network (failed fetch/XHR/resource/navigation).
public struct BrowserConsoleMessage: Sendable, Codable, Equatable {
    public var level: String
    public var message: String
    public var date: Date

    public init(level: String, message: String, date: Date) {
        self.level = level
        self.message = message
        self.date = date
    }

    public var isError: Bool { ["error", "exception", "rejection", "network"].contains(level) }
}

/// A JSON value returned by page JavaScript.
public enum BrowserValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BrowserValue])
    case object([String: BrowserValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([BrowserValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: BrowserValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses JSON text (as produced by `JSON.stringify`).
    public init(jsonText: String) throws {
        self = try JSONDecoder().decode(BrowserValue.self, from: Data(jsonText.utf8))
    }

    public subscript(key: String) -> BrowserValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

/// An element the user picked with the element picker, ready to hand to an agent.
public struct PickedElement: Sendable, Codable, Equatable {
    /// A CSS selector that matched exactly this element when it was picked.
    public var selector: String
    public var tagName: String
    /// Truncated to ~3,000 characters.
    public var outerHTML: String
    /// Visible text, truncated to ~500 characters.
    public var text: String
    /// Computed styles that aren't defaults (color, font, spacing, layout, …).
    public var styles: [String: String]
    /// In CSS pixels, relative to the viewport at pick time.
    public var rect: CGRect
    /// The snapshot ref assigned to it, usable with click/fill.
    public var ref: String?
    public var pageURL: String
    public var pageTitle: String
    /// PNG crop of the element, if the capture succeeded.
    public var screenshotPath: String?

    public init(
        selector: String, tagName: String, outerHTML: String, text: String, styles: [String: String], rect: CGRect,
        ref: String?, pageURL: String, pageTitle: String, screenshotPath: String?
    ) {
        self.selector = selector
        self.tagName = tagName
        self.outerHTML = outerHTML
        self.text = text
        self.styles = styles
        self.rect = rect
        self.ref = ref
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.screenshotPath = screenshotPath
    }

    /// A compact block to paste into an agent's prompt.
    public var promptText: String {
        var lines = ["Element from \(pageURL)\(pageTitle.isEmpty ? "" : " (\(pageTitle))"):"]
        lines.append("Selector: \(selector)")
        if let ref { lines.append("Browser ref: \(ref)") }
        if !text.isEmpty { lines.append("Text: \(text)") }
        lines.append("Size: \(Int(rect.width.rounded()))×\(Int(rect.height.rounded())) at (\(Int(rect.minX.rounded())), \(Int(rect.minY.rounded())))")
        if !styles.isEmpty {
            lines.append("Styles: " + styles.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
        }
        lines.append("HTML:\n\(outerHTML)")
        if let screenshotPath { lines.append("Screenshot: \(screenshotPath)") }
        return lines.joined(separator: "\n")
    }
}

public enum BrowserError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL(String)
    case navigationFailed(String)
    /// A script error: element not found, disabled, not fillable, page exception, …
    case script(String)
    case screenshotFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let input): "Not a URL: \(input)"
        case .navigationFailed(let message): message
        case .script(let message): message
        case .screenshotFailed(let message): "Screenshot failed: \(message)"
        }
    }
}

/// Snapshot of what the toolbar shows.
public struct BrowserState: Sendable, Equatable {
    public var url: URL?
    public var title: String
    public var isLoading: Bool
    public var progress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isPicking: Bool

    public init(
        url: URL? = nil, title: String = "", isLoading: Bool = false, progress: Double = 0, canGoBack: Bool = false,
        canGoForward: Bool = false, isPicking: Bool = false
    ) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.progress = progress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isPicking = isPicking
    }
}

/// Turns what people type into URL fields into URLs.
public enum BrowserURL {
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "::1"]
    private static let localSuffixes = [".localhost", ".local", ".test", ".internal", ".lan"]

    /// `localhost:3000` → `http://localhost:3000`, `:5173` → `http://localhost:5173`,
    /// `example.com` → `https://example.com`, `~/site/index.html` → file URL,
    /// anything else → a web search.
    public static func normalize(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let colon = text.firstIndex(of: ":"), text[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }),
           text[..<colon].first?.isLetter == true {
            let scheme = text[..<colon].lowercased()
            if ["http", "https", "file", "about", "data", "blob", "view-source"].contains(scheme) || text.contains("://") {
                return URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? text)
            }
        }
        if text.hasPrefix("/") || text.hasPrefix("~/") {
            let path = text.hasPrefix("~/") ? NSHomeDirectory() + text.dropFirst() : text
            return URL(fileURLWithPath: path)
        }
        if text.hasPrefix(":"), let port = Int(text.dropFirst().prefix { $0.isNumber }), port > 0 {
            return URL(string: "http://localhost" + text)
        }
        if !text.contains(" ") {
            let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
            let host = hostPart.hasPrefix("[") ? String(hostPart.prefix { $0 != "]" }) + "]" : String(hostPart.split(separator: ":").first ?? "")
            let lowered = host.lowercased()
            let isLocal = localHosts.contains(lowered) || localSuffixes.contains { lowered.hasSuffix($0) } || isPrivateIPv4(lowered)
            if isLocal { return URL(string: "http://" + text) }
            if isIPv4(lowered) || (lowered.contains(".") && !lowered.hasSuffix(".") && lowered.split(separator: ".").last?.allSatisfy(\.isLetter) == true) {
                return URL(string: "https://" + text)
            }
            if hostPart.contains(":"), let port = hostPart.split(separator: ":").last, Int(port) != nil {
                return URL(string: "http://" + text)  // devbox:8080
            }
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    static func isPrivateIPv4(_ host: String) -> Bool {
        guard isIPv4(host) else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
    }

    /// For display in the URL field: no trailing slash on bare origins.
    public static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        if url.isFileURL { return url.path }
        var text = url.absoluteString
        if url.path == "/" && url.query == nil && url.fragment == nil && text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
