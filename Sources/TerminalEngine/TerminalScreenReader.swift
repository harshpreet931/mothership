import AppKit
import CoreImage
import GhosttyKit
import GhosttyTerminal
import IOSurface

/// Reads text and pixels out of a live surface.
///
/// libghostty-spm exposes `ghostty_surface_read_text` publicly only for its in-memory
/// backend (`InMemoryTerminalSession.readViewportText`); for `.exec` surfaces the raw
/// `ghostty_surface_t` sits in a private stored property of `TerminalSurface`. We reach it
/// through `Mirror`, which reads stored properties without mutating anything, and fall
/// back to nil if a package update renames it.
@MainActor
enum TerminalScreenReader {
    static func rawSurface(of surface: TerminalSurface) -> ghostty_surface_t? {
        for child in Mirror(reflecting: surface).children where child.label == "surface" {
            if let pointer = child.value as? ghostty_surface_t { return pointer }
        }
        return nil
    }

    /// Visible rows, plus up to `scrollbackLines` rows above the viewport. Trailing blanks
    /// are trimmed from every row and blank rows are trimmed from the end.
    static func readText(
        surface: TerminalSurface, scrollbackLines: Int, scrollbar: TerminalScrollbar?
    ) -> String? {
        guard let raw = rawSurface(of: surface) else { return nil }
        let size = ghostty_surface_size(raw)
        let columns = UInt32(size.columns)
        let viewportRows = UInt32(size.rows)
        guard columns > 0, viewportRows > 0 else { return "" }

        var lines: [String] = []
        if scrollbackLines > 0 {
            // Screen coordinates span scrollback + active screen (Patches/ghostty/0018).
            guard let viewportTop = viewportTop(raw, columns: columns, rows: viewportRows, scrollbar: scrollbar) else { return nil }
            let first = viewportTop > UInt32(scrollbackLines) ? viewportTop - UInt32(scrollbackLines) : 0
            let last = viewportTop + viewportRows
            for row in first ..< last {
                guard let line = readRow(raw, row: row, columns: columns, tag: GHOSTTY_POINT_SCREEN) else { return nil }
                lines.append(line)
            }
        } else {
            for row in 0 ..< viewportRows {
                guard let line = readRow(raw, row: row, columns: columns, tag: GHOSTTY_POINT_VIEWPORT) else { return nil }
                lines.append(line)
            }
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The viewport's first row in screen coordinates. Ghostty reports the scrollbar only when
    /// the pane renders, so a hidden pane's is stale once output arrives (an agent's background
    /// pane, a reattached session replaying). Unless the user scrolled up, the viewport is the
    /// last `rows` rows of the screen, counted afresh.
    private static func viewportTop(
        _ surface: ghostty_surface_t, columns: UInt32, rows: UInt32, scrollbar: TerminalScrollbar?
    ) -> UInt32? {
        if let scrollbar, scrollbar.offset + scrollbar.len < scrollbar.total {
            return UInt32(clamping: scrollbar.offset)
        }
        guard let total = screenRowCount(surface, columns: columns, hint: UInt32(clamping: scrollbar?.total ?? 0)) else { return nil }
        return total > rows ? total - rows : 0
    }

    /// Rows in the screen (scrollback + active). Screen reads clamp to the last row, so row r is
    /// the last one exactly when reading rows r...r+1 gives the same text as row r alone (a row
    /// before it adds a newline or the wrapped continuation). `hint`, the scrollbar's total, is
    /// confirmed in four reads; otherwise an exponential then binary search, ~2·log2(rows) reads.
    static func screenRowCount(_ surface: ghostty_surface_t, columns: UInt32, hint: UInt32) -> UInt32? {
        func isLast(_ row: UInt32) -> Bool? {
            guard let one = readRaw(surface, from: row, to: row, columns: columns),
                  let two = readRaw(surface, from: row, to: row + 1, columns: columns) else { return nil }
            return one == two
        }
        if hint >= 2, isLast(hint - 1) == true, isLast(hint - 2) == false { return hint }
        guard let onlyRow = isLast(0) else { return nil }
        if onlyRow { return 1 }
        var below: UInt32 = 0 // not the last row
        var above = max(hint, 256)
        while true {
            guard let last = isLast(above) else { return nil }
            if last { break }
            guard above < UInt32.max / 4 else { return nil }
            below = above
            above *= 2
        }
        while above - below > 1 { // `above` is the last row or past it
            let middle = below + (above - below) / 2
            guard let last = isLast(middle) else { return nil }
            if last { above = middle } else { below = middle }
        }
        return above + 1
    }

    /// Screen rows `from...to`, untrimmed.
    private static func readRaw(_ surface: ghostty_surface_t, from: UInt32, to: UInt32, columns: UInt32) -> [UInt8]? {
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: from),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: columns - 1, y: to),
            rectangle: false
        )
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let pointer = out.text, out.text_len > 0 else { return [] }
        return Array(UnsafeRawBufferPointer(start: pointer, count: Int(out.text_len)))
    }

    /// One physical row; reading rows one at a time keeps soft-wrapped lines on their
    /// own row so callers can index by row.
    private static func readRow(_ surface: ghostty_surface_t, row: UInt32, columns: UInt32, tag: ghostty_point_tag_e) -> String? {
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: row),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_EXACT, x: columns - 1, y: row),
            rectangle: false
        )
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let pointer = out.text, out.text_len > 0 else { return "" }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(out.text_len))
        var line = String(decoding: bytes, as: UTF8.self)
        while let last = line.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
            line.removeLast()
        }
        return line
    }

    // MARK: Pixels

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Ghostty's macOS renderer presents frames by setting an IOSurface as the view's
    /// layer contents, which `cacheDisplay` can't see. Read that IOSurface directly.
    static func snapshot(of view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let layers = [view.layer].compactMap { $0 } + (view.layer?.sublayers ?? [])
        for layer in layers {
            guard let contents = layer.contents else { continue }
            let object = contents as CFTypeRef
            guard CFGetTypeID(object) == IOSurfaceGetTypeID() else { continue }
            let ioSurface = unsafeDowncast(object, to: IOSurfaceRef.self)
            let image = CIImage(ioSurface: ioSurface)
            guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { continue }
            return NSImage(cgImage: cgImage, size: view.bounds.size)
        }
        return nil
    }
}
