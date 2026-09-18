import XCTest

final class TmuxLayoutTests: XCTestCase {
    private func pane(_ id: Int) -> TmuxLayoutNode {
        .pane(paneId: id, width: 1, height: 1, x: 0, y: 0)
    }

    private func split(_ axis: TmuxLayoutNode.Direction, _ children: [TmuxLayoutNode],
                       width: Int = 203, height: Int = 69) -> TmuxLayoutNode {
        .split(direction: axis, children: children, width: width, height: height, x: 0, y: 0)
    }

    private func body(_ layout: TmuxLayoutNode) throws -> String {
        String(try XCTUnwrap(layout.equalizedLayoutString()).dropFirst(5))
    }

    func testNestedThreeColumnsKeepPaneOrderAndRows() throws {
        let left = split(.vertical, [pane(1), pane(10)])
        let middle = split(.vertical, [pane(7), pane(13)])
        let right = split(.vertical, [pane(11), pane(12)])
        let layout = split(.horizontal, [left, split(.horizontal, [middle, right])])
        XCTAssertEqual(try body(layout), "203x69,0,0{67x69,0,0[67x34,0,0,1,67x34,0,35,10],67x69,68,0[67x34,68,0,7,67x34,68,35,13],67x69,136,0[67x34,136,0,11,67x34,136,35,12]}")
        // The integration harness also submits this exact result to real tmux.
        print("TMUX_LAYOUT_FIXTURE=\(try XCTUnwrap(layout.equalizedLayoutString()))")
    }

    func testNestedVerticalSplitsAndRounding() throws {
        let layout = split(.vertical, [pane(0), split(.vertical, [pane(2), pane(3)])], width: 10, height: 12)
        XCTAssertEqual(try body(layout), "10x12,0,0[10x4,0,0,0,10x3,0,5,2,10x3,0,9,3]")
    }

    func testPerpendicularGroupRetainsMinimumWidth() throws {
        let group = split(.vertical, [split(.horizontal, [pane(1), pane(2), pane(3)]), pane(4)])
        let layout = split(.horizontal, [pane(0), group], width: 8, height: 5)
        XCTAssertEqual(try body(layout), "8x5,0,0{2x5,0,0,0,5x5,3,0[5x2,3,0{1x2,3,0,1,1x2,5,0,2,1x2,7,0,3},5x2,3,3,4]}")
    }

    func testTooSmallLayoutIsRejected() {
        XCTAssertNil(split(.horizontal, [pane(1), pane(2)], width: 2).equalizedLayoutString())
    }

    func testEmptySplitIsRejected() {
        XCTAssertNil(split(.horizontal, []).equalizedLayoutString())
    }

    func testSinglePaneChecksumAndZeroID() {
        let layout = TmuxLayoutNode.pane(paneId: 0, width: 80, height: 24, x: 0, y: 0)
        XCTAssertEqual(layout.equalizedLayoutString(), "b25d,80x24,0,0,0")
    }
}
