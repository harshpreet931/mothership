import AppKit
import Foundation
import os
import ShipModel
import WebKit

/// One browser pane's web view plus everything agents use to drive it: navigation, DOM
/// snapshots with stable refs, click/fill, JavaScript evaluation, console capture,
/// screenshots and the element picker.
///
/// ```swift
/// let session = BrowserSession(workspace: workspace.id, surface: surface.id)
/// session.onTitleChange = { title in pane.title = title }
/// session.onElementPicked = { element in agentPane.paste(element.promptText) }
/// let view = BrowserSurfaceView(session: session)      // toolbar + web view
/// try await session.navigate(to: "localhost:3000")
/// let outline = try await session.snapshot().outline
/// ```
@MainActor
public final class BrowserSession: NSObject {
    public enum DataStore {
        /// Cookies and storage shared by every browser pane of one workspace, isolated from
        /// other workspaces (`WKWebsiteDataStore(forIdentifier:)` keyed by the workspace UUID).
        case workspace(WorkspaceID)
        /// Nothing persists (tests, private panes).
        case ephemeral
    }

    public let workspace: WorkspaceID?
    public let surface: SurfaceID?
    public let webView: WKWebView

    public var onTitleChange: ((String) -> Void)?
    public var onURLChange: ((URL?) -> Void)?
    public var onLoadingChange: ((_ isLoading: Bool, _ progress: Double) -> Void)?
    public var onElementPicked: ((PickedElement) -> Void)?
    public var onConsoleMessage: ((BrowserConsoleMessage) -> Void)?
    /// Every toolbar-relevant change (URL, title, loading, history, picker).
    public var onStateChange: ((BrowserState) -> Void)?

    public private(set) var state = BrowserState()
    /// Console ring buffer capacity.
    public var consoleCapacity = 1000

    private var console: [BrowserConsoleMessage] = []
    private var observations: [NSKeyValueObservation] = []
    private var stateObservers: [UUID: (BrowserState) -> Void] = [:]
    private var navigationWaiters: [ObjectIdentifier: [CheckedContinuation<NavigationOutcome, Never>]] = [:]
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var failedURL: URL?
    private var stagingWindow: NSWindow?
    private let world = WKContentWorld.world(name: BrowserScripts.worldName)

    private static let log = Logger(subsystem: ShipInfo.bundleIdentifier, category: "browser")
    private static var dataStores: [WorkspaceID: WKWebsiteDataStore] = [:]

    enum NavigationOutcome {
        case finished
        case failed(any Error)
        case timedOut
    }

    public init(workspace: WorkspaceID?, surface: SurfaceID? = nil, dataStore: DataStore? = nil) {
        self.workspace = workspace
        self.surface = surface

        let configuration = WKWebViewConfiguration()
        switch dataStore ?? workspace.map(DataStore.workspace) ?? .ephemeral {
        case .workspace(let id): configuration.websiteDataStore = Self.dataStore(for: id)
        case .ephemeral: configuration.websiteDataStore = .nonPersistent()
        }
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Sites sniff for "Safari"; a bare WKWebView user agent gets "unsupported browser" pages.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15 Mothership/\(ShipInfo.version)"

        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: BrowserScripts.consoleCapture, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
        ))

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()

        // The controller retains handlers strongly; a weak proxy avoids a session ↔ web view cycle.
        let proxy = WeakMessageHandler(self)
        controller.add(proxy, contentWorld: .page, name: BrowserScripts.consoleHandler)
        controller.add(proxy, contentWorld: world, name: BrowserScripts.pickerHandler)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeWebView()
    }

    isolated deinit {
        let controller = webView.configuration.userContentController
        controller.removeAllScriptMessageHandlers()
        stagingWindow?.close()
    }

    /// The shared data store for a workspace's browser panes.
    public static func dataStore(for workspace: WorkspaceID) -> WKWebsiteDataStore {
        if let store = dataStores[workspace] { return store }
        let store = WKWebsiteDataStore(forIdentifier: workspace.rawValue)
        dataStores[workspace] = store
        return store
    }

    /// Deletes a closed workspace's cookies and storage.
    public static func removeData(for workspace: WorkspaceID) async {
        dataStores[workspace] = nil
        try? await WKWebsiteDataStore.remove(forIdentifier: workspace.rawValue)
    }

    // MARK: Navigation

    /// Normalizes `input` (see `BrowserURL.normalize`), loads it and waits for the load to
    /// finish (or `timeout`, after which it returns while the page keeps loading).
    @discardableResult
    public func navigate(to input: String, timeout: Duration = .seconds(30)) async throws(BrowserError) -> URL {
        guard let url = BrowserURL.normalize(input) else { throw .invalidURL(input) }
        try await navigate(to: url, timeout: timeout)
        return url
    }

    public func navigate(to url: URL, timeout: Duration = .seconds(30)) async throws(BrowserError) {
        failedURL = nil
        let navigation: WKNavigation?
        if url.isFileURL {
            navigation = webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            navigation = webView.load(URLRequest(url: url))
        }
        guard let navigation else { return }
        switch await wait(for: navigation, timeout: timeout) {
        case .finished, .timedOut:
            return
        case .failed(let error):
            if Self.isCancellation(error) { return }  // superseded by another navigation
            throw .navigationFailed("Couldn't load \(BrowserURL.display(url)): \(error.localizedDescription)")
        }
    }

    /// Loads HTML directly (tests, generated pages) and waits for it to finish.
    public func loadHTML(_ html: String, baseURL: URL? = nil, timeout: Duration = .seconds(30)) async {
        guard let navigation = webView.loadHTMLString(html, baseURL: baseURL) else { return }
        _ = await wait(for: navigation, timeout: timeout)
    }

    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }

    public func reload() {
        if let failedURL {
            Task { try? await navigate(to: failedURL) }
        } else {
            webView.reload()
        }
    }

    public func stopLoading() { webView.stopLoading() }

    /// Opens the current page in the user's default browser.
    public func openInDefaultBrowser() {
        guard let url = failedURL ?? webView.url, url.scheme == "http" || url.scheme == "https" || url.isFileURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Waits until no load is in progress (at most `timeout`).
    public func waitUntilLoaded(timeout: Duration = .seconds(10)) async {
        guard webView.isLoading else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loadWaiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeLoadWaiters()
            }
        }
    }

    private func wait(for navigation: WKNavigation, timeout: Duration) async -> NavigationOutcome {
        let key = ObjectIdentifier(navigation)
        return await withCheckedContinuation { continuation in
            navigationWaiters[key, default: []].append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveNavigation(key, .timedOut)
            }
        }
    }

    private func resolveNavigation(_ key: ObjectIdentifier, _ outcome: NavigationOutcome) {
        guard let waiters = navigationWaiters.removeValue(forKey: key) else { return }
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    private func resumeLoadWaiters() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Automation

    /// An outline of the visible page. Interactive elements get refs (`[ref=e12]`) that stay
    /// attached to the same element across snapshots for the life of the document.
    public func snapshot() async throws(BrowserError) -> BrowserSnapshot {
        await waitUntilLoaded()
        let result = try await runAutomation("return window.__mship.snapshot();")
        guard let object = result as? [String: Any] else { throw .script("The page returned no snapshot.") }
        return BrowserSnapshot(
            url: object["url"] as? String ?? webView.url?.absoluteString ?? "",
            title: object["title"] as? String ?? webView.title ?? "",
            outline: object["outline"] as? String ?? ""
        )
    }

    /// Clicks an element by snapshot ref (`e12`) or CSS selector.
    public func click(ref: String) async throws(BrowserError) {
        _ = try await runAutomation("return window.__mship.click(ref);", arguments: ["ref": ref])
        await settle()
    }

    /// Replaces a field's value with `text`, firing the events frameworks listen for; `submit`
    /// presses Enter afterwards.
    public func fill(ref: String, text: String, submit: Bool = false) async throws(BrowserError) {
        _ = try await runAutomation(
            "return window.__mship.fill(ref, text, submit);", arguments: ["ref": ref, "text": text, "submit": submit]
        )
        await settle()
    }

    /// Runs JavaScript in the page's own world (so page globals are visible) and returns its
    /// result as JSON. Accepts an expression (`document.title`) or a function body with
    /// `return`; `await` works in both.
    public func evaluate(_ script: String) async throws(BrowserError) -> BrowserValue {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        var expression = trimmed
        while expression.hasSuffix(";") { expression.removeLast() }
        do {
            return try await evaluateBody("return (\n\(expression)\n);")
        } catch {
            guard case .script(let message) = error, message.contains("SyntaxError") else { throw error }
        }
        return try await evaluateBody(trimmed)
    }

    private func evaluateBody(_ body: String) async throws(BrowserError) -> BrowserValue {
        let wrapped = """
            const __mshipValue = await (async () => {
            \(body)
            })();
            const __mshipSeen = new WeakSet();
            const __mshipText = JSON.stringify(__mshipValue === undefined ? null : __mshipValue, (key, value) => {
              if (value === undefined) return null;
              if (typeof value === 'bigint') return value.toString();
              if (typeof value === 'function') return `[Function ${value.name || 'anonymous'}]`;
              if (typeof value === 'symbol') return value.toString();
              if (typeof Node !== 'undefined' && value instanceof Node) {
                return value.nodeType === 1 ? value.outerHTML.slice(0, 2000) : String(value.textContent || '').slice(0, 2000);
              }
              if (value instanceof Error) return { name: value.name, message: value.message, stack: value.stack };
              if (value instanceof Map) return Object.fromEntries(value);
              if (value instanceof Set) return [...value];
              if (typeof value === 'object' && value !== null) {
                if (__mshipSeen.has(value)) return '[Circular]';
                __mshipSeen.add(value);
              }
              return value;
            });
            return __mshipText === undefined ? 'null' : __mshipText;
            """
        let result = try await callJavaScript(wrapped, arguments: [:], world: .page)
        guard let text = result as? String else { return .null }
        do {
            return try BrowserValue(jsonText: text)
        } catch {
            return .string(text)
        }
    }

    /// Captured console output, oldest first.
    public func consoleEntries() -> [BrowserConsoleMessage] { console }

    public func clearConsole() { console.removeAll() }

    /// PNG of the visible viewport, written to a temp file.
    public func screenshot() async throws(BrowserError) -> URL {
        await waitUntilLoaded()
        let image = try await takeSnapshot(rect: nil)
        return try Self.writePNG(image, prefix: "browser")
    }

    // MARK: Element picker

    public var isPicking: Bool { state.isPicking }

    /// Turns the hover-highlight picker on or off. A click picks (→ `onElementPicked`), Esc cancels.
    public func setPicking(_ enabled: Bool) async {
        guard enabled != state.isPicking else { return }
        do {
            _ = try await runAutomation(enabled ? "return window.__mshipPicker.start();" : "return window.__mshipPicker.stop();")
            updateState { $0.isPicking = enabled }
            if enabled { webView.window?.makeFirstResponder(webView) }
        } catch {
            Self.log.error("picker toggle failed: \(error.localizedDescription, privacy: .public)")
            updateState { $0.isPicking = false }
        }
    }

    private func handlePick(_ body: [String: Any]) {
        updateState { $0.isPicking = false }
        guard let info = body["picked"] as? [String: Any] else { return }
        let number = { (key: String) in (info[key] as? NSNumber)?.doubleValue ?? 0 }
        let rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
        var element = PickedElement(
            selector: info["selector"] as? String ?? "", tagName: info["tag"] as? String ?? "",
            outerHTML: info["outerHTML"] as? String ?? "", text: info["text"] as? String ?? "",
            styles: info["styles"] as? [String: String] ?? [:], rect: rect, ref: info["ref"] as? String,
            pageURL: info["url"] as? String ?? "", pageTitle: info["title"] as? String ?? "", screenshotPath: nil
        )
        Task { @MainActor in
            if rect.width >= 1, rect.height >= 1 {
                let padded = rect.insetBy(dx: -8, dy: -8)
                if let image = try? await takeSnapshot(rect: padded), let url = try? Self.writePNG(image, prefix: "element") {
                    element.screenshotPath = url.path
                }
            }
            onElementPicked?(element)
        }
    }

    // MARK: State

    /// Internal observers (the toolbar) in addition to the public callbacks.
    func addStateObserver(_ observer: @escaping (BrowserState) -> Void) -> UUID {
        let id = UUID()
        stateObservers[id] = observer
        observer(state)
        return id
    }

    func removeStateObserver(_ id: UUID) { stateObservers[id] = nil }

    private func updateState(_ change: (inout BrowserState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        let previous = state
        state = next
        if previous.title != next.title { onTitleChange?(next.title) }
        if previous.url != next.url { onURLChange?(next.url) }
        if previous.isLoading != next.isLoading || previous.progress != next.progress { onLoadingChange?(next.isLoading, next.progress) }
        onStateChange?(next)
        for observer in stateObservers.values { observer(next) }
    }

    private func observeWebView() {
        let sync: @Sendable (WKWebView) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.syncState() }
        }
        observations = [
            webView.observe(\.title) { view, _ in sync(view) },
            webView.observe(\.url) { view, _ in sync(view) },
            webView.observe(\.isLoading) { view, _ in sync(view) },
            webView.observe(\.estimatedProgress) { view, _ in sync(view) },
            webView.observe(\.canGoBack) { view, _ in sync(view) },
            webView.observe(\.canGoForward) { view, _ in sync(view) },
        ]
    }

    private func syncState() {
        updateState {
            $0.url = failedURL ?? webView.url
            $0.title = webView.title ?? ""
            $0.isLoading = webView.isLoading
            $0.progress = webView.estimatedProgress
            $0.canGoBack = webView.canGoBack
            $0.canGoForward = webView.canGoForward
        }
        if !webView.isLoading { resumeLoadWaiters() }
    }

    // MARK: Console

    fileprivate func receive(_ message: WKScriptMessage) {
        switch message.name {
        case BrowserScripts.consoleHandler:
            guard let body = message.body as? [String: Any], let level = body["level"] as? String else { return }
            let millis = (body["time"] as? NSNumber)?.doubleValue
            record(BrowserConsoleMessage(
                level: level, message: body["message"] as? String ?? "",
                date: millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            ))
        case BrowserScripts.pickerHandler:
            guard let body = message.body as? [String: Any] else { return }
            if body["cancelled"] != nil {
                updateState { $0.isPicking = false }
            } else {
                handlePick(body)
            }
        default:
            break
        }
    }

    private func record(_ entry: BrowserConsoleMessage) {
        console.append(entry)
        if console.count > consoleCapacity { console.removeFirst(console.count - consoleCapacity) }
        onConsoleMessage?(entry)
    }

    // MARK: JavaScript plumbing

    /// Runs `body` in the isolated automation world after making sure the helpers exist there.
    private func runAutomation(_ body: String, arguments: [String: Any] = [:]) async throws(BrowserError) -> Any? {
        let source = BrowserScripts.automation + "\n" + BrowserScripts.picker + "\n" + body
        return try await callJavaScript(source, arguments: arguments, world: world)
    }

    private func callJavaScript(_ body: String, arguments: [String: Any], world: WKContentWorld) async throws(BrowserError) -> Any? {
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
        } catch {
            throw .script(Self.scriptMessage(error))
        }
    }

    /// The JS exception text without WebKit's wrapping.
    static func scriptMessage(_ error: any Error) -> String {
        let nsError = error as NSError
        var message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? nsError.localizedDescription
        for prefix in ["Error: ", "Uncaught Error: "] where message.hasPrefix(prefix) {
            message.removeFirst(prefix.count)
        }
        return message
    }

    /// Gives the page a moment to react (navigation start, re-render) before the caller snapshots.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
        await waitUntilLoaded(timeout: .seconds(10))
    }

    // MARK: Screenshots

    private func takeSnapshot(rect: CGRect?) async throws(BrowserError) -> NSImage {
        let staged = stageIfDetached()
        defer { if staged { unstage() } }
        let configuration = WKSnapshotConfiguration()
        if let rect {
            let zoom = webView.pageZoom * webView.magnification
            let scaled = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
            let visible = scaled.intersection(webView.bounds)
            guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { throw .screenshotFailed("the element is off screen") }
            configuration.rect = visible
        }
        do {
            return try await webView.takeSnapshot(configuration: configuration)
        } catch {
            throw .screenshotFailed(error.localizedDescription)
        }
    }

    /// WebKit only renders views that are in a window. A pane in a hidden workspace may be
    /// detached, so screenshots host it in an off-screen window for the duration.
    private func stageIfDetached() -> Bool {
        guard webView.window == nil else { return false }
        var root: NSView = webView
        while let parent = root.superview { root = parent }
        let window = stagingWindow ?? NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1280, height: 800), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        stagingWindow = window
        if root.frame.isEmpty { root.frame = NSRect(x: 0, y: 0, width: 1280, height: 800) }
        window.setContentSize(root.frame.size)
        window.contentView?.addSubview(root)
        window.orderBack(nil)
        return true
    }

    private func unstage() {
        guard let window = stagingWindow, let content = window.contentView else { return }
        for view in content.subviews { view.removeFromSuperview() }
        window.orderOut(nil)
    }

    static func writePNG(_ image: NSImage, prefix: String) throws(BrowserError) -> URL {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw .screenshotFailed("couldn't encode PNG")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "Mothership/Screenshots", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let url = directory.appending(path: "\(prefix)-\(stamp)-\(UUID().uuidString.prefix(6)).png")
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            throw .screenshotFailed(error.localizedDescription)
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
            || nsError.domain == "WebKitErrorDomain" && nsError.code == 102  // frame load interrupted (e.g. download)
    }

    // MARK: Error page

    fileprivate func showErrorPage(for url: URL, error: any Error) {
        failedURL = url
        let host = url.host() ?? url.absoluteString
        let local = ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) || host.hasSuffix(".localhost")
        let hint = local ? "Is the dev server running? Start it in a terminal pane, then try again." : "Check the address and your connection."
        record(BrowserConsoleMessage(level: "network", message: "Navigation to \(url.absoluteString) failed: \(error.localizedDescription)", date: Date()))
        let html = Self.errorPage(
            title: "Can’t reach \(BrowserURL.display(url).replacingOccurrences(of: "http://", with: ""))",
            detail: error.localizedDescription, hint: hint, retryURL: url.absoluteString
        )
        webView.loadHTMLString(html, baseURL: nil)
        updateState { $0.url = url }
    }

    static func errorPage(title: String, detail: String, hint: String, retryURL: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
            :root { color-scheme: light dark; }
            body { font: 14px/1.5 -apple-system, system-ui, sans-serif; margin: 0; min-height: 100vh; display: grid;
                   place-items: center; background: Canvas; color: CanvasText; }
            main { max-width: 440px; padding: 32px; }
            h1 { font-size: 20px; font-weight: 600; margin: 0 0 8px; }
            p { margin: 0 0 6px; opacity: .72; }
            button { margin-top: 18px; font: inherit; padding: 6px 16px; border-radius: 7px; border: 0;
                     background: #0a84ff; color: white; cursor: pointer; }
            </style></head><body><main>
            <h1>\(escape(title))</h1><p>\(escape(detail))</p><p>\(escape(hint))</p>
            <button onclick="location.href = \(escape("\"" + retryURL.replacingOccurrences(of: "\"", with: "%22") + "\""))">Try Again</button>
            </main></body></html>
            """
    }
}

extension BrowserSession: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation else { return }
        resolveNavigation(ObjectIdentifier(navigation), .finished)
        syncState()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard let navigation else { return }
        resolveNavigation(ObjectIdentifier(navigation), .failed(error))
        syncState()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if let navigation { resolveNavigation(ObjectIdentifier(navigation), .failed(error)) }
        if !Self.isCancellation(error) {
            let nsError = error as NSError
            if let failing = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
                showErrorPage(for: failing, error: error)
            }
        }
        syncState()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView.url != nil, webView.url?.absoluteString != "about:blank" { failedURL = nil }
        syncState()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        record(BrowserConsoleMessage(level: "error", message: "The page's web content process crashed; reloading.", date: Date()))
        webView.reload()
    }
}

extension BrowserSession: WKUIDelegate {
    /// `target=_blank` and `window.open` load in this pane rather than vanishing.
    public func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    public func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        record(BrowserConsoleMessage(level: "info", message: "alert(): \(message)", date: Date()))
        guard let window = webView.window else { return }
        let alert = NSAlert()
        alert.messageText = webView.url?.host() ?? "This page says"
        alert.informativeText = message
        _ = await alert.beginSheetModal(for: window)
    }

    public func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        record(BrowserConsoleMessage(level: "info", message: "confirm(): \(message)", date: Date()))
        guard let window = webView.window else { return false }
        let alert = NSAlert()
        alert.messageText = webView.url?.host() ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    public func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        record(BrowserConsoleMessage(level: "info", message: "prompt(): \(prompt)", date: Date()))
        guard let window = webView.window else { return nil }
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

/// Forwards script messages without retaining the session.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: BrowserSession?

    @MainActor init(_ session: BrowserSession) { self.session = session }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { session?.receive(message) }
    }
}
