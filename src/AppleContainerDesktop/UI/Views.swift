import AppKit

final class ThemedContainerView: NSView {
    var onAppearanceChange: (() -> Void)?
    private let backgroundColor: NSColor

    init(backgroundColor: NSColor) {
        self.backgroundColor = backgroundColor
        super.init(frame: .zero)
        wantsLayer = true
        applyColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        onAppearanceChange?()
    }

    private func applyColors() {
        layer?.backgroundColor = resolvedCGColor(backgroundColor)
    }
}

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

final class SidebarRowView: NSControl {
    let item: SidebarItem
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    var isRowSelected = false {
        didSet {
            applyColors()
            setAccessibilityValue(isRowSelected ? "selected" : "not selected")
        }
    }

    init(item: SidebarItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        titleLabel.stringValue = item.rawValue
        titleLabel.font = AppFonts.sidebar
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.rawValue)
        setAccessibilityValue("not selected")

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: AppSpacing.lg),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -AppSpacing.sm),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        applyColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyColors()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.charactersIgnoringModifiers == " " {
            sendAction(action, to: target)
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        titleLabel.textColor = AppColors.ink
        layer?.backgroundColor = isRowSelected || isHovered
            ? resolvedCGColor(AppColors.surface)
            : NSColor.clear.cgColor
        layer?.borderColor = isRowSelected
            ? resolvedCGColor(AppColors.border)
            : NSColor.clear.cgColor
        layer?.borderWidth = isRowSelected ? 1 : 0
    }
}

final class SidebarStatusView: NSControl {
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var health: ServiceHealth = .unknown
    var isStatusSelected = false {
        didSet {
            applyColors()
            setAccessibilityValue(isStatusSelected ? "selected" : "not selected")
        }
    }

    init(title: String, health: ServiceHealth) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = AppFonts.small
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(titleLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Opens runtime status and maintenance controls.")
        setAccessibilityValue("not selected")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: AppSpacing.sm),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: AppSpacing.sm),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -AppSpacing.sm),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update(title: title, health: health)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func update(title: String, health: ServiceHealth) {
        self.health = health
        titleLabel.stringValue = title
        toolTip = title
        setAccessibilityLabel("Runtime status: \(title)")
        applyColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyColors()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.charactersIgnoringModifiers == " " {
            sendAction(action, to: target)
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        titleLabel.textColor = AppColors.muted
        dot.layer?.backgroundColor = resolvedCGColor(color(for: health))
        layer?.backgroundColor = isStatusSelected || isHovered
            ? resolvedCGColor(AppColors.surface)
            : NSColor.clear.cgColor
        layer?.borderColor = isStatusSelected || isHovered
            ? resolvedCGColor(AppColors.border)
            : NSColor.clear.cgColor
        layer?.borderWidth = isStatusSelected || isHovered ? 1 : 0
    }

    private func color(for health: ServiceHealth) -> NSColor {
        switch health {
        case .running:
            AppColors.success
        case .stopped, .unknown:
            AppColors.warning
        case .missingCLI, .unhealthy:
            AppColors.danger
        }
    }
}

final class StatusChipView: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let health: ServiceHealth

    init(title: String, health: ServiceHealth) {
        self.health = health
        super.init(frame: .zero)
        wantsLayer = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = AppFonts.small
        label.textColor = AppColors.ink
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(label)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: AppSpacing.sm),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -AppSpacing.sm),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Status: \(title)")
        applyColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.cornerRadius = 11
        layer?.backgroundColor = resolvedCGColor(AppColors.surface)
        layer?.borderColor = resolvedCGColor(AppColors.border)
        layer?.borderWidth = 1
        dot.layer?.backgroundColor = resolvedCGColor(color(for: health))
    }

    private func color(for health: ServiceHealth) -> NSColor {
        switch health {
        case .running:
            AppColors.success
        case .stopped, .unknown:
            AppColors.warning
        case .missingCLI, .unhealthy:
            AppColors.danger
        }
    }
}

final class EmptyStateView: NSView {
    init(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AppSpacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppFonts.title
        titleLabel.textColor = AppColors.ink

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = AppFonts.body
        messageLabel.textColor = AppColors.muted
        messageLabel.maximumNumberOfLines = 0

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)

        if let actionTitle, let action {
            let button = ClosureButton(title: actionTitle, action: action)
            button.bezelStyle = .rounded
            stack.addArrangedSubview(button)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: AppSpacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -AppSpacing.xl),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class CardView: NSView {
    let stack = NSStackView()

    init(spacing: CGFloat = AppSpacing.md) {
        super.init(frame: .zero)
        wantsLayer = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: AppSpacing.lg),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -AppSpacing.lg),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: AppSpacing.lg),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -AppSpacing.lg)
        ])
        applyColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = resolvedCGColor(AppColors.surface)
        layer?.borderColor = resolvedCGColor(AppColors.border)
        layer?.borderWidth = 1
        layer?.cornerRadius = 12
    }
}

final class PageHeaderView: NSView {
    private let stack = NSStackView()

    init(title: String, subtitle: String) {
        super.init(frame: .zero)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AppSpacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)

        let titleLabel = NSTextField.label(title, font: AppFonts.title)
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = AppFonts.body
        subtitleLabel.textColor = AppColors.muted
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.alignment = .left
        subtitleLabel.setContentHuggingPriority(.required, for: .vertical)
        subtitleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(subtitleLabel)

        addSubview(stack)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: stack.fittingSize.height)
    }
}

final class ClosureButton: NSButton {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        closure = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(runAction)
        setAccessibilityLabel(title)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func runAction() {
        closure()
    }
}

final class ToolbarActionButton: NSControl {
    private let titleLabel = NSTextField.label("", font: AppFonts.body)
    private let chevronView: NSImageView?
    private let actionHandler: (ToolbarActionButton) -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private let showsMenuIndicator: Bool

    init(title: String, showsMenuIndicator: Bool = false, action: @escaping (ToolbarActionButton) -> Void) {
        self.showsMenuIndicator = showsMenuIndicator
        actionHandler = action
        if showsMenuIndicator {
            let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
            chevronView = NSImageView(image: image ?? NSImage())
        } else {
            chevronView = nil
        }
        super.init(frame: .zero)

        wantsLayer = true
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: AppSpacing.md),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]

        if let chevronView {
            chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            chevronView.contentTintColor = AppColors.muted
            chevronView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chevronView)
            constraints += [
                chevronView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: AppSpacing.xs),
                chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -AppSpacing.sm),
                chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
                chevronView.widthAnchor.constraint(equalToConstant: 10),
                chevronView.heightAnchor.constraint(equalToConstant: 10)
            ]
        } else {
            constraints.append(titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -AppSpacing.md))
        }

        NSLayoutConstraint.activate(constraints)
        applyColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let labelWidth = titleLabel.intrinsicContentSize.width
        let indicatorWidth: CGFloat = showsMenuIndicator ? 18 : 0
        let minimumWidth: CGFloat = showsMenuIndicator ? 70 : 58
        return NSSize(width: max(minimumWidth, ceil(labelWidth + indicatorWidth + 24)), height: 28)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyColors()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isPressed = true
        applyColors()
        defer {
            isPressed = false
            applyColors()
        }

        guard let mouseUp = window?.nextEvent(matching: [.leftMouseUp]) else {
            return
        }
        let point = convert(mouseUp.locationInWindow, from: nil)
        if bounds.contains(point) {
            actionHandler(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.charactersIgnoringModifiers == " " {
            actionHandler(self)
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = resolvedCGColor(AppColors.border)
        layer?.backgroundColor = resolvedCGColor(isHovered || isPressed ? AppColors.controlHover : AppColors.control)
        titleLabel.textColor = isEnabled ? AppColors.ink : AppColors.muted
        chevronView?.contentTintColor = isEnabled ? AppColors.muted : AppColors.border
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        closure = action
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runAction() {
        closure()
    }
}

extension NSTextField {
    static func label(_ text: String, font: NSFont = AppFonts.body, color: NSColor = AppColors.ink) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = .left
        return label
    }
}

extension NSView {
    func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}

extension NSStackView {
    func addFullWidthArrangedSubview(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}
