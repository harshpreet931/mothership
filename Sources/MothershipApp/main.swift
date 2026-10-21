import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    // `NSApplication.delegate` is weak; keep the delegate alive for the app's lifetime.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
