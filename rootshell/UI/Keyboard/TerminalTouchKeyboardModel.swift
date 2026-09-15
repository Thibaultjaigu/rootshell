import Foundation
import CoreGraphics

/// Platform-independent behavior shared by the touch surface and its tests.
nonisolated enum TerminalTouchKeyboardModel {
    enum Modifier: Int, CaseIterable, Sendable {
        // Matches KeyModifiers without importing UIKit into the model.
        case control = 1, alt = 2, command = 4, shift = 8
    }

    struct Modifiers: Sendable {
        private(set) var oneShot: Set<Modifier> = []
        private(set) var locked: Set<Modifier> = []
        private var held: Set<Modifier> = []
        private var used: Set<Modifier> = []
        private var lastTap: [Modifier: TimeInterval] = [:]

        var rawValue: Int { oneShot.union(locked).union(held).reduce(0) { $0 | $1.rawValue } }
        func isActive(_ modifier: Modifier) -> Bool { rawValue & modifier.rawValue != 0 }

        mutating func begin(_ modifier: Modifier) {
            held.insert(modifier)
            used.remove(modifier)
        }

        mutating func end(_ modifier: Modifier, at time: TimeInterval, cancelled: Bool = false) {
            held.remove(modifier)
            defer { used.remove(modifier) }
            guard !cancelled, !used.contains(modifier) else { return }
            if locked.remove(modifier) != nil {
                lastTap[modifier] = nil
            } else if oneShot.contains(modifier), time - (lastTap[modifier] ?? -.infinity) < 0.5 {
                oneShot.remove(modifier)
                locked.insert(modifier)
                lastTap[modifier] = nil
            } else if oneShot.remove(modifier) == nil {
                oneShot.insert(modifier)
                lastTap[modifier] = time
            } else {
                lastTap[modifier] = nil
            }
        }

        mutating func consume() {
            used.formUnion(held)
            oneShot.removeAll()
            lastTap.removeAll()
        }

        mutating func reset() { self = Self() }
    }

    enum Page: CaseIterable { case letters, numbers, symbols }
    enum Action: Hashable {
        case text(String), key(String), modifier(Modifier)
        case page, switchKeyboard, drawer, dismiss, joystick, compose, paste, tabs, mode
    }

    struct Key: Hashable {
        let title: String
        let action: Action
        var symbol: String? = nil
        var weight: Double = 1
        var accessibility: String? = nil
    }

    static let controls: [Key] = [
        Key(title: "Esc", action: .key("\u{1b}"), accessibility: "Escape"),
        Key(title: "Tab", action: .key("\t")),
        Key(title: "Ctrl", action: .modifier(.control), accessibility: "Control"),
        Key(title: "Alt", action: .modifier(.alt)),
        Key(title: "Arrows", action: .joystick, symbol: "arrow.up.and.down.and.arrow.left.and.right",
            accessibility: "Arrow joystick. Drag to move, or activate for navigation keys."),
        Key(title: "Tabs", action: .tabs, symbol: "sidebar.left", accessibility: "Vertical Tab Menu"),
        Key(title: "Mode", action: .mode, weight: 1.3, accessibility: "Keyboard Mode and Tools"),
        Key(title: "Hide", action: .dismiss, symbol: "keyboard.chevron.compact.down", accessibility: "Hide keyboard. Hold to pin hidden.")
    ]

    /// Paired neutral colors remain legible through keyboard-window trait changes.
    /// Both cap and ink must resolve from the same appearance, including Shift.
    static func keyColors(dark: Bool, character: Bool, pressed: Bool, selected: Bool) -> (background: Double, ink: Double) {
        if selected { return dark ? (0.96, 0.08) : (0.12, 1.0) }
        if dark { return (pressed ? 0.44 : (character ? 0.32 : 0.19), 1.0) }
        return (pressed ? 0.75 : (character ? 1.0 : 0.79), 0.08)
    }

    static func rows(page: Page) -> [[Key]] {
        func text(_ string: String) -> [Key] { string.map { Key(title: String($0), action: .text(String($0))) } }
        let shift = Key(title: "Shift", action: .modifier(.shift), symbol: "shift", weight: 1.5)
        let delete = Key(title: "Delete", action: .key("\u{7f}"), symbol: "delete.left", weight: 1.5)
        let first: [Key]
        let second: [Key]
        let third: [Key]
        switch page {
        case .letters:
            first = text("qwertyuiop")
            second = text("asdfghjkl")
            third = [shift] + text("zxcvbnm") + [delete]
        case .numbers:
            first = text("1234567890")
            second = text("-/:;()$&@\"")
            third = [Key(title: "#+=", action: .page, weight: 1.5)] + text(".,?!'[]") + [delete]
        case .symbols:
            first = text("[]{}#%^*+=")
            second = text("_\\|~<>€£¥•")
            third = [Key(title: "123", action: .page, weight: 1.5)] + text(".,?!'`;") + [delete]
        }
        return [first, second, third, [
            Key(title: page == .letters ? "123" : "ABC", action: .page, weight: 1.25),
            Key(title: "Apple Keyboard", action: .switchKeyboard, symbol: "keyboard", weight: 1.15),
            Key(title: "space", action: .text(" "), weight: 5.8, accessibility: "Space. Hold and drag to move the terminal cursor."),
            Key(title: "return", action: .key("\r"), symbol: "return", weight: 1.8)
        ]]
    }

    /// Full cells are hit targets; the visual caps are inset inside them.
    static func frames(keys: [Key], width: Double, y: Double, height: Double, inset: Double = 0) -> [CGRect] {
        let unit = max(0, width - inset * 2) / max(1, keys.reduce(0) { $0 + $1.weight })
        var x = inset
        return keys.map { key in
            defer { x += unit * key.weight }
            return CGRect(x: x, y: y, width: unit * key.weight, height: height)
        }
    }

    struct Shortcut {
        let title: String
        let key: String
        var modifiers: Int = 0
        var chord: String {
            (modifiers & 1 != 0 ? "⌃" : "") + (modifiers & 2 != 0 ? "⌥" : "")
                + (modifiers & 8 != 0 ? "⇧" : "")
                + (["\u{1b}": "Esc", "\t": "Tab", "\r": "Return"][key] ?? key)
        }
    }

    enum Preset: String, CaseIterable {
        case shell = "Shell", vim = "Vim", emacs = "Emacs", nano = "Nano", agent = "Agent"

        var shortcuts: [Shortcut] {
            func ctrl(_ title: String, _ key: String) -> Shortcut { Shortcut(title: title, key: key, modifiers: 1) }
            switch self {
            case .shell:
                return [ctrl("Interrupt", "c"), ctrl("EOF", "d"), ctrl("Clear", "l"), ctrl("History", "r"),
                        ctrl("Line start", "a"), ctrl("Line end", "e"), ctrl("Delete word", "w")]
            case .vim:
                return [Shortcut(title: "Normal mode", key: "\u{1b}"), Shortcut(title: "Command", key: ":"),
                        Shortcut(title: "Search", key: "/"), Shortcut(title: "Next match", key: "n"),
                        Shortcut(title: "Previous match", key: "N"), Shortcut(title: "Undo", key: "u"),
                        ctrl("Redo", "r"), ctrl("Half page down", "d"), ctrl("Half page up", "u")]
            case .emacs:
                return [ctrl("Cancel", "g"), ctrl("Prefix", "x"), Shortcut(title: "Command", key: "x", modifiers: 2),
                        ctrl("Search", "s"), ctrl("Line start", "a"), ctrl("Line end", "e"), ctrl("Kill line", "k"), ctrl("Yank", "y")]
            case .nano:
                return [ctrl("Write out", "o"), ctrl("Exit", "x"), ctrl("Search", "w"),
                        ctrl("Cut", "k"), ctrl("Uncut", "u"), ctrl("Help", "g")]
            case .agent:
                return [Shortcut(title: "Escape", key: "\u{1b}"), ctrl("Interrupt", "c"),
                        Shortcut(title: "Tab", key: "\t"), Shortcut(title: "Backtab", key: "\t", modifiers: 8),
                        Shortcut(title: "Shift-Return", key: "\r", modifiers: 8)]
            }
        }
    }

    static let accents: [String: String] = [
        "a": "àáâäæãåā", "e": "èéêëēėę", "i": "ìíîïīį", "o": "òóôöõøœō",
        "u": "ùúûüū", "c": "çćč", "n": "ñń", "s": "ßśš", "y": "ÿý", "z": "žźż"
    ]

    struct SuggestionContext: Equatable, Sendable {
        let document: String
        let generation: UInt64
        let documentGeneration: UInt64
        let range: NSRange
        var word: String { (document as NSString).substring(with: range) }

        init?(document: String, eligibleCount: Int, generation: UInt64, documentGeneration: UInt64) {
            let suffix = document.reversed().prefix { $0.isASCII && $0.isLetter }.reversed()
            let word = String(suffix)
            guard word.count >= 2, word.count <= 32, word.utf16.count <= eligibleCount else { return nil }
            let prefix = document.dropLast(word.count)
            // Never guess inside a path, identifier, flag, or shell expansion.
            guard prefix.isEmpty || prefix.last?.isWhitespace == true else { return nil }
            self.document = document
            self.generation = generation
            self.documentGeneration = documentGeneration
            self.range = NSRange(location: document.utf16.count - word.utf16.count, length: word.utf16.count)
        }
    }
}
