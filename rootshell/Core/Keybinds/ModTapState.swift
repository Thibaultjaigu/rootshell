import UIKit

/// The per-press part of mod-tap, independent of responders, settings and timers.
struct ModTapState {
    enum Phase: Equatable {
        case pending
        case held
    }

    enum Resolution: Equatable {
        case tap
        case hold
    }

    let sourceKey: UIKeyboardHIDUsage
    let holdModifier: UIKeyModifierFlags
    let startedAt: TimeInterval
    let threshold: TimeInterval
    private(set) var phase: Phase = .pending

    /// Returns true only on the first transition to hold. A shortcut counts as
    /// chord use even when UIKit handles it without delivering pressesBegan.
    @discardableResult
    mutating func useInChord() -> Bool {
        guard phase == .pending else { return false }
        phase = .held
        return true
    }

    @discardableResult
    mutating func advance(to time: TimeInterval) -> Bool {
        guard time - startedAt >= threshold else { return false }
        return useInChord()
    }

    func resolution(onRelease key: UIKeyboardHIDUsage) -> Resolution? {
        guard key == sourceKey else { return nil }
        return phase == .pending ? .tap : .hold
    }

    /// Match the original shortcut first. An unbound chord substitutes the
    /// source modifier instead of accumulating both source and hold modifiers.
    func modifiers(
        hardware: UIKeyModifierFlags,
        originalShortcutIsBound: Bool,
        heldKeys: Set<UIKeyboardHIDUsage>
    ) -> UIKeyModifierFlags {
        guard phase == .held, !originalShortcutIsBound else { return hardware }
        var result = hardware
        if let sourceModifier = Self.modifierFlag(for: sourceKey),
           !heldKeys.contains(where: { $0 != sourceKey && Self.modifierFlag(for: $0) == sourceModifier }) {
            result.remove(sourceModifier)
        }
        result.formUnion(holdModifier)
        return result
    }

    /// Caps Lock is deliberately excluded: it is a toggle, with separate
    /// compensation in the terminal's text path, rather than a held modifier.
    static func modifierFlag(for key: UIKeyboardHIDUsage) -> UIKeyModifierFlags? {
        switch key {
        case .keyboardLeftGUI, .keyboardRightGUI: return .command
        case .keyboardLeftControl, .keyboardRightControl: return .control
        case .keyboardLeftAlt, .keyboardRightAlt: return .alternate
        case .keyboardLeftShift, .keyboardRightShift: return .shift
        default: return nil
        }
    }
}

/// Routing policy for printable chords delivered by GCKeyboard on Catalyst.
/// A nil result leaves the physical chord to UIKit (a binding or Option text).
struct ModifierPrintableChord {
    let modifiers: UIKeyModifierFlags

    init?(
        hardware: UIKeyModifierFlags,
        state: ModTapState?,
        originalShortcutIsBound: Bool,
        heldKeys: Set<UIKeyboardHIDUsage>,
        optionActsAsAlt: Bool
    ) {
        guard !originalShortcutIsBound else { return nil }
        let effective = state?.modifiers(
            hardware: hardware, originalShortcutIsBound: false, heldKeys: heldKeys
        ) ?? hardware
        // Consuming Option must also bypass its composed UIKit text when
        // Option-as-Alt is off. Retained physical Option keeps its normal policy.
        guard !effective.contains(.alternate) || optionActsAsAlt else { return nil }
        modifiers = effective
    }
}
