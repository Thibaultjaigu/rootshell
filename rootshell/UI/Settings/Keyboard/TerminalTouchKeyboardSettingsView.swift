import SwiftUI

struct TerminalTouchKeyboardSettingsView: View {
    @State private var sample = ""
    @State private var previewHeight: CGFloat = 280

    var body: some View {
        List {
            Section {
                SettingToggle(Settings.Keyboard.touchEnabled, title: "Terminal Keyboard", icon: "keyboard.badge.ellipsis")
                    .themedRow()
            } footer: {
                Text("An optional English QWERTY keyboard for terminal sessions. Switch to Apple's keyboard for other languages, swipe typing, emoji, or dictation.")
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("❯").foregroundStyle(.secondary)
                        Text(sample.isEmpty ? "Type a command or prompt…" : sample)
                            .foregroundStyle(sample.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { sample = "" } label: { Image(systemName: "arrow.counterclockwise") }
                            .accessibilityLabel("Clear keyboard preview")
                    }
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .frame(minHeight: 58)
                    TerminalTouchKeyboardPreview(sample: $sample, height: $previewHeight)
                        .frame(height: previewHeight)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Try it")
            } footer: {
                Text("This preview stays on your device and sends nothing to a terminal. Hold Space to move the cursor; tap a modifier for one key, double-tap to lock, or hold it while typing.")
            }
            Section {
                SettingToggle(Settings.Keyboard.touchSuggestions, title: "Suggestions", icon: "textformat.abc")
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchHaptics, title: "Haptic Feedback", icon: "hand.tap")
                    .themedRow()
            } header: {
                Text("Typing")
            } footer: {
                Text("Suggestions are local English spelling guesses and completions. Tap to apply one to recent input. The keyboard never automatically corrects text or adds punctuation.")
            }
            Section {
                SettingToggle(Settings.Keyboard.touchCompactHeight, title: "Compact Height", icon: "arrow.down.to.line")
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchGlyphs, title: "Key Glyphs", icon: "command")
                    .themedRow()
            } header: {
                Text("Layout")
            } footer: {
                Text("Compact Height moves every row, including Space, down into the bottom safe area without reducing key height. The bottom corners adapt to your iPhone. Key Glyphs shows symbols for Escape, Tab, and modifiers; turn it off to show their names.")
            }
            Section("Terminal tools") {
                NavigationLink(value: SettingsSearchDestination.toolbarKeys) {
                    Label("Custom Shortcut Keys", systemImage: "command")
                }
                .themedRow()
                Text("Tap the mode button above the keys to choose Agent, Shell, Vim, Emacs, or Nano, or open symbols, navigation, and function keys. Shortcuts use each application's standard bindings; customized bindings may behave differently.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Terminal Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TerminalTouchKeyboardPreview: UIViewRepresentable {
    @Binding var sample: String
    @Binding var height: CGFloat

    final class Coordinator: TerminalTouchKeyboardHost {
        var parent: TerminalTouchKeyboardPreview
        init(_ parent: TerminalTouchKeyboardPreview) { self.parent = parent }
        var touchKeyboardCanSend: Bool { true }
        var touchKeyboardSuggestionContext: TerminalTouchKeyboardModel.SuggestionContext? { nil }
        func touchKeyboardInsert(_ text: String) { parent.sample = String((parent.sample + text).suffix(180)) }
        func touchKeyboardSend(_ key: String, modifiers: KeyModifiers) {
            if key == "\u{7f}" { if !parent.sample.isEmpty { parent.sample.removeLast() }; return }
            if modifiers.isEmpty, key == "\r" { touchKeyboardInsert("\n"); return }
            if modifiers.isEmpty, key == "\t" { touchKeyboardInsert("    "); return }
            let label = ["\u{1b}": "Esc", "\u{1b}[A": "↑", "\u{1b}[B": "↓", "\u{1b}[C": "→", "\u{1b}[D": "←", "\r": "Return", "\t": "Tab"][key] ?? key
            touchKeyboardInsert("⟨" + (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.alt) ? "⌥" : "")
                                + (modifiers.contains(.shift) ? "⇧" : "") + label + "⟩")
        }
        func touchKeyboardAccept(_ text: String, context: TerminalTouchKeyboardModel.SuggestionContext) {}
        func touchKeyboardInvalidateSuggestions() {}
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> TerminalTouchKeyboardView {
        let view = TerminalTouchKeyboardView()
        view.host = context.coordinator
        view.onHeightChanged = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.parent.height = view.intrinsicContentSize.height
        }
        return view
    }
    func updateUIView(_ view: TerminalTouchKeyboardView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ view: TerminalTouchKeyboardView, coordinator: Coordinator) { view.cancelInteraction() }
}
