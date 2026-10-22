import AppKit
import Observation
import ShipModel
import SwiftUI

/// While a debug snapshot renders, glass drops its material (which `cacheDisplay` draws as
/// an opaque fallback) and shows only its true tint.
@MainActor
@Observable
final class SnapshotMode {
    static let shared = SnapshotMode()
    var active = false
    private init() {}
}

/// `MOTHERSHIP_SNAPSHOT=/path.png`: a PNG of the main window shortly after launch, for
/// verifying UI without screen-recording permission.
///
/// `cacheDisplay` can't see the Metal sky, Metal-presented terminal frames, materials or
/// layer shadows, so the image is composited layer by layer: the sky (rendered with
/// `ImageRenderer`), the pane canvas with each terminal's IOSurface frame and the attention
/// halos, then every SwiftUI chrome layer in z-order. Glass shows its tint without blur,
/// which over a soft sky is a faithful stand-in.
@MainActor
enum DebugSnapshot {
    /// `MOTHERSHIP_SNAPSHOT_VIEW`: home | fleet | palette | toasts[:open] |
    /// settings[:agents|appearance|notifications|keys].
    static func prepareView(_ view: String?, model: AppModel, root: RootView) {
        guard let view, !view.isEmpty else { return }
        let parts = view.split(separator: ":").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            switch parts[0] {
            case "home": model.show(.home)
            case "fleet": model.show(.fleet)
            case "palette": model.isPalettePresented = true
            case "composer": model.openComposer()
            case "override":
                // web-dashboard runs in Ember; ":on" selects it, ":off" stays on mothership.
                if model.workspaces.count > 1 {
                    let target = model.workspaces[1].id
                    model.setWorkspaceTheme(target, to: "ember")
                    if parts.count > 1, parts[1] == "on" { model.selectWorkspace(target) }
                }
            case "undo":
                // Applies a theme the way the gallery does, then Edit → Undo: the window should
                // be back in the theme it started with.
                let undoManager = root.window?.undoManager
                model.applyTheme(parts.count > 1 ? parts[1] : "aurora", undoManager: undoManager)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Up the responder chain from the window's first responder, as the Edit
                    // menu's ⌘Z does (the snapshot window may not be key).
                    let responder = root.window?.firstResponder
                    let handled = responder?.tryToPerform(Selector(("undo:")), with: nil) == true
                    NSLog("Mothership: undo from %@ handled %d → theme %@",
                          String(describing: responder.map { type(of: $0) }), handled, model.themeID)
                }
            case "longpath":
                // A deep project folder (the user's own, when present) selected, to check row
                // truncation and the card's top edge.
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let candidates = [home + "/Desktop/Juspay/xyne-spaces-test", FileManager.default.currentDirectoryPath]
                let path = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? home
                model.createWorkspace(cwd: path, focus: true)
            case "newtask":
                model.presentNewTask(
                    prompt: "Return X-RateLimit-Limit, X-RateLimit-Remaining and Retry-After on every API response, with tests, and document them in docs/api.",
                    repo: FileManager.default.homeDirectoryForCurrentUser.path + "/code/api-gateway", agents: [.claude, .codex]
                )
                model.newTaskDraft?.baseBranch = "main"
            case "task":
                // A run of the Best-of-3 selected, so the sidebar shows its group.
                if let run = model.tasks.first?.runs.first { model.selectWorkspace(run.workspaceID) }
            case "compare":
                if let task = model.tasks.dropFirst(parts.count > 1 ? (Int(parts[1]) ?? 1) - 1 : 0).first { model.openCompare(task.id) }
            case "diff":
                if let run = model.tasks.first?.runs.first {
                    model.openDiff(run.id)
                    if parts.count > 1 {
                        // "diff:find" shows the find bar with a query.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            NotificationCenter.default.post(name: DiffView.debugFind, object: "Retry-After")
                        }
                    }
                }
            case "prcard":
                guard let path = ProcessInfo.processInfo.environment["MOTHERSHIP_SNAPSHOT"] else { break }
                let statuses = model.pullRequests.values.sorted { $0.number < $1.number }
                let cards = VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        ForEach(statuses, id: \.number) { status in PullRequestChip(status: status) {} }
                    }
                    ForEach(statuses.prefix(2), id: \.number) { status in
                        PullRequestCard(status: status).solidPanel(radius: 14)
                    }
                }
                .padding(24)
                .background(Color(nsColor: .skyBubble))
                let host = NSHostingView(rootView: cards)
                host.appearance = root.window?.appearance
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let url = URL(fileURLWithPath: (path as NSString).deletingPathExtension + "-prcard.png")
                    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
                }
            case "consent":
                // The consent sheet as its own PNG beside the snapshot (sheets are separate
                // windows). Use with MOTHERSHIP_DEMO so no real config is read into it.
                guard let path = ProcessInfo.processInfo.environment["MOTHERSHIP_SNAPSHOT"] else { break }
                let kind = parts.count > 1 ? AgentKind(rawValue: parts[1]) : .opencode
                let sheet = IntegrationConsentSheet(model: model, change: IntegrationChange(kind: kind, install: true)) {}
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: sheet)
                host.appearance = root.window?.appearance
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let url = URL(fileURLWithPath: (path as NSString).deletingPathExtension + "-consent.png")
                    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
                }
            case "settings": model.openSettings(parts.count > 1 ? SettingsTab(rawValue: parts[1]) : .agents)
            case "preview":
                // The theme gallery while a card is hovered: the window previews that theme.
                model.openSettings(.appearance)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    model.previewThemeID = parts.count > 1 ? parts[1] : "aurora"
                }
            case "toasts":
                // Stand-in attention events from whatever sessions exist, plus a finished
                // one written in Markdown, to check the dock.
                model.enqueueToast(AttentionEvent(
                    kind: .finished, session: nil, surface: model.focusedSurface?.id, title: "Claude · Rate limiter fix",
                    body: "## Done\n- **Retries** now reuse the original token\n- Tests pass (`pnpm test`)", shouldNotify: true
                ))
                for session in model.sessions.filter({ $0.needsYou || $0.state.isError }).prefix(2).reversed() {
                    let kind: AttentionEvent.Kind = session.pendingPermission.map { .permission($0) } ?? (session.state.isError ? .failed : .needsInput)
                    model.enqueueToast(AttentionEvent(
                        kind: kind, session: session.id, surface: session.surface,
                        title: "\(session.kind.shortName) · \(session.title ?? "Session")",
                        body: session.lastAssistantMessage ?? session.displayLine ?? "", shouldNotify: true
                    ))
                }
                if parts.count > 1, parts[1] == "open" {
                    root.toastHover.hovering = true
                    model.toastsHeld = true
                }
            default: break
            }
        }
    }

    static func schedule(to path: String, after delay: TimeInterval = 2.4, window: MainWindowController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay - 0.4) {
            SnapshotMode.shared.active = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
            guard let window else { return }
            NSLog("Mothership: snapshot %@", capture(window, to: URL(fileURLWithPath: path)) ? path : "failed")
            SnapshotMode.shared.active = false
            let sky = window.model.skyState
            NSLog("Mothership: sky %@ altitude %.1f° luminance %.3f sky-dark %@ chrome %@ (terminal %@) paused %@", sky.phaseName, sky.sun.altitude,
                  sky.palette.luminance, sky.isDark ? "yes" : "no", window.model.chromeIsDark ? "dark" : "light",
                  window.model.runtime.themeChoice.storageValue, (window.window?.contentView as? RootView)?.skyView.isPaused == true ? "yes" : "no")
            // MOTHERSHIP_SNAPSHOT_SKY_PAIR=1: the sky alone, twice, 1.5 s apart (proves it moves).
            if ProcessInfo.processInfo.environment["MOTHERSHIP_SNAPSHOT_SKY_PAIR"] != nil {
                let base = (path as NSString).deletingPathExtension
                _ = captureSky(window, to: URL(fileURLWithPath: base + "-sky-a.png"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in
                    guard let window else { return }
                    NSLog("Mothership: sky pair %@", captureSky(window, to: URL(fileURLWithPath: base + "-sky-b.png")) ? base : "failed")
                }
            }
            logGeometry(window)
            let ports = window.model.ports.map { "\($0.port) \($0.process) ws=\(window.model.workspaceName(for: $0) ?? "-")" }
            NSLog("Mothership: ports %@", ports.joined(separator: ", "))
            if let focused = window.model.focusedSurface, let text = focused.terminal?.readScreenText(scrollbackLines: 0) {
                NSLog("Mothership: focused pane %@ screen:\n%@", focused.id.description, text)
            }
        }
    }

    static func capture(_ controller: MainWindowController, to url: URL) -> Bool {
        guard let window = controller.window, let root = window.contentView as? RootView else { return false }
        root.layoutSubtreeIfNeeded()
        let bounds = root.bounds
        let scale = window.backingScaleFactor
        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }
        // The context takes its point→pixel scale from the rep's size, so set it first.
        output.size = bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: output) else { return false }
        let model = controller.model
        // Root is flipped (top-left origin); the bitmap context isn't.
        let height = bounds.height
        func cg(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            // 1. Sky.
            drawSky(root.skyView, model: model, size: bounds.size, dark: root.effectiveAppearance.isDark, context: context.cgContext)

            // 2. Canvas: halos, cards, the terminals' own frames, dim, ring, in-card chrome.
            if !root.canvas.isHidden, let workspace = model.selectedWorkspace, let view = root.canvas.selectedWorkspaceView {
                for (id, frame) in view.paneFrames() {
                    let rect = cg(view.convert(frame, to: root))
                    let path = NSBezierPath(roundedRect: rect, xRadius: Sky.radiusPane, yRadius: Sky.radiusPane)
                    if model.paneNeedsAttention(id) {
                        NSGraphicsContext.saveGraphicsState()
                        let glow = NSShadow()
                        glow.shadowColor = NSColor.skyAttention.withAlphaComponent(0.85)
                        glow.shadowBlurRadius = 18
                        glow.set()
                        NSColor.skyAttention.setFill()
                        path.fill()
                        NSGraphicsContext.restoreGraphicsState()
                    } else if !root.effectiveAppearance.isDark {
                        // Day elevation: 0 8 24 ink @ 8 %.
                        NSGraphicsContext.saveGraphicsState()
                        let shadow = NSShadow()
                        shadow.shadowColor = NSColor.skyInk.withAlphaComponent(id == workspace.focusedSurface?.id ? 0.16 : 0.08)
                        shadow.shadowBlurRadius = 24
                        shadow.shadowOffset = NSSize(width: 0, height: -8)
                        shadow.set()
                        NSColor.black.setFill()
                        path.fill()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    drawCached(view: view, rect: frame, at: rect)
                    guard let surface = workspace.surfaces[id], let terminal = surface.terminal else { continue }
                    if let image = terminal.snapshotImage() {
                        NSGraphicsContext.saveGraphicsState()
                        path.addClip()
                        let terminalRect = cg(terminal.view.convert(terminal.view.bounds, to: root))
                        image.draw(in: terminalRect)
                        if workspace.visibleSurfaceIDs.count > 1, id != workspace.focusedSurface?.id {
                            // The cached card already carries its dim; only the terminal's own frame needs it.
                            NSColor.black.withAlphaComponent(0.14).setFill()
                            terminalRect.fill(using: .sourceOver)
                        }
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    for subview in terminal.view.superview?.subviews ?? [] where subview is NSHostingView<ResumeBanner> || subview is NSHostingView<PaneChrome> {
                        guard !subview.isHidden, subview.alphaValue > 0.01 else { continue }
                        drawCached(view: subview, rect: subview.bounds, at: cg(subview.convert(subview.bounds, to: root)))
                    }
                    if workspace.visibleSurfaceIDs.count > 1, id == workspace.focusedSurface?.id {
                        NSColor.skyInk.withAlphaComponent(0.18).setStroke()
                        let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Sky.radiusPane, yRadius: Sky.radiusPane)
                        ring.lineWidth = 1
                        ring.stroke()
                    }
                }
            }

            // 3. Chrome layers in z-order.
            for layer in root.chromeLayers where !layer.isHidden && layer.alphaValue > 0.01 && layer.frame.maxX > 0 {
                drawCached(view: layer, rect: layer.bounds, at: cg(layer.frame))
            }

            // 4. The window buttons, where AppKit put them.
            drawWindowButtons(window: window, in: root, convert: cg)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = output.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }

    /// The sky's layers as they are this instant (twinkles mid-flight included).
    private static func drawSky(_ sky: any SkyRendering, model: AppModel, size: NSSize, dark: Bool, context: CGContext) {
        guard model.skyState.kind != .desktop else {
            NSColor(white: dark ? 0.16 : 0.82, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            return
        }
        context.saveGState()
        sky.renderCurrentFrame(in: context)
        context.restoreGState()
    }

    /// Just the sky, for comparing frames (`MOTHERSHIP_SNAPSHOT_SKY_PAIR`).
    static func captureSky(_ controller: MainWindowController, to url: URL) -> Bool {
        guard let window = controller.window, let root = window.contentView as? RootView else { return false }
        let size = root.bounds.size
        let scale = window.backingScaleFactor
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.scaleBy(x: scale, y: scale)
        root.skyView.renderCurrentFrame(in: context)
        guard let image = context.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// `cacheDisplay` of `view` (its `rect`), drawn at `target` (bitmap coordinates).
    private static func drawCached(view: NSView, rect: NSRect, at target: NSRect) {
        guard rect.width > 0, rect.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        guard let image = rep.cgImage else { return }
        NSImage(cgImage: image, size: rect.size).draw(in: target)
    }

    /// The traffic lights live outside contentView; draw them where AppKit put them.
    private static func drawWindowButtons(window: NSWindow, in root: NSView, convert: (NSRect) -> NSRect) {
        let buttons: [(NSWindow.ButtonType, NSColor)] = [
            (.closeButton, NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1)),
            (.miniaturizeButton, NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1)),
            (.zoomButton, NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)),
        ]
        for (type, color) in buttons {
            guard let button = window.standardWindowButton(type), let superview = button.superview else { continue }
            let frame = convert(root.convert(superview.convert(button.frame, to: nil), from: nil))
            color.setFill()
            let side = min(frame.width, frame.height) - 2
            NSBezierPath(ovalIn: NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)).fill()
        }
    }

    /// Where the window buttons ended up, and whether a click in the top bar reaches our
    /// views rather than the titlebar.
    private static func logGeometry(_ controller: MainWindowController) {
        guard let window = controller.window, let root = window.contentView, let themeFrame = root.superview,
              let close = window.standardWindowButton(.closeButton), let superview = close.superview else { return }
        let frame = root.convert(superview.convert(close.frame, to: nil), from: nil)
        NSLog("Mothership: close button center (%.1f, %.1f) in root (flipped)", frame.midX, frame.midY)
        for x in [100.0, Double(root.bounds.midX), Double(root.bounds.width - 60)] {
            let windowPoint = root.convert(NSPoint(x: x, y: 26), to: nil)
            let hit = themeFrame.hitTest(themeFrame.convert(windowPoint, from: nil))
            NSLog("Mothership: top-bar hit at x=%.0f → %@", x, hit.map { String(describing: type(of: $0)) } ?? "nil")
        }
    }
}
