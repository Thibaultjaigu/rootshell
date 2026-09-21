import XCTest

final class TerminalScrollbarAvailabilityTests: XCTestCase {
    func testTmuxControlPanePreservesDocumentAcrossMissingViewerSample() {
        XCTAssertTrue(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
            isTmuxPane: true,
            hasValidSample: true
        ))
    }

    func testFreshTmuxPaneStillUsesResetPath() {
        XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
            isTmuxPane: true,
            hasValidSample: false
        ))
    }

    func testOrdinaryTerminalStillUsesResetPath() {
        XCTAssertFalse(TerminalScrollbarAvailabilityPolicy.preservesExistingDocument(
            isTmuxPane: false,
            hasValidSample: true
        ))
    }
}
