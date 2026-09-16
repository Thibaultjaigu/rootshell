import UIKit
import Combine
import SwiftUI

private struct TerminalTouchKeyboardPalette {
    let background: UIColor
    let key: UIColor
    let pressedKey: UIColor
    let pressedInk: UIColor
    let ink: UIColor
    let toolbarInk: UIColor
    let isLight: Bool

    init?(colors: ThemeManager.ThemeInfo.ThemeColors) {
        guard let base = Color(hex: colors.background), let derived = ThemeUIColorDerivation.derive(from: colors) else { return nil }
        let key = derived.sheetRowBackground
        let preferred = Color(hex: colors.foreground) ?? derived.tabText
        func rgb(_ color: Color) -> TerminalTouchKeyboardModel.RGB {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            return .init(red: Double(r), green: Double(g), blue: Double(b))
        }
        func readable(on surface: Color) -> Color {
            let ink = rgb(surface).readableInk(preferred: rgb(preferred))
            return Color(red: ink.red, green: ink.green, blue: ink.blue)
        }
        let ink = readable(on: key)
        let pressed = key.blended(toward: ink, amount: 0.1)
        self.background = UIColor(base)
        self.key = UIColor(key)
        self.pressedKey = UIColor(pressed)
        self.ink = UIColor(ink)
        self.pressedInk = UIColor(readable(on: pressed))
        self.toolbarInk = UIColor(readable(on: base))
        self.isLight = base.isLight
    }
}

private enum TerminalTouchKeyboardAppearance {
    static let background = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 34 / 255, green: 34 / 255, blue: 39 / 255, alpha: 1)
            : UIColor(red: 210 / 255, green: 213 / 255, blue: 219 / 255, alpha: 1)
    }
    static let toolbar = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 38 / 255, green: 38 / 255, blue: 46 / 255, alpha: 1)
            : UIColor(red: 233 / 255, green: 235 / 255, blue: 240 / 255, alpha: 1)
    }
}

/// An in-app keyboard. The terminal remains first responder throughout typing.
@MainActor
protocol TerminalTouchKeyboardHost: AnyObject {
    var touchKeyboardThemeColors: ThemeManager.ThemeInfo.ThemeColors? { get }
    var touchKeyboardCanSend: Bool { get }
    var touchKeyboardSuggestionContext: TerminalTouchKeyboardModel.SuggestionContext? { get }
    func touchKeyboardInsert(_ text: String)
    func touchKeyboardSend(_ key: String, modifiers: KeyModifiers)
    func touchKeyboardAccept(_ text: String, context: TerminalTouchKeyboardModel.SuggestionContext)
    func touchKeyboardInvalidateSuggestions()
}

extension TerminalTouchKeyboardHost {
    var touchKeyboardThemeColors: ThemeManager.ThemeInfo.ThemeColors? { nil }
}

private final class TerminalTouchKeycap: UIView {
    let key: TerminalTouchKeyboardModel.Key
    let plate = UIView()
    let label = UILabel()
    let icon = UIImageView()
    private let lockIndicator = UIView()
    private let toolbarKey: Bool
    var palette: TerminalTouchKeyboardPalette? { didSet { updateColor() } }
    var locked = false { didSet { lockIndicator.isHidden = !locked } }
    var activate: (() -> Void)?
    var pressed = false { didSet { updateColor() } }
    var selected = false { didSet { updateColor() } }

    init(_ key: TerminalTouchKeyboardModel.Key, small: Bool = false) {
        self.key = key
        self.toolbarKey = small
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = [.keyboardKey]
        accessibilityLabel = key.accessibility ?? key.title
        plate.isUserInteractionEnabled = false
        plate.layer.cornerRadius = small ? 12 : 8
        plate.layer.cornerCurve = .continuous
        plate.layer.shadowColor = UIColor.black.cgColor
        plate.layer.shadowOffset = CGSize(width: 0, height: 1)
        plate.layer.shadowRadius = 0.5
        addSubview(plate)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: small ? 13 : (key.title.count == 1 ? 25 : 16), weight: small ? .medium : .regular)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.text = key.title
        plate.addSubview(label)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: small ? 17 : 21, weight: .regular)
        plate.addSubview(icon)
        lockIndicator.layer.cornerRadius = 1.5
        lockIndicator.isHidden = true
        plate.addSubview(lockIndicator)
        setSymbol(key.symbol)
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSymbol(_ name: String?) {
        icon.image = name.flatMap { UIImage(systemName: $0) }
        label.isHidden = name != nil
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        plate.frame = bounds.insetBy(dx: 3, dy: 5)
        label.frame = plate.bounds.insetBy(dx: 3, dy: 0)
        lockIndicator.frame = CGRect(x: (plate.bounds.width - 14) / 2, y: plate.bounds.height - 4, width: 14, height: 2.5)
        let iconSize = CGSize(width: min(24, max(0, plate.bounds.width - 8)), height: min(23, max(0, plate.bounds.height - 6)))
        icon.frame = CGRect(x: (plate.bounds.width - iconSize.width) / 2, y: (plate.bounds.height - iconSize.height) / 2,
                            width: iconSize.width, height: iconSize.height)
    }
    func updateColor() {
        let character: Bool = { if case .text = key.action { return true }; return false }()
        let selected = self.selected, pressed = self.pressed, toolbarKey = self.toolbarKey
        // A keyboard can acquire its final appearance after attachment. Do not
        // mix a light-only background with a dynamically changing .label color.
        plate.backgroundColor = UIColor { traits in
            if toolbarKey && !selected {
                return pressed ? UIColor.label.resolvedColor(with: traits).withAlphaComponent(0.12) : .clear
            }
            let colors = TerminalTouchKeyboardModel.keyColors(dark: traits.userInterfaceStyle == .dark,
                character: character, pressed: pressed, selected: selected)
            if traits.userInterfaceStyle == .dark, !selected {
                return UIColor(red: colors.background, green: colors.background, blue: colors.background + 4 / 255, alpha: 1)
            }
            return UIColor(white: colors.background, alpha: 1)
        }
        let ink = UIColor { traits in
            let colors = TerminalTouchKeyboardModel.keyColors(dark: traits.userInterfaceStyle == .dark,
                character: character, pressed: pressed, selected: selected)
            return UIColor(white: colors.ink, alpha: 1)
        }
        label.textColor = ink
        icon.tintColor = ink
        lockIndicator.backgroundColor = ink
        if let palette {
            let themedInk = selected ? palette.key : (toolbarKey ? palette.toolbarInk : (pressed ? palette.pressedInk : palette.ink))
            plate.backgroundColor = selected ? palette.ink : (toolbarKey ? (pressed ? palette.toolbarInk.withAlphaComponent(0.12) : .clear) : (pressed ? palette.pressedKey : palette.key))
            label.textColor = themedInk
            icon.tintColor = themedInk
            lockIndicator.backgroundColor = themedInk
        }
        plate.layer.shadowOpacity = toolbarKey || traitCollection.userInterfaceStyle == .dark ? 0 : 0.12
        plate.layer.borderWidth = UIAccessibility.isDarkerSystemColorsEnabled && (!toolbarKey || selected) ? 1 : 0
        plate.layer.borderColor = UIColor.label.cgColor
        accessibilityTraits = selected ? [.keyboardKey, .selected] : [.keyboardKey]
    }
    override func accessibilityActivate() -> Bool { activate?(); return true }
}

/// UIKit cancels the ordinary button tap when this recognizer starts repeating.
private final class TerminalTouchRepeatingButton: UIButton {
    var repeatAction: (() -> Void)?
    private var repeatTask: Task<Void, Never>?
    func enableRepeat(_ action: @escaping () -> Void) {
        repeatAction = action
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.35
        addGestureRecognizer(hold)
    }
    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            repeatAction?()
            repeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, let self, self.window != nil else { return }
                    self.repeatAction?()
                }
            }
        } else if gesture.state != .changed || !bounds.contains(gesture.location(in: self)) { cancelRepeat() }
    }
    func cancelRepeat() { repeatTask?.cancel(); repeatTask = nil }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancelRepeat() } }
}

final class TerminalTouchKeyboardView: UIView, KeyboardButtonDelegate {
    typealias Model = TerminalTouchKeyboardModel
    weak var host: TerminalTouchKeyboardHost? { didSet { updateAppearance() } }
    private var palette: TerminalTouchKeyboardPalette?
    var onAppearanceChanged: (() -> Void)?
    var containerBackgroundColor: UIColor { palette?.background ?? TerminalTouchKeyboardAppearance.background }
    weak var sequenceDelegate: KeyboardButtonDelegate?
    var onModifiersChanged: ((KeyModifiers) -> Void)?
    var onDismiss: (() -> Void)?
    var onPinHidden: (() -> Void)?
    var onSwitchKeyboard: (() -> Void)?
    var onCompose: (() -> Void)?
    var onPaste: (() -> Void)?
    var onTabs: (() -> Void)?
    var onCustomize: (() -> Void)?
    var onHeightChanged: (() -> Void)?
    var onPlacementRequested: ((Model.Placement) -> Void)? { didSet { refreshPlacementActions() } }
    var onFloatingDrag: ((CGPoint, Bool) -> Void)?
    var onFloatingDragCancelled: (() -> Void)?
    var onFloatingNudge: ((CGPoint) -> Void)?
    private(set) var isFloating = false
    var floatingAvailableHeight: CGFloat = 1000 {
        didSet { if abs(oldValue - floatingAvailableHeight) > 0.5 { setNeedsLayout() } }
    }

    private var modifierState = Model.Modifiers()
    private var page = Model.Page.letters
    private var preset = Model.Preset.shell
    private var drawerOpen = false
    private var rows: [[TerminalTouchKeycap]] = []
    private var controls: [TerminalTouchKeycap] = []
    private let background = UIView()
    private let controlGlass = UIVisualEffectView()
    private let drawer = UIScrollView()
    private let sections = UISegmentedControl(items: ["Symbols", "Navigation", "Shortcuts", "Custom"])
    private let presets = UISegmentedControl(items: Model.Preset.allCases.map(\.rawValue))
    private let closeDrawerButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)
    private let grabber = UIButton(type: .system)
    private let grabberLine = UIView()
    private var drawerButtons: [TerminalTouchRepeatingButton] = []
    private var drawerColumns = 6
    private let suggestions = UIStackView()
    private let preview = UILabel()
    private let accents = UIStackView()
    private var accentChoices: [String] = []
    private var accentIndex = 0
    private let checker = UITextChecker()
    private var suggestionTask: Task<Void, Never>?
    private var sequenceTask: Task<Void, Never>?
    private var lastSuggestionContext: Model.SuggestionContext?
    private var observations = Set<AnyCancellable>()
    private var heightConstraint: NSLayoutConstraint!
    private var previousWidth: CGFloat = 0
    private var suggestionsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchSuggestions)
    private var hapticsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchHaptics)
    private var compactHeightEnabled = SettingsStore.shared.value(Settings.Keyboard.touchCompactHeight)
    private var glyphsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchGlyphs)
    #if !os(visionOS)
    private let haptic = UIImpactFeedbackGenerator(style: .soft)
    #endif

    private final class Contact {
        let initial: TerminalTouchKeycap
        var current: TerminalTouchKeycap?
        let origin: CGPoint
        var anchor: CGPoint
        var task: Task<Void, Never>?
        var consumed = false
        var trackpad = false
        var accent = false
        var direction: String?
        init(key: TerminalTouchKeycap, point: CGPoint) {
            initial = key; current = key; origin = point; anchor = point
        }
    }
    private var contacts: [ObjectIdentifier: Contact] = [:]
    private var canSend: Bool { window != nil && host?.touchKeyboardCanSend == true }
    private var compact: Bool { traitCollection.verticalSizeClass == .compact }
    private var rowHeight: CGFloat {
        if isFloating {
            return min(44, max(28, (floatingAvailableHeight - 48 - 28 - (suggestionsEnabled ? 36 : 0) - (drawerOpen ? 90 : 0)) / 4))
        }
        return compact ? 40 : (traitCollection.userInterfaceIdiom == .pad ? 60 : 54)
    }
    private var drawerHeight: CGFloat {
        if isFloating { return min(124, max(0, floatingAvailableHeight - 48 - rowHeight * 4 - 28 - (suggestionsEnabled ? 36 : 0))) }
        return compact ? 124 : 156
    }
    private var deviceBottomInset: CGFloat {
        // An embedded settings preview must not inherit padding from the window's
        // bottom edge unless the keyboard actually reaches that edge.
        guard let window, convert(bounds, to: window).maxY >= window.bounds.maxY - 1 else {
            return safeAreaInsets.bottom
        }
        return max(safeAreaInsets.bottom, window.safeAreaInsets.bottom)
    }
    private var bottomInset: CGFloat { isFloating ? 28 : (compactHeightEnabled ? 6 : max(6, deviceBottomInset)) }
    private var desiredHeight: CGFloat { 48 + rowHeight * 4 + bottomInset + (drawerOpen ? drawerHeight : 0) + (suggestionsEnabled ? 36 : 0) }

    init() {
        // Supply one surface ourselves; UIKit's keyboard style adds another
        // material behind it, which washes out the native dark palette.
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 304))
        translatesAutoresizingMaskIntoConstraints = false
        isMultipleTouchEnabled = true
        background.isUserInteractionEnabled = false
        background.layer.cornerRadius = 24
        background.layer.cornerCurve = .continuous
        background.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(background)
        controlGlass.isUserInteractionEnabled = false
        controlGlass.layer.cornerRadius = 22
        controlGlass.layer.cornerCurve = .continuous
        controlGlass.clipsToBounds = true
        addSubview(controlGlass)
        heightConstraint = heightAnchor.constraint(equalToConstant: desiredHeight)
        heightConstraint.priority = .init(999)
        heightConstraint.isActive = true
        sections.selectedSegmentIndex = 2
        sections.addTarget(self, action: #selector(changeSection), for: .valueChanged)
        addSubview(sections)
        presets.selectedSegmentIndex = Model.Preset.allCases.firstIndex(of: preset) ?? 0
        presets.addTarget(self, action: #selector(changePreset), for: .valueChanged)
        presets.accessibilityLabel = String(localized: "Keyboard preset")
        addSubview(presets)
        drawer.showsVerticalScrollIndicator = true
        drawer.alwaysBounceVertical = false
        addSubview(drawer)
        closeDrawerButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        closeDrawerButton.tintColor = .label
        closeDrawerButton.accessibilityLabel = String(localized: "Close keyboard tools")
        closeDrawerButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.cancelInteraction()
            self.drawerOpen = false
            self.rebuildDrawer()
        }, for: .touchUpInside)
        addSubview(closeDrawerButton)
        suggestions.axis = .horizontal
        suggestions.distribution = .fillEqually
        addSubview(suggestions)
        preview.textAlignment = .center
        preview.font = .systemFont(ofSize: 32)
        preview.layer.cornerRadius = 10
        preview.clipsToBounds = true
        preview.isUserInteractionEnabled = false
        preview.isHidden = true
        addSubview(preview)
        accents.axis = .horizontal
        accents.distribution = .fillEqually
        accents.layer.cornerRadius = 12
        accents.clipsToBounds = true
        accents.isUserInteractionEnabled = false
        accents.isHidden = true
        addSubview(accents)
        modeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.cancelInteraction()
            self.drawerOpen.toggle()
            self.rebuildDrawer()
        }, for: .touchUpInside)
        modeButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        modeButton.titleLabel?.adjustsFontSizeToFitWidth = true
        modeButton.titleLabel?.minimumScaleFactor = 0.7
        modeButton.accessibilityLabel = String(localized: "Keyboard tools")
        addSubview(modeButton)
        grabber.accessibilityLabel = String(localized: "Move keyboard")
        grabber.accessibilityHint = String(localized: "Drag to move. Double-tap to dock.")
        grabber.addAction(UIAction { [weak self] _ in self?.onPlacementRequested?(.docked) }, for: .touchUpInside)
        grabberLine.isUserInteractionEnabled = false
        grabberLine.backgroundColor = .tertiaryLabel
        grabberLine.layer.cornerRadius = 2.5
        grabber.addSubview(grabberLine)
        addSubview(grabber)
        grabber.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragFloatingKeyboard(_:))))
        if traitCollection.userInterfaceIdiom == .pad {
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchKeyboard(_:)))
            pinch.cancelsTouchesInView = true
            addGestureRecognizer(pinch)
        }
        rebuildKeys()
        rebuildDrawer()
        ThemeManager.shared.themeDidChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateAppearance(); self?.rebuildDrawer()
        }.store(in: &observations)
        ThemeOverrideManager.shared.overridesDidChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateAppearance(); self?.rebuildDrawer()
        }.store(in: &observations)
        for name in [UIApplication.willResignActiveNotification, UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                     UIAccessibility.darkerSystemColorsStatusDidChangeNotification, Notification.Name.settingsDidChange,
                     KeyboardToolbarManager.layoutDidChangeNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == UIApplication.willResignActiveNotification { self.cancelInteraction(); return }
                    self.refreshSettings()
                }
            }
            observations.insert(AnyCancellable { NotificationCenter.default.removeObserver(token) })
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) {
            (self: TerminalTouchKeyboardView, _: UITraitCollection) in
            self.cancelInteraction()
            self.updateAppearance()
            self.setNeedsLayout()
        }
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: desiredHeight) }

    func setFloating(_ floating: Bool) {
        guard isFloating != floating else { return }
        cancelInteraction()
        isFloating = floating
        heightConstraint.isActive = !floating
        translatesAutoresizingMaskIntoConstraints = floating
        layer.shadowColor = UIColor.black.cgColor
        layer.cornerRadius = floating ? 24 : 0
        layer.cornerCurve = .continuous
        layer.shadowOpacity = floating ? 0.25 : 0
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 6)
        refreshPlacementActions()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func refreshPlacementActions() {
        guard traitCollection.userInterfaceIdiom == .pad, onPlacementRequested != nil else {
            modeButton.accessibilityCustomActions = nil
            return
        }
        modeButton.accessibilityCustomActions = [UIAccessibilityCustomAction(name: isFloating ? String(localized: "Dock Keyboard") : String(localized: "Float Keyboard")) { [weak self] _ in
            guard let self else { return false }
            self.cancelInteraction()
            self.onPlacementRequested?(self.isFloating ? .docked : .floating)
            return true
        }]
        grabber.accessibilityCustomActions = [
            (String(localized: "Move left"), CGPoint(x: -44, y: 0)),
            (String(localized: "Move right"), CGPoint(x: 44, y: 0)),
            (String(localized: "Move up"), CGPoint(x: 0, y: -44)),
            (String(localized: "Move down"), CGPoint(x: 0, y: 44))
        ].map { name, offset in UIAccessibilityCustomAction(name: name) { [weak self] _ in
            self?.onFloatingNudge?(offset); return true
        } }
    }

    @objc private func pinchKeyboard(_ gesture: UIPinchGestureRecognizer) {
        guard onPlacementRequested != nil else { return }
        if gesture.state == .began { cancelInteraction() }
        guard gesture.state == .ended else { return }
        let current: Model.Placement = isFloating ? .floating : .docked
        let destination = Model.placementAfterPinch(gesture.scale, from: current)
        if destination != current { onPlacementRequested?(destination) }
    }

    @objc private func dragFloatingKeyboard(_ gesture: UIPanGestureRecognizer) {
        guard isFloating else { return }
        switch gesture.state {
        case .began, .changed: onFloatingDrag?(gesture.translation(in: superview), false)
        case .ended: onFloatingDrag?(gesture.translation(in: superview), true)
        case .cancelled, .failed: onFloatingDragCancelled?()
        default: break
        }
    }

    private func refreshSettings() {
        let enabled = SettingsStore.shared.value(Settings.Keyboard.touchSuggestions)
        if suggestionsEnabled != enabled {
            suggestionsEnabled = enabled
            lastSuggestionContext = nil
            host?.touchKeyboardInvalidateSuggestions()
            updateSuggestions()
        }
        hapticsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchHaptics)
        let compactHeight = SettingsStore.shared.value(Settings.Keyboard.touchCompactHeight)
        let glyphs = SettingsStore.shared.value(Settings.Keyboard.touchGlyphs)
        if compactHeightEnabled != compactHeight || glyphsEnabled != glyphs { cancelInteraction() }
        compactHeightEnabled = compactHeight
        glyphsEnabled = glyphs
        updateModifierAppearance()
        updateAppearance()
        rebuildDrawer()
        setNeedsLayout()
    }

    private func updateAppearance() {
        palette = SettingsStore.shared.value(Settings.Keyboard.touchThemeAware)
            ? (host?.touchKeyboardThemeColors ?? ThemeManager.shared.currentThemeInfo?.colors).flatMap(TerminalTouchKeyboardPalette.init) : nil
        let style: UIUserInterfaceStyle = palette.map { $0.isLight ? .light : .dark } ?? .unspecified
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
        let toolbar = palette?.background ?? TerminalTouchKeyboardAppearance.toolbar
        background.backgroundColor = palette?.background ?? TerminalTouchKeyboardAppearance.background
        // Paint the gaps around the glass toolbar too. A clear input root lets
        // UIKit's independently styled keyboard backdrop show through here.
        backgroundColor = containerBackgroundColor
        if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
            let glass = UIGlassEffect(style: .clear)
            glass.tintColor = toolbar.withAlphaComponent(0.8)
            controlGlass.effect = glass
            controlGlass.contentView.backgroundColor = .clear
        } else if UIAccessibility.isReduceTransparencyEnabled {
            controlGlass.effect = nil
            controlGlass.contentView.backgroundColor = toolbar
        } else {
            controlGlass.effect = UIBlurEffect(style: .systemThinMaterial)
            controlGlass.contentView.backgroundColor = toolbar.withAlphaComponent(0.75)
        }
        controlGlass.backgroundColor = .clear
        preview.backgroundColor = palette?.key ?? .secondarySystemBackground
        preview.textColor = palette?.ink ?? .label
        accents.backgroundColor = palette?.key ?? .secondarySystemBackground
        grabberLine.backgroundColor = palette?.toolbarInk.withAlphaComponent(0.45) ?? .tertiaryLabel
        (controls + rows.flatMap { $0 }).forEach { $0.palette = palette }
        refreshModeButton()
        onAppearanceChanged?()
    }

    private func makeCap(_ key: Model.Key, small: Bool = false) -> TerminalTouchKeycap {
        let cap = TerminalTouchKeycap(key, small: small)
        cap.palette = palette
        cap.activate = { [weak self, weak cap] in
            guard let self, let cap, self.canSend else { return }
            if case .modifier(let mod) = key.action {
                self.modifierState.begin(mod)
                self.modifierState.end(mod, at: ProcessInfo.processInfo.systemUptime)
                self.publishModifiers()
            } else if key.action == .joystick {
                self.drawerOpen = true
                self.sections.selectedSegmentIndex = 1
                self.rebuildDrawer()
                self.setNeedsLayout()
            } else { self.perform(cap.key) }
        }
        if case .text(let text) = key.action, let variants = Model.accents[text] {
            cap.accessibilityCustomActions = variants.map { variant in
                UIAccessibilityCustomAction(name: String(variant)) { [weak self] _ in
                    guard let self, self.canSend else { return false }
                    self.perform(Model.Key(title: String(variant), action: .text(String(variant))))
                    return true
                }
            }
        }
        addSubview(cap)
        return cap
    }

    private func rebuildKeys() {
        (controls + rows.flatMap { $0 }).forEach { $0.removeFromSuperview() }
        controls = Model.controls.map { makeCap($0, small: true) }
        if let modeCap = controls.first(where: { $0.key.action == .mode }) {
            modeCap.label.isHidden = true
            modeCap.isAccessibilityElement = false
        }
        bringSubviewToFront(modeButton)
        rows = Model.rows(page: page).map { $0.map { makeCap($0) } }
        bringSubviewToFront(preview)
        bringSubviewToFront(accents)
        updateModifierAppearance()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if previousWidth != bounds.width {
            if previousWidth != 0 { cancelInteraction() }
            previousWidth = bounds.width
        }
        let leading = isFloating ? 0 : max(safeAreaInsets.left, window?.safeAreaInsets.left ?? 0)
        let trailing = isFloating ? 0 : max(safeAreaInsets.right, window?.safeAreaInsets.right ?? 0)
        let width = max(0, bounds.width - leading - trailing)
        background.frame = isFloating ? bounds : CGRect(x: 0, y: 48, width: bounds.width, height: max(0, bounds.height - 48))
        background.layer.maskedCorners = isFloating ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        if isFloating { layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 24).cgPath }
        grabber.isHidden = !isFloating
        grabber.frame = CGRect(x: 0, y: bounds.height - 28, width: bounds.width, height: 28)
        grabberLine.frame = CGRect(x: (bounds.width - 44) / 2, y: 11, width: 44, height: 5)
        controlGlass.frame = CGRect(x: leading + 2, y: 2, width: max(0, width - 4), height: 44)
        for (cap, rect) in zip(controls, Model.frames(keys: controls.map(\.key), width: width, y: 0, height: 48, inset: 5)) { cap.frame = rect.offsetBy(dx: leading, dy: 0) }
        if let modeCap = controls.first(where: { $0.key.action == .mode }) {
            modeButton.frame = modeCap.frame.insetBy(dx: 4, dy: 5)
        }
        var y: CGFloat = 48
        sections.isHidden = !drawerOpen
        drawer.isHidden = !drawerOpen
        presets.isHidden = !drawerOpen || sections.selectedSegmentIndex != 2
        closeDrawerButton.isHidden = !drawerOpen
        if drawerOpen {
            sections.frame = CGRect(x: leading + 8, y: y + 3, width: max(0, width - 60), height: 30)
            closeDrawerButton.frame = CGRect(x: leading + width - 48, y: y - 2, width: 44, height: 44)
            y += 40
            let presetHeight: CGFloat = sections.selectedSegmentIndex == 2 ? 32 : 0
            if presetHeight > 0 {
                presets.frame = CGRect(x: leading + 8, y: y, width: width - 16, height: 28)
                y += presetHeight
            }
            drawer.frame = CGRect(x: leading + 5, y: y, width: width - 10, height: drawerHeight - 44 - presetHeight)
            let cellWidth = drawer.bounds.width / CGFloat(drawerColumns)
            let cellHeight: CGFloat = compact ? 38 : 46
            for (i, button) in drawerButtons.enumerated() {
                button.frame = CGRect(x: CGFloat(i % drawerColumns) * cellWidth + 2, y: CGFloat(i / drawerColumns) * cellHeight + 2,
                                      width: cellWidth - 4, height: cellHeight - 4)
            }
            drawer.contentSize = CGSize(width: drawer.bounds.width, height: CGFloat((drawerButtons.count + drawerColumns - 1) / drawerColumns) * cellHeight)
            y = 48 + drawerHeight
        }
        suggestions.isHidden = !suggestionsEnabled
        if suggestionsEnabled {
            suggestions.frame = CGRect(x: leading + 8, y: y, width: width - 16, height: 36)
            y += 36
        }
        for (index, row) in rows.enumerated() {
            var inset: CGFloat = index == 1 && page == .letters ? width / 20 + 2 : 2
            if index == 3, compactHeightEnabled, traitCollection.userInterfaceIdiom == .phone {
                // Keep the entire bottom row at its normal height while fitting
                // its end keys inside the rounded screen corners.
                inset = max(2, min(width / 10, deviceBottomInset - min(leading, trailing)))
            }
            for (cap, rect) in zip(row, Model.frames(keys: row.map(\.key), width: width, y: y, height: rowHeight, inset: inset)) { cap.frame = rect.offsetBy(dx: leading, dy: 0) }
            y += rowHeight
        }
        if abs(heightConstraint.constant - desiredHeight) > 0.5 {
            heightConstraint.constant = desiredHeight
            invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in self?.onHeightChanged?() }
        }
    }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelInteraction() } else { refreshSettings(); updateSuggestions() }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point) else { return nil }
        if modeButton.frame.contains(point) {
            return modeButton.hitTest(convert(point, to: modeButton), with: event)
        }
        if cap(at: point) != nil { return self }
        return super.hitTest(point, with: event)
    }
    private func cap(at point: CGPoint) -> TerminalTouchKeycap? {
        (controls + rows.flatMap { $0 }).first { $0.frame.contains(point) }
    }
    private func feedback() {
        #if !os(visionOS)
        if hapticsEnabled { haptic.impactOccurred(intensity: 0.45) }
        #endif
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard canSend else { return }
        sequenceTask?.cancel()
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let point = touch.location(in: self)
            guard let key = cap(at: point) else { continue }
            let id = ObjectIdentifier(touch)
            let contact = Contact(key: key, point: point)
            contacts[id] = contact
            key.pressed = true
            feedback()
            if case .modifier(let mod) = key.key.action {
                modifierState.begin(mod)
                publishModifiers()
            } else {
                showPreview(key)
                contact.task = Task { @MainActor [weak self, weak contact] in
                    try? await Task.sleep(for: .milliseconds(420))
                    guard !Task.isCancelled, let self, let contact, self.contacts[id] === contact, self.canSend,
                          contact.current === contact.initial else { return }
                    switch key.key.action {
                    case .key("\u{7f}"):
                        contact.consumed = true
                        while !Task.isCancelled, self.contacts[id] === contact, self.canSend {
                            self.perform(key.key)
                            try? await Task.sleep(for: .milliseconds(65))
                        }
                    case .text(" "):
                        contact.trackpad = true
                        contact.consumed = true
                        self.preview.isHidden = true
                        key.label.text = "↔  cursor  ↕"
                        self.feedback()
                    case .text(let text):
                        if let variants = Model.accents[text] { self.showAccents(variants, contact: contact) }
                    case .dismiss:
                        contact.consumed = true
                        self.cancelInteraction()
                        self.onPinHidden?()
                    default: break
                    }
                }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let contact = contacts[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)
            if contact.accent {
                accentIndex = min(accentChoices.count - 1, max(0, Int((point.x - accents.frame.minX) / (accents.bounds.width / CGFloat(accentChoices.count)))))
                updateAccentSelection()
                continue
            }
            if contact.trackpad {
                let dx = point.x - contact.anchor.x, dy = point.y - contact.anchor.y
                if abs(dx) >= 12 || abs(dy) >= 18 {
                    let horizontal = abs(dx) >= abs(dy)
                    keyPressed(horizontal ? (dx > 0 ? "\u{1b}[C" : "\u{1b}[D") : (dy > 0 ? "\u{1b}[B" : "\u{1b}[A"), modifiers: [])
                    contact.anchor = point
                }
                continue
            }
            if contact.initial.key.action == .joystick {
                let dx = point.x - contact.origin.x, dy = point.y - contact.origin.y
                let direction: String? = hypot(dx, dy) < 18 ? nil :
                    (abs(dx) > abs(dy) ? (dx > 0 ? "\u{1b}[C" : "\u{1b}[D") : (dy > 0 ? "\u{1b}[B" : "\u{1b}[A"))
                if direction != contact.direction {
                    contact.task?.cancel()
                    contact.direction = direction
                    if let direction {
                        contact.consumed = true
                        keyPressed(direction, modifiers: [])
                        contact.task = Task { @MainActor [weak self, weak contact] in
                            try? await Task.sleep(for: .milliseconds(320))
                            while !Task.isCancelled, let self, let contact, contact.direction == direction, self.canSend {
                                self.keyPressed(direction, modifiers: [])
                                try? await Task.sleep(for: .milliseconds(80))
                            }
                        }
                    }
                }
                continue
            }
            if case .modifier = contact.initial.key.action { continue }
            let next = cap(at: point)
            // Sliding adjusts the typed key, never activates a nearby action or modifier.
            let compatible: TerminalTouchKeycap? = {
                if next === contact.initial { return next }
                if case .text = contact.initial.key.action, let next, case .text = next.key.action { return next }
                return nil
            }()
            if compatible !== contact.current {
                contact.task?.cancel()
                contact.current?.pressed = false
                contact.current = compatible
                compatible?.pressed = true
                if let compatible { showPreview(compatible) } else { preview.isHidden = true }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }
    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        // Resolve letters before released modifiers when UIKit batches the chord.
        let ordered = touches.sorted {
            let a = contacts[ObjectIdentifier($0)]?.initial.key.action
            let b = contacts[ObjectIdentifier($1)]?.initial.key.action
            if case .modifier = a { return false }
            if case .modifier = b { return true }
            return $0.timestamp < $1.timestamp
        }
        for touch in ordered {
            guard let contact = contacts.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            contact.task?.cancel()
            contact.current?.pressed = false
            contact.initial.pressed = false
            if case .modifier(let mod) = contact.initial.key.action {
                modifierState.end(mod, at: touch.timestamp, cancelled: cancelled || !contact.initial.frame.contains(touch.location(in: self)))
                publishModifiers()
            } else if !cancelled, canSend {
                if contact.accent, accents.frame.insetBy(dx: -20, dy: -70).contains(touch.location(in: self)) {
                    perform(Model.Key(title: accentChoices[accentIndex], action: .text(accentChoices[accentIndex])))
                } else if !contact.consumed, let current = contact.current, current.frame.contains(touch.location(in: self)) {
                    perform(current.key)
                }
            }
        }
        preview.isHidden = true
        accents.isHidden = true
        updateModifierAppearance()
    }

    func cancelInteraction() {
        contacts.values.forEach { $0.task?.cancel(); $0.initial.pressed = false; $0.current?.pressed = false }
        contacts.removeAll()
        drawerButtons.forEach { $0.cancelRepeat() }
        sequenceTask?.cancel(); sequenceTask = nil
        suggestionTask?.cancel(); suggestionTask = nil
        lastSuggestionContext = nil
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        modifierState.reset()
        publishModifiers()
        preview.isHidden = true
        accents.isHidden = true
    }

    private func publishModifiers() {
        onModifiersChanged?(KeyModifiers(rawValue: modifierState.rawValue))
        updateModifierAppearance()
    }
    private func updateModifierAppearance() {
        for cap in controls + rows.flatMap({ $0 }) {
            switch cap.key.action {
            case .key("\u{1b}"): cap.setSymbol(glyphsEnabled ? "escape" : nil)
            case .key("\t"): cap.setSymbol(glyphsEnabled ? "arrow.right.to.line" : nil)
            case .modifier(.control): cap.setSymbol(glyphsEnabled ? "control" : nil)
            case .modifier(.alt): cap.setSymbol(glyphsEnabled ? "option" : nil)
            case .modifier(.command): cap.setSymbol(glyphsEnabled ? "command" : nil)
            default: break
            }
            if case .modifier(let mod) = cap.key.action {
                cap.selected = modifierState.isActive(mod)
                cap.locked = modifierState.locked.contains(mod)
                cap.accessibilityValue = modifierState.locked.contains(mod) ? "Locked" : (cap.selected ? "On" : "Off")
                if mod == .shift {
                    cap.setSymbol(glyphsEnabled ? (modifierState.locked.contains(mod) ? "capslock.fill" : (cap.selected ? "shift.fill" : "shift")) : nil)
                }
            } else if case .text(let text) = cap.key.action {
                cap.updateColor()
                cap.label.text = text == " " ? "space" : (modifierState.isActive(.shift) ? text.uppercased() : text)
            }
        }
    }

    private func perform(_ key: Model.Key) {
        guard canSend else { return }
        switch key.action {
        case .text(let text):
            let mods = KeyModifiers(rawValue: modifierState.rawValue)
            if mods.subtracting(.shift).isEmpty {
                // Shift changes letters without invoking terminal shortcut encoding.
                host?.touchKeyboardInsert(mods.contains(.shift) ? text.uppercased() : text)
            } else { host?.touchKeyboardSend(text, modifiers: mods) }
            modifierState.consume(); publishModifiers(); updateSuggestions()
        case .key(let value): keyPressed(value, modifiers: [])
        case .page:
            cancelInteraction()
            if key.title == "#+=" { page = .symbols }
            else if key.title == "123" { page = .numbers }
            else { page = .letters }
            rebuildKeys()
        case .switchKeyboard: cancelInteraction(); onSwitchKeyboard?()
        case .drawer:
            drawerOpen.toggle(); rebuildDrawer(); setNeedsLayout()
        case .dismiss: cancelInteraction(); onDismiss?()
        case .compose: cancelInteraction(); onCompose?()
        case .paste: cancelInteraction(); onPaste?()
        case .tabs: cancelInteraction(); onTabs?()
        case .mode: break
        case .joystick:
            drawerOpen = true; sections.selectedSegmentIndex = 1; rebuildDrawer(); setNeedsLayout()
        case .modifier: break
        }
    }

    func keyPressed(_ key: String, modifiers: KeyModifiers) {
        guard canSend else { return }
        host?.touchKeyboardSend(key, modifiers: modifiers.union(KeyModifiers(rawValue: modifierState.rawValue)))
        modifierState.consume(); publishModifiers(); updateSuggestions()
    }
    func sendRawData(_ data: Data) { guard canSend else { return }; sequenceDelegate?.sendRawData(data) }

    private func showPreview(_ cap: TerminalTouchKeycap) {
        guard traitCollection.userInterfaceIdiom == .phone, case .text(let text) = cap.key.action, text != " ", !UIAccessibility.isVoiceOverRunning else { return }
        preview.text = modifierState.isActive(.shift) ? text.uppercased() : text
        preview.frame = CGRect(x: min(max(2, cap.frame.midX - 26), bounds.width - 54), y: max(0, cap.frame.minY - 49), width: 52, height: 55)
        preview.isHidden = false
        bringSubviewToFront(preview)
    }
    private func showAccents(_ variants: String, contact: Contact) {
        contact.accent = true; contact.consumed = true
        preview.isHidden = true
        accentChoices = variants.map { modifierState.isActive(.shift) ? String($0).uppercased() : String($0) }
        accents.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for value in accentChoices {
            let label = UILabel(); label.text = value; label.textAlignment = .center; label.font = .systemFont(ofSize: 24)
            accents.addArrangedSubview(label)
        }
        let width = min(bounds.width - 8, CGFloat(accentChoices.count) * 38)
        accents.frame = CGRect(x: min(max(4, contact.initial.frame.midX - width / 2), bounds.width - width - 4),
                              y: max(0, contact.initial.frame.minY - 49), width: width, height: 48)
        accentIndex = min(accentChoices.count - 1, max(0, Int((contact.origin.x - accents.frame.minX) / (width / CGFloat(accentChoices.count)))))
        updateAccentSelection()
        accents.isHidden = false
        bringSubviewToFront(accents)
        feedback()
    }
    private func updateAccentSelection() {
        for (index, view) in accents.arrangedSubviews.enumerated() {
            view.backgroundColor = index == accentIndex ? .tertiarySystemFill : .clear
        }
    }

    @objc private func changeSection() { rebuildDrawer(); setNeedsLayout() }
    @objc private func changePreset() {
        guard Model.Preset.allCases.indices.contains(presets.selectedSegmentIndex) else { return }
        preset = Model.Preset.allCases[presets.selectedSegmentIndex]
        rebuildDrawer()
    }
    private func drawerButton(_ title: String, subtitle: String? = nil, repeats: Bool = false, action: @escaping () -> Void) {
        let button = TerminalTouchRepeatingButton(type: .system)
        var config = palette == nil ? UIButton.Configuration.tinted() : UIButton.Configuration.filled()
        config.title = title
        config.subtitle = subtitle
        config.baseForegroundColor = palette?.ink ?? .label
        config.baseBackgroundColor = palette?.key ?? .secondaryLabel
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 3, bottom: 2, trailing: 3)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var output = input; output.font = .systemFont(ofSize: subtitle == nil ? 17 : 12, weight: .medium); return output
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var output = input; output.font = .monospacedSystemFont(ofSize: 12, weight: .regular); return output
        }
        button.configuration = config
        button.accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
        button.addAction(UIAction { [weak self] _ in guard self?.canSend == true else { return }; action() }, for: .touchUpInside)
        if repeats { button.enableRepeat { [weak self] in guard self?.canSend == true else { return }; action() } }
        drawer.addSubview(button)
        drawerButtons.append(button)
    }
    private func refreshModeButton() {
        modeButton.setTitle(preset.rawValue + (drawerOpen ? " ⌃" : " ⌄"), for: .normal)
        modeButton.setTitleColor(palette?.toolbarInk ?? UIColor { traits in
            UIColor(white: Model.keyColors(dark: traits.userInterfaceStyle == .dark,
                character: false, pressed: false, selected: false).ink, alpha: 1)
        }, for: .normal)
        modeButton.accessibilityValue = preset.rawValue + (drawerOpen ? ", expanded" : ", collapsed")
    }

    private func rebuildDrawer() {
        refreshModeButton()
        drawerButtons.forEach { $0.cancelRepeat(); $0.removeFromSuperview() }; drawerButtons.removeAll()
        drawer.contentOffset = .zero
        drawerColumns = sections.selectedSegmentIndex == 0 ? 8 : 4
        switch sections.selectedSegmentIndex {
        case 0:
            for char in "`~^_\\|[]{}<>/=-\"';:()@$%&*+?!#" {
                let text = String(char)
                drawerButton(text) { [weak self] in self?.perform(Model.Key(title: text, action: .text(text))) }
            }
        case 1:
            let keys = [("←", "\u{1b}[D"), ("↓", "\u{1b}[B"), ("↑", "\u{1b}[A"), ("→", "\u{1b}[C"),
                        ("Home", "\u{1b}[H"), ("End", "\u{1b}[F"), ("PgUp", "\u{1b}[5~"), ("PgDn", "\u{1b}[6~"), ("Delete", "\u{1b}[3~")]
            for (title, key) in keys { drawerButton(title, repeats: true) { [weak self] in self?.keyPressed(key, modifiers: []) } }
            for index in 1...12 { drawerButton("F\(index)") { [weak self] in self?.keyPressed("F\(index)", modifiers: []) } }
            drawerButton("Cmd") { [weak self] in
                guard let self else { return }; self.modifierState.begin(.command)
                self.modifierState.end(.command, at: ProcessInfo.processInfo.systemUptime); self.publishModifiers()
            }
        case 2:
            for shortcut in preset.shortcuts {
                drawerButton(shortcut.title, subtitle: shortcut.chord) { [weak self] in
                    self?.keyPressed(shortcut.key, modifiers: KeyModifiers(rawValue: shortcut.modifiers))
                }
            }
            if preset == .agent {
                drawerButton("Compose") { [weak self] in self?.perform(Model.Key(title: "Compose", action: .compose)) }
                drawerButton("Paste") { [weak self] in self?.perform(Model.Key(title: "Paste", action: .paste)) }
            }
        default:
            for key in KeyboardToolbarManager.shared.customKeys {
                drawerButton(key.label, subtitle: key.sequenceSummary) { [weak self] in self?.sendCustomSequence(key.sequence) }
            }
            drawerButton("Edit keys", subtitle: "Customize") { [weak self] in self?.cancelInteraction(); self?.onCustomize?() }
        }
        setNeedsLayout()
    }

    private func sendCustomSequence(_ steps: [SequenceStep]) {
        cancelInteraction()
        host?.touchKeyboardInvalidateSuggestions()
        sequenceTask = Task { @MainActor [weak self] in
            for step in steps {
                guard !Task.isCancelled, let self, self.canSend else { return }
                let data = step.terminalData()
                self.sequenceDelegate?.sendRawData(data)
                if data.last == 0x1b { try? await Task.sleep(for: .milliseconds(50)) }
            }
        }
    }

    func updateSuggestions() {
        guard suggestionsEnabled, canSend, let context = host?.touchKeyboardSuggestionContext else {
            suggestionTask?.cancel(); lastSuggestionContext = nil
            suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard lastSuggestionContext != context else { return }
        lastSuggestionContext = context
        suggestionTask?.cancel()
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        suggestionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.canSend, self.host?.touchKeyboardSuggestionContext == context else { return }
            let language = UITextChecker.availableLanguages.first { $0.hasPrefix("en") } ?? "en_US"
            let wordRange = NSRange(location: 0, length: context.word.utf16.count)
            let completions = self.checker.completions(forPartialWordRange: wordRange, in: context.word, language: language) ?? []
            let guesses = self.checker.guesses(forWordRange: wordRange, in: context.word, language: language) ?? []
            var seen: Set<String> = [context.word]
            let candidates = (guesses + completions).filter {
                $0.count <= 32 && $0.allSatisfy { $0.isLetter } && seen.insert($0).inserted
            }.prefix(3)
            for candidate in candidates {
                let button = UIButton(type: .system)
                button.setTitle(candidate, for: .normal)
                button.tintColor = .label
                button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
                button.accessibilityLabel = "Replace \(context.word) with \(candidate)"
                button.addAction(UIAction { [weak self] _ in
                    guard let self, self.canSend else { return }
                    self.host?.touchKeyboardAccept(candidate, context: context)
                    self.updateSuggestions()
                }, for: .touchUpInside)
                self.suggestions.addArrangedSubview(button)
            }
        }
    }
}
