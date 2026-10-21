import AppKit
import ShipModel

/// A split of two or more panes along one axis. Fractions are the source of truth (so a
/// window resize keeps proportions); the gaps between children are the draggable dividers.
@MainActor
final class PaneSplitView: NSView {
    static let gap: CGFloat = 6
    static let minimumPaneLength: CGFloat = 90

    let axis: SplitAxis
    let path: [Int]
    private(set) var fractions: [Double]
    private let children: [NSView]
    /// Called when a divider drag ends, with this split's path and new fractions.
    var onFractionsCommitted: (([Int], [Double]) -> Void)?

    private var dragIndex: Int?
    private var dragStartFractions: [Double] = []
    private var dragStartLocation: CGFloat = 0

    init(axis: SplitAxis, fractions: [Double], children: [NSView], path: [Int]) {
        self.axis = axis
        self.path = path
        self.children = children
        let total = fractions.reduce(0, +)
        self.fractions = fractions.count == children.count && total > 0
            ? fractions.map { $0 / total }
            : Array(repeating: 1 / Double(children.count), count: children.count)
        super.init(frame: .zero)
        for child in children { addSubview(child) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private var length: CGFloat {
        axis == .horizontal ? bounds.width : bounds.height
    }

    private var available: CGFloat {
        max(0, length - Self.gap * CGFloat(children.count - 1))
    }

    override func layout() {
        super.layout()
        var offset: CGFloat = 0
        for (index, child) in children.enumerated() {
            let size = index == children.count - 1
                ? max(0, length - offset)
                : (available * fractions[index]).rounded()
            child.frame = axis == .horizontal
                ? CGRect(x: offset, y: 0, width: size, height: bounds.height)
                : CGRect(x: 0, y: offset, width: bounds.width, height: size)
            offset += size + Self.gap
        }
        window?.invalidateCursorRects(for: self)
    }

    private func dividerRect(after index: Int) -> CGRect {
        let child = children[index].frame
        let slop: CGFloat = 3
        return axis == .horizontal
            ? CGRect(x: child.maxX - slop, y: 0, width: Self.gap + slop * 2, height: bounds.height)
            : CGRect(x: 0, y: child.maxY - slop, width: bounds.width, height: Self.gap + slop * 2)
    }

    private func dividerIndex(at point: NSPoint) -> Int? {
        (0 ..< max(0, children.count - 1)).first { dividerRect(after: $0).contains(point) }
    }

    override func resetCursorRects() {
        let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
        for index in 0 ..< max(0, children.count - 1) {
            addCursorRect(dividerRect(after: index), cursor: cursor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local), dividerIndex(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = dividerIndex(at: point) else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            // Double-click a divider: share the two neighbours equally.
            let pair = fractions[index] + fractions[index + 1]
            fractions[index] = pair / 2
            fractions[index + 1] = pair / 2
            needsLayout = true
            onFractionsCommitted?(path, fractions)
            return
        }
        dragIndex = index
        dragStartFractions = fractions
        dragStartLocation = axis == .horizontal ? point.x : point.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = dragIndex, available > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = Double(((axis == .horizontal ? point.x : point.y) - dragStartLocation) / available)
        let pair = dragStartFractions[index] + dragStartFractions[index + 1]
        let minimum = Double(Self.minimumPaneLength / available)
        let first = min(max(dragStartFractions[index] + delta, minimum), pair - minimum)
        guard first > 0, pair - first > 0 else { return }
        fractions[index] = first
        fractions[index + 1] = pair - first
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragIndex != nil else { return super.mouseUp(with: event) }
        dragIndex = nil
        onFractionsCommitted?(path, fractions)
    }
}
