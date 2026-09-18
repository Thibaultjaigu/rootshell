/// A node in a tmux window's layout tree, decoded from the opaque
/// `ghostty_tmux_layout_*` accessors. Geometry is in terminal cells.
///
/// `nonisolated`: built by `TmuxReconcileDecoder.decode` on the off-main action
/// callback thread (see that type), so it must NOT pick up the project's default
/// `@MainActor` isolation. A pure value type — safe to construct/read anywhere.
nonisolated indirect enum TmuxLayoutNode: Equatable {
    case pane(paneId: Int, width: Int, height: Int, x: Int, y: Int)
    case split(direction: Direction, children: [TmuxLayoutNode], width: Int, height: Int, x: Int, y: Int)

    enum Direction: Equatable { case horizontal, vertical }

    var width: Int {
        switch self {
        case let .pane(_, w, _, _, _): return w
        case let .split(_, _, w, _, _, _): return w
        }
    }

    var height: Int {
        switch self {
        case let .pane(_, _, h, _, _): return h
        case let .split(_, _, _, h, _, _): return h
        }
    }
}

extension TmuxLayoutNode {
    /// Generate a server layout, not local pixel ratios. Adjacent splits on the
    /// same axis are flattened so three columns become thirds, not half/quarters.
    func equalizedLayoutString() -> String? {
        guard let body = layoutBody(width: width, height: height, x: 0, y: 0) else { return nil }
        var checksum: UInt16 = 0
        for byte in body.utf8 {
            checksum = (checksum >> 1) | (checksum << 15)
            checksum = checksum &+ UInt16(byte)
        }
        let hex = String(checksum, radix: 16)
        return String(repeating: "0", count: 4 - hex.count) + hex + "," + body
    }

    private func children(along direction: Direction) -> [TmuxLayoutNode] {
        if case let .split(axis, children, _, _, _, _) = self, axis == direction {
            return children.flatMap { $0.children(along: direction) }
        }
        return [self]
    }

    /// One cell per leaf plus a cell for every intervening tmux border.
    private func minimumSize(along direction: Direction) -> Int {
        switch self {
        case .pane: return 1
        case let .split(axis, children, _, _, _, _):
            let sizes = children.map { $0.minimumSize(along: direction) }
            return axis == direction ? sizes.reduce(0, +) + max(0, children.count - 1) : sizes.max() ?? 1
        }
    }

    private func layoutBody(width: Int, height: Int, x: Int, y: Int) -> String? {
        guard width >= minimumSize(along: .horizontal),
              height >= minimumSize(along: .vertical) else { return nil }
        let prefix = "\(width)x\(height),\(x),\(y)"
        switch self {
        case let .pane(id, _, _, _, _):
            return "\(prefix),\(id)"
        case let .split(direction, _, _, _, _, _):
            let children = children(along: direction)
            guard !children.isEmpty else { return nil }
            let horizontal = direction == .horizontal
            var remaining = (horizontal ? width : height) - children.count + 1
            var pending = Array(children.indices)
            var sizes = Array(repeating: 0, count: children.count)
            // Keep deeply nested perpendicular groups large enough to fit; share
            // the remaining cells equally, assigning rounding cells in pane order.
            while !pending.isEmpty {
                let share = remaining / pending.count
                let constrained = pending.filter { children[$0].minimumSize(along: direction) > share }
                if constrained.isEmpty {
                    for (offset, index) in pending.enumerated() {
                        sizes[index] = share + (offset < remaining % pending.count ? 1 : 0)
                    }
                    break
                }
                for index in constrained {
                    sizes[index] = children[index].minimumSize(along: direction)
                    remaining -= sizes[index]
                }
                pending.removeAll { constrained.contains($0) }
            }
            var cursor = horizontal ? x : y
            var bodies: [String] = []
            for (index, child) in children.enumerated() {
                guard let body = child.layoutBody(
                    width: horizontal ? sizes[index] : width,
                    height: horizontal ? height : sizes[index],
                    x: horizontal ? cursor : x, y: horizontal ? y : cursor
                ) else { return nil }
                bodies.append(body)
                cursor += sizes[index] + 1
            }
            let brackets = horizontal ? ("{", "}") : ("[", "]")
            return prefix + brackets.0 + bodies.joined(separator: ",") + brackets.1
        }
    }
}
