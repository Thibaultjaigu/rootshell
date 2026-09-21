/// Equalize existing server cells. Most layouts use tmux's native spread
/// operation. Adjacent nested splits on the same axis need an explicit layout,
/// because every binary node can be equal while its visible leaves are not.
/// Before that import, verify tmux's pane-list assignment order against the
/// current layout traversal; custom layout strings cannot encode pane identity.
@MainActor
enum TmuxSplitEqualizer {
    enum Failure: Error {
        case invalidSnapshot
        case layoutChanged
        case didNotConverge
        case unsafeLayout
    }

    private struct Snapshot {
        let layout: String
        let zoomedPaneID: Int?
        let tree: TmuxLayoutNode
        let hasDecorations: Bool

        init(_ reply: String) throws {
            let lines = reply.split(whereSeparator: \.isNewline)
            guard lines.count == 1 else { throw Failure.invalidSnapshot }
            let fields = lines[0].split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 5, !fields[0].isEmpty,
                  fields[1] == "0" || fields[1] == "1",
                  fields[2].first == "%", let paneID = Int(fields[2].dropFirst()), paneID >= 0,
                  let tree = TmuxLayoutNode.parseServerLayout(String(fields[0])) else {
                throw Failure.invalidSnapshot
            }
            self.tree = tree
            // Decorations change tmux's leaf minima. Refuse -E until those
            // additional cells can be accounted for, rather than undercounting.
            hasDecorations = fields[3] != "off" || (fields[4] != "off" && !fields[4].isEmpty)
            layout = String(fields[0])
            zoomedPaneID = fields[1] == "1" ? paneID : nil
        }
    }

    /// `send` must validate that the window still has the same pane traversal
    /// before each command. Every call contains exactly one command / reply.
    static func run(windowID: Int, layout: TmuxLayoutNode,
                    send: (String) async throws -> String) async throws {
        let paneIDs = layout.paneIDs
        guard paneIDs.count > 1 else { return }
        guard Set(paneIDs).count == paneIDs.count, paneIDs.allSatisfy({ $0 >= 0 }) else {
            throw Failure.layoutChanged
        }
        let snapshotCommand = "display-message -p -t @\(windowID) '#{window_layout}|#{window_zoomed_flag}|#{pane_id}|#{pane-border-status}|#{pane-scrollbars}'"
        let paneListCommand = "list-panes -t @\(windowID) -F '#{pane_id}'"
        let original = try Snapshot(await send(snapshotCommand))
        func validate(_ snapshot: Snapshot) throws {
            guard snapshot.tree.hasSameTopology(as: layout) else { throw Failure.layoutChanged }
            guard !snapshot.hasDecorations, snapshot.tree.permitsNativeEqualization else {
                throw Failure.unsafeLayout
            }
        }
        // In particular, reject an unsafe zoomed layout before unzooming it.
        try validate(original)

        func restoreZoom() async throws {
            guard let paneID = original.zoomedPaneID else { return }
            let current = try Snapshot(await send(snapshotCommand))
            // Do not toggle off an already zoomed pane (including an intervening
            // zoom from another client). Window-qualified IDs cannot follow a
            // pane that has since moved to another window.
            if current.zoomedPaneID == nil {
                _ = try await send("resize-pane -Z -t @\(windowID).%\(paneID)")
            }
        }

        if original.tree.hasNestedSameAxisSplit {
            guard let equalized = original.tree.equalizedLayout(),
                  equalized.paneIDs == original.tree.paneIDs else {
                throw Failure.unsafeLayout
            }
            do {
                // layout_parse ignores leaf IDs and assigns w->panes in list
                // order. tmux normally maintains that list in layout traversal
                // order, but verify the server's authoritative state before an
                // operation that could otherwise move pane contents.
                let paneListReply = try await send(paneListCommand)
                let serverPaneIDs = try parsePaneList(paneListReply)
                guard serverPaneIDs == original.tree.paneIDs else {
                    throw Failure.layoutChanged
                }
                _ = try await send("select-layout -t @\(windowID) \(TmuxControlModeParser.quote(equalized.serverLayoutString))")
                let current = try Snapshot(await send(snapshotCommand))
                guard current.tree == equalized else { throw Failure.layoutChanged }
            } catch {
                try? await restoreZoom()
                throw error
            }
            try await restoreZoom()
            return
        }

        do {
            var previous = original.layout
            var current = original
            var converged = false
            // layout_spread_out spreads the first unequal ancestor of a pane.
            // Visit every leaf, repeating because a later ancestor resize may
            // disturb a previously equalized descendant. Compare authoritative
            // server layouts, not the asynchronously delivered UI reconcile.
            // Refresh after EVERY command: subsequent -E calls must not use
            // stale dimensions when checking recursive subtree minima.
            // Bound the passes in case another client keeps resizing the window.
            for _ in 0..<(2 * layout.depth + 1) {
                for paneID in paneIDs {
                    try validate(current)
                    _ = try await send("select-layout -E -t @\(windowID).%\(paneID)")
                    current = try Snapshot(await send(snapshotCommand))
                }
                try validate(current)
                if current.layout == previous {
                    converged = true
                    break
                }
                previous = current.layout
            }
            guard converged else { throw Failure.didNotConverge }
        } catch {
            // A failed spread may already have unzoomed the window. Preserve the
            // original error if cleanup also fails or the topology disappeared.
            try? await restoreZoom()
            throw error
        }
        try await restoreZoom()
    }

    private static func parsePaneList(_ reply: String) throws -> [Int] {
        let lines = reply.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { throw Failure.invalidSnapshot }
        var paneIDs: [Int] = []
        paneIDs.reserveCapacity(lines.count)
        for line in lines {
            guard line.first == "%", let paneID = Int(line.dropFirst()), paneID >= 0 else {
                throw Failure.invalidSnapshot
            }
            paneIDs.append(paneID)
        }
        guard Set(paneIDs).count == paneIDs.count else {
            throw Failure.invalidSnapshot
        }
        return paneIDs
    }
}
