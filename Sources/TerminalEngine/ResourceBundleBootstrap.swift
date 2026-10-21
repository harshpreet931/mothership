import Foundation
import GhosttyTerminal
import ObjectiveC

/// SwiftPM's generated `Bundle.module` looks for `<Package>_<Target>.bundle` next to
/// `Bundle.main.bundleURL` — for an app that is the `.app` root, where codesign forbids
/// anything but `Contents/`. `scripts/bundle.sh` therefore puts resource bundles in
/// `Contents/Resources/`, and before GhosttyTerminal's `Bundle.module` is first read we
/// briefly answer `bundleURL` for the main bundle with `resourceURL`, so the lazily
/// initialized `Bundle.module` caches the right bundle for the rest of the process.
/// Outside an `.app` (e.g. `swift run`) nothing happens.
@MainActor
enum ResourceBundleBootstrap {
    private static var done = false
    static let ghosttyBundleName = "GhosttyKit_GhosttyTerminal.bundle"

    static func prepare() {
        guard !done else { return }
        done = true
        let main = Bundle.main
        guard main.bundleURL.pathExtension == "app", let resources = main.resourceURL else { return }
        let inRoot = main.bundleURL.appending(path: ghosttyBundleName)
        let inResources = resources.appending(path: ghosttyBundleName)
        guard !FileManager.default.fileExists(atPath: inRoot.path),
              FileManager.default.fileExists(atPath: inResources.path),
              let method = class_getInstanceMethod(Bundle.self, #selector(getter: Bundle.bundleURL))
        else { return }

        typealias Getter = @convention(c) (AnyObject, Selector) -> NSURL
        let original = method_getImplementation(method)
        let originalGetter = unsafeBitCast(original, to: Getter.self)
        let mainBundle = main
        let replacement: @convention(block) (AnyObject) -> NSURL = { object in
            if object === mainBundle { return resources as NSURL }
            return originalGetter(object, #selector(getter: Bundle.bundleURL))
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        // First read of GhosttyTerminal's `Bundle.module`; the result is cached.
        _ = GhosttyRuntimeResources.directoryURL
        method_setImplementation(method, original)
    }
}
