import UIKit

/// Invisible first responder that captures typing from the on-screen keyboard.
final class KeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onPresses: ((Set<UIPress>, Bool) -> Bool)?

    private var accessory: UIView?
    override var inputAccessoryView: UIView? {
        get { accessory }
        set { accessory = newValue }
    }

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }   // so backspace always fires
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onBackspace?() }

    // UITextInputTraits
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var inlinePredictionType: UITextInlinePredictionType = .no

    // Hardware keyboard: handle raw key presses so modifiers and shortcuts work.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, true) != true { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, false) != true { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, false) != true { super.pressesCancelled(presses, with: event) }
    }
}

/// Bar above the keyboard with Mac modifier keys and special keys.
final class ModifierBar: UIInputView {
    enum Modifier: CaseIterable {
        case command, option, control, shift
        var title: String {
            switch self { case .command: "⌘"; case .option: "⌥"; case .control: "⌃"; case .shift: "⇧" }
        }
        var keysym: UInt32 {
            switch self {
            case .command: Keysym.command
            case .option: Keysym.option
            case .control: Keysym.control
            case .shift: Keysym.shift
            }
        }
    }

    var onKey: ((UInt32) -> Void)?
    var onShortcut: ((UInt32, [UInt32]) -> Void)?
    var onDismiss: (() -> Void)?
    var onModifiersChanged: (() -> Void)?

    private(set) var active: Set<Modifier> = []
    private var locked: Set<Modifier> = []
    private var modButtons: [Modifier: UIButton] = [:]
    private var lastTap: [Modifier: CFTimeInterval] = [:]

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 48) }

    var activeKeysyms: [UInt32] { Modifier.allCases.filter { active.contains($0) }.map(\.keysym) }

    /// Clear one-shot modifiers after a key has been sent (locked ones stay).
    func consumeModifiers() {
        active = locked
        refresh()
    }

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])

        stack.addArrangedSubview(button(image: "keyboard.chevron.compact.down") { [weak self] in self?.onDismiss?() })
        stack.addArrangedSubview(button(title: "esc") { [weak self] in self?.onKey?(Keysym.escape) })
        stack.addArrangedSubview(button(title: "tab") { [weak self] in self?.onKey?(Keysym.tab) })
        for m in Modifier.allCases {
            let b = button(title: m.title, wide: true) { [weak self] in self?.toggle(m) }
            modButtons[m] = b
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(button(image: "arrow.left") { [weak self] in self?.onKey?(Keysym.left) })
        stack.addArrangedSubview(button(image: "arrow.up") { [weak self] in self?.onKey?(Keysym.up) })
        stack.addArrangedSubview(button(image: "arrow.down") { [weak self] in self?.onKey?(Keysym.down) })
        stack.addArrangedSubview(button(image: "arrow.right") { [weak self] in self?.onKey?(Keysym.right) })
        stack.addArrangedSubview(button(image: "delete.right") { [weak self] in self?.onKey?(Keysym.delete) })
        stack.addArrangedSubview(button(title: "home") { [weak self] in self?.onKey?(Keysym.home) })
        stack.addArrangedSubview(button(title: "end") { [weak self] in self?.onKey?(Keysym.end) })
        stack.addArrangedSubview(button(title: "pgup") { [weak self] in self?.onKey?(Keysym.pageUp) })
        stack.addArrangedSubview(button(title: "pgdn") { [weak self] in self?.onKey?(Keysym.pageDown) })
        for n in 1...12 {
            stack.addArrangedSubview(button(title: "F\(n)") { [weak self] in self?.onKey?(Keysym.function(n)) })
        }
        refresh()
    }

    private func toggle(_ m: Modifier) {
        let now = CACurrentMediaTime()
        if let t = lastTap[m], now - t < 0.35 {
            // Double-tap locks the modifier.
            locked.insert(m)
            active.insert(m)
        } else if active.contains(m) {
            active.remove(m)
            locked.remove(m)
        } else {
            active.insert(m)
        }
        lastTap[m] = now
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        refresh()
        onModifiersChanged?()
    }

    private func refresh() {
        for (m, b) in modButtons {
            let on = active.contains(m)
            var cfg = b.configuration
            cfg?.baseBackgroundColor = on ? (locked.contains(m) ? .systemOrange : .systemBlue) : .secondarySystemFill
            cfg?.baseForegroundColor = on ? .white : .label
            b.configuration = cfg
        }
    }

    private func button(title: String? = nil, image: String? = nil, wide: Bool = false,
                        action: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.baseBackgroundColor = .secondarySystemFill
        cfg.baseForegroundColor = .label
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: wide ? 14 : 10, bottom: 6, trailing: wide ? 14 : 10)
        if let title {
            var a = AttributedString(title)
            a.font = .systemFont(ofSize: wide ? 18 : 15, weight: .medium)
            cfg.attributedTitle = a
        }
        if let image {
            cfg.image = UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        }
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in action() })
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return b
    }
}
