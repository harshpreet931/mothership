import AppKit
import ShipModel
import WebKit

/// A browser pane: a slim native toolbar (back, forward, reload, address field, element
/// picker, open in default browser) above the session's web view.
@MainActor
public final class BrowserSurfaceView: NSView {
    public let session: BrowserSession

    private let toolbar = NSVisualEffectView()
    private let backButton = BrowserSurfaceView.toolbarButton("chevron.left", "Back")
    private let forwardButton = BrowserSurfaceView.toolbarButton("chevron.right", "Forward")
    private let reloadButton = BrowserSurfaceView.toolbarButton("arrow.clockwise", "Reload")
    private let pickerButton = BrowserSurfaceView.toolbarButton("cursorarrow.rays", "Pick an element to send to your agent")
    private let openButton = BrowserSurfaceView.toolbarButton("arrow.up.forward.app", "Open in default browser")
    private let addressField = AddressField()
    private let progressLine = NSView()
    private let separator = NSBox()
    private var progressWidth: NSLayoutConstraint?
    private var observer: UUID?

    public static let toolbarHeight: CGFloat = 34

    public init(session: BrowserSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        buildViews()
        observer = session.addStateObserver { [weak self] state in self?.render(state) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let observer { session.removeStateObserver(observer) }
    }

    /// Puts the cursor in the address field with its text selected (⌘L).
    public func focusAddressField() {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    // MARK: Layout

    private func buildViews() {
        toolbar.material = .headerView
        toolbar.blendingMode = .withinWindow
        toolbar.state = .followsWindowActiveState
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        addressField.placeholderString = "Search or enter address"
        addressField.font = .systemFont(ofSize: 12)
        addressField.bezelStyle = .roundedBezel
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.target = self
        addressField.action = #selector(addressEntered)
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setAccessibilityLabel("Address")

        backButton.action = #selector(goBack)
        forwardButton.action = #selector(goForward)
        reloadButton.action = #selector(reloadOrStop)
        pickerButton.action = #selector(togglePicker)
        pickerButton.setButtonType(.pushOnPushOff)
        openButton.action = #selector(openExternally)
        for button in [backButton, forwardButton, reloadButton, pickerButton, openButton] { button.target = self }

        let stack = NSStackView(views: [backButton, forwardButton, reloadButton, addressField, pickerButton, openButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.setCustomSpacing(8, after: reloadButton)
        stack.setCustomSpacing(8, after: addressField)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)

        progressLine.wantsLayer = true
        progressLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressLine.translatesAutoresizingMaskIntoConstraints = false
        progressLine.isHidden = true
        toolbar.addSubview(progressLine)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let webView = session.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        addSubview(toolbar)
        addSubview(separator)

        let progressWidth = progressLine.widthAnchor.constraint(equalToConstant: 0)
        self.progressWidth = progressWidth
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),

            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            progressLine.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            progressLine.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progressLine.heightAnchor.constraint(equalToConstant: 2),
            progressWidth,

            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            webView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func render(_ state: BrowserState) {
        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
        reloadButton.image = Self.symbol(state.isLoading ? "xmark" : "arrow.clockwise", state.isLoading ? "Stop" : "Reload")
        reloadButton.toolTip = state.isLoading ? "Stop" : "Reload"
        pickerButton.state = state.isPicking ? .on : .off
        pickerButton.contentTintColor = state.isPicking ? .controlAccentColor : nil
        if addressField.currentEditor() == nil {
            addressField.stringValue = BrowserURL.display(state.url)
        }
        let showProgress = state.isLoading && state.progress < 1
        progressLine.isHidden = !showProgress
        progressWidth?.constant = toolbar.bounds.width * max(0.05, state.progress)
    }

    // MARK: Actions

    @objc private func addressEntered() {
        let text = addressField.stringValue
        window?.makeFirstResponder(session.webView)
        Task { try? await session.navigate(to: text) }
    }

    @objc private func goBack() { session.goBack() }
    @objc private func goForward() { session.goForward() }

    @objc private func reloadOrStop() {
        if session.state.isLoading { session.stopLoading() } else { session.reload() }
    }

    @objc private func togglePicker() {
        let enable = !session.isPicking
        Task { await session.setPicking(enable) }
    }

    @objc private func openExternally() { session.openInDefaultBrowser() }

    // MARK: Helpers

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(configuration)
            ?? NSImage(size: NSSize(width: 14, height: 14))
    }

    private static func toolbarButton(_ symbolName: String, _ description: String) -> NSButton {
        let button = NSButton(image: symbol(symbolName, description), target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.toolTip = description
        button.setAccessibilityLabel(description)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }
}

/// Selects its whole contents when clicked into, like every browser's address bar.
private final class AddressField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
        return accepted
    }
}
