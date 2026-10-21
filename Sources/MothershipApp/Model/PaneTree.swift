import CoreGraphics
import ShipModel
import ShipProtocol

/// Pure edits on the shared `PaneNode` tree. Paths address split nodes by child index from
/// the root, so a divider drag can write its fractions back without rebuilding views.
extension PaneNode {
    static func axis(for direction: SplitDirection) -> SplitAxis {
        switch direction {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }
    }

    func contains(_ id: SurfaceID) -> Bool {
        surfaceIDs.contains(id)
    }

    /// Puts `new` beside `target`. A split in the same direction as the parent joins the
    /// parent's children (halving the target's share) instead of nesting another level.
    func inserting(_ new: SurfaceID, beside target: SurfaceID, direction: SplitDirection) -> PaneNode {
        let axis = Self.axis(for: direction)
        let after = direction == .right || direction == .down
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            return .split(axis: axis, fractions: [0.5, 0.5], children: after ? [self, .leaf(new)] : [.leaf(new), self])
        case .split(let splitAxis, var fractions, var children):
            if splitAxis == axis, let index = children.firstIndex(of: .leaf(target)) {
                let share = fractions[index] / 2
                fractions[index] = share
                let insertAt = after ? index + 1 : index
                children.insert(.leaf(new), at: insertAt)
                fractions.insert(share, at: insertAt)
                return .split(axis: splitAxis, fractions: fractions, children: children)
            }
            return .split(
                axis: splitAxis, fractions: fractions,
                children: children.map { $0.inserting(new, beside: target, direction: direction) }
            )
        }
    }

    /// Removes a leaf; its share goes to its neighbours. Nil when nothing is left.
    func removing(_ id: SurfaceID) -> PaneNode? {
        switch self {
        case .leaf(let leaf):
            return leaf == id ? nil : self
        case .split(let axis, let fractions, let children):
            var newChildren: [PaneNode] = []
            var newFractions: [Double] = []
            for (child, fraction) in zip(children, fractions) {
                if let kept = child.removing(id) {
                    newChildren.append(kept)
                    newFractions.append(fraction)
                }
            }
            if newChildren.isEmpty { return nil }
            if newChildren.count == 1 { return newChildren[0] }
            let total = newFractions.reduce(0, +)
            return .split(axis: axis, fractions: newFractions.map { $0 / max(total, 0.0001) }, children: newChildren)
        }
    }

    func node(at path: [Int]) -> PaneNode? {
        guard let first = path.first else { return self }
        guard case .split(_, _, let children) = self, children.indices.contains(first) else { return nil }
        return children[first].node(at: Array(path.dropFirst()))
    }

    func settingFractions(_ newFractions: [Double], at path: [Int]) -> PaneNode {
        guard case .split(let axis, let fractions, var children) = self else { return self }
        guard let first = path.first else {
            guard newFractions.count == fractions.count else { return self }
            return .split(axis: axis, fractions: newFractions, children: children)
        }
        guard children.indices.contains(first) else { return self }
        children[first] = children[first].settingFractions(newFractions, at: Array(path.dropFirst()))
        return .split(axis: axis, fractions: fractions, children: children)
    }

    /// Same tree shape and leaves; fractions may differ.
    func hasSameStructure(as other: PaneNode) -> Bool {
        switch (self, other) {
        case (.leaf(let a), .leaf(let b)): a == b
        case (.split(let a, _, let lhs), .split(let b, _, let rhs)):
            a == b && lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.hasSameStructure(as: $1) }
        default: false
        }
    }

    /// Every leaf's rectangle when the tree fills `rect` (gaps ignored).
    func frames(in rect: CGRect) -> [SurfaceID: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: rect]
        case .split(let axis, let fractions, let children):
            var result: [SurfaceID: CGRect] = [:]
            var offset: CGFloat = 0
            for (child, fraction) in zip(children, fractions) {
                let childRect: CGRect
                if axis == .horizontal {
                    let width = rect.width * fraction
                    childRect = CGRect(x: rect.minX + offset, y: rect.minY, width: width, height: rect.height)
                    offset += width
                } else {
                    let height = rect.height * fraction
                    childRect = CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: height)
                    offset += height
                }
                result.merge(child.frames(in: childRect)) { first, _ in first }
            }
            return result
        }
    }

    /// The pane geometrically next to `from` in `direction` (y grows downward here).
    func neighbor(of from: SurfaceID, toward direction: SplitDirection) -> SurfaceID? {
        let frames = frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let origin = frames[from] else { return nil }
        let epsilon: CGFloat = 0.0001
        var best: (id: SurfaceID, distance: CGFloat, overlap: CGFloat)?
        for (id, frame) in frames where id != from {
            let distance: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left:
                guard frame.maxX <= origin.minX + epsilon else { continue }
                distance = origin.minX - frame.maxX
                overlap = min(frame.maxY, origin.maxY) - max(frame.minY, origin.minY)
            case .right:
                guard frame.minX >= origin.maxX - epsilon else { continue }
                distance = frame.minX - origin.maxX
                overlap = min(frame.maxY, origin.maxY) - max(frame.minY, origin.minY)
            case .up:
                guard frame.maxY <= origin.minY + epsilon else { continue }
                distance = origin.minY - frame.maxY
                overlap = min(frame.maxX, origin.maxX) - max(frame.minX, origin.minX)
            case .down:
                guard frame.minY >= origin.maxY - epsilon else { continue }
                distance = frame.minY - origin.maxY
                overlap = min(frame.maxX, origin.maxX) - max(frame.minX, origin.minX)
            }
            guard overlap > epsilon else { continue }
            if let current = best {
                if distance < current.distance - epsilon || (abs(distance - current.distance) <= epsilon && overlap > current.overlap) {
                    best = (id, distance, overlap)
                }
            } else {
                best = (id, distance, overlap)
            }
        }
        return best?.id
    }

    /// Sets every split back to equal shares.
    func equalized() -> PaneNode {
        switch self {
        case .leaf: self
        case .split(let axis, _, let children):
            .split(axis: axis, fractions: Array(repeating: 1 / Double(children.count), count: children.count), children: children.map { $0.equalized() })
        }
    }
}
