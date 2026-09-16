import UIKit

/// Keeps UIKit's input region self-sizing, including while content floats in
/// the app window. Only the ordinary content view may move between containers.
final class TerminalTouchKeyboardInputView: UIInputView {
    private let keyboard: TerminalTouchKeyboardView
    var hostSize: (() -> CGSize)?
    var shouldHideAfterDocking: (() -> Bool)?
    var onDocked: (() -> Void)?
    var onNativeFloating: (() -> Void)?
    private var suppressed = false
    private var heightConstraint: NSLayoutConstraint!

    init(keyboard: TerminalTouchKeyboardView) {
        self.keyboard = keyboard
        super.init(frame: keyboard.frame, inputViewStyle: .default)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: keyboard.intrinsicContentSize.height)
        heightConstraint.priority = .init(999)
        heightConstraint.isActive = true
        keyboard.useContainerSizing()
        keyboard.onAppearanceChanged = { [weak self] in self?.updateAppearance() }
        updateAppearance()
        attachKeyboard()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: suppressed ? 0 : keyboard.intrinsicContentSize.height)
    }

    func setSuppressed(_ value: Bool) {
        guard suppressed != value else { return }
        suppressed = value
        keyboard.cancelInteraction()
        if keyboard.superview === self { keyboard.isHidden = value }
        updateHeight()
    }

    func updateHeight() {
        let height = intrinsicContentSize.height
        guard abs(heightConstraint.constant - height) > 0.5 else { return }
        heightConstraint.constant = height
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func updateAppearance() {
        backgroundColor = keyboard.isFloating && !UIAccessibility.isReduceTransparencyEnabled
            ? .clear : keyboard.containerBackgroundColor
        overrideUserInterfaceStyle = keyboard.overrideUserInterfaceStyle
    }

    override func layoutSubviews() {
        let size = hostSize?() ?? .zero
        // UIKit sends intermediate zero-size layouts while replacing input sets.
        // They are not a user's request to dock the floating keyboard.
        guard !suppressed, bounds.width > 0, size.width > 0 else {
            super.layoutSubviews()
            return
        }
        let floating = TerminalTouchKeyboardModel.isFloatingInput(
            width: bounds.width, hostWidth: size.width,
            isPad: traitCollection.userInterfaceIdiom == .pad)
        let docked = keyboard.isFloating && !floating
        if floating && !keyboard.isFloating {
            DispatchQueue.main.async { [weak self] in self?.onNativeFloating?() }
        }
        if docked && shouldHideAfterDocking?() == true {
            // Collapse the existing self-sizing input root before it can grow
            // to docked height. Replacing it with an empty UIView preserves the
            // native floating container's old frame on some iPadOS versions.
            setSuppressed(true)
            keyboard.setFloating(false)
            DispatchQueue.main.async { [weak self] in self?.onDocked?() }
            super.layoutSubviews()
            return
        }
        keyboard.floatingAvailableHeight = max(230, size.height - 48)
        keyboard.setFloating(floating)
        updateHeight()
        super.layoutSubviews()
    }

    func attachKeyboard() {
        guard keyboard.superview !== self else { return }
        keyboard.setFloating(false)
        keyboard.isHidden = suppressed
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboard)
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateHeight()
    }
}

/// Retains a self-sizing input root across software/hardware presentation changes.
final class TerminalTouchKeyboardInputController: UIInputViewController {
    private let keyboardInput: TerminalTouchKeyboardInputView

    init(keyboardInput: TerminalTouchKeyboardInputView) {
        self.keyboardInput = keyboardInput
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { inputView = keyboardInput }
}
