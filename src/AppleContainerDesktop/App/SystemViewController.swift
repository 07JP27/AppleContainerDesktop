import AppKit

final class SystemViewController: NSViewController, ContentReloading {
    private let systemService: SystemService
    private let onRuntimeStatusChange: @MainActor () -> Void
    private let scrollView = NSScrollView()
    private let stack = NSStackView()

    init(
        systemService: SystemService = SystemService(),
        onRuntimeStatusChange: @escaping @MainActor () -> Void = {}
    ) {
        self.systemService = systemService
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
        stack.addFullWidthArrangedSubview(PageHeaderView(title: "Runtime", subtitle: "Checking status."))
        addFullWidth(statusHero(title: "Checking runtime", message: "Reading status.", health: .unknown, actions: []))
    }

    private func render(_ snapshot: SystemSnapshot) {
        stack.setViews([], in: .top)

        if snapshot.health == .missingCLI {
            stack.addFullWidthArrangedSubview(PageHeaderView(title: "Runtime", subtitle: "Install Apple container CLI first."))
            addFullWidth(missingCLIGate(snapshot))
            return
        }

        stack.addFullWidthArrangedSubview(PageHeaderView(title: "Runtime", subtitle: "Status and controls."))

        let actions = runtimeActions(for: snapshot.health)

        addFullWidth(
            statusHero(
                title: heroTitle(for: snapshot.health),
                message: heroMessage(for: snapshot),
                health: snapshot.health,
                actions: actions
            )
        )
        addFullWidth(systemCards(snapshot))

        if shouldShowStatusDetail(for: snapshot), let errorDetail = snapshot.errorDetail, !errorDetail.isEmpty {
            addFullWidth(commandCard(title: "Status detail", value: errorDetail))
        }
    }

    private func addFullWidth(_ view: NSView) {
        stack.addFullWidthArrangedSubview(view)
    }

    private func shouldShowStatusDetail(for snapshot: SystemSnapshot) -> Bool {
        snapshot.health != .stopped
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
        card.stack.addArrangedSubview(StatusChipView(title: "Runtime unavailable", health: .missingCLI))
        card.stack.addArrangedSubview(NSTextField.label("Runtime unavailable", font: AppFonts.heading))

        let message = NSTextField(wrappingLabelWithString: "Install Apple's signed CLI, then refresh.")
        message.font = AppFonts.body
        message.textColor = AppColors.muted
        message.maximumNumberOfLines = 3
        card.stack.addArrangedSubview(message)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = AppSpacing.sm
        actions.addArrangedSubview(releaseButton)
        card.stack.addArrangedSubview(actions)

        let details = NSTextField(wrappingLabelWithString: "Checked PATH, /usr/local/bin/container, and /Library/Apple/usr/bin/container.")
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
            ("Service", snapshot.health.label, nil),
            ("CLI", snapshot.version?.cliVersion ?? "Not available", snapshot.detection.executableURL?.path ?? "No executable detected"),
            ("API server", snapshot.version?.apiServerVersion ?? "Not available", nil),
            ("Disk usage", snapshot.diskUsageJSON == nil ? "Not available" : "Available", nil)
        ])
        card.stack.addArrangedSubview(statusTable)
        statusTable.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        return card
    }

    private func systemStatusTable(_ rows: [(String, String, String?)]) -> NSStackView {
        let table = NSStackView()
        table.orientation = .vertical
        table.alignment = .leading
        table.spacing = AppSpacing.md
        rows.forEach {
            let row = systemStatusRow($0.0, $0.1, $0.2)
            table.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: table.widthAnchor).isActive = true
        }
        return table
    }

    private func systemStatusRow(_ label: String, _ value: String, _ detail: String?) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = AppSpacing.lg
        row.translatesAutoresizingMaskIntoConstraints = false
        let keyLabel = NSTextField.label(label, font: AppFonts.body, color: AppColors.muted)
        keyLabel.alignment = .left
        keyLabel.widthAnchor.constraint(equalToConstant: 116).isActive = true
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = AppSpacing.xs

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = AppFonts.body
        valueLabel.textColor = AppColors.ink
        valueLabel.maximumNumberOfLines = 2
        valueLabel.alignment = .left
        content.addArrangedSubview(valueLabel)
        if let detail, !detail.isEmpty {
            let captionLabel = NSTextField(wrappingLabelWithString: detail)
            captionLabel.font = AppFonts.small
            captionLabel.textColor = AppColors.muted
            captionLabel.maximumNumberOfLines = 2
            captionLabel.alignment = .left
            content.addArrangedSubview(captionLabel)
        }

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
        valueLabel.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
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
            "Runtime unavailable"
        case .unknown:
            "Container runtime status is unclear"
        }
    }

    private func heroMessage(for snapshot: SystemSnapshot) -> String {
        switch snapshot.health {
        case .running:
            "Ready."
        case .stopped:
            "Stopped or unreachable."
        case .unhealthy:
            snapshot.message
        case .missingCLI:
            "CLI not found."
        case .unknown:
            "Status unknown."
        }
    }

    private func runtimeActions(for health: ServiceHealth) -> [NSButton] {
        switch health {
        case .stopped:
            let button = ClosureButton(title: "Start runtime...") { [weak self] in
                self?.confirmAndStartSystem()
            }
            button.bezelStyle = .rounded
            return [button]
        case .running:
            let stopButton = ClosureButton(title: "Stop runtime...") { [weak self] in
                self?.confirmAndStopSystem()
            }
            stopButton.bezelStyle = .rounded

            let restartButton = ClosureButton(title: "Restart runtime...") { [weak self] in
                self?.confirmAndRestartSystem()
            }
            restartButton.bezelStyle = .texturedRounded
            return [stopButton, restartButton]
        case .missingCLI, .unhealthy, .unknown:
            return []
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
        renderRuntimeProgress(title: "Starting runtime", message: "Starting...")
        Task { [systemService, weak self] in
            let outcome = await systemService.startSystem(enableKernelInstall: enableKernelInstall)
            let snapshot: SystemSnapshot
            if outcome.succeeded {
                await MainActor.run {
                    self?.renderRuntimeProgress(title: "Starting runtime", message: "Waiting for ready status.")
                }
                snapshot = await systemService.waitForRunningSystemSnapshot()
            } else {
                snapshot = await systemService.loadSystemSnapshot()
            }

            await MainActor.run {
                guard let self else { return }
                self.render(snapshot)
                if !outcome.succeeded, !outcome.detail.isEmpty {
                    self.addFullWidth(self.commandCard(title: "Start failed", value: outcome.detail))
                }
                self.onRuntimeStatusChange()
            }
        }
    }

    private func confirmAndStopSystem() {
        let alert = NSAlert()
        alert.messageText = "Stop Apple container runtime?"
        alert.informativeText = "Stopping the runtime can interrupt running containers and active operations."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop runtime")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        renderRuntimeProgress(title: "Stopping runtime", message: "Stopping...")
        Task { [systemService, weak self] in
            let outcome = await systemService.stopSystem()
            let snapshot = outcome.succeeded
                ? await systemService.waitForStoppedSystemSnapshot()
                : await systemService.loadSystemSnapshot()

            await MainActor.run {
                guard let self else { return }
                self.render(snapshot)
                if !outcome.succeeded, !outcome.detail.isEmpty {
                    self.addFullWidth(self.commandCard(title: "Stop failed", value: outcome.detail))
                }
                self.onRuntimeStatusChange()
            }
        }
    }

    private func confirmAndRestartSystem() {
        let alert = NSAlert()
        alert.messageText = "Restart Apple container runtime?"
        alert.informativeText = "Restarting the runtime stops it first, which can interrupt running containers and active operations."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart runtime")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        renderRuntimeProgress(title: "Restarting runtime", message: "Stopping...")
        Task { [systemService, weak self] in
            let outcome = await systemService.restartSystem()
            let snapshot: SystemSnapshot
            if outcome.succeeded {
                await MainActor.run {
                    self?.renderRuntimeProgress(title: "Restarting runtime", message: "Waiting for ready status.")
                }
                snapshot = await systemService.waitForRunningSystemSnapshot()
            } else {
                snapshot = await systemService.loadSystemSnapshot()
            }

            await MainActor.run {
                guard let self else { return }
                self.render(snapshot)
                if !outcome.succeeded, !outcome.detail.isEmpty {
                    self.addFullWidth(self.commandCard(title: "Restart failed", value: outcome.detail))
                }
                self.onRuntimeStatusChange()
            }
        }
    }

    private func renderRuntimeProgress(title: String, message: String) {
        stack.setViews([], in: .top)
        stack.addFullWidthArrangedSubview(PageHeaderView(title: "Runtime", subtitle: "Status and controls."))
        addFullWidth(statusHero(title: title, message: message, health: .unknown, actions: []))
    }
}
