import AppKit

final class LaunchTextField: NSTextField, NSTextFieldDelegate {
    var onChange: (() -> Void)?

    init(placeholder: String = "") {
        super.init(frame: .zero)
        placeholderString = placeholder
        font = AppFonts.body
        delegate = self
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingMiddle
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func controlTextDidChange(_ obj: Notification) {
        toolTip = stringValue
        onChange?()
    }
}

final class LaunchComboBox: NSComboBox, NSComboBoxDelegate {
    var onChange: (() -> Void)?

    init(placeholder: String) {
        super.init(frame: .zero)
        placeholderString = placeholder
        font = AppFonts.body
        delegate = self
        usesSingleLineMode = true
        numberOfVisibleItems = 8
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func setSuggestions(_ values: [String]) {
        let draft = stringValue
        removeAllItems()
        addItems(withObjectValues: values)
        stringValue = draft
    }

    func controlTextDidChange(_ obj: Notification) {
        toolTip = stringValue
        onChange?()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let selection = objectValueOfSelectedItem as? String { stringValue = selection }
        toolTip = stringValue
        onChange?()
    }
}

@MainActor
enum LaunchFormStyle {
    static func vertical(spacing: CGFloat = AppSpacing.sm) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = spacing
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        return stack
    }

    static func horizontal(_ views: [NSView], alignment: NSLayoutConstraint.Attribute = .bottom) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.alignment = alignment
        stack.spacing = AppSpacing.sm
        return stack
    }

    static func label(_ text: String, color: NSColor = AppColors.muted, font: NSFont = AppFonts.small) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    static func labeled(_ title: String, input: NSControl) -> NSStackView {
        let stack = vertical(spacing: AppSpacing.xs)
        let label = self.label(title, color: AppColors.ink)
        stack.addFullWidthArrangedSubview(label)
        stack.addFullWidthArrangedSubview(input)
        input.setAccessibilityLabel(title)
        return stack
    }

    static func button(_ title: String, action: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.font = AppFonts.body
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    static func updateDisclosure(_ button: NSButton, expanded: Bool) {
        button.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.state = expanded ? .on : .off
        button.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

class LaunchFormItemView: NSView {
    let stack = LaunchFormStyle.vertical()
    let errorLabel = LaunchFormStyle.label("", color: AppColors.danger)
    var firstInput: NSControl?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
        errorLabel.isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func finishLayout() {
        stack.addFullWidthArrangedSubview(errorLabel)
    }

    func showError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
    }

    func revealError() {}
}

final class LaunchLabeledFieldView: LaunchFormItemView {
    init(title: String, input: NSControl, help: String? = nil) {
        super.init(frame: .zero)
        firstInput = input
        stack.addFullWidthArrangedSubview(LaunchFormStyle.labeled(title, input: input))
        if let help {
            stack.addFullWidthArrangedSubview(LaunchFormStyle.label(help))
            input.setAccessibilityHelp(help)
        }
        finishLayout()
    }

    required init?(coder: NSCoder) { nil }
}

class LaunchInputRowView: LaunchFormItemView {
    let id: UUID
    var onChange: (() -> Void)?
    var onRemove: (() -> Void)?
    private(set) var removeButton: NSButton!

    init(id: UUID, removeTitle: String) {
        self.id = id
        super.init(frame: .zero)
        let button = LaunchFormStyle.button(removeTitle) { [weak self] in self?.onRemove?() }
        button.image = NSImage(systemSymbolName: "minus", accessibilityDescription: removeTitle)
        button.imagePosition = .imageOnly
        button.toolTip = removeTitle
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        removeButton = button
    }

    required init?(coder: NSCoder) { nil }

    func observe(_ inputs: LaunchTextField...) {
        for input in inputs {
            input.onChange = { [weak self] in self?.valueChanged() }
        }
    }

    @objc func valueChanged() { onChange?() }
    func restoreControlState() {}
}

final class LaunchPortRowView: LaunchInputRowView {
    let hostPort = LaunchTextField(placeholder: "e.g. 8080")
    let containerPort = LaunchTextField(placeholder: "e.g. 80")
    let hostAddress = LaunchTextField(placeholder: "All interfaces")
    let transport = NSPopUpButton(frame: .zero, pullsDown: false)
    private let addressFields = LaunchFormStyle.vertical(spacing: AppSpacing.xs)
    private var addressButton: NSButton!
    private var addressExpanded = false

    var input: ContainerPortInput {
        ContainerPortInput(
            id: id, hostAddress: hostAddress.stringValue,
            hostPort: hostPort.stringValue, containerPort: containerPort.stringValue,
            transport: transport.indexOfSelectedItem == 1 ? .udp : .tcp
        )
    }

    init(input: ContainerPortInput) {
        super.init(id: input.id, removeTitle: "Remove port mapping")
        hostPort.stringValue = input.hostPort
        containerPort.stringValue = input.containerPort
        hostAddress.stringValue = input.hostAddress
        firstInput = hostPort
        transport.addItems(withTitles: ["TCP", "UDP"])
        transport.selectItem(at: input.transport == .udp ? 1 : 0)
        transport.target = self
        transport.action = #selector(valueChanged)
        transport.translatesAutoresizingMaskIntoConstraints = false
        transport.widthAnchor.constraint(equalToConstant: 86).isActive = true
        transport.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let host = LaunchFormStyle.labeled("Host port", input: hostPort)
        let container = LaunchFormStyle.labeled("Container port", input: containerPort)
        stack.addFullWidthArrangedSubview(LaunchFormStyle.horizontal([
            host, container, LaunchFormStyle.labeled("Protocol", input: transport), removeButton
        ]))
        host.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        addressButton = LaunchFormStyle.button("Host address") { [weak self] in
            guard let self else { return }
            self.setAddressExpanded(!self.addressExpanded)
        }
        addressButton.font = AppFonts.small
        let addressHeader = LaunchFormStyle.horizontal([addressButton, NSView()], alignment: .centerY)
        stack.addFullWidthArrangedSubview(addressHeader)
        addressFields.addFullWidthArrangedSubview(LaunchFormStyle.labeled("Host address", input: hostAddress))
        addressFields.addFullWidthArrangedSubview(LaunchFormStyle.label("Leave empty for all host interfaces, or use an IP such as 127.0.0.1 or ::1."))
        stack.addFullWidthArrangedSubview(addressFields)
        setAddressExpanded(!input.hostAddress.isEmpty)
        observe(hostPort, containerPort, hostAddress)
        finishLayout()
    }

    required init?(coder: NSCoder) { nil }

    override func valueChanged() {
        updateAddressTitle()
        super.valueChanged()
    }

    override func revealError() {
        if !hostAddress.stringValue.isEmpty { setAddressExpanded(true) }
    }

    private func setAddressExpanded(_ expanded: Bool) {
        addressExpanded = expanded
        addressFields.isHidden = !expanded
        LaunchFormStyle.updateDisclosure(addressButton, expanded: expanded)
        updateAddressTitle()
        window?.recalculateKeyViewLoop()
    }

    private func updateAddressTitle() {
        let address = hostAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        addressButton.title = addressExpanded ? "Host address" : "Host address: \(address.isEmpty ? "All interfaces" : address)"
        addressButton.setAccessibilityLabel(addressButton.title)
    }
}

final class LaunchEnvironmentRowView: LaunchInputRowView {
    let name = LaunchTextField(placeholder: "e.g. NODE_ENV")
    let value = LaunchTextField(placeholder: "Value (may be empty)")
    let inherit = NSButton(checkboxWithTitle: "Use value from host environment", target: nil, action: nil)

    var input: ContainerEnvironmentInput {
        ContainerEnvironmentInput(id: id, name: name.stringValue, value: value.stringValue, inheritFromHost: inherit.state == .on)
    }

    init(input: ContainerEnvironmentInput) {
        super.init(id: input.id, removeTitle: "Remove environment variable")
        firstInput = name
        name.stringValue = input.name
        value.stringValue = input.value
        inherit.state = input.inheritFromHost ? .on : .off
        inherit.target = self
        inherit.action = #selector(valueChanged)
        inherit.font = AppFonts.small
        inherit.setAccessibilityHelp("Off: an empty value is passed as an empty string. On: read the value from the application's environment.")
        let nameField = LaunchFormStyle.labeled("Variable", input: name)
        let valueField = LaunchFormStyle.labeled("Value", input: value)
        stack.addFullWidthArrangedSubview(LaunchFormStyle.horizontal([nameField, valueField, removeButton]))
        nameField.widthAnchor.constraint(equalTo: valueField.widthAnchor, multiplier: 0.7).isActive = true
        stack.addFullWidthArrangedSubview(inherit)
        observe(name, value)
        restoreControlState()
        finishLayout()
    }

    required init?(coder: NSCoder) { nil }

    override func restoreControlState() { value.isEnabled = inherit.state != .on }

    override func valueChanged() {
        restoreControlState()
        super.valueChanged()
    }
}

final class LaunchMountRowView: LaunchInputRowView {
    let kind = NSPopUpButton(frame: .zero, pullsDown: false)
    let source = LaunchComboBox(placeholder: "/Users/you/project")
    let destination = LaunchTextField(placeholder: "e.g. /app")
    let readOnly = NSButton(checkboxWithTitle: "Read only", target: nil, action: nil)
    private var browseButton: NSButton!
    private let volumeHelp = LaunchFormStyle.label("A new named volume is created when you submit these settings if it does not exist.")
    private var volumeNames: [String] = []

    var input: ContainerMountInput {
        ContainerMountInput(
            id: id, kind: kind.indexOfSelectedItem == 1 ? .volume : .bind,
            source: source.stringValue, destination: destination.stringValue, readOnly: readOnly.state == .on
        )
    }

    init(input: ContainerMountInput) {
        super.init(id: input.id, removeTitle: "Remove volume mapping")
        firstInput = source
        kind.addItems(withTitles: ["Host folder", "Named volume"])
        kind.selectItem(at: input.kind == .volume ? 1 : 0)
        kind.target = self
        kind.action = #selector(kindChanged)
        kind.translatesAutoresizingMaskIntoConstraints = false
        kind.widthAnchor.constraint(equalToConstant: 132).isActive = true
        kind.heightAnchor.constraint(equalToConstant: 28).isActive = true
        source.stringValue = input.source
        destination.stringValue = input.destination
        readOnly.state = input.readOnly ? .on : .off
        readOnly.target = self
        readOnly.action = #selector(valueChanged)
        browseButton = LaunchFormStyle.button("Choose...") { [weak self] in self?.chooseFolder() }
        browseButton.setAccessibilityLabel("Choose host folder")
        stack.addFullWidthArrangedSubview(LaunchFormStyle.horizontal([
            LaunchFormStyle.labeled("Type", input: kind),
            LaunchFormStyle.labeled("Source", input: source), browseButton, removeButton
        ]))
        stack.addFullWidthArrangedSubview(LaunchFormStyle.horizontal([
            LaunchFormStyle.labeled("Container path", input: destination), readOnly
        ]))
        stack.addFullWidthArrangedSubview(volumeHelp)
        source.onChange = { [weak self] in self?.valueChanged() }
        observe(destination)
        updateKind()
        finishLayout()
    }

    required init?(coder: NSCoder) { nil }

    func setVolumeNames(_ names: [String]) {
        volumeNames = names
        updateKind()
    }

    override func restoreControlState() {
        browseButton.isEnabled = kind.indexOfSelectedItem == 0
    }

    @objc private func kindChanged() {
        updateKind()
        valueChanged()
    }

    private func updateKind() {
        let isVolume = kind.indexOfSelectedItem == 1
        source.placeholderString = isVolume ? "e.g. app-data" : "/Users/you/project"
        source.setAccessibilityLabel(isVolume ? "Volume name" : "Host folder")
        source.setSuggestions(isVolume ? volumeNames : [])
        source.hasVerticalScroller = isVolume
        volumeHelp.isHidden = !isVolume
        browseButton.isHidden = isVolume
        restoreControlState()
    }

    private func chooseFolder() {
        guard let window else {
            showError("Open these settings in a window before choosing a folder.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        if source.stringValue.hasPrefix("/") {
            panel.directoryURL = URL(fileURLWithPath: source.stringValue)
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            guard let url = panel.url else {
                self?.showError("The selected folder could not be read. Enter its path instead.")
                return
            }
            self?.source.stringValue = url.path
            self?.source.toolTip = url.path
            self?.valueChanged()
        }
    }
}

final class LaunchNetworkRowView: LaunchInputRowView {
    let specification = LaunchComboBox(placeholder: "Network name")

    var input: ContainerNetworkInput { ContainerNetworkInput(id: id, specification: specification.stringValue) }

    init(input: ContainerNetworkInput) {
        super.init(id: input.id, removeTitle: "Remove network attachment")
        firstInput = specification
        specification.stringValue = input.specification
        specification.setAccessibilityHelp("One network attachment per row. Optional mac and mtu settings stay with this network.")
        specification.onChange = { [weak self] in self?.valueChanged() }
        stack.addFullWidthArrangedSubview(LaunchFormStyle.horizontal([
            LaunchFormStyle.labeled("Network", input: specification), removeButton
        ]))
        finishLayout()
    }

    required init?(coder: NSCoder) { nil }
}
