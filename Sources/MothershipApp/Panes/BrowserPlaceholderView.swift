import AppKit
import SwiftUI

/// Default browser pane until BrowserKit's view is injected through
/// `AppModel.makeBrowserView`.
final class BrowserPlaceholderView: NSView {
    init(url: URL?) {
        super.init(frame: .zero)
        let host = NSHostingView(rootView: BrowserPlaceholder(url: url))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }
}

struct BrowserPlaceholder: View {
    let url: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(url?.absoluteString ?? "about:blank")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(8)
            Divider().opacity(0.5)
            VStack(spacing: 10) {
                Image(systemName: "safari")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Browser")
                    .font(.system(size: 14, weight: .semibold))
                Text("Web panes render here once BrowserKit is connected.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
