import XCTest

final class PaneCloseConfirmationTests: XCTestCase {
    func testConfirmationRequiresEnabledSettingAndMultiplePanes() {
        XCTAssertFalse(PaneCloseConfirmationPolicy.shouldConfirm(isEnabled: false, paneCount: 2))
        XCTAssertFalse(PaneCloseConfirmationPolicy.shouldConfirm(isEnabled: true, paneCount: 0))
        XCTAssertFalse(PaneCloseConfirmationPolicy.shouldConfirm(isEnabled: true, paneCount: 1))
        XCTAssertTrue(PaneCloseConfirmationPolicy.shouldConfirm(isEnabled: true, paneCount: 2))
        XCTAssertTrue(PaneCloseConfirmationPolicy.shouldConfirm(isEnabled: true, paneCount: 4))
    }
}
