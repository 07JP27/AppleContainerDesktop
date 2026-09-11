import AppKit

@MainActor
final class ContainerSelectionHeaderView: NSTableHeaderView {
    let selectionButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var onToggleAll: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        selectionButton.allowsMixedState = true
        selectionButton.target = self
        selectionButton.action = #selector(toggleAll)
        selectionButton.setAccessibilityLabel("Select all visible containers")
        selectionButton.setAccessibilityHelp("Selects or clears every container visible in the current filter.")
        addSubview(selectionButton)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard let tableView, !tableView.tableColumns.isEmpty else { return }
        let header = headerRect(ofColumn: 0)
        let size = NSSize(width: 18, height: 18)
        selectionButton.frame = NSRect(
            x: header.midX - size.width / 2,
            y: header.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    func update(state: NSControl.StateValue, isEnabled: Bool) {
        selectionButton.state = state
        selectionButton.isEnabled = isEnabled
        let value: String
        switch state {
        case .on:
            value = "All visible containers selected"
        case .mixed:
            value = "Some visible containers selected"
        default:
            value = "No visible containers selected"
        }
        selectionButton.setAccessibilityValue(value)
    }

    @objc private func toggleAll() {
        onToggleAll?(selectionButton.state != .off)
    }
}

@MainActor
final class ContainerSelectionCellView: NSTableCellView {
    let selectionButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var onToggle: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        selectionButton.translatesAutoresizingMaskIntoConstraints = false
        selectionButton.target = self
        selectionButton.action = #selector(toggle)
        addSubview(selectionButton)
        NSLayoutConstraint.activate([
            selectionButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            selectionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionButton.widthAnchor.constraint(equalToConstant: 18),
            selectionButton.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(name: String, isSelected: Bool, isEnabled: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        update(name: name, isSelected: isSelected, isEnabled: isEnabled)
    }

    func update(name: String, isSelected: Bool, isEnabled: Bool) {
        selectionButton.state = isSelected ? .on : .off
        selectionButton.isEnabled = isEnabled
        selectionButton.setAccessibilityLabel(isSelected ? "Deselect container \(name)" : "Select container \(name)")
        selectionButton.setAccessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    @objc private func toggle() {
        onToggle?(selectionButton.state == .on)
    }
}

@MainActor
final class ContainerNameLinkCellView: NSTableCellView {
    let linkButton = NSButton()
    private var onOpen: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        linkButton.translatesAutoresizingMaskIntoConstraints = false
        linkButton.isBordered = false
        linkButton.alignment = .left
        linkButton.font = AppFonts.body
        linkButton.contentTintColor = AppColors.info
        linkButton.lineBreakMode = .byTruncatingTail
        linkButton.target = self
        linkButton.action = #selector(openDetails)
        linkButton.focusRingType = .exterior
        addSubview(linkButton)
        NSLayoutConstraint.activate([
            linkButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: AppSpacing.sm),
            linkButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -AppSpacing.sm),
            linkButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            linkButton.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(name: String, fullIdentifier: String, onOpen: @escaping () -> Void) {
        linkButton.title = name
        linkButton.toolTip = "Open details for \(fullIdentifier)"
        linkButton.setAccessibilityLabel("Open container \(name)")
        linkButton.setAccessibilityHelp("Opens the dedicated container details screen.")
        self.onOpen = onOpen
    }

    @objc private func openDetails() {
        onOpen?()
    }
}

@MainActor
final class ContainerActionsCellView: NSTableCellView {
    let primaryButton = NSButton()
    let moreButton = NSButton()
    let deleteButton = NSButton()
    private var onPrimary: (() -> Void)?
    private var onMore: ((NSButton) -> Void)?
    private var onDelete: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureButton(primaryButton)
        configureButton(moreButton)
        configureButton(deleteButton)
        primaryButton.target = self
        primaryButton.action = #selector(runPrimary)
        moreButton.target = self
        moreButton.action = #selector(showMore)
        deleteButton.target = self
        deleteButton.action = #selector(runDelete)
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        deleteButton.contentTintColor = AppColors.danger

        let stack = NSStackView(views: [primaryButton, moreButton, deleteButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = AppSpacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        name: String,
        isRunning: Bool,
        isEnabled: Bool,
        onPrimary: @escaping () -> Void,
        onMore: @escaping (NSButton) -> Void,
        onDelete: @escaping () -> Void
    ) {
        let primaryTitle = isRunning ? "Stop" : "Start"
        primaryButton.image = NSImage(
            systemSymbolName: isRunning ? "stop.fill" : "play.fill",
            accessibilityDescription: nil
        )
        primaryButton.toolTip = "\(primaryTitle) \(name)"
        primaryButton.setAccessibilityLabel("\(primaryTitle) container \(name)")
        moreButton.toolTip = "More actions for \(name)"
        moreButton.setAccessibilityLabel("More actions for container \(name)")
        deleteButton.toolTip = "Delete \(name)"
        deleteButton.setAccessibilityLabel("Delete container \(name)")
        for button in [primaryButton, moreButton, deleteButton] {
            button.isEnabled = isEnabled
        }
        self.onPrimary = onPrimary
        self.onMore = onMore
        self.onDelete = onDelete
    }

    private func configureButton(_ button: NSButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .exterior
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @objc private func runPrimary() {
        onPrimary?()
    }

    @objc private func showMore() {
        onMore?(moreButton)
    }

    @objc private func runDelete() {
        onDelete?()
    }
}
