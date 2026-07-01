import AppKit

final class SystemViewController: NSViewController, ContentReloading {
    private let systemService: SystemService
    private let resourceService: ResourceService
    private let operationService: OperationService
    private let historyStore: OperationHistoryStoring
    private let onRuntimeStatusChange: @MainActor () -> Void
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private weak var builderResultStack: NSStackView?
    private weak var machineResultStack: NSStackView?

    init(
        systemService: SystemService = SystemService(),
        resourceService: ResourceService = ResourceService(),
        operationService: OperationService = OperationService(),
        historyStore: OperationHistoryStoring = UserDefaultsOperationHistoryStore(),
        onRuntimeStatusChange: @escaping @MainActor () -> Void = {}
    ) {
        self.systemService = systemService
        self.resourceService = resourceService
        self.operationService = operationService
        self.historyStore = historyStore
        self.onRuntimeStatusChange = onRuntimeStatusChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = ThemedContainerView(backgroundColor: AppColors.background)

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = AppSpacing.xl
        stack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: AppSpacing.xxl),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -AppSpacing.xxl),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: AppSpacing.xxl),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -AppSpacing.xxl)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadContent()
    }

    func reloadContent() {
        renderLoading()
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await systemService.loadSystemSnapshot()
            await MainActor.run {
                self.render(snapshot)
            }
        }
    }

    private func renderLoading() {
        stack.setViews([], in: .top)
        stack.addFullWidthArrangedSubview(PageHeaderView(title: "Runtime", subtitle: "Checking local container runtime status."))
        addFullWidth(statusHero(title: "Checking runtime", message: "Reading CLI and service status.", health: .unknown, actions: []))
    }

    private func render(_ snapshot: SystemSnapshot) {
        stack.setViews([], in: .top)

        if snapshot.health == .missingCLI {
            stack.addFullWidthArrangedSubview(PageHeaderView(title: "Runtime", subtitle: "Local Apple container runtime status."))
            addFullWidth(missingCLIGate(snapshot))
            return
        }

        stack.addFullWidthArrangedSubview(PageHeaderView(title: "Runtime", subtitle: "Status and maintenance controls for the local Apple container runtime."))

        let actions = snapshot.health == .stopped ? [
            ClosureButton(title: "Start runtime...") { [weak self] in
                self?.confirmAndStartSystem()
            }
        ] : []
        actions.first?.bezelStyle = .rounded

        addFullWidth(
            statusHero(
                title: heroTitle(for: snapshot.health),
                message: snapshot.message,
                health: snapshot.health,
                actions: actions
            )
        )
        addFullWidth(systemCards(snapshot))
        addFullWidth(systemControls())

        if let errorDetail = snapshot.errorDetail, !errorDetail.isEmpty {
            addFullWidth(commandCard(title: "Status detail", value: errorDetail))
        } else if let statusJSON = snapshot.statusJSON {
            addFullWidth(commandCard(title: "Runtime status JSON", value: statusJSON))
        }

        addFullWidth(recentOperationsCard())
    }

    private func addFullWidth(_ view: NSView) {
        stack.addFullWidthArrangedSubview(view)
    }

    private func statusHero(title: String, message: String, health: ServiceHealth, actions: [NSButton]) -> NSView {
        let card = CardView(spacing: AppSpacing.md)
        card.stack.addArrangedSubview(StatusChipView(title: health.label, health: health))
        card.stack.addArrangedSubview(NSTextField.label(title, font: AppFonts.title))

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = AppFonts.body
        messageLabel.textColor = AppColors.muted
        messageLabel.maximumNumberOfLines = 3
        card.stack.addArrangedSubview(messageLabel)

        if !actions.isEmpty {
            let actionRow = NSStackView()
            actionRow.orientation = .horizontal
            actionRow.alignment = .centerY
            actionRow.spacing = AppSpacing.sm
            actions.forEach { actionRow.addArrangedSubview($0) }
            card.stack.addArrangedSubview(actionRow)
        }

        return card
    }

    private func missingCLIGate(_ snapshot: SystemSnapshot) -> NSView {
        let releaseButton = ClosureButton(title: "Download signed installer...") {
            if let url = URL(string: "https://github.com/apple/container/releases") {
                NSWorkspace.shared.open(url)
            }
        }
        releaseButton.bezelStyle = .rounded

        let card = CardView(spacing: AppSpacing.md)
        card.stack.addArrangedSubview(StatusChipView(title: "Missing CLI", health: .missingCLI))
        card.stack.addArrangedSubview(NSTextField.label("Apple container CLI is missing", font: AppFonts.heading))

        let message = NSTextField(wrappingLabelWithString: "Install Apple's signed CLI, then press Refresh. This app never installs packages automatically.")
        message.font = AppFonts.body
        message.textColor = AppColors.muted
        message.maximumNumberOfLines = 2
        card.stack.addArrangedSubview(message)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = AppSpacing.sm
        actions.addArrangedSubview(releaseButton)
        card.stack.addArrangedSubview(actions)

        let details = NSTextField(wrappingLabelWithString: "Looked in PATH, /usr/local/bin/container, and /Library/Apple/usr/bin/container.")
        details.font = AppFonts.small
        details.textColor = AppColors.muted
        details.alignment = .left
        details.maximumNumberOfLines = 2
        card.stack.addArrangedSubview(details)
        details.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        return card
    }

    private func systemCards(_ snapshot: SystemSnapshot) -> NSView {
        let card = CardView(spacing: AppSpacing.md)
        card.stack.addArrangedSubview(NSTextField.label("Runtime status", font: AppFonts.heading))
        let statusTable = systemStatusTable([
            ("Service", snapshot.health.label, snapshot.message),
            ("CLI", snapshot.version?.cliVersion ?? "Not available", snapshot.detection.executableURL?.path ?? "No executable detected"),
            ("API server", snapshot.version?.apiServerVersion ?? "Not available", snapshot.lastCommand?.displayString ?? "Status command has not run"),
            ("Disk usage", snapshot.diskUsageJSON == nil ? "Not available" : "Available", snapshot.diskUsageJSON == nil ? "Run service to read container storage." : "Raw df output is available in status detail."),
            ("Install source", sourceLabel(for: snapshot.detection.source), snapshot.detection.problem ?? "Resolved from local machine.")
        ])
        card.stack.addArrangedSubview(statusTable)
        statusTable.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        return card
    }

    private func systemStatusTable(_ rows: [(String, String, String)]) -> NSStackView {
        let table = NSStackView()
        table.orientation = .vertical
        table.alignment = .width
        table.spacing = AppSpacing.md
        rows.forEach { table.addArrangedSubview(systemStatusRow($0.0, $0.1, $0.2)) }
        return table
    }

    private func systemStatusRow(_ label: String, _ value: String, _ detail: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = AppSpacing.lg
        let keyLabel = NSTextField.label(label, font: AppFonts.body, color: AppColors.muted)
        keyLabel.widthAnchor.constraint(equalToConstant: 116).isActive = true
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = AppSpacing.xs

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = AppFonts.body
        valueLabel.textColor = AppColors.ink
        valueLabel.maximumNumberOfLines = 2
        valueLabel.alignment = .left
        let captionLabel = NSTextField(wrappingLabelWithString: detail)
        captionLabel.font = AppFonts.small
        captionLabel.textColor = AppColors.muted
        captionLabel.maximumNumberOfLines = 2
        captionLabel.alignment = .left
        content.addArrangedSubview(valueLabel)
        content.addArrangedSubview(captionLabel)

        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(content)
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func commandCard(title: String, value: String) -> NSView {
        let card = CardView(spacing: AppSpacing.sm)
        card.stack.addArrangedSubview(NSTextField.label(title, font: AppFonts.heading))
        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = AppFonts.mono
        valueLabel.textColor = AppColors.ink
        valueLabel.maximumNumberOfLines = 10
        card.stack.addArrangedSubview(valueLabel)
        return card
    }

    private func systemControls() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = AppSpacing.md
        row.addArrangedSubview(builderCard())
        row.addArrangedSubview(machineCard())
        return row
    }

    private func builderCard() -> NSView {
        let card = CardView(spacing: AppSpacing.md)
        card.stack.addArrangedSubview(NSTextField.label("Builder", font: AppFonts.heading))
        let message = NSTextField(wrappingLabelWithString: "Build backend used by image builds.")
        message.font = AppFonts.body
        message.textColor = AppColors.muted
        message.maximumNumberOfLines = 3
        card.stack.addArrangedSubview(message)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = AppSpacing.sm
        for operation in BuilderOperation.allCases {
            let button = ClosureButton(title: operation.rawValue) { [weak self] in
                self?.runBuilder(operation)
            }
            button.controlSize = .small
            button.bezelStyle = operation.isDestructive ? .rounded : .texturedRounded
            actions.addArrangedSubview(button)
        }
        card.stack.addArrangedSubview(actions)
        let resultStack = makeInlineResultStack()
        builderResultStack = resultStack
        card.stack.addArrangedSubview(resultStack)
        return card
    }

    private func machineCard() -> NSView {
        let card = CardView(spacing: AppSpacing.md)
        card.stack.addArrangedSubview(NSTextField.label("Machines", font: AppFonts.heading))
        let message = NSTextField(wrappingLabelWithString: "Backing VM state for runtime diagnostics.")
        message.font = AppFonts.body
        message.textColor = AppColors.muted
        message.maximumNumberOfLines = 3
        card.stack.addArrangedSubview(message)
        let button = ClosureButton(title: "Load machines") { [weak self] in
            self?.loadMachines()
        }
        button.controlSize = .small
        button.bezelStyle = .texturedRounded
        card.stack.addArrangedSubview(button)
        let resultStack = makeInlineResultStack()
        machineResultStack = resultStack
        card.stack.addArrangedSubview(resultStack)
        return card
    }

    private func recentOperationsCard() -> NSView {
        let card = CardView(spacing: AppSpacing.md)
        card.stack.addArrangedSubview(NSTextField.label("Recent operations", font: AppFonts.heading))
        let recent = historyStore.recent(limit: 5)
        guard !recent.isEmpty else {
            let emptyLabel = NSTextField(wrappingLabelWithString: "Operations you run from Containers, Images, Networks, Volumes, Registries, and runtime controls will appear here.")
            emptyLabel.font = AppFonts.body
            emptyLabel.textColor = AppColors.muted
            emptyLabel.maximumNumberOfLines = 3
            card.stack.addArrangedSubview(emptyLabel)
            return card
        }

        for record in recent {
            let state = record.succeeded ? "Succeeded" : "Failed"
            card.stack.addArrangedSubview(keyValue(record.title, "\(state) · \(record.command)", monospaced: true, maxLines: 2))
        }
        return card
    }

    private func heroTitle(for health: ServiceHealth) -> String {
        switch health {
        case .running:
            "Container runtime is ready"
        case .stopped:
            "Container runtime is stopped"
        case .unhealthy:
            "Container runtime needs attention"
        case .missingCLI:
            "Apple container CLI is not installed"
        case .unknown:
            "Container runtime status is unclear"
        }
    }

    private func sourceLabel(for source: CLIExecutableSource?) -> String {
        switch source {
        case .settingsOverride:
            "Settings override"
        case .path:
            "PATH"
        case .knownLocation:
            "Known location"
        case nil:
            "Not detected"
        }
    }

    private func keyValue(_ key: String, _ value: String, monospaced: Bool = false, maxLines: Int = 8) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AppSpacing.xs

        let keyLabel = NSTextField.label(key, font: AppFonts.small, color: AppColors.muted)
        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = monospaced ? AppFonts.mono : AppFonts.body
        valueLabel.textColor = AppColors.ink
        valueLabel.maximumNumberOfLines = maxLines

        stack.addArrangedSubview(keyLabel)
        stack.addArrangedSubview(valueLabel)
        return stack
    }

    private func confirmAndStartSystem() {
        let alert = NSAlert()
        alert.messageText = "Start Apple container runtime?"
        alert.informativeText = "The container CLI may need kernel installation on first run. Choose whether to allow that explicitly; the app will not rely on an interactive CLI prompt."
        alert.addButton(withTitle: "Start without kernel install")
        alert.addButton(withTitle: "Start and allow kernel install")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
            return
        }

        let enableKernelInstall = response == .alertSecondButtonReturn
        addFullWidth(statusHero(title: "Starting runtime", message: "Running container system start with an explicit kernel-install choice.", health: .unknown, actions: []))
        Task { [systemService, weak self] in
            let outcome = await systemService.startSystem(enableKernelInstall: enableKernelInstall)
            let snapshot = await systemService.loadSystemSnapshot()
            await MainActor.run {
                if !outcome.succeeded, !outcome.detail.isEmpty {
                    self?.stack.addArrangedSubview(
                        self?.commandCard(title: "Start failed", value: outcome.detail) ?? NSView()
                    )
                }
                self?.render(snapshot)
                self?.onRuntimeStatusChange()
            }
        }
    }

    private func runBuilder(_ operation: BuilderOperation) {
        if operation.isDestructive {
            let alert = NSAlert()
            alert.messageText = "Delete builder?"
            alert.informativeText = "The builder will be removed and can be recreated with Builder Start."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        let preview = CLICommandPreview(executable: "container", arguments: operation.arguments())
        setInlineResult(in: builderResultStack, title: "Builder \(operation.rawValue)", value: "Running \(preview.displayString)")
        Task { [operationService, operation, weak self] in
            let outcome = await operationService.runBuilderOperation(operation)
            await MainActor.run {
                self?.setInlineResult(in: self?.builderResultStack, title: outcome.title, value: outcome.output.isEmpty ? (outcome.succeeded ? "Succeeded" : "Failed") : outcome.output)
            }
        }
    }

    private func loadMachines() {
        setInlineResult(in: machineResultStack, title: "Machines", value: "Loading container machine list...")
        Task { [resourceService, weak self] in
            let snapshot = await resourceService.load(kind: .machines)
            await MainActor.run {
                guard let self else { return }
                self.replaceInlineResults(in: self.machineResultStack, with: self.machinesResultView(snapshot))
            }
        }
    }

    private func machinesResultView(_ snapshot: ResourceListSnapshot) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = AppSpacing.sm

        if let error = snapshot.errorMessage {
            let detail = [error, snapshot.errorDetail].compactMap { $0 }.joined(separator: "\n")
            stack.addArrangedSubview(monospacedValue(detail))
            return stack
        }

        guard !snapshot.items.isEmpty else {
            let label = NSTextField(wrappingLabelWithString: ResourceKind.machines.emptyMessage)
            label.font = AppFonts.body
            label.textColor = AppColors.muted
            stack.addArrangedSubview(label)
            return stack
        }

        for item in snapshot.items {
            stack.addArrangedSubview(machineRow(item))
        }
        return stack
    }

    private func machineRow(_ item: ResourceListItem) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = AppSpacing.sm

        row.addArrangedSubview(NSTextField.label("\(item.title) · \(item.status)", font: AppFonts.body))
        if !item.detail.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: item.detail)
            detail.font = AppFonts.small
            detail.textColor = AppColors.muted
            detail.maximumNumberOfLines = 2
            row.addArrangedSubview(detail)
        }

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = AppSpacing.sm
        for operation in MachineOperation.allCases {
            let button = ClosureButton(title: operation.rawValue) { [weak self] in
                self?.runMachine(operation, item: item)
            }
            button.controlSize = .small
            button.bezelStyle = operation.isDestructive ? .rounded : .texturedRounded
            actions.addArrangedSubview(button)
        }
        row.addArrangedSubview(actions)
        return row
    }

    private func runMachine(_ operation: MachineOperation, item: ResourceListItem) {
        if operation.isDestructive {
            let alert = NSAlert()
            alert.messageText = "\(operation.rawValue) \(item.title)?"
            alert.informativeText = "This machine operation may affect the container runtime."
            alert.alertStyle = .warning
            alert.addButton(withTitle: operation.rawValue)
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        setInlineResult(in: machineResultStack, title: "Machine \(operation.rawValue)", value: "Running operation for \(item.title)...")
        Task { [operationService, operation, item, weak self] in
            let outcome = await operationService.runMachineOperation(operation, identifier: item.inspectIdentifier)
            await MainActor.run {
                self?.setInlineResult(in: self?.machineResultStack, title: outcome.title, value: outcome.output.isEmpty ? (outcome.succeeded ? "Succeeded" : "Failed") : outcome.output)
            }
        }
    }

    private func makeInlineResultStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = AppSpacing.sm
        return stack
    }

    private func setInlineResult(in resultStack: NSStackView?, title: String, value: String) {
        replaceInlineResults(in: resultStack, with: keyValue(title, value, monospaced: true, maxLines: 12))
    }

    private func replaceInlineResults(in resultStack: NSStackView?, with view: NSView) {
        guard let resultStack else { return }
        resultStack.setViews([], in: .top)
        resultStack.addArrangedSubview(view)
    }

    private func monospacedValue(_ value: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = AppFonts.mono
        label.textColor = AppColors.ink
        label.maximumNumberOfLines = 12
        return label
    }
}
