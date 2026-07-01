import AppKit

final class ResourceListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate, SearchFocusHandling, ContainerShortcutHandling, ContentReloading {
    private struct ResourceAction {
        var title: String
        var isDestructive: Bool
        var run: () -> Void
    }

    private enum Column: String {
        case name
        case status
        case detail
    }

    private let kind: ResourceKind
    private let service: ResourceService
    private let operationService: OperationService
    private let onInspectorUpdate: @MainActor (InspectorSnapshot) -> Void
    private let onRuntimeStatusRequested: (@MainActor () -> Void)?
    private let onBuildRequested: (@MainActor () -> Void)?

    private let stack = NSStackView()
    private let actionRow = NSStackView()
    private let tableCard = CardView(spacing: AppSpacing.md)
    private let tableScrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField.label("", color: AppColors.muted)
    private var tableStateView: NSView?
    private var snapshot: ResourceListSnapshot?
    private var rows: [ResourceListItem] = []
    private var filteredRows: [ResourceListItem] = []

    init(
        kind: ResourceKind,
        service: ResourceService = ResourceService(),
        operationService: OperationService = OperationService(),
        onInspectorUpdate: @escaping @MainActor (InspectorSnapshot) -> Void,
        onRuntimeStatusRequested: (@MainActor () -> Void)? = nil,
        onBuildRequested: (@MainActor () -> Void)? = nil
    ) {
        self.kind = kind
        self.service = service
        self.operationService = operationService
        self.onInspectorUpdate = onInspectorUpdate
        self.onRuntimeStatusRequested = onRuntimeStatusRequested
        self.onBuildRequested = onBuildRequested
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = ThemedContainerView(backgroundColor: AppColors.background)
        buildLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        onInspectorUpdate(.empty)
        loadResources()
    }

    func reloadContent() {
        loadResources()
    }

    private func buildLayout() {
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = AppSpacing.xl
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = AppSpacing.lg

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = AppSpacing.xs
        titleStack.addArrangedSubview(PageHeaderView(title: kind.rawValue, subtitle: pageSubtitle))
        titleStack.addArrangedSubview(statusLabel)

        let controlStack = NSStackView()
        controlStack.orientation = .vertical
        controlStack.alignment = .trailing
        controlStack.spacing = AppSpacing.sm

        searchField.placeholderString = "Search \(kind.rawValue.lowercased())"
        searchField.setAccessibilityLabel("Search \(kind.rawValue.lowercased())")
        searchField.setAccessibilityHelp("Filters the \(kind.rawValue.lowercased()) table by name, status, or detail.")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 280).isActive = true

        header.addArrangedSubview(titleStack)
        header.addArrangedSubview(NSView())
        controlStack.addArrangedSubview(searchField)
        controlStack.addArrangedSubview(actionRow)
        header.addArrangedSubview(controlStack)

        actionRow.orientation = .horizontal
        actionRow.spacing = AppSpacing.sm
        actionRow.alignment = .centerY

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 34
        tableView.headerView = NSTableHeaderView()
        tableView.backgroundColor = AppColors.surface
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu
        tableView.setAccessibilityLabel("\(kind.rawValue) table")
        tableView.setAccessibilityHelp("Use arrow keys to select rows. The inspector updates with details for the selected row.")

        addColumn(.name, title: "Name", width: 220)
        addColumn(.status, title: "Status", width: 110)
        addColumn(.detail, title: "Detail", width: 360)

        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = true
        tableScrollView.drawsBackground = false
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false

        tableCard.stack.addArrangedSubview(tableScrollView)

        stack.addFullWidthArrangedSubview(header)
        stack.addFullWidthArrangedSubview(tableCard)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: AppSpacing.xxl),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -AppSpacing.xxl),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: AppSpacing.xxl),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -AppSpacing.xxl),
            tableScrollView.widthAnchor.constraint(equalTo: tableCard.stack.widthAnchor)
        ])
        let tableHeight = tableScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        tableHeight.priority = .defaultHigh
        tableHeight.isActive = true
        rebuildActions()
    }

    private var pageSubtitle: String {
        switch kind {
        case .containers:
            "Create, run, inspect, and manage local containers through Apple container."
        case .images:
            "Pull, tag, push, inspect, and prune images available to the local runtime."
        case .networks:
            "View and manage container networks without leaving the desktop app."
        case .volumes:
            "Track persistent container volumes and run safe lifecycle operations."
        case .registry:
            "Manage registry sessions with password input passed through stdin."
        case .machines:
            "Inspect local container machines and manage default machine state."
        }
    }

    private func addColumn(_ column: Column, title: String, width: CGFloat) {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.title = title
        tableColumn.width = width
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
        tableView.addTableColumn(tableColumn)
    }

    private func loadResources() {
        statusLabel.stringValue = "Loading \(kind.rawValue.lowercased())..."
        Task { [kind, service, weak self] in
            let snapshot = await service.load(kind: kind)
            await MainActor.run {
                self?.render(snapshot)
            }
        }
    }

    private func render(_ snapshot: ResourceListSnapshot) {
        self.snapshot = snapshot
        rows = snapshot.items
        applyFilter()

        if !snapshot.detection.isAvailable {
            statusLabel.stringValue = "Apple container CLI is required."
            showTableState(
                title: "Install Apple container to view \(snapshot.kind.rawValue.lowercased())",
                message: "Install Apple's signed container CLI, then press Refresh. The app will not show fake resources or enable actions until the executable is detected.",
                actionTitle: "Download installer..."
            ) {
                if let url = URL(string: "https://github.com/apple/container/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
            onInspectorUpdate(.empty)
        } else if let errorMessage = snapshot.errorMessage {
            let detail = snapshot.errorDetail.map { "\n\($0)" } ?? ""
            statusLabel.stringValue = "\(errorMessage)\(detail)"
            showTableState(
                title: "Could not load \(snapshot.kind.rawValue.lowercased())",
                message: [errorMessage, snapshot.errorDetail].compactMap { $0 }.joined(separator: "\n"),
                actionTitle: onRuntimeStatusRequested == nil ? nil : "Open runtime status..."
            ) { [weak self] in
                self?.onRuntimeStatusRequested?()
            }
            onInspectorUpdate(.empty)
        } else if snapshot.items.isEmpty {
            statusLabel.stringValue = snapshot.kind.emptyMessage
            showTableState(title: "No \(snapshot.kind.rawValue.lowercased())", message: snapshot.kind.emptyMessage)
            onInspectorUpdate(.empty)
        } else {
            statusLabel.stringValue = "\(snapshot.items.count) item(s)"
            showTable()
            if tableView.selectedRow < 0 {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }
    }

    @objc private func searchChanged() {
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredRows = rows
        } else {
            filteredRows = rows.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
        }
        sortRows()
        tableView.reloadData()
        statusLabel.stringValue = filteredRows.isEmpty && !rows.isEmpty ? "No matching \(kind.rawValue.lowercased())." : statusLabel.stringValue
        rebuildActions()
    }

    private func showTable() {
        if let tableStateView {
            tableCard.stack.removeArrangedSubview(tableStateView)
            tableStateView.removeFromSuperview()
        }
        tableStateView = nil
        tableScrollView.isHidden = false
    }

    private func showTableState(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        if let tableStateView {
            tableCard.stack.removeArrangedSubview(tableStateView)
            tableStateView.removeFromSuperview()
        }
        tableScrollView.isHidden = true

        let state = NSStackView()
        state.orientation = .vertical
        state.alignment = .leading
        state.spacing = AppSpacing.sm
        state.translatesAutoresizingMaskIntoConstraints = false
        state.addArrangedSubview(NSTextField.label(title, font: AppFonts.heading))

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = AppFonts.body
        messageLabel.textColor = AppColors.muted
        messageLabel.maximumNumberOfLines = 4
        state.addArrangedSubview(messageLabel)

        if let actionTitle, let action {
            let button = ClosureButton(title: actionTitle, action: action)
            button.bezelStyle = .rounded
            state.addArrangedSubview(button)
        }

        tableCard.stack.insertArrangedSubview(state, at: 0)
        tableStateView = state
    }

    private func rebuildActions() {
        actionRow.setViews([], in: .leading)
        guard snapshot?.detection.isAvailable == true else {
            let message = snapshot == nil
                ? "Checking Apple container availability..."
                : "Install Apple container CLI to enable actions."
            actionRow.addArrangedSubview(NSTextField.label(message, font: AppFonts.small, color: AppColors.muted))
            return
        }

        let primaryActions = dedupe(availablePrimaryActions())
        for action in primaryActions {
            let button = ClosureButton(title: action.title, action: action.run)
            button.bezelStyle = action.isDestructive ? .rounded : .texturedRounded
            button.controlSize = .small
            actionRow.addArrangedSubview(button)
        }

        let secondaryActions = dedupe(availableSecondaryActions(excluding: Set(primaryActions.map(\.title))))
        if !secondaryActions.isEmpty {
            let menuButton = NSPopUpButton()
            menuButton.controlSize = .small
            menuButton.pullsDown = true
            menuButton.addItem(withTitle: "More")
            for action in secondaryActions {
                menuButton.menu?.addItem(ClosureMenuItem(title: action.title, action: action.run))
            }
            actionRow.addArrangedSubview(menuButton)
        }

        if actionRow.arrangedSubviews.isEmpty {
            actionRow.addArrangedSubview(NSTextField.label("No actions are available for the current selection.", font: AppFonts.small, color: AppColors.muted))
        }
    }

    private func dedupe(_ actions: [ResourceAction]) -> [ResourceAction] {
        var seen = Set<String>()
        return actions.filter { action in
            if seen.contains(action.title) {
                return false
            }
            seen.insert(action.title)
            return true
        }
    }

    private func availablePrimaryActions() -> [ResourceAction] {
        let selected = selectedItem()
        switch kind {
        case .containers:
            if let selected {
                if isRunning(selected) {
                    return [
                        action("Stop") { [weak self] in self?.runContainerOperation(.stop) },
                        action("Logs") { [weak self] in self?.runContainerOperation(.logs) },
                        action("Exec") { [weak self] in self?.runContainerOperation(.exec) }
                    ]
                }
                return [
                    action("Start") { [weak self] in self?.runContainerOperation(.start) },
                    action("Logs") { [weak self] in self?.runContainerOperation(.logs) }
                ]
            }
            return [
                action("Run") { [weak self] in self?.runContainerOperation(.run) },
                action("Create") { [weak self] in self?.runContainerOperation(.create) }
            ]
        case .images:
            if selected != nil {
                return [
                    action("Build") { [weak self] in self?.onBuildRequested?() },
                    action("Tag") { [weak self] in self?.runImageOperation(.tag) },
                    action("Push") { [weak self] in self?.runImageOperation(.push) }
                ]
            }
            return [
                action("Pull") { [weak self] in self?.runImageOperation(.pull) },
                action("Build") { [weak self] in self?.onBuildRequested?() }
            ]
        case .networks:
            return [action("Create") { [weak self] in self?.runNetworkOperation(.create) }]
        case .volumes:
            return [action("Create") { [weak self] in self?.runVolumeOperation(.create) }]
        case .registry:
            if selected != nil {
                return [
                    action("Login") { [weak self] in self?.runRegistryOperation(.login) },
                    action("Logout", destructive: true) { [weak self] in self?.runRegistryOperation(.logout) }
                ]
            }
            return [action("Login") { [weak self] in self?.runRegistryOperation(.login) }]
        case .machines:
            if selected != nil {
                return [
                    action("Logs") { [weak self] in self?.runMachineOperation(.logs) },
                    action("Stop") { [weak self] in self?.runMachineOperation(.stop) }
                ]
            }
            return []
        }
    }

    private func availableSecondaryActions(excluding primaryTitles: Set<String>) -> [ResourceAction] {
        let selected = selectedItem()
        let actions: [ResourceAction]
        switch kind {
        case .containers:
            var result: [ResourceAction] = [
                action("Run") { [weak self] in self?.runContainerOperation(.run) },
                action("Create") { [weak self] in self?.runContainerOperation(.create) },
                action("Prune", destructive: true) { [weak self] in self?.runContainerOperation(.prune) }
            ]
            if let selected {
                if isRunning(selected) {
                    result += [
                        action("Stop") { [weak self] in self?.runContainerOperation(.stop) },
                        action("Logs") { [weak self] in self?.runContainerOperation(.logs) },
                        action("Stats") { [weak self] in self?.runContainerOperation(.stats) },
                        action("Copy") { [weak self] in self?.runContainerOperation(.copy) },
                        action("Exec") { [weak self] in self?.runContainerOperation(.exec) },
                        action("Kill", destructive: true) { [weak self] in self?.runContainerOperation(.kill) },
                        action("Delete", destructive: true) { [weak self] in self?.runContainerOperation(.delete) }
                    ]
                } else {
                    result += [
                        action("Start") { [weak self] in self?.runContainerOperation(.start) },
                        action("Export") { [weak self] in self?.runContainerOperation(.export) },
                        action("Delete", destructive: true) { [weak self] in self?.runContainerOperation(.delete) }
                    ]
                }
            }
            actions = result
        case .images:
            var result: [ResourceAction] = [
                action("Pull") { [weak self] in self?.runImageOperation(.pull) },
                action("Build") { [weak self] in self?.onBuildRequested?() },
                action("Prune", destructive: true) { [weak self] in self?.runImageOperation(.prune) }
            ]
            if selected != nil {
                result += [
                    action("Push") { [weak self] in self?.runImageOperation(.push) },
                    action("Tag") { [weak self] in self?.runImageOperation(.tag) },
                    action("Delete", destructive: true) { [weak self] in self?.runImageOperation(.delete) }
                ]
            }
            actions = result
        case .networks:
            var result: [ResourceAction] = [
                action("Create") { [weak self] in self?.runNetworkOperation(.create) },
                action("Prune", destructive: true) { [weak self] in self?.runNetworkOperation(.prune) }
            ]
            if selected != nil {
                result.append(action("Delete", destructive: true) { [weak self] in self?.runNetworkOperation(.delete) })
            }
            actions = result
        case .volumes:
            var result: [ResourceAction] = [
                action("Create") { [weak self] in self?.runVolumeOperation(.create) },
                action("Prune", destructive: true) { [weak self] in self?.runVolumeOperation(.prune) }
            ]
            if selected != nil {
                result.append(action("Delete", destructive: true) { [weak self] in self?.runVolumeOperation(.delete) })
            }
            actions = result
        case .registry:
            actions = selected == nil ? [
                action("Login") { [weak self] in self?.runRegistryOperation(.login) }
            ] : [
                action("Login") { [weak self] in self?.runRegistryOperation(.login) },
                action("Logout", destructive: true) { [weak self] in self?.runRegistryOperation(.logout) }
            ]
        case .machines:
            actions = selected == nil ? [] : [
                action("Logs") { [weak self] in self?.runMachineOperation(.logs) },
                action("Set Default") { [weak self] in self?.runMachineOperation(.setDefault) },
                action("Stop") { [weak self] in self?.runMachineOperation(.stop) },
                action("Delete", destructive: true) { [weak self] in self?.runMachineOperation(.delete) }
            ]
        }
        return actions.filter { !primaryTitles.contains($0.title) }
    }

    private func action(_ title: String, destructive: Bool = false, run: @escaping () -> Void) -> ResourceAction {
        ResourceAction(title: title, isDestructive: destructive, run: run)
    }

    private func isRunning(_ item: ResourceListItem) -> Bool {
        let status = item.status.lowercased()
        return status.contains("running") || status == "true"
    }

    private func sortRows() {
        guard let descriptor = tableView.sortDescriptors.first else {
            return
        }
        filteredRows.sort { lhs, rhs in
            let lhsValue = value(for: descriptor.key, row: lhs)
            let rhsValue = value(for: descriptor.key, row: rhs)
            let result = lhsValue.localizedStandardCompare(rhsValue)
            return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func value(for key: String?, row: ResourceListItem) -> String {
        switch key {
        case Column.name.rawValue:
            row.title
        case Column.status.rawValue:
            row.status
        case Column.detail.rawValue:
            row.detail
        default:
            row.title
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredRows.count else {
            return nil
        }

        let item = filteredRows[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case Column.status.rawValue:
            value = item.status
        case Column.detail.rawValue:
            value = item.detail
        default:
            value = item.title
        }

        let identifier = NSUserInterfaceItemIdentifier("Cell-\(tableColumn?.identifier.rawValue ?? Column.name.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        let label: NSTextField
        if let existing = cell.textField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: AppSpacing.sm),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -AppSpacing.sm),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        label.stringValue = value
        label.font = tableColumn?.identifier.rawValue == Column.name.rawValue ? AppFonts.body : AppFonts.small
        label.textColor = tableColumn?.identifier.rawValue == Column.status.rawValue ? AppColors.muted : AppColors.ink
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel("\(tableColumn?.title ?? "Value"): \(value)")
        return cell
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    var hasSelectedContainer: Bool {
        kind == .containers && selectedItem() != nil
    }

    func startSelectedContainer() {
        guard kind == .containers else { return }
        runContainerOperation(.start)
    }

    func stopSelectedContainer() {
        guard kind == .containers else { return }
        runContainerOperation(.stop)
    }

    func showSelectedContainerLogs() {
        guard kind == .containers else { return }
        runContainerOperation(.logs)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        rebuildActions()
        let row = tableView.selectedRow
        guard row >= 0, row < filteredRows.count else {
            onInspectorUpdate(.empty)
            return
        }

        let item = filteredRows[row]
        onInspectorUpdate(
            InspectorSnapshot(
                title: item.title,
                subtitle: item.status,
                command: snapshot?.command,
                detail: item.detail,
                json: item.rawJSON
            )
        )

        guard let identifier = item.inspectIdentifier else {
            return
        }

        Task { [kind, service, weak self] in
            let inspected = await service.inspect(kind: kind, identifier: identifier)
            await MainActor.run {
                guard let self else { return }
                if let error = inspected.error {
                    self.onInspectorUpdate(
                        InspectorSnapshot(
                            title: item.title,
                            subtitle: item.status,
                            command: inspected.command ?? self.snapshot?.command,
                            detail: error,
                            json: item.rawJSON
                        )
                    )
                } else {
                    self.onInspectorUpdate(
                        InspectorSnapshot(
                            title: item.title,
                            subtitle: item.status,
                            command: inspected.command,
                            detail: item.detail,
                            json: inspected.json
                        )
                    )
                }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clickedRow = tableView.clickedRow
        if clickedRow >= 0, clickedRow < filteredRows.count, tableView.selectedRow != clickedRow {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        guard snapshot?.detection.isAvailable == true else {
            let item = NSMenuItem(title: "Install Apple container CLI to enable actions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let primary = dedupe(availablePrimaryActions())
        let actions = dedupe(primary + availableSecondaryActions(excluding: Set(primary.map(\.title))))
        guard !actions.isEmpty else {
            let item = NSMenuItem(title: "No actions available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for action in actions {
            menu.addItem(ClosureMenuItem(title: action.title, action: action.run))
        }
    }

    private func selectedItem() -> ResourceListItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredRows.count else {
            return nil
        }
        return filteredRows[row]
    }

    private func runContainerOperation(_ operation: ContainerOperation) {
        switch operation {
        case .create, .run:
            runContainerCreateOrRun(operation)
            return
        case .copy:
            runContainerCopy()
            return
        case .export:
            runContainerExport()
            return
        case .exec:
            runContainerExec()
            return
        case .start, .stop, .kill, .delete, .logs, .stats, .prune:
            break
        }

        let selected = selectedItem()
        if operation != .prune, selected == nil {
            onInspectorUpdate(
                InspectorSnapshot(
                    title: operation.rawValue,
                    subtitle: "Select a container before running this operation.",
                    command: nil,
                    detail: nil,
                    json: nil
                )
            )
            return
        }

        if operation.isDestructive, !confirm(operation: operation, target: selected?.title) {
            return
        }

        let identifier = operation == .prune ? nil : selected?.inspectIdentifier
        onInspectorUpdate(
            InspectorSnapshot(
                title: operation.rawValue,
                subtitle: "Running...",
                command: operation.arguments(identifier: identifier).map {
                    CLICommandPreview(executable: "container", arguments: $0)
                },
                detail: nil,
                json: nil
            )
        )

        let preview = operation.arguments(identifier: identifier).map {
            CLICommandPreview(executable: "container", arguments: $0)
        }
        let presenter = preview.map { streamingOutputPresenter(title: operation.rawValue, command: $0) }

        Task { [operationService, operation, identifier, presenter, weak self] in
            let outcome = await operationService.runContainerOperation(operation, identifier: identifier, outputHandler: presenter?.handler)
            await MainActor.run {
                presenter?.finish()
                self?.onInspectorUpdate(
                    InspectorSnapshot(
                        title: outcome.title,
                        subtitle: outcome.succeeded ? "Succeeded" : "Failed",
                        command: outcome.command,
                        detail: outcome.output,
                        json: operation == .stats ? ResourceJSONParser().prettyJSON(outcome.output) : nil
                    )
                )
                if operation != .logs && operation != .stats {
                    self?.loadResources()
                }
            }
        }
    }

            private func runContainerCreateOrRun(_ operation: ContainerOperation) {
                guard let request = promptForCreateRun(operation) else {
                    return
                }

                let preview = CLICommandPreview(executable: "container", arguments: request.arguments)
                let presenter = streamingOutputPresenter(title: request.operation.rawValue, command: preview)
                onInspectorUpdate(InspectorSnapshot(title: operation.rawValue, subtitle: "Running...", command: preview, detail: nil, json: nil))

                Task { [operationService, request, presenter, weak self] in
                    let outcome = await operationService.runContainerCreateOrRun(request, outputHandler: presenter.handler)
                    await MainActor.run {
                        presenter.finish()
                        self?.onInspectorUpdate(
                            InspectorSnapshot(
                                title: outcome.title,
                                subtitle: outcome.succeeded ? "Succeeded" : "Failed",
                                command: outcome.command,
                                detail: outcome.output,
                                json: nil
                            )
                        )
                        self?.loadResources()
                    }
                }
            }

            private func promptForCreateRun(_ operation: ContainerOperation) -> ContainerCreateRunRequest? {
                let alert = NSAlert()
                alert.messageText = operation == .run ? "Run container" : "Create container"
                alert.informativeText = operation == .run ? "Run uses --detach so the app does not block on the container process." : "Create prepares a container without starting it."
                alert.addButton(withTitle: operation.rawValue)
                alert.addButton(withTitle: "Cancel")

                let form = NSStackView()
                form.orientation = .vertical
                form.spacing = AppSpacing.sm
                let image = NSTextField(string: "")
                image.placeholderString = "image, e.g. ubuntu:latest"
                image.setAccessibilityLabel("Image reference")
                let name = NSTextField(string: "")
                name.placeholderString = "optional container name"
                name.setAccessibilityLabel("Container name")
                let detach = NSButton(checkboxWithTitle: "Detach (--detach)", target: nil, action: nil)
                detach.state = operation == .run ? .on : .off
                detach.isEnabled = false
                let remove = NSButton(checkboxWithTitle: "Remove after exit (--rm)", target: nil, action: nil)
                remove.isEnabled = operation == .run
                let cpus = NSTextField(string: "")
                cpus.placeholderString = "optional CPUs, e.g. 2"
                cpus.setAccessibilityLabel("CPUs")
                let memory = NSTextField(string: "")
                memory.placeholderString = "optional memory, e.g. 4G"
                memory.setAccessibilityLabel("Memory")
                let environment = NSTextField(string: "")
                environment.placeholderString = "optional env, comma-separated, e.g. KEY=value"
                environment.setAccessibilityLabel("Environment variables")
                let volumes = NSTextField(string: "")
                volumes.placeholderString = "optional volumes, comma-separated"
                volumes.setAccessibilityLabel("Volumes")
                let ports = NSTextField(string: "")
                ports.placeholderString = "optional ports, comma-separated, e.g. 8080:80"
                ports.setAccessibilityLabel("Published ports")
                let networks = NSTextField(string: "")
                networks.placeholderString = "optional networks, comma-separated"
                networks.setAccessibilityLabel("Networks")
                let platform = NSTextField(string: "")
                platform.placeholderString = "optional platform, e.g. linux/arm64"
                platform.setAccessibilityLabel("Platform")
                let command = NSTextField(string: "")
                command.placeholderString = "optional command, e.g. /bin/sh -lc 'echo hello'"
                command.setAccessibilityLabel("Container command")
                form.addArrangedSubview(image)
                form.addArrangedSubview(name)
                form.addArrangedSubview(detach)
                form.addArrangedSubview(remove)
                form.addArrangedSubview(cpus)
                form.addArrangedSubview(memory)
                form.addArrangedSubview(environment)
                form.addArrangedSubview(volumes)
                form.addArrangedSubview(ports)
                form.addArrangedSubview(networks)
                form.addArrangedSubview(platform)
                form.addArrangedSubview(command)
                form.frame = NSRect(x: 0, y: 0, width: 460, height: 310)
                alert.accessoryView = form

                guard alert.runModal() == .alertFirstButtonReturn else {
                    return nil
                }

                return ContainerCreateRunRequest(
                    operation: operation,
                    image: image.stringValue,
                    name: name.stringValue,
                    detach: detach.state == .on,
                    remove: remove.state == .on,
                    cpus: cpus.stringValue,
                    memory: memory.stringValue,
                    environment: environment.stringValue,
                    volumes: volumes.stringValue,
                    ports: ports.stringValue,
                    networks: networks.stringValue,
                    platform: platform.stringValue,
                    command: command.stringValue
                )
            }

            private func runContainerCopy() {
                guard let selected = selectedItem() else {
                    onInspectorUpdate(InspectorSnapshot(title: "Copy", subtitle: "Select a running container first.", command: nil, detail: nil, json: nil))
                    return
                }
                guard selected.status.localizedCaseInsensitiveContains("running") else {
                    onInspectorUpdate(InspectorSnapshot(title: "Copy", subtitle: "Copy requires a running container.", command: nil, detail: "Selected status: \(selected.status)", json: nil))
                    return
                }
                guard let request = promptForCopy(selected: selected) else {
                    return
                }

                let preview = CLICommandPreview(executable: "container", arguments: request.arguments)
                let presenter = streamingOutputPresenter(title: "Copy", command: preview)
                runOutcome(
                    title: "Copy",
                    preview: preview,
                    streamingPresenter: presenter
                ) { [operationService, presenter] in
                    await operationService.runContainerCopy(request, outputHandler: presenter.handler)
                }
            }

            private func promptForCopy(selected: ResourceListItem) -> ContainerCopyRequest? {
                let alert = NSAlert()
                alert.messageText = "Copy files"
                alert.informativeText = "Use container:path for one side and a local path for the other side."
                alert.addButton(withTitle: "Copy")
                alert.addButton(withTitle: "Cancel")

                let form = NSStackView()
                form.orientation = .vertical
                form.spacing = AppSpacing.sm
                let source = NSTextField(string: "\(selected.inspectIdentifier ?? selected.title):/path/in/container")
                source.setAccessibilityLabel("Copy source")
                let destination = NSTextField(string: "\(NSHomeDirectory())/Downloads")
                destination.setAccessibilityLabel("Copy destination")
                form.addArrangedSubview(source)
                form.addArrangedSubview(destination)
                form.frame = NSRect(x: 0, y: 0, width: 440, height: 56)
                alert.accessoryView = form

                guard alert.runModal() == .alertFirstButtonReturn else {
                    return nil
                }
                return ContainerCopyRequest(source: source.stringValue, destination: destination.stringValue)
            }

            private func runContainerExport() {
                guard let selected = selectedItem(), let identifier = selected.inspectIdentifier else {
                    onInspectorUpdate(InspectorSnapshot(title: "Export", subtitle: "Select a container first.", command: nil, detail: nil, json: nil))
                    return
                }
                guard selected.status.localizedCaseInsensitiveContains("stopped") else {
                    onInspectorUpdate(InspectorSnapshot(title: "Export", subtitle: "Export requires a stopped container.", command: nil, detail: "Selected status: \(selected.status)", json: nil))
                    return
                }
                let output = promptForText(title: "Export output path", placeholder: "\(NSHomeDirectory())/Downloads/\(identifier).tar") ?? ""
                if output.isEmpty {
                    return
                }
                let request = ContainerExportRequest(identifier: identifier, outputPath: output)
                let preview = CLICommandPreview(executable: "container", arguments: request.arguments)
                let presenter = streamingOutputPresenter(title: "Export", command: preview)
                runOutcome(
                    title: "Export",
                    preview: preview,
                    streamingPresenter: presenter
                ) { [operationService, presenter] in
                    await operationService.runContainerExport(request, outputHandler: presenter.handler)
                }
            }

            private func runContainerExec() {
                guard let selected = selectedItem(), let identifier = selected.inspectIdentifier else {
                    onInspectorUpdate(InspectorSnapshot(title: "Exec", subtitle: "Select a container first.", command: nil, detail: nil, json: nil))
                    return
                }
                guard selected.status.localizedCaseInsensitiveContains("running") else {
                    onInspectorUpdate(InspectorSnapshot(title: "Exec", subtitle: "Exec requires a running container.", command: nil, detail: "Selected status: \(selected.status)", json: nil))
                    return
                }
                let command = promptForText(title: "Exec command", placeholder: "/bin/sh") ?? ""
                let request = ContainerExecRequest(identifier: identifier, command: command.isEmpty ? "/bin/sh" : command)
                runOutcome(
                    title: "Exec",
                    preview: CLICommandPreview(executable: "container", arguments: request.arguments)
                ) { [operationService] in
                    await operationService.openExecInTerminal(request)
                }
            }

            private func runOutcome(
                title: String,
                preview: CLICommandPreview,
                streamingPresenter: InspectorStreamingPresenter? = nil,
                operation: @escaping () async -> OperationOutcome
            ) {
                onInspectorUpdate(InspectorSnapshot(title: title, subtitle: "Running...", command: preview, detail: nil, json: nil))
                Task { [operation, streamingPresenter, weak self] in
                    let outcome = await operation()
                    await MainActor.run {
                        streamingPresenter?.finish()
                        self?.onInspectorUpdate(
                            InspectorSnapshot(
                                title: outcome.title,
                                subtitle: outcome.succeeded ? "Succeeded" : "Failed",
                                command: outcome.command,
                                detail: outcome.output,
                                json: nil
                            )
                        )
                        if title != "Exec" {
                            self?.loadResources()
                        }
                    }
                }
            }

    private func confirm(operation: ContainerOperation, target: String?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(operation.rawValue) \(target ?? "stopped containers")?"
        alert.informativeText = "This operation may be destructive. The command and result will be recorded locally in operation history."
        alert.alertStyle = .warning
        alert.addButton(withTitle: operation.rawValue)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func runImageOperation(_ operation: ImageOperation) {
        let selected = selectedItem()
        if operation != .pull && operation != .prune && selected == nil {
            onInspectorUpdate(
                InspectorSnapshot(
                    title: operation.rawValue,
                    subtitle: "Select an image before running this operation.",
                    command: nil,
                    detail: nil,
                    json: nil
                )
            )
            return
        }

        let input: String?
        if operation.requiresInput {
            input = promptForInput(operation)
            if input?.isEmpty != false {
                return
            }
        } else {
            input = nil
        }

        if operation.isDestructive, !confirm(operation: operation, target: selected?.title) {
            return
        }

        let identifier = operation == .pull || operation == .prune ? nil : selected?.inspectIdentifier
        onInspectorUpdate(
            InspectorSnapshot(
                title: operation.rawValue,
                subtitle: "Running...",
                command: operation.arguments(identifier: identifier, input: input).map {
                    CLICommandPreview(executable: "container", arguments: $0)
                },
                detail: nil,
                json: nil
            )
        )

        let preview = operation.arguments(identifier: identifier, input: input).map {
            CLICommandPreview(executable: "container", arguments: $0)
        }
        let presenter = preview.map { streamingOutputPresenter(title: operation.rawValue, command: $0) }

        Task { [operationService, operation, identifier, input, presenter, weak self] in
            let outcome = await operationService.runImageOperation(operation, identifier: identifier, input: input, outputHandler: presenter?.handler)
            await MainActor.run {
                presenter?.finish()
                self?.onInspectorUpdate(
                    InspectorSnapshot(
                        title: outcome.title,
                        subtitle: outcome.succeeded ? "Succeeded" : "Failed",
                        command: outcome.command,
                        detail: outcome.output,
                        json: nil
                    )
                )
                self?.loadResources()
            }
        }
    }

    private func promptForInput(_ operation: ImageOperation) -> String? {
        let alert = NSAlert()
        alert.messageText = operation == .pull ? "Image reference to pull" : "New image reference"
        alert.informativeText = operation == .pull ? "Enter an image reference, for example ubuntu:latest." : "Enter the new tag/reference for the selected image."
        alert.addButton(withTitle: operation.rawValue)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = operation == .pull ? "ubuntu:latest" : "example/app:latest"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirm(operation: ImageOperation, target: String?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(operation.rawValue) \(target ?? "unused images")?"
        alert.informativeText = "This operation may be destructive. The command and result will be recorded locally in operation history."
        alert.alertStyle = .warning
        alert.addButton(withTitle: operation.rawValue)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func runNetworkOperation(_ operation: NetworkOperation) {
        runNamedResourceOperation(
            title: "Network \(operation.rawValue)",
            isDestructive: operation.isDestructive,
            requiresInput: operation == .create,
            inputPrompt: "Network name",
            operationTitle: operation.rawValue,
            arguments: { selected, input in operation.arguments(identifier: operation == .prune ? nil : selected?.inspectIdentifier, input: input) },
            runner: { [operationService] selected, input, streamHandler in
                await operationService.runNetworkOperation(operation, identifier: operation == .prune ? nil : selected?.inspectIdentifier, input: input, outputHandler: streamHandler)
            }
        )
    }

    private func runVolumeOperation(_ operation: VolumeOperation) {
        runNamedResourceOperation(
            title: "Volume \(operation.rawValue)",
            isDestructive: operation.isDestructive,
            requiresInput: operation == .create,
            inputPrompt: "Volume name",
            operationTitle: operation.rawValue,
            arguments: { selected, input in operation.arguments(identifier: operation == .prune ? nil : selected?.inspectIdentifier, input: input) },
            runner: { [operationService] selected, input, streamHandler in
                await operationService.runVolumeOperation(operation, identifier: operation == .prune ? nil : selected?.inspectIdentifier, input: input, outputHandler: streamHandler)
            }
        )
    }

    private func runMachineOperation(_ operation: MachineOperation) {
        runNamedResourceOperation(
            title: "Machine \(operation.rawValue)",
            isDestructive: operation.isDestructive,
            requiresInput: false,
            inputPrompt: nil,
            operationTitle: operation.rawValue,
            arguments: { selected, _ in operation.arguments(identifier: selected?.inspectIdentifier) },
            runner: { [operationService] selected, _, streamHandler in
                await operationService.runMachineOperation(operation, identifier: selected?.inspectIdentifier, outputHandler: streamHandler)
            }
        )
    }

    private func runNamedResourceOperation(
        title: String,
        isDestructive: Bool,
        requiresInput: Bool,
        inputPrompt: String?,
        operationTitle: String,
        arguments: (ResourceListItem?, String?) -> [String]?,
        runner: @escaping (ResourceListItem?, String?, ProcessOutputHandler?) async -> OperationOutcome
    ) {
        let selected = selectedItem()
        if !requiresInput, arguments(selected, nil) == nil {
            onInspectorUpdate(InspectorSnapshot(title: title, subtitle: "Select a resource first.", command: nil, detail: nil, json: nil))
            return
        }

        let input = requiresInput ? promptForText(title: inputPrompt ?? operationTitle, placeholder: "") : nil
        if requiresInput, input?.isEmpty != false {
            return
        }

        if isDestructive, !confirmDestructive(title: operationTitle, target: selected?.title) {
            return
        }

        onInspectorUpdate(
            InspectorSnapshot(
                title: title,
                subtitle: "Running...",
                command: arguments(selected, input).map { CLICommandPreview(executable: "container", arguments: $0) },
                detail: nil,
                json: nil
            )
        )

        let preview = arguments(selected, input).map { CLICommandPreview(executable: "container", arguments: $0) }
        let presenter = preview.map { streamingOutputPresenter(title: title, command: $0) }

        Task { [runner, selected, input, presenter, weak self] in
            let outcome = await runner(selected, input, presenter?.handler)
            await MainActor.run {
                presenter?.finish()
                self?.onInspectorUpdate(
                    InspectorSnapshot(
                        title: outcome.title,
                        subtitle: outcome.succeeded ? "Succeeded" : "Failed",
                        command: outcome.command,
                        detail: outcome.output,
                        json: nil
                    )
                )
                self?.loadResources()
            }
        }
    }

    private func runRegistryOperation(_ operation: RegistryOperation) {
        switch operation {
        case .login:
            guard let request = promptForRegistryLogin() else {
                return
            }
            onInspectorUpdate(
                InspectorSnapshot(
                    title: "Registry Login",
                    subtitle: "Running...",
                    command: CLICommandPreview(
                        executable: "container",
                        arguments: ["registry", "login", request.registry, "--username", request.username, "--password-stdin"]
                    ),
                    detail: nil,
                    json: nil
                )
            )
            Task { [operationService, request, weak self] in
                let outcome = await operationService.runRegistryLogin(request)
                await MainActor.run {
                    self?.onInspectorUpdate(
                        InspectorSnapshot(
                            title: outcome.title,
                            subtitle: outcome.succeeded ? "Succeeded" : "Failed",
                            command: outcome.command,
                            detail: outcome.output,
                            json: nil
                        )
                    )
                    self?.loadResources()
                }
            }
        case .logout:
            let selected = selectedItem()
            if !confirmDestructive(title: "Logout", target: selected?.title) {
                return
            }
            Task { [operationService, selected, weak self] in
                let outcome = await operationService.runRegistryLogout(identifier: selected?.inspectIdentifier)
                await MainActor.run {
                    self?.onInspectorUpdate(
                        InspectorSnapshot(
                            title: outcome.title,
                            subtitle: outcome.succeeded ? "Succeeded" : "Failed",
                            command: outcome.command,
                            detail: outcome.output,
                            json: nil
                        )
                    )
                    self?.loadResources()
                }
            }
        }
    }

    private func promptForText(title: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = placeholder
        field.setAccessibilityLabel(title)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func promptForRegistryLogin() -> RegistryLoginRequest? {
        let alert = NSAlert()
        alert.messageText = "Registry login"
        alert.informativeText = "The password is passed to the container CLI via stdin and is not displayed in the command preview."
        alert.addButton(withTitle: "Login")
        alert.addButton(withTitle: "Cancel")

        let form = NSStackView()
        form.orientation = .vertical
        form.spacing = AppSpacing.sm
        let registry = NSTextField(string: "")
        registry.placeholderString = "ghcr.io"
        registry.setAccessibilityLabel("Registry server")
        let username = NSTextField(string: "")
        username.placeholderString = "username"
        username.setAccessibilityLabel("Registry username")
        let password = NSSecureTextField(string: "")
        password.placeholderString = "password"
        password.setAccessibilityLabel("Registry password")
        form.addArrangedSubview(registry)
        form.addArrangedSubview(username)
        form.addArrangedSubview(password)
        form.frame = NSRect(x: 0, y: 0, width: 360, height: 88)
        alert.accessoryView = form

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return RegistryLoginRequest(
            registry: registry.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password.stringValue
        )
    }

    private func confirmDestructive(title: String, target: String?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(title) \(target ?? "selected resources")?"
        alert.informativeText = "This operation may be destructive. The command and result will be recorded locally in operation history."
        alert.alertStyle = .warning
        alert.addButton(withTitle: title)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortRows()
        tableView.reloadData()
    }

    private func streamingOutputPresenter(title: String, command: CLICommandPreview) -> InspectorStreamingPresenter {
        InspectorStreamingPresenter(title: title, command: command, onInspectorUpdate: onInspectorUpdate)
    }

    private func accessibilityHelp(for operation: ContainerOperation) -> String {
        switch operation {
        case .start:
            "Starts the selected container. Shortcut: Command-Return."
        case .stop:
            "Stops the selected container. Shortcut: Option-Command-S."
        case .logs:
            "Shows recent logs for the selected container. Shortcut: Command-L."
        case .delete, .kill, .prune:
            "Destructive container operation. Confirmation is required."
        case .create, .run, .copy, .export, .exec, .stats:
            "\(operation.rawValue) container operation."
        }
    }
}
