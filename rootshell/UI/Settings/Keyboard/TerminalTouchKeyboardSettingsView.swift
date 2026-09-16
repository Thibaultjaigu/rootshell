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
                SettingToggle(Settings.Keyboard.touchLetterPrediction, title: "Letter Prediction", icon: "textformat.abc")
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchSuggestions, title: "Suggestions", icon: "textformat.abc")
                    .themedRow()
                SettingToggle(Settings.Keyboard.touchHaptics, title: "Haptic Feedback", icon: "hand.tap")
                    .themedRow()
            } header: {
                Text("Typing")
            } footer: {
                Text("Letter Prediction uses recent English typing to help choose between nearby letters. Turn it off for literal key targeting. Suggestions are local spelling guesses and completions; tap to apply one. Words are never automatically replaced. The double-space period shortcut follows your Terminal keyboard setting.")
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
            Section {
                SettingToggle(Settings.Keyboard.touchThemeAware, title: "Follow Terminal Theme", icon: "paintpalette")
                    .themedRow()
            } header: {
                Text("Appearance")
            } footer: {
                Text("Match the active terminal’s colors, including tab and window themes. Key labels keep their contrast in every mode.")
            }
            Section("Terminal tools") {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    Text("On iPad, pinch inward to float the keyboard. Drag the … handle to move it. Spread two fingers or double-tap the handle to dock. Docking hides the keys when a hardware keyboard is connected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .themedRow()
                }
                NavigationLink(value: SettingsSearchDestination.toolbarKeys) {
                    Label("Customize Toolbar", systemImage: "command")
                }
                .themedRow()
                Text("Swipe left or right across the keys to reach Symbols, Navigation, and Shortcuts. A temporary overlay shows your position. The toolbar follows your customized button layout. Tap … to open your custom drawer rows, using the same stack or cycle setting as the regular keyboard toolbar. Choose Agent, Shell, Vim, Emacs, or Nano on the Shortcuts page. Shortcuts use each application's standard bindings; customized bindings may behave differently.")
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
        var predictionContext = TerminalTouchKeyboardModel.PredictionContext()
        var lastSample = ""
        init(_ parent: TerminalTouchKeyboardPreview) { self.parent = parent }
        var touchKeyboardCanSend: Bool { true }
        var touchKeyboardSuggestionContext: TerminalTouchKeyboardModel.SuggestionContext? { nil }
        var touchKeyboardPredictionContext: TerminalTouchKeyboardModel.PredictionSnapshot? { predictionContext.snapshot }
        func touchKeyboardInsert(_ text: String) {
            parent.sample = String((parent.sample + text).suffix(180))
            lastSample = parent.sample
            predictionContext.append(text)
        }
        func touchKeyboardSend(_ key: String, modifiers: KeyModifiers) {
            if key == "\u{7f}", modifiers.isEmpty {
                if !parent.sample.isEmpty { parent.sample.removeLast() }
                lastSample = parent.sample
                predictionContext.backspace()
                return
            }
            if modifiers.isEmpty, key == "\r" { touchKeyboardInsert("\n"); return }
            if modifiers.isEmpty, key == "\t" { touchKeyboardInsert("    "); return }
            let label = ["\u{1b}": "Esc", "\u{1b}[A": "↑", "\u{1b}[B": "↓", "\u{1b}[C": "→", "\u{1b}[D": "←", "\r": "Return", "\t": "Tab"][key] ?? key
            touchKeyboardInsert("⟨" + (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.alt) ? "⌥" : "")
                                + (modifiers.contains(.shift) ? "⇧" : "") + label + "⟩")
            predictionContext.reset()
        }
        func touchKeyboardAccept(_ text: String, context: TerminalTouchKeyboardModel.SuggestionContext) {}
        func touchKeyboardInvalidateSuggestions() { predictionContext.reset() }
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
    func updateUIView(_ view: TerminalTouchKeyboardView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.lastSample != sample {
            coordinator.predictionContext.reset()
            coordinator.lastSample = sample
        }
        view.updatePrediction()
    }
    static func dismantleUIView(_ view: TerminalTouchKeyboardView, coordinator: Coordinator) { view.cancelInteraction() }
}
