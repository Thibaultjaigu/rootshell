import UIKit

/// Keeps UIKit's input region self-sizing, including while content floats in
/// the app window. Only the ordinary content view may move between containers.
final class TerminalTouchKeyboardInputView: UIInputView {
    private let keyboard: TerminalTouchKeyboardView
    var hostSize: (() -> CGSize)?
    var shouldHideAfterDocking: (() -> Bool)?
    var onDocked: (() -> Void)?
    var onNativePlacementChanged: ((TerminalTouchKeyboardModel.Placement) -> Void)?
    private(set) var isNativeFloating = false
    private var suppressed = false
    private var heightConstraint: NSLayoutConstraint!
    private let floatingPanel = TerminalTouchKeyboardFloatingPanel()

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
        if value { releaseFloatingPanel() }
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
        let docked = isNativeFloating && !floating
        if floating != isNativeFloating {
            isNativeFloating = floating
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isNativeFloating == floating else { return }
                self.onNativePlacementChanged?(floating ? .floating : .docked)
            }
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
        // A native keyboard window may be only as tall as its current card.
        // Feeding that height back into row sizing shrinks the keys on each
        // layout. Use the display's height, independent of the current card.
        let availableHeight = keyboard.usesSystemPlacement
            ? (window?.windowScene?.screen.bounds.height ?? size.height) : size.height
        keyboard.floatingAvailableHeight = max(230, availableHeight - 48)
        keyboard.setFloating(floating)
        updateHeight()
        super.layoutSubviews()
        updateFloatingPanel()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window { releaseFloatingPanel() }
        super.willMove(toWindow: newWindow)
    }

    private func updateFloatingPanel() {
        guard keyboard.usesSystemPlacement, isNativeFloating, !suppressed,
              keyboard.superview === self else {
            releaseFloatingPanel()
            return
        }
        floatingPanel.update(input: self, content: keyboard)
        keyboard.onFloatingDrag = { [weak self] translation, ended in
            self?.floatingPanel.move(translation, ended: ended)
        }
        keyboard.onFloatingDragCancelled = { [weak self] in self?.floatingPanel.cancelDrag() }
        keyboard.onFloatingNudge = { [weak self] delta in self?.floatingPanel.move(delta, ended: true) }
    }

    private func releaseFloatingPanel() {
        guard floatingPanel.isAttached else { return }
        floatingPanel.detach()
        keyboard.onFloatingDrag = nil
        keyboard.onFloatingDragCancelled = nil
        keyboard.onFloatingNudge = nil
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

/// An app input view replaces the system keys, including their drag handle.
/// UIKit can nevertheless keep a taller floating hosting item (the old system
/// keyboard's footer). Clip that item to our card and move the item as a whole,
/// so rendering and hit testing travel together in the keyboard's own window.
/// No keyboard-window frame or private selector is changed.
@MainActor
private final class TerminalTouchKeyboardFloatingPanel {
    private weak var panel: UIView?
    private weak var content: UIView?
    private let cardMask = CAShapeLayer()
    private var baseCenter = CGPoint.zero
    private var lastAppliedCenter: CGPoint?
    private var desiredOrigin: CGPoint?
    private var originalMask: CALayer?
    private var dragOrigin: CGPoint?
    var isAttached: Bool { panel != nil }

    func update(input: UIView, content: UIView) {
        guard let window = input.window else { detach(); return }
        // Stop before the full-screen tracking view. Only the narrow hosting
        // item containing this input belongs to this floating keyboard.
        var candidate = input
        if dragOrigin != nil, let panel, panel.window === window, input.isDescendant(of: panel) {
            // A self-sizing pass can temporarily leave an ancestor at its old
            // height. Do not swap drag hosts and restart the gesture mid-pan.
            candidate = panel
        } else {
            while let parent = candidate.superview, parent !== window,
                  abs(parent.bounds.width - input.bounds.width) < 1,
                  parent.bounds.height >= input.bounds.height,
                  parent.bounds.height <= input.bounds.height + 100 {
                candidate = parent
            }
        }
        guard candidate !== input else { detach(); return }
        if panel !== candidate {
            detach()
            panel = candidate
            baseCenter = candidate.center
            originalMask = candidate.layer.mask
            candidate.layer.mask = cardMask
        }
        self.content = content
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardMask.frame = candidate.bounds
        cardMask.path = UIBezierPath(roundedRect: content.convert(content.bounds, to: candidate),
                                    cornerRadius: content.layer.cornerRadius).cgPath
        cardMask.fillColor = UIColor.black.cgColor
        CATransaction.commit()
        // Leave UIKit's presentation/pinch positioning alone until the user
        // drags. Afterwards retain that position through drawer/rotation layout.
        if let desiredOrigin { position(at: desiredOrigin) }
    }

    /// Translation arrives in the stationary keyboard window, not the moving
    /// (and potentially scaled) input view. Keep the gesture's initial origin
    /// for the entire drag, including when a screen edge clamps the card.
    func move(_ translation: CGPoint, ended: Bool) {
        guard let content, let window = panel?.window else { return }
        if dragOrigin == nil { dragOrigin = content.convert(content.bounds, to: window).origin }
        guard let origin = dragOrigin else { return }
        let destination = CGPoint(x: origin.x + translation.x, y: origin.y + translation.y)
        desiredOrigin = destination
        position(at: destination)
        if ended { dragOrigin = nil }
    }

    private func position(at origin: CGPoint) {
        guard let panel, let content, let window = panel.window,
              let parent = panel.superview else { return }
        // Preserve UIKit's current scale/rotation. Capturing its transform at
        // attachment can freeze a transient pinch/presentation scale forever.
        if panel.center != lastAppliedCenter { baseCenter = panel.center }
        let frame = content.convert(content.bounds, to: window)
        let available = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: 12, dy: 12)
        let proposed = CGRect(origin: origin, size: frame.size)
        let moved = TerminalTouchKeyboardModel.clampedFloatingDragFrame(proposed, in: available)
        let before = parent.convert(frame.origin, from: window)
        let after = parent.convert(moved.origin, from: window)
        // Center is in the parent's coordinates, so UIKit's own transform is
        // applied exactly once. No implicit animation may trail the finger.
        UIView.performWithoutAnimation {
            panel.center = CGPoint(x: panel.center.x + after.x - before.x,
                                   y: panel.center.y + after.y - before.y)
        }
        lastAppliedCenter = panel.center
    }

    func cancelDrag() { dragOrigin = nil }

    func detach() {
        if let panel {
            if panel.center == lastAppliedCenter { panel.center = baseCenter }
            if panel.layer.mask === cardMask { panel.layer.mask = originalMask }
        }
        panel = nil
        content = nil
        originalMask = nil
        lastAppliedCenter = nil
        desiredOrigin = nil
        dragOrigin = nil
    }
}
