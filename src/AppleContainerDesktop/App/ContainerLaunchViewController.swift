import AppKit

final class ContainerLaunchViewController: NSViewController, NSWindowDelegate {
    private let operation: ContainerOperation
    private let imageIsEditable: Bool
    private let service: ResourceService
    private let onSubmit: @MainActor (ContainerCreateRunRequest) async -> OperationOutcome
    private let onDismiss: @MainActor (Bool) -> Void
    private var sheetWindow: NSWindow?
    private var submissionTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var suggestionGeneration = 0
    private var cachedImage: ImageMetadata?
    private var choiceTasks: [ResourceKind: Task<Void, Never>] = [:]
    private var requestedChoices = Set<ResourceKind>()
    private var volumeNames: [String] = []
    private var networkNames: [String] = []
    private var validationTargets: [ContainerLaunchField: LaunchFormItemView] = [:]
    private var hasAttemptedSubmission = false

    let imageInput = LaunchTextField(placeholder: "e.g. nginx:latest")
    let nameInput = LaunchTextField(placeholder: "Optional")
    let cpuInput = LaunchTextField(placeholder: "Runtime default")
    let memoryInput = LaunchTextField(placeholder: "Runtime default, e.g. 2G")
    let platformInput = LaunchComboBox(placeholder: "Runtime default")
    let commandInput = LaunchTextField(placeholder: "Image default")
    let removeInput = NSButton(checkboxWithTitle: "Remove container after it exits", target: nil, action: nil)
    let scrollView = NSScrollView()
    let bodyStack = LaunchFormStyle.vertical(spacing: AppSpacing.xl)
    let advancedStack = LaunchFormStyle.vertical(spacing: AppSpacing.lg)
    let footerStatus = LaunchFormStyle.label("")
    let operationError = LaunchFormStyle.label("", color: AppColors.danger)
    let suggestionStatus = LaunchFormStyle.label("Add a mapping to make a container port available on your Mac.")
    let suggestionWarning = LaunchFormStyle.label("")
    private let suggestionRows = LaunchFormStyle.vertical()
    private let portStack = LaunchFormStyle.vertical(spacing: AppSpacing.lg)
    private let volumeStack = LaunchFormStyle.vertical(spacing: AppSpacing.lg)
    private let environmentStack = LaunchFormStyle.vertical(spacing: AppSpacing.lg)
    private let networkStack = LaunchFormStyle.vertical(spacing: AppSpacing.lg)
    private let volumeChoicesStatus = LaunchFormStyle.label("")
    private let networkChoicesStatus = LaunchFormStyle.label("")
    private let progress = NSProgressIndicator()

    private(set) var portRows: [LaunchPortRowView] = []
    private(set) var mountRows: [LaunchMountRowView] = []
    private(set) var environmentRows: [LaunchEnvironmentRowView] = []
    private(set) var networkRows: [LaunchNetworkRowView] = []
    private(set) var suggestions: [ImagePortSuggestion] = []
    private(set) var advancedExpanded = false
    private(set) var isSubmitting = false
    private(set) var didDismiss = false

    private(set) lazy var submitButton = LaunchFormStyle.button(operation.rawValue) { [weak self] in self?.submit() }
    private(set) lazy var cancelButton = LaunchFormStyle.button("Cancel") { [weak self] in self?.cancel() }
    private(set) lazy var advancedButton = LaunchFormStyle.button("Advanced settings") { [weak self] in
        guard let self else { return }
        self.setAdvancedExpanded(!self.advancedExpanded)
    }
    private lazy var refreshSuggestionsButton = LaunchFormStyle.button("Refresh suggestions") { [weak self] in
        self?.refreshPortSuggestions()
    }

    init(
        operation: ContainerOperation,
        imageReference: String = "",
        imageIsEditable: Bool = true,
        imageMetadata: ImageMetadata? = nil,
        service: ResourceService,
        onSubmit: @escaping @MainActor (ContainerCreateRunRequest) async -> OperationOutcome,
        onDismiss: @escaping @MainActor (Bool) -> Void
    ) {
        self.operation = operation
        self.imageIsEditable = imageIsEditable
        self.service = service
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
        self.cachedImage = imageMetadata
        super.init(nibName: nil, bundle: nil)
        imageInput.stringValue = imageReference
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        suggestionTask?.cancel()
        for task in choiceTasks.values { task.cancel() }
    }

    var draft: ContainerCreateRunRequest {
        ContainerCreateRunRequest(
            operation: operation, image: imageInput.stringValue, name: nameInput.stringValue,
            remove: operation == .run && removeInput.state == .on,
            cpus: cpuInput.stringValue, memory: memoryInput.stringValue,
            environment: environmentRows.map(\.input), volumes: mountRows.map(\.input),
            ports: portRows.map(\.input), networks: networkRows.map(\.input),
            platform: platformInput.stringValue, command: commandInput.stringValue
        )
    }

    override func loadView() {
        view = ThemedContainerView(backgroundColor: AppColors.surface)
        view.frame = NSRect(x: 0, y: 0, width: 680, height: 720)
        buildLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        imageInput.onChange = { [weak self] in
            guard let self else { return }
            self.cachedImage = nil
            self.suggestions = []
            self.renderSuggestions()
            self.fieldEdited()
            self.refreshPortSuggestions(debounce: true)
        }
        platformInput.onChange = { [weak self] in
            self?.fieldEdited()
            self?.applyCachedSuggestions()
        }
        for input in [nameInput, cpuInput, memoryInput, commandInput] {
            input.onChange = { [weak self] in self?.fieldEdited() }
        }
        removeInput.target = self
        removeInput.action = #selector(fieldEdited)
        applyCachedSuggestions()
        refreshPortSuggestions()
    }

    func present(asSheetOf parent: NSWindow) {
        loadViewIfNeeded()
        let available = parent.screen?.visibleFrame.size ?? parent.frame.size
        let size = NSSize(width: min(680, available.width - 48), height: min(720, available.height - 120))
        let sheet = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.title = operation == .run ? "Run container" : "Create container"
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = self
        sheet.setContentSize(size)
        sheet.contentMinSize = NSSize(width: min(560, size.width), height: min(380, size.height))
        sheet.contentMaxSize = NSSize(width: max(size.width, 900), height: max(size.height, available.height - 80))
        sheet.autorecalculatesKeyViewLoop = true
        sheet.delegate = self
        sheetWindow = sheet
        parent.beginSheet(sheet) { [weak self] _ in
            self?.finishPresentation(succeeded: false)
        }
        sheet.makeFirstResponder(imageIsEditable ? imageInput : nameInput)
    }

    func windowWillClose(_ notification: Notification) {
        finishPresentation(succeeded: false)
    }

    func cancel() {
        guard !isSubmitting else {
            footerStatus.stringValue = "The operation is still running."
            return
        }
        finishPresentation(succeeded: false)
    }

    func submit() {
        guard !isSubmitting, !didDismiss else { return }
        view.window?.makeFirstResponder(nil)
        let request = draft
        hasAttemptedSubmission = true
        let issues = request.validationIssues
        showValidation(issues, focusFirst: true)
        guard issues.isEmpty else { return }

        isSubmitting = true
        operationError.isHidden = true
        footerStatus.stringValue = operation == .run ? "Starting container..." : "Creating container..."
        progress.isHidden = false
        progress.startAnimation(nil)
        setFormEnabled(false)
        submissionTask = Task { [weak self, onSubmit] in
            let outcome = await onSubmit(request)
            guard let self, !self.didDismiss else { return }
            self.isSubmitting = false
            self.submissionTask = nil
            self.progress.stopAnimation(nil)
            self.progress.isHidden = true
            self.setFormEnabled(true)
            if outcome.succeeded {
                self.finishPresentation(succeeded: true)
            } else {
                self.footerStatus.stringValue = "Could not \(self.operation == .run ? "start" : "create") container."
                let detail = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = detail.isEmpty ? "The runtime did not report a successful result." : String(detail.prefix(1_200))
                self.operationError.stringValue = "Your settings have been kept. Correct the problem and try again.\n\(summary)"
                self.operationError.toolTip = detail
                self.operationError.isHidden = false
                self.reveal(self.operationError)
            }
        }
    }

    @objc func fieldEdited() {
        guard !isSubmitting, !didDismiss else { return }
        if hasAttemptedSubmission { showValidation(draft.validationIssues, focusFirst: false) }
        renderSuggestions()
        if mountRows.contains(where: { $0.input.kind == .volume }) { loadChoices(.volumes) }
    }

    func setAdvancedExpanded(_ expanded: Bool) {
        advancedExpanded = expanded
        advancedStack.isHidden = !expanded
        LaunchFormStyle.updateDisclosure(advancedButton, expanded: expanded)
        view.window?.recalculateKeyViewLoop()
    }

    func addPort(_ input: ContainerPortInput = ContainerPortInput(), focus: Bool = true) {
        let row = LaunchPortRowView(input: input)
        let id = row.id
        portRows.append(row)
        registerRow(row, in: portStack, field: .port(row.id)) { [weak self] in
            self?.portRows.removeAll { $0.id == id }
        }
        fieldEdited()
        if focus { revealAndFocus(row) }
    }

    func addMount(_ input: ContainerMountInput = ContainerMountInput(), focus: Bool = true) {
        let row = LaunchMountRowView(input: input)
        let id = row.id
        row.setVolumeNames(volumeNames)
        mountRows.append(row)
        registerRow(row, in: volumeStack, field: .mount(row.id)) { [weak self] in
            self?.mountRows.removeAll { $0.id == id }
        }
        fieldEdited()
        if focus { revealAndFocus(row) }
    }

    func addEnvironment(_ input: ContainerEnvironmentInput = ContainerEnvironmentInput(), focus: Bool = true) {
        let row = LaunchEnvironmentRowView(input: input)
        let id = row.id
        environmentRows.append(row)
        registerRow(row, in: environmentStack, field: .environment(row.id)) { [weak self] in
            self?.environmentRows.removeAll { $0.id == id }
        }
        fieldEdited()
        if focus { revealAndFocus(row) }
    }

    func addNetwork(_ input: ContainerNetworkInput = ContainerNetworkInput(), focus: Bool = true) {
        let row = LaunchNetworkRowView(input: input)
        let id = row.id
        row.specification.setSuggestions(networkNames)
        networkRows.append(row)
        registerRow(row, in: networkStack, field: .network(row.id)) { [weak self] in
            self?.networkRows.removeAll { $0.id == id }
        }
        loadChoices(.networks)
        fieldEdited()
        if focus { revealAndFocus(row) }
    }

    func addSuggestedPort(_ suggestion: ImagePortSuggestion) {
        addPort(ContainerPortInput(
            containerPort: String(suggestion.port.port),
            transport: suggestion.port.transport == "udp" ? .udp : .tcp
        ))
    }

    func refreshPortSuggestions(debounce: Bool = false) {
        suggestionGeneration += 1
        suggestionTask?.cancel()
        let generation = suggestionGeneration
        let reference = imageInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !didDismiss, !draft.validationIssues.contains(where: { $0.field == .image }) else {
            suggestionTask = nil
            refreshSuggestionsButton.isEnabled = !didDismiss && !isSubmitting
            suggestionStatus.stringValue = "Enter an image to see its declared ports, or add a mapping manually."
            suggestionWarning.isHidden = true
            return
        }
        suggestionStatus.stringValue = "Looking up ports declared by the local image..."
        refreshSuggestionsButton.isEnabled = false
        suggestionTask = Task { [weak self, service] in
            if debounce {
                do {
                    try await Task.sleep(for: .milliseconds(450))
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, self.suggestionGeneration == generation, !self.didDismiss else { return }
                    self.showSuggestionFailure(error.localizedDescription)
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let result = await service.inspectLaunchImage(reference: reference)
            guard let self, !Task.isCancelled, !self.didDismiss, self.suggestionGeneration == generation else { return }
            self.suggestionTask = nil
            self.refreshSuggestionsButton.isEnabled = !self.isSubmitting
            switch result {
            case .success(let image):
                self.cachedImage = image
                self.applyCachedSuggestions()
            case .failure(let error):
                self.showSuggestionFailure(error.message)
            }
        }
    }

    private func buildLayout() {
        let header = LaunchFormStyle.vertical(spacing: AppSpacing.md)
        header.addFullWidthArrangedSubview(LaunchFormStyle.label(
            operation == .run ? "Run container" : "Create container", color: AppColors.ink, font: AppFonts.heading
        ))
        imageInput.isEditable = imageIsEditable
        imageInput.isSelectable = true
        imageInput.toolTip = imageInput.stringValue
        imageInput.font = AppFonts.mono
        if !imageIsEditable {
            imageInput.isBezeled = false
            imageInput.drawsBackground = false
        }
        let image = LaunchLabeledFieldView(title: "Image", input: imageInput)
        validationTargets[.image] = image
        header.addFullWidthArrangedSubview(image)
        if operation == .create {
            header.addFullWidthArrangedSubview(LaunchFormStyle.label("Prepare a container without starting it."))
        }

        let name = LaunchLabeledFieldView(title: "Container name", input: nameInput, help: "Leave empty to use a generated name.")
        validationTargets[.name] = name
        operationError.isHidden = true
        operationError.maximumNumberOfLines = 6
        bodyStack.addFullWidthArrangedSubview(operationError)
        bodyStack.addFullWidthArrangedSubview(name)

        let ports = section("Ports", action: "Add port") { [weak self] in self?.addPort() }
        ports.addFullWidthArrangedSubview(suggestionStatus)
        suggestionWarning.isHidden = true
        ports.addFullWidthArrangedSubview(suggestionWarning)
        ports.addFullWidthArrangedSubview(suggestionRows)
        refreshSuggestionsButton.font = AppFonts.small
        let refreshRow = LaunchFormStyle.horizontal([refreshSuggestionsButton, NSView()], alignment: .centerY)
        ports.addFullWidthArrangedSubview(refreshRow)
        ports.addFullWidthArrangedSubview(portStack)
        bodyStack.addFullWidthArrangedSubview(ports)

        let volumes = section("Volumes", action: "Add volume") { [weak self] in self?.addMount() }
        volumes.addFullWidthArrangedSubview(LaunchFormStyle.label("Share a host folder or keep data in a named volume."))
        volumeChoicesStatus.isHidden = true
        volumes.addFullWidthArrangedSubview(volumeChoicesStatus)
        volumes.addFullWidthArrangedSubview(volumeStack)
        bodyStack.addFullWidthArrangedSubview(volumes)

        let environment = section("Environment variables", action: "Add variable") { [weak self] in self?.addEnvironment() }
        environment.addFullWidthArrangedSubview(LaunchFormStyle.label("Set a name and value for each variable. Empty values are allowed."))
        environment.addFullWidthArrangedSubview(environmentStack)
        bodyStack.addFullWidthArrangedSubview(environment)
        buildAdvancedFields()
        bodyStack.addFullWidthArrangedSubview(LaunchFormStyle.horizontal([advancedButton, NSView()], alignment: .centerY))
        bodyStack.addFullWidthArrangedSubview(advancedStack)
        setAdvancedExpanded(false)

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(bodyStack)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.setAccessibilityLabel("Container settings")

        let footer = makeFooter()
        let topRule = NSBox()
        let bottomRule = NSBox()
        topRule.boxType = .separator
        bottomRule.boxType = .separator
        for child in [header, scrollView, footer, topRule, bottomRule] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: AppSpacing.xl),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -AppSpacing.xl),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: AppSpacing.xl),
            topRule.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topRule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: AppSpacing.lg),
            scrollView.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            bottomRule.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -AppSpacing.lg),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: AppSpacing.xl),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -AppSpacing.xl),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -AppSpacing.lg),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: AppSpacing.xl),
            bodyStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -AppSpacing.xl),
            bodyStack.topAnchor.constraint(equalTo: document.topAnchor, constant: AppSpacing.xl),
            bodyStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -AppSpacing.xl)
        ])
    }

    private func buildAdvancedFields() {
        let cpu = LaunchLabeledFieldView(title: "CPUs", input: cpuInput)
        let memory = LaunchLabeledFieldView(title: "Memory limit", input: memoryInput)
        validationTargets[.cpus] = cpu
        validationTargets[.memory] = memory
        advancedStack.addFullWidthArrangedSubview(LaunchFormStyle.horizontal([cpu, memory]))
        cpu.widthAnchor.constraint(equalTo: memory.widthAnchor).isActive = true
        advancedStack.addFullWidthArrangedSubview(LaunchFormStyle.label("Empty fields keep the runtime defaults. Memory accepts units such as M or G."))

        let networks = section("Networks", action: "Add network") { [weak self] in self?.addNetwork() }
        networks.addFullWidthArrangedSubview(LaunchFormStyle.label("Leave empty to use the default network."))
        networkChoicesStatus.isHidden = true
        networks.addFullWidthArrangedSubview(networkChoicesStatus)
        networks.addFullWidthArrangedSubview(networkStack)
        advancedStack.addFullWidthArrangedSubview(networks)

        platformInput.setSuggestions(["linux/arm64", "linux/amd64"])
        let platform = LaunchLabeledFieldView(title: "Platform", input: platformInput, help: "Leave empty to let the runtime select the platform.")
        validationTargets[.platform] = platform
        advancedStack.addFullWidthArrangedSubview(platform)
        let command = LaunchLabeledFieldView(
            title: "Command override", input: commandInput,
            help: "Replaces the image command. Quotes group arguments; shell expansion is not performed."
        )
        commandInput.font = AppFonts.mono
        validationTargets[.command] = command
        advancedStack.addFullWidthArrangedSubview(command)
        if operation == .run {
            advancedStack.addFullWidthArrangedSubview(removeInput)
        }
        removeInput.isEnabled = operation == .run
    }

    private func makeFooter() -> NSStackView {
        submitButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        for button in [submitButton, cancelButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.isHidden = true
        progress.setAccessibilityLabel("Container operation in progress")
        footerStatus.maximumNumberOfLines = 2
        let status = LaunchFormStyle.horizontal([progress, footerStatus], alignment: .centerY)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return LaunchFormStyle.horizontal([status, cancelButton, submitButton], alignment: .centerY)
    }

    private func section(_ title: String, action: String, onAction: @escaping () -> Void) -> NSStackView {
        let stack = LaunchFormStyle.vertical(spacing: AppSpacing.md)
        let label = LaunchFormStyle.label(title, color: AppColors.ink, font: .systemFont(ofSize: AppFonts.body.pointSize, weight: .semibold))
        let button = LaunchFormStyle.button(action, action: onAction)
        stack.addFullWidthArrangedSubview(LaunchFormStyle.horizontal([label, NSView(), button], alignment: .centerY))
        return stack
    }

    private func registerRow(_ row: LaunchInputRowView, in stack: NSStackView, field: ContainerLaunchField, remove: @escaping () -> Void) {
        validationTargets[field] = row
        row.onChange = { [weak self] in self?.fieldEdited() }
        row.onRemove = { [weak self, weak row, weak stack] in
            guard let self, let row, let stack, !self.isSubmitting else { return }
            remove()
            self.validationTargets.removeValue(forKey: field)
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
            self.fieldEdited()
            self.view.window?.recalculateKeyViewLoop()
        }
        stack.addFullWidthArrangedSubview(row)
        view.window?.recalculateKeyViewLoop()
    }

    private func showValidation(_ issues: [ContainerLaunchValidationIssue], focusFirst: Bool) {
        let grouped = Dictionary(grouping: issues, by: \.field)
        for (field, target) in validationTargets {
            target.showError(grouped[field]?.map(\.message).joined(separator: "\n"))
        }
        footerStatus.stringValue = issues.isEmpty ? "" : "Review the highlighted settings."
        guard focusFirst, let first = issues.first else { return }
        switch first.field {
        case .cpus, .memory, .platform, .command, .network:
            setAdvancedExpanded(true)
        default:
            break
        }
        if let target = validationTargets[first.field] {
            target.revealError()
            revealAndFocus(target)
        } else {
            operationError.stringValue = first.message
            operationError.isHidden = false
            reveal(operationError)
        }
    }

    private func revealAndFocus(_ item: LaunchFormItemView) {
        reveal(item)
        if let control = item.firstInput { view.window?.makeFirstResponder(control) }
    }

    private func reveal(_ item: NSView) {
        view.layoutSubtreeIfNeeded()
        if let document = scrollView.documentView, item.isDescendant(of: document) {
            let rect = document.convert(item.bounds, from: item).insetBy(dx: 0, dy: -AppSpacing.sm)
            _ = document.scrollToVisible(rect)
        }
    }

    private func setFormEnabled(_ enabled: Bool) {
        func update(_ view: NSView) {
            if let control = view as? NSControl { control.isEnabled = enabled }
            let children = (view as? NSStackView)?.arrangedSubviews ?? view.subviews
            for child in children { update(child) }
        }
        update(bodyStack)
        imageInput.isEnabled = enabled
        submitButton.isEnabled = enabled
        cancelButton.isEnabled = enabled
        if enabled {
            for row in mountRows { row.restoreControlState() }
            for row in environmentRows { row.restoreControlState() }
            removeInput.isEnabled = operation == .run
            refreshSuggestionsButton.isEnabled = suggestionTask == nil
            renderSuggestions()
        }
    }

    private func applyCachedSuggestions() {
        guard let image = cachedImage,
              image.reference.normalized == ImageReference(imageInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)).normalized else { return }
        let result = ImagePortSuggestions(image: image, platform: platformInput.stringValue)
        suggestions = result.ports
        suggestionStatus.stringValue = result.message
        suggestionWarning.stringValue = result.warning ?? ""
        suggestionWarning.isHidden = result.warning == nil
        suggestionWarning.toolTip = result.warning
        let platforms = (image.runtimeVariants ?? []).map(\.platform).filter { !$0.isEmpty }
        platformInput.setSuggestions(Array(Set(platforms + ["linux/arm64", "linux/amd64"])).sorted())
        renderSuggestions()
    }

    private func renderSuggestions() {
        for row in suggestionRows.arrangedSubviews {
            suggestionRows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for suggestion in suggestions {
            let isAdded = portRows.contains {
                $0.input.containerPort.trimmingCharacters(in: .whitespacesAndNewlines) == String(suggestion.port.port)
                    && $0.input.transport.rawValue == suggestion.port.transport
            }
            let title = suggestion.port.displayValue + " (" + suggestion.platforms.joined(separator: ", ") + ")"
            let label = LaunchFormStyle.label(title, color: AppColors.ink)
            let button = LaunchFormStyle.button(isAdded ? "Added" : "Add") { [weak self] in self?.addSuggestedPort(suggestion) }
            button.isEnabled = !isAdded && !isSubmitting
            button.setAccessibilityLabel(isAdded ? "\(suggestion.id) mapping added" : "Add \(suggestion.id) mapping")
            suggestionRows.addFullWidthArrangedSubview(LaunchFormStyle.horizontal([label, NSView(), button], alignment: .centerY))
        }
        suggestionRows.isHidden = suggestions.isEmpty
    }

    private func showSuggestionFailure(_ detail: String) {
        applyCachedSuggestions()
        suggestionTask = nil
        suggestionStatus.stringValue = suggestions.isEmpty ? "No port suggestions available. Add a mapping manually." : "Showing previously loaded port declarations."
        suggestionWarning.stringValue = "Could not read the local image. This does not prevent manual configuration."
        suggestionWarning.toolTip = detail
        suggestionWarning.setAccessibilityHelp(detail)
        suggestionWarning.isHidden = false
        refreshSuggestionsButton.isEnabled = !isSubmitting
    }

    private func loadChoices(_ kind: ResourceKind) {
        guard requestedChoices.insert(kind).inserted else { return }
        choiceTasks[kind] = Task { [weak self, service] in
            let snapshot = await service.load(kind: kind)
            guard let self, !self.didDismiss, !Task.isCancelled else { return }
            self.choiceTasks.removeValue(forKey: kind)
            let status = kind == .volumes ? self.volumeChoicesStatus : self.networkChoicesStatus
            if let error = snapshot.errorMessage {
                status.stringValue = "Saved \(kind.rawValue.lowercased()) could not be loaded. Enter a name directly."
                status.toolTip = snapshot.errorDetail ?? error
                status.isHidden = false
                return
            }
            status.isHidden = true
            let names = Array(Set(snapshot.items.map(\.title))).sorted()
            if kind == .volumes {
                self.volumeNames = names
                for row in self.mountRows { row.setVolumeNames(names) }
            } else {
                self.networkNames = names
                for row in self.networkRows { row.specification.setSuggestions(names) }
            }
            if self.isSubmitting { self.setFormEnabled(false) }
        }
    }

    private func finishPresentation(succeeded: Bool) {
        guard !didDismiss else { return }
        didDismiss = true
        suggestionGeneration += 1
        suggestionTask?.cancel()
        for task in choiceTasks.values { task.cancel() }
        if let sheet = sheetWindow {
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(nil)
            sheet.contentViewController = nil
            sheetWindow = nil
        }
        onDismiss(succeeded)
    }
}
