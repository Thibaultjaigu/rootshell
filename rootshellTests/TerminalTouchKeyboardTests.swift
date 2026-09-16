import CoreGraphics
import XCTest

final class TerminalTouchKeyboardTests: XCTestCase {
    private typealias Model = TerminalTouchKeyboardModel

    func testThemeContrastDecodesSRGBBeforeChoosingInk() {
        let gray = Model.RGB(red: 0.5, green: 0.5, blue: 0.5)
        XCTAssertEqual(gray.luminance, 0.214041, accuracy: 0.000001)
        XCTAssertEqual(Model.RGB.white.contrast(against: .black), 21, accuracy: 0.000001)
        // Screenshot regression: the old gamma-encoded brightness calculation
        // rejected the terminal foreground and chose black on these dark keys.
        let key = Model.RGB(red: 44 / 255, green: 44 / 255, blue: 68 / 255)
        let foreground = Model.RGB(red: 205 / 255, green: 214 / 255, blue: 244 / 255)
        XCTAssertEqual(key.readableInk(preferred: foreground), foreground)
        XCTAssertGreaterThan(foreground.contrast(against: key), 9)
        XCTAssertLessThan(Model.RGB.black.contrast(against: key), 2)
    }

    func testThemedInkRemainsReadableForDarkLightPressedAndSelectedKeys() {
        for background in [Model.RGB(red: 30 / 255, green: 30 / 255, blue: 46 / 255),
                           Model.RGB(red: 44 / 255, green: 44 / 255, blue: 68 / 255),
                           Model.RGB(red: 0.28, green: 0.3, blue: 0.38),
                           Model.RGB(red: 0.94, green: 0.92, blue: 0.86),
                           Model.RGB(red: 0.5, green: 0.5, blue: 0.5)] {
            for preferred in [Model.RGB.white, .black, background] {
                let ink = background.readableInk(preferred: preferred)
                XCTAssertGreaterThanOrEqual(ink.contrast(against: background), 4.5)
                // Locked modifiers reverse the fill and ink.
                XCTAssertGreaterThanOrEqual(background.contrast(against: ink), 4.5)
            }
        }
    }

    func testPinchRequiresDeliberateMotionInTheCorrectDirection() {
        XCTAssertEqual(Model.placementAfterPinch(0.7, from: .docked), .floating)
        XCTAssertEqual(Model.placementAfterPinch(1.3, from: .floating), .docked)
        XCTAssertEqual(Model.placementAfterPinch(0.95, from: .docked), .docked)
        XCTAssertEqual(Model.placementAfterPinch(1.05, from: .floating), .floating)
        XCTAssertEqual(Model.placementAfterPinch(1.4, from: .docked), .docked)
        XCTAssertEqual(Model.placementAfterPinch(0.6, from: .floating), .floating)
        XCTAssertEqual(Model.placementAfterPinch(.nan, from: .floating), .floating)
    }

    func testFloatingKeyboardFitsRotatedAndNarrowWindows() {
        for size in [CGSize(width: 810, height: 1080), CGSize(width: 1080, height: 810),
                     CGSize(width: 320, height: 500), CGSize(width: 260, height: 260)] {
            let available = CGRect(origin: CGPoint(x: 12, y: 36), size: size)
            for anchor in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: -2, y: 4)] {
                let frame = Model.floatingFrame(in: available, height: 376, anchor: anchor)
                XCTAssertTrue(available.contains(frame))
                XCTAssertLessThanOrEqual(frame.width, 320)
                XCTAssertGreaterThan(frame.height, 0)
            }
        }
    }

    func testFloatingDragAnchorClampsAndSurvivesResize() {
        let available = CGRect(x: 12, y: 36, width: 1000, height: 700)
        let original = Model.floatingFrame(in: available, height: 252, anchor: CGPoint(x: 0.3, y: 0.8))
        let anchor = Model.floatingAnchor(for: original, in: available)
        XCTAssertEqual(anchor.x, 0.3, accuracy: 0.001)
        XCTAssertEqual(anchor.y, 0.8, accuracy: 0.001)
        let moved = original.offsetBy(dx: 5000, dy: -5000)
        XCTAssertEqual(Model.floatingAnchor(for: moved, in: available), CGPoint(x: 1, y: 0))
        let resized = CGRect(x: 12, y: 36, width: 330, height: 480)
        XCTAssertTrue(resized.contains(Model.floatingFrame(in: resized, height: 376, anchor: anchor)))
    }

    func testDraggingToBottomCenterDocksButBottomCornerDoesNot() {
        let available = CGRect(x: 12, y: 36, width: 1000, height: 700)
        let centered = Model.floatingFrame(in: available, height: 252, anchor: CGPoint(x: 0.5, y: 1))
        XCTAssertTrue(Model.shouldDockAfterDrag(centered, in: available))
        XCTAssertFalse(Model.shouldDockAfterDrag(centered.offsetBy(dx: 0, dy: -80), in: available))
        let corner = Model.floatingFrame(in: available, height: 252, anchor: CGPoint(x: 1, y: 1))
        XCTAssertFalse(Model.shouldDockAfterDrag(corner, in: available))
    }

    func testSystemFloatingWidthAdaptsWithoutMistakingNarrowDockedWindows() {
        XCTAssertTrue(Model.isFloatingInput(width: 320, hostWidth: 834, isPad: true))
        XCTAssertTrue(Model.isFloatingInput(width: 320, hostWidth: 375, isPad: true))
        XCTAssertFalse(Model.isFloatingInput(width: 834, hostWidth: 834, isPad: true))
        XCTAssertFalse(Model.isFloatingInput(width: 320, hostWidth: 320, isPad: true))
        XCTAssertFalse(Model.isFloatingInput(width: 320, hostWidth: 834, isPad: false))
        XCTAssertFalse(Model.isFloatingInput(width: 0, hostWidth: 834, isPad: true))
    }

    func testTabMenuAndModeAreAlwaysInControlRow() {
        XCTAssertTrue(Model.controls.contains { $0.action == .tabs })
        XCTAssertTrue(Model.controls.contains { $0.action == .mode })
        XCTAssertEqual(Model.controls.count, 8)
        XCTAssertTrue(Model.Preset.allCases.contains(.agent))
    }

    func testKeyContrastAcrossAppearancePressedAndLockedStates() {
        func luminance(_ white: Double) -> Double {
            white <= 0.04045 ? white / 12.92 : pow((white + 0.055) / 1.055, 2.4)
        }
        for dark in [false, true] {
            for character in [false, true] {
                for pressed in [false, true] {
                    for selected in [false, true] {
                        let colors = Model.keyColors(dark: dark, character: character, pressed: pressed, selected: selected)
                        let a = luminance(colors.background), b = luminance(colors.ink)
                        XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5)
                    }
                }
            }
        }
    }

    func testDoubleTapTimingMatchesOriginalToolbar() {
        var state = Model.Modifiers()
        state.begin(.control); state.end(.control, at: 1)
        state.begin(.control); state.end(.control, at: 1.45)
        XCTAssertEqual(state.locked, [.control])
        state.consume()
        XCTAssertEqual(state.rawValue, 1)
        state.begin(.control); state.end(.control, at: 2)
        XCTAssertEqual(state.rawValue, 0)
    }

    func testModifierTapIsOneShot() {
        var state = Model.Modifiers()
        state.begin(.control)
        state.end(.control, at: 1)
        XCTAssertEqual(state.rawValue, 1)
        state.consume()
        XCTAssertEqual(state.rawValue, 0)
    }

    func testDoubleTapLocksUntilTappedAgain() {
        var state = Model.Modifiers()
        state.begin(.shift); state.end(.shift, at: 1)
        state.begin(.shift); state.end(.shift, at: 1.2)
        state.consume()
        XCTAssertEqual(state.locked, [.shift])
        state.begin(.shift); state.end(.shift, at: 2)
        XCTAssertEqual(state.rawValue, 0)
    }

    func testHeldChordRemainsActiveAcrossLettersAndDoesNotLatch() {
        var state = Model.Modifiers()
        state.begin(.control); state.begin(.alt)
        XCTAssertEqual(state.rawValue, 3)
        state.consume(); state.consume()
        XCTAssertEqual(state.rawValue, 3)
        state.end(.control, at: 2); state.end(.alt, at: 2)
        XCTAssertEqual(state.rawValue, 0)
    }

    func testCancelledModifierDoesNotLatch() {
        var state = Model.Modifiers()
        state.begin(.control); state.end(.control, at: 1, cancelled: true)
        XCTAssertEqual(state.rawValue, 0)
    }

    func testConsumedModifierCannotAccidentallyBecomeLockedOnNextTap() {
        var state = Model.Modifiers()
        state.begin(.control); state.end(.control, at: 1)
        state.consume()
        state.begin(.control); state.end(.control, at: 1.1)
        XCTAssertTrue(state.locked.isEmpty)
        XCTAssertEqual(state.oneShot, [.control])
    }

    func testResetClearsEveryModifierState() {
        var state = Model.Modifiers()
        state.begin(.shift); state.end(.shift, at: 1)
        state.begin(.shift); state.end(.shift, at: 1.1)
        state.begin(.control)
        state.reset()
        XCTAssertEqual(state.rawValue, 0)
        state.end(.control, at: 1.2, cancelled: true)
        XCTAssertEqual(state.rawValue, 0)
    }

    func testTypingRowsFillTheirBoundsWithoutOverlapping() {
        for width in [320.0, 375, 393, 440, 568, 744, 1024, 1366] {
            for page in Model.Page.allCases {
                let rows = Model.rows(page: page)
                XCTAssertEqual(rows.count, 4)
                for (row, keys) in rows.enumerated() {
                    let inset = page == .letters && row == 1 ? width / 20 : 2
                    let frames = Model.frames(keys: keys, width: width, y: Double(row) * 54, height: 54, inset: inset)
                    XCTAssertEqual(frames.count, keys.count)
                    XCTAssertEqual(frames.first!.minX, inset, accuracy: 0.001)
                    XCTAssertEqual(frames.last!.maxX, width - inset, accuracy: 0.001)
                    for (left, right) in zip(frames, frames.dropFirst()) {
                        XCTAssertEqual(left.maxX, right.minX, accuracy: 0.001)
                        XCTAssertGreaterThan(left.width, 25)
                    }
                }
            }
        }
    }

    func testQWERTYOrderAndSpaceWidth() {
        let rows = Model.rows(page: .letters)
        XCTAssertEqual(rows[0].map(\.title).joined(), "qwertyuiop")
        XCTAssertEqual(rows[1].map(\.title).joined(), "asdfghjkl")
        XCTAssertEqual(rows[2].dropFirst().dropLast().map(\.title).joined(), "zxcvbnm")
        XCTAssertGreaterThan(rows[3][2].weight, 5)
        XCTAssertEqual(rows[3][1].action, .switchKeyboard)
    }

    func testAllCodingPunctuationIsReachable() {
        let characters = Set(Model.Page.allCases.flatMap { Model.rows(page: $0).flatMap { $0 }.compactMap { key -> String? in
            if case .text(let text) = key.action { return text }; return nil
        } }.joined())
        for value in "0123456789`~!@#$%^&*()-_=+[]{}\\|;:'\",.<>/?" {
            XCTAssertTrue(characters.contains(value), "Missing \(value)")
        }
    }

    func testPresetsExposeExactKeysAndNeverEmbedCommands() {
        XCTAssertEqual(Model.Preset.shell.shortcuts.first?.key, "c")
        XCTAssertEqual(Model.Preset.shell.shortcuts.first?.modifiers, 1)
        XCTAssertEqual(Model.Preset.vim.shortcuts.first?.key, "\u{1b}")
        let backtab = Model.Preset.agent.shortcuts.first { $0.title == "Backtab" }
        XCTAssertEqual(backtab?.key, "\t")
        XCTAssertEqual(backtab?.modifiers, 8)
        for preset in Model.Preset.allCases {
            XCTAssertTrue(preset.shortcuts.allSatisfy { $0.key.count == 1 })
        }
    }

    func testSuggestionsRejectCodeTokensAndUntrackedSuffixes() {
        for value in ["/usr/bni", "--verbose", "my_var", "$PATH", "git.staus", "echo x", ""] {
            XCTAssertNil(Model.SuggestionContext(document: value, eligibleCount: value.utf16.count, generation: 0, documentGeneration: 0), value)
        }
        XCTAssertNil(Model.SuggestionContext(document: "hello", eligibleCount: 2, generation: 0, documentGeneration: 0))
        XCTAssertNotNil(Model.SuggestionContext(document: "please explai", eligibleCount: 6, generation: 0, documentGeneration: 0))
    }

    func testSuggestionSnapshotChangesEvenWhenAppendKeepsGeneration() {
        var document = TerminalCorrectionContext()
        document.apply(.text("hel", eligible: true))
        let old = context(document)
        document.apply(.text("p", eligible: true))
        XCTAssertNotEqual(old, context(document))
    }

    func testSuggestionReplacementIsLiteralAndCannotCrossInvalidation() {
        var document = TerminalCorrectionContext()
        document.apply(.text("explain teh", eligible: true))
        let snapshot = context(document)!
        let replacement = document.replacement(in: snapshot.range, with: "the", generation: snapshot.generation)!
        XCTAssertEqual(Array(replacement.payload), [127, 127, 127] + Array("the".utf8))
        document.apply(.invalidate)
        XCTAssertNil(context(document))
        XCTAssertFalse(document.apply(.correction(replacement)))
    }

    func testSuggestionReplacementDoesNotEraseComplexGraphemes() {
        var document = TerminalCorrectionContext()
        document.apply(.text("🙂 teh", eligible: true))
        let snapshot = context(document)!
        XCTAssertEqual(snapshot.range, NSRange(location: 3, length: 3))
        XCTAssertNotNil(document.replacement(in: snapshot.range, with: "the", generation: snapshot.generation))
    }

    private func context(_ document: TerminalCorrectionContext) -> Model.SuggestionContext? {
        Model.SuggestionContext(document: document.document, eligibleCount: document.eligibleUTF16Count,
                                generation: document.generation, documentGeneration: document.documentGeneration)
    }
}
