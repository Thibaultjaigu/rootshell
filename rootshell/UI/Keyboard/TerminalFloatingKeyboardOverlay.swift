#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit

/// Runtime state is scoped to a window, optionally partitioned by tab. Weak
/// window keys release everything when a scene closes.
@MainActor
final class TerminalTouchKeyboardWindowState {
    private static let windows = NSMapTable<UIWindow, TerminalTouchKeyboardWindowState>.weakToStrongObjects()
    private var states = TerminalTouchKeyboardModel.StateStore<TerminalFloatingKeyboardState>()
    weak var activeController: TerminalKeyboardAccessoryController?
    lazy var presentation = TerminalTouchKeyboardPresentation()

    func state(tabID: UUID?, perTab: Bool) -> TerminalFloatingKeyboardState {
        states.state(tabID: tabID, perTab: perTab) { TerminalFloatingKeyboardState() }
    }

    func activate(tabID: UUID?, perTab: Bool) -> TerminalFloatingKeyboardState {
        states.activate(tabID: tabID, perTab: perTab, make: { TerminalFloatingKeyboardState() }) {
            previous, selected in selected.copyChoices(from: previous)
        }
    }

    static func forWindow(_ window: UIWindow) -> TerminalTouchKeyboardWindowState {
        if let state = windows.object(forKey: window) { return state }
        let state = TerminalTouchKeyboardWindowState()
        windows.setObject(state, forKey: window)
        return state
    }
}

/// UIKit sees the same input view/controller when focus moves between terminals.
/// The keyboard and its effect stay mounted; only their input target changes.
@MainActor
final class TerminalTouchKeyboardPresentation {
    let keyboard = TerminalTouchKeyboardView()
    let input: TerminalTouchKeyboardInputView
    let controller: TerminalTouchKeyboardInputController
    weak var owner: TerminalKeyboardAccessoryController?
    var displayedState: TerminalFloatingKeyboardState?
    var overlay: TerminalFloatingKeyboardOverlay?

    init() {
        keyboard.setBackgroundEffectSurface(nil)
        input = TerminalTouchKeyboardInputView(keyboard: keyboard)
        controller = TerminalTouchKeyboardInputController(keyboardInput: input)
    }

    func dismissOverlay() {
        overlay?.detach()
        overlay = nil
    }
}

@MainActor
final class TerminalFloatingKeyboardState {
    var backgroundEffect = TerminalKeyboardEffectSurface()
    var nativeFloatingPosition: (origin: CGPoint, screen: UIScreen)?
    var presentation: TerminalTouchKeyboardModel.PresentationState?
    var temporarilyUseSystemKeyboard = false
    var requestedWithHardware = false
    var placement = TerminalTouchKeyboardModel.Placement.docked
    var anchor = CGPoint(x: 1, y: 0.85)

    func copyChoices(from other: TerminalFloatingKeyboardState) {
        guard self !== other else { return }
        // Move the live renderer with the visible choices when changing scope.
        // Swap ownership so separate tabs never retain the same effect surface.
        let previousEffect = backgroundEffect
        backgroundEffect = other.backgroundEffect
        other.backgroundEffect = previousEffect
        nativeFloatingPosition = other.nativeFloatingPosition
        presentation = other.presentation
        temporarilyUseSystemKeyboard = other.temporarilyUseSystemKeyboard
        requestedWithHardware = other.requestedWithHardware
        placement = other.placement
        anchor = other.anchor
    }
}

/// A scene-local overlay: only the floating card consumes touches. Everything
/// outside it continues to reach the terminal and the app's ordinary controls.
final class TerminalFloatingKeyboardOverlay: UIView {
    private let keyboard: TerminalTouchKeyboardView
    private var state: TerminalFloatingKeyboardState
    private var dragOrigin: CGRect?
    var onDock: (() -> Void)?
    var isHostActive: (() -> Bool)?

    init(keyboard: TerminalTouchKeyboardView, state: TerminalFloatingKeyboardState) {
        self.keyboard = keyboard
        self.state = state
        super.init(frame: .zero)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(keyboard)
        keyboard.onFloatingDrag = { [weak self] translation, ended in self?.move(translation, ended: ended) }
        keyboard.onFloatingDragCancelled = { [weak self] in self?.dragOrigin = nil }
        keyboard.onFloatingNudge = { [weak self] delta in self?.move(delta, ended: true, allowDock: false) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateState(_ state: TerminalFloatingKeyboardState) {
        guard self.state !== state else { return }
        self.state = state
        dragOrigin = nil
        setNeedsLayout()
    }

    private var available: CGRect { bounds.inset(by: safeAreaInsets).insetBy(dx: 12, dy: 12) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard available.width > 0, available.height > 0 else { return }
        keyboard.floatingAvailableHeight = available.height
        let frame = TerminalTouchKeyboardModel.floatingFrame(in: available,
            height: keyboard.intrinsicContentSize.height, anchor: state.anchor)
        if keyboard.frame.size != frame.size {
            if keyboard.frame.width != frame.width { keyboard.cancelInteraction(preservingModifiers: true) }
            dragOrigin = nil
        }
        keyboard.frame = frame
    }

    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isHostActive?() == true, !isHidden, alpha > 0.01,
              keyboard.frame.contains(point) else { return nil }
        return keyboard.hitTest(convert(point, to: keyboard), with: event)
    }

    private func move(_ translation: CGPoint, ended: Bool, allowDock: Bool = true) {
        guard isHostActive?() == true else { return }
        if dragOrigin == nil { dragOrigin = keyboard.frame; keyboard.cancelInteraction(preservingModifiers: true) }
        guard let origin = dragOrigin else { return }
        let proposed = origin.offsetBy(dx: translation.x, dy: translation.y)
        state.anchor = TerminalTouchKeyboardModel.floatingAnchor(for: proposed, in: available)
        keyboard.frame = TerminalTouchKeyboardModel.floatingFrame(in: available,
            height: keyboard.intrinsicContentSize.height, anchor: state.anchor)
        if ended {
            dragOrigin = nil
            if allowDock && TerminalTouchKeyboardModel.shouldDockAfterDrag(proposed, in: available) { onDock?() }
        }
    }

    func detach() {
        keyboard.cancelInteraction(preservingModifiers: true)
        keyboard.onFloatingDrag = nil
        keyboard.onFloatingDragCancelled = nil
        keyboard.onFloatingNudge = nil
        keyboard.removeFromSuperview()
        removeFromSuperview()
    }
}

#endif
