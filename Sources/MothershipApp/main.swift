import AppKit
import TerminalEngine

// Before anything spawns a shell: don't hand panes the identity of whatever launched us.
let scrubbed = InheritedEnvironment.scrub()
if !scrubbed.isEmpty { NSLog("Mothership: cleared inherited %@", scrubbed.joined(separator: ", ")) }

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
