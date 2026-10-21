import AppKit

/// `MOTHERSHIP_SNAPSHOT=/path.png`: a PNG of the main window's content shortly after
/// launch, for verifying UI without screen-recording permission. `cacheDisplay` can't see
/// Metal-presented terminal frames or glass materials, so the terminals' own frames are
/// composited on top, the sidebar glass is approximated with a flat fill, and the window
/// buttons are drawn where AppKit actually placed them.
@MainActor
enum DebugSnapshot {
    static func schedule(to path: String, after delay: TimeInterval = 2, window: MainWindowController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
            guard let window else { return }
            if capture(window, to: URL(fileURLWithPath: path)) {
                NSLog("Mothership: wrote snapshot to %@", path)
            } else {
                NSLog("Mothership: snapshot failed")
            }
            NSLog("Mothership: %@", window.contentController.headerDebugDescription)
            if let focused = window.model.focusedSurface, let text = focused.terminal?.readScreenText(scrollbackLines: 0) {
                NSLog("Mothership: focused pane %@ screen:\n%@", focused.id.description, text)
            }
        }
    }

    static func capture(_ controller: MainWindowController, to url: URL) -> Bool {
        guard let window = controller.window, let contentView = window.contentView else { return false }
        contentView.layoutSubtreeIfNeeded()
        let bounds = contentView.bounds
        guard let cached = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        contentView.cacheDisplay(in: bounds, to: cached)

        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: cached.pixelsWide, pixelsHigh: cached.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }
        // The context takes its point→pixel scale from the rep's size, so set it first.
        output.size = bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: output) else { return false }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        contentView.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.canvasShip.setFill()
            bounds.fill()
            // Stand-in for the sidebar's glass.
            let sidebarWidth = CGFloat(controller.sidebarWidth ?? 0)
            if sidebarWidth > 0 {
                let dark = contentView.effectiveAppearance.isDark
                (dark ? NSColor(srgbRed: 0.115, green: 0.12, blue: 0.14, alpha: 1) : NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)).setFill()
                NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height).fill()
            }
        }
        if let cgImage = cached.cgImage {
            NSImage(cgImage: cgImage, size: bounds.size).draw(in: bounds)
        }

        // Terminal frames (Metal/IOSurface) on top of their panes.
        if let workspace = controller.model.selectedWorkspace {
            let dimsUnfocused = workspace.visibleSurfaceIDs.count > 1
            for surface in workspace.surfaces.values {
                guard let terminal = surface.terminal, !terminal.view.isHiddenOrHasHiddenAncestor,
                      terminal.view.window != nil, let image = terminal.snapshotImage() else { continue }
                let frame = terminal.view.convert(terminal.view.bounds, to: contentView)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).addClip()
                image.draw(in: frame)
                if dimsUnfocused, surface.id != workspace.focusedSurface?.id {
                    // Same tint PaneContainerView's dim overlay applies on screen.
                    (contentView.effectiveAppearance.isDark ? NSColor.black.withAlphaComponent(0.22) : NSColor.white.withAlphaComponent(0.28)).setFill()
                    frame.fill(using: .sourceOver)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        // Overlays (the palette) sit above the terminals on screen; redraw them on top.
        for overlay in controller.overlayViews {
            guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { continue }
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            guard let image = rep.cgImage else { continue }
            NSImage(cgImage: image, size: overlay.bounds.size).draw(in: overlay.convert(overlay.bounds, to: contentView))
        }
        drawWindowButtons(window: window, in: contentView)
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

    /// Plain `cacheDisplay` capture of any window's content (Settings).
    static func captureContent(of window: NSWindow, to url: URL) -> Bool {
        guard let contentView = window.contentView,
              let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { return false }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// The traffic lights live outside contentView; draw them where AppKit put them.
    private static func drawWindowButtons(window: NSWindow, in contentView: NSView) {
        let buttons: [(NSWindow.ButtonType, NSColor)] = [
            (.closeButton, NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1)),
            (.miniaturizeButton, NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1)),
            (.zoomButton, NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)),
        ]
        for (type, color) in buttons {
            guard let button = window.standardWindowButton(type), let superview = button.superview else { continue }
            let frame = contentView.convert(superview.convert(button.frame, to: nil), from: nil)
            if type == .closeButton {
                NSLog(
                    "Mothership: close button center is %.1f pt from the top, x %.1f",
                    contentView.bounds.height - frame.midY, frame.midX
                )
            }
            color.setFill()
            let side = min(frame.width, frame.height) - 2
            NSBezierPath(ovalIn: NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)).fill()
        }
    }
}
