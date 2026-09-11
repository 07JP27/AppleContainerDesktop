import AppKit

final class ResourceListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate, SearchFocusHandling, ContainerShortcutHandling, ContentReloading {
    private enum ControlColumn {
        static let selection = NSUserInterfaceItemIdentifier("container-selection")
        static let actions = NSUserInterfaceItemIdentifier("container-actions")
    }

    private struct ResourceAction {
        var title: String
        var isDestructive: Bool
        var isEnabled = true
        var accessibilityHelp: String? = nil
        var run: () -> Void
    }

    private typealias Column = ResourceListColumn

    private let kind: ResourceKind
    private let service: ResourceService
    private let operationService: OperationService
    private let openURL: @MainActor (URL) -> Void
    private let inspectorUpdateHandler: @MainActor (InspectorSnapshot) -> Void
    private let onRuntimeStatusRequested: (@MainActor () -> Void)?
    private let onBuildRequested: (@MainActor () -> Void)?
    private let batchDeleteConfirmation: (@MainActor ([ResourceListItem], Bool) -> Bool)?

    private let stack = NSStackView()
    private let tableToolbarRow = NSStackView()
    private let actionRow = NSStackView()
    private let tableCard = CardView(spacing: AppSpacing.md)
    private let tableScrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let tableView = ResourceTableView()
    private let statusLabel = NSTextField.label("", color: AppColors.muted)
    private var tableHeightConstraint: NSLayoutConstraint?
    private var tableStateView: NSView?
    private var snapshot: ResourceListSnapshot?
    private var rows: [ResourceListItem] = []
    private var filteredRows: [ResourceListItem] = []
    private var loadGeneration = 0
    private var inspectionGeneration = 0
    private var inspectionTask: Task<Void, Never>?
    private var isApplyingRows = false
    private var isInspectingSelection = true
    private(set) var launchController: ContainerLaunchViewController?
    private var launchIdentifier: UUID?
    private(set) var detailViewController: ResourceDetailViewController?
    private var detailItemID: String?
    private var isSizingColumns = false
    private(set) var checkedContainerIDs = Set<String>()
    private(set) var isBatchRunning = false
    private var batchGeneration = 0

    init(
        kind: ResourceKind,
        service: ResourceService = ResourceService(),
        operationService: OperationService = OperationService(),
        openURL: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        onInspectorUpdate: @escaping @MainActor (InspectorSnapshot) -> Void,
        onRuntimeStatusRequested: (@MainActor () -> Void)? = nil,
        onBuildRequested: (@MainActor () -> Void)? = nil,
        batchDeleteConfirmation: (@MainActor ([ResourceListItem], Bool) -> Bool)? = nil
    ) {
        self.kind = kind
        self.service = service
        self.operationService = operationService
        self.openURL = openURL
        self.inspectorUpdateHandler = onInspectorUpdate
        self.onRuntimeStatusRequested = onRuntimeStatusRequested
        self.onBuildRequested = onBuildRequested
        self.batchDeleteConfirmation = batchDeleteConfirmation
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

    override func viewDidLayout() {
        super.viewDidLayout()
        fitResourceColumns()
    }

    func reloadContent() {
        guard !isBatchRunning else { return }
        if detailViewController != nil {
            refreshVisibleDetail()
            return
        }
        isInspectingSelection = true
        invalidateInspection()
        loadResources()
    }

    func suspendInspection() {
        showCollection(restoreFocus: false)
        isInspectingSelection = false
        invalidateInspection()
        loadGeneration += 1
    }

    func showCollection(restoreFocus: Bool = true) {
        guard kind.usesDedicatedDetail else { return }
        invalidateInspection()
        detailItemID = nil
        detailViewController?.view.removeFromSuperview()
        detailViewController?.removeFromParent()
        detailViewController = nil
        stack.isHidden = false
        onInspectorUpdate(.empty)
        guard restoreFocus, let window = view.window else { return }
        window.makeFirstResponder(tableView)
        if tableView.selectedRow >= 0 {
            tableView.scrollRowToVisible(tableView.selectedRow)
        }
    }

    func restorePrimaryFocus() {
        guard let window = view.window else { return }
        if let detailViewController {
            window.makeFirstResponder(detailViewController.backButton)
        } else {
            window.makeFirstResponder(tableView)
        }
    }

    private func invalidateInspection() {
        inspectionGeneration += 1
        inspectionTask?.cancel()
        inspectionTask = nil
    }

    private func onInspectorUpdate(_ snapshot: InspectorSnapshot) {
        if snapshot.overview == nil, snapshot.title != InspectorSnapshot.empty.title {
            isInspectingSelection = false
            invalidateInspection()
            detailViewController?.setRefreshing(false)
        }
        inspectorUpdateHandler(snapshot)
    }

    private func buildLayout() {
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = AppSpacing.lg
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = AppSpacing.xs
        header.setContentHuggingPriority(.required, for: .vertical)
        header.setContentCompressionResistancePriority(.required, for: .vertical)

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = AppSpacing.xs
        titleStack.setContentHuggingPriority(.required, for: .vertical)
        titleStack.setContentCompressionResistancePriority(.required, for: .vertical)
        titleStack.addArrangedSubview(PageHeaderView(title: kind.rawValue, subtitle: pageSubtitle))
        titleStack.addArrangedSubview(statusLabel)
        header.addArrangedSubview(titleStack)

        searchField.placeholderString = "Search \(kind.rawValue.lowercased())"
        searchField.setAccessibilityLabel("Search \(kind.rawValue.lowercased())")
        let searchableColumns = Column.columns(for: kind).map(\.title).joined(separator: ", ")
        searchField.setAccessibilityHelp("Search \(searchableColumns) and resource metadata.")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.controlSize = .regular
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let preferredSearchWidth = searchField.widthAnchor.constraint(equalToConstant: 220)
        preferredSearchWidth.priority = .defaultHigh
        preferredSearchWidth.isActive = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        searchField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        searchField.setContentHuggingPriority(.required, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.required, for: .horizontal)

        tableToolbarRow.orientation = .horizontal
        tableToolbarRow.alignment = .centerY
        tableToolbarRow.spacing = AppSpacing.md

        let toolbarSpacer = NSView()
        toolbarSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbarSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionRow.orientation = .horizontal
        actionRow.spacing = 6
        actionRow.alignment = .centerY
        actionRow.setContentHuggingPriority(.required, for: .horizontal)
        actionRow.setContentCompressionResistancePriority(.required, for: .horizontal)

        tableToolbarRow.addArrangedSubview(actionRow)
        tableToolbarRow.addArrangedSubview(toolbarSpacer)
        tableToolbarRow.addArrangedSubview(searchField)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = kind == .containers
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 34
        if kind == .containers {
            let header = ContainerSelectionHeaderView()
            header.onToggleAll = { [weak self] selected in
                self?.setAllVisibleContainersChecked(selected)
            }
            tableView.headerView = header
        } else {
            tableView.headerView = NSTableHeaderView()
        }
        tableView.backgroundColor = AppColors.surface
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu
        tableView.setAccessibilityLabel("\(kind.rawValue) table")
        tableView.setAccessibilityHelp(
            kind.usesDedicatedDetail
                ? "Use arrow keys to select rows. Click a row or press Return to open its details."
                : "Use arrow keys to select rows. The inspector updates with details for the selected row."
        )
        if kind.usesDedicatedDetail {
            tableView.target = self
            if kind == .containers {
                tableView.doubleAction = #selector(containerRowDoubleActivated)
                tableView.onToggleFocusedSelection = { [weak self] in
                    self?.toggleFocusedContainerSelection()
                }
                tableView.onSelectAllVisible = { [weak self] in
                    self?.setAllVisibleContainersChecked(true)
                }
            } else {
                tableView.action = #selector(tableRowActivated)
            }
            tableView.onReturn = { [weak self] in self?.openSelectedResourceDetails() }
        }

        if kind == .containers {
            addControlColumn(identifier: ControlColumn.selection, title: "", width: 34)
        }
        for column in Column.columns(for: kind) {
            let width = kind == .containers || kind == .images
                ? CGFloat(column.width)
                : column == .name ? 220 : column == .status ? 110 : 360
            addColumn(column, title: column.title, width: width)
        }
        if kind == .containers {
            addControlColumn(identifier: ControlColumn.actions, title: "Actions", width: 96)
        }
        if kind == .containers || kind == .images {
            tableView.columnAutoresizingStyle = .noColumnAutoresizing
        }
        statusLabel.maximumNumberOfLines = 0
        statusLabel.cell?.wraps = true

        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = true
        tableScrollView.drawsBackground = false
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false

        tableCard.stack.addArrangedSubview(tableToolbarRow)
        tableCard.stack.addArrangedSubview(tableScrollView)
        tableToolbarRow.widthAnchor.constraint(equalTo: tableCard.stack.widthAnchor).isActive = true

        stack.addFullWidthArrangedSubview(header)
        stack.addFullWidthArrangedSubview(tableCard)
        stack.setCustomSpacing(AppSpacing.md, after: header)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: AppSpacing.xxl),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -AppSpacing.xxl),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: AppSpacing.xxl),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -AppSpacing.xxl),
            tableScrollView.widthAnchor.constraint(equalTo: tableCard.stack.widthAnchor)
        ])
        tableHeightConstraint = tableScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        tableHeightConstraint?.priority = .defaultHigh
        tableHeightConstraint?.isActive = true
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
        if kind == .containers || kind == .images {
            tableColumn.minWidth = column == .name ? 120 : 75
        }
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
        tableView.addTableColumn(tableColumn)
    }

    private func addControlColumn(identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat) {
        let tableColumn = NSTableColumn(identifier: identifier)
        tableColumn.title = title
        tableColumn.width = width
        tableColumn.minWidth = width
        tableColumn.maxWidth = width
        tableColumn.resizingMask = []
        tableView.addTableColumn(tableColumn)
    }

    private func fitResourceColumns() {
        guard !isSizingColumns, kind == .containers || kind == .images,
              !tableScrollView.isHidden, tableScrollView.contentView.bounds.width > 0 else { return }
        let definitions = Column.columns(for: kind)
        let dataColumns = tableView.tableColumns.filter { Column(rawValue: $0.identifier.rawValue) != nil }
        guard definitions.count == dataColumns.count else { return }
        let controlWidth = tableView.tableColumns
            .filter { Column(rawValue: $0.identifier.rawValue) == nil }
            .reduce(CGFloat.zero) { $0 + $1.width }
        let allSpacing = tableView.intercellSpacing.width * CGFloat(max(0, tableView.tableColumns.count - 1))
        let available = max(0, tableScrollView.contentView.bounds.width - controlWidth - allSpacing)
        let preferred = definitions.map { CGFloat($0.width) }
        let minimum = definitions.map { $0 == .name ? CGFloat(120) : CGFloat(75) }
        let preferredTotal = preferred.reduce(0, +)
        let minimumTotal = minimum.reduce(0, +)
        let widths: [CGFloat]
        if available >= preferredTotal {
            widths = preferred
        } else if available > minimumTotal {
            let ratio = (available - minimumTotal) / (preferredTotal - minimumTotal)
            widths = zip(preferred, minimum).map { desired, floor in
                floor + (desired - floor) * ratio
            }
        } else {
            widths = minimum
        }
        guard zip(dataColumns, widths).contains(where: { abs($0.width - $1) > 0.5 }) else { return }
        isSizingColumns = true
        for (column, width) in zip(dataColumns, widths) {
            column.width = width
        }
        isSizingColumns = false
    }

    private func loadResources() {
        loadGeneration += 1
        let generation = loadGeneration
        statusLabel.isHidden = false
        statusLabel.stringValue = "Loading \(kind.rawValue.lowercased())..."
        Task { [kind, service, weak self] in
            guard self?.loadGeneration == generation else { return }
            let snapshot = await service.load(kind: kind)
            await MainActor.run {
                guard self?.loadGeneration == generation else { return }
                self?.render(snapshot)
            }
        }
    }

    private func render(_ snapshot: ResourceListSnapshot) {
        self.snapshot = snapshot
        rows = snapshot.items
        applyFilter(refreshInspector: true)

        if !snapshot.detection.isAvailable {
            statusLabel.isHidden = true
            showTableState(
                title: "Install Apple container to view \(snapshot.kind.rawValue.lowercased())",
                message: "Install Apple's signed container CLI, then choose View > Refresh or press Command-R. The app will not show fake resources or enable actions until the executable is detected.",
                actionTitle: "Download installer..."
            ) {
                if let url = URL(string: "https://github.com/apple/container/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
            onInspectorUpdate(.empty)
        } else if let errorMessage = snapshot.errorMessage {
            let detail = snapshot.errorDetail.map { "\n\($0)" } ?? ""
            statusLabel.isHidden = false
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
            statusLabel.isHidden = true
            showTableState(title: "No \(snapshot.kind.rawValue.lowercased())", message: snapshot.kind.emptyMessage)
            onInspectorUpdate(.empty)
        } else {
            statusLabel.isHidden = false
            updateListStatus()
            showTable()
        }
    }

    @objc private func searchChanged() {
        isInspectingSelection = !kind.usesDedicatedDetail
        applyFilter()
    }

    private func applyFilter(refreshInspector: Bool = false) {
        let selectedID = detailItemID ?? focusedItem()?.id
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredRows = rows
        } else {
            filteredRows = rows.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
        }
        sortRows()
        if kind == .containers {
            checkedContainerIDs.formIntersection(Set(filteredRows.map(\.id)))
        }
        isApplyingRows = true
        tableView.reloadData()
        if kind == .containers {
            synchronizeContainerTableSelection()
        } else {
            let selectedIndex = filteredRows.firstIndex { $0.id == selectedID }
            let fallbackIndex = detailItemID == nil && !filteredRows.isEmpty ? 0 : nil
            if let index = selectedIndex ?? fallbackIndex {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        }
        isApplyingRows = false
        updateContainerSelectionHeader()
        updateListStatus()
        rebuildActions()
        if let detailItemID {
            updateVisibleDetailFromList(id: detailItemID, refreshInspection: refreshInspector)
        } else if !kind.usesDedicatedDetail, isInspectingSelection,
                  refreshInspector || selectedID != focusedItem()?.id {
            presentSelectedResource()
        }
    }

    private func updateListStatus() {
        let count = filteredRows.isEmpty && !rows.isEmpty
            ? "No matching \(kind.rawValue.lowercased())."
            : filteredRows.count == rows.count ? "\(rows.count) item(s)" : "\(filteredRows.count) of \(rows.count) item(s)"
        statusLabel.stringValue = [count, snapshot?.warningMessage].compactMap { $0 }.joined(separator: "\n")
    }

    private func showTable() {
        if let tableStateView {
            tableCard.stack.removeArrangedSubview(tableStateView)
            tableStateView.removeFromSuperview()
        }
        tableStateView = nil
        tableHeightConstraint?.isActive = true
        tableScrollView.isHidden = false
        fitResourceColumns()
    }

    private func showTableState(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        if let tableStateView {
            tableCard.stack.removeArrangedSubview(tableStateView)
            tableStateView.removeFromSuperview()
        }
        tableHeightConstraint?.isActive = false
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

        tableCard.stack.insertArrangedSubview(state, at: min(1, tableCard.stack.arrangedSubviews.count))
        state.widthAnchor.constraint(equalTo: tableCard.stack.widthAnchor).isActive = true
        tableStateView = state
    }

    private func rebuildActions() {
        actionRow.setViews([], in: .leading)
        actionRow.isHidden = false
        guard snapshot?.detection.isAvailable == true else {
            actionRow.isHidden = true
            return
        }
        if kind == .containers, !checkedContainerIDs.isEmpty {
            rebuildContainerSelectionActions()
            return
        }

        let rawPrimaryActions = dedupe(kind.usesDedicatedDetail ? collectionPrimaryActions() : availablePrimaryActions())
        let primaryActions = rawPrimaryActions.filter { !$0.isDestructive }
        for action in primaryActions {
            actionRow.addArrangedSubview(toolbarButton(for: action))
        }

        let secondaryActions = dedupe(
            rawPrimaryActions.filter(\.isDestructive)
                + (kind.usesDedicatedDetail
                    ? collectionSecondaryActions(excluding: Set(primaryActions.map(\.title)))
                    : availableSecondaryActions(excluding: Set(primaryActions.map(\.title))))
        )
        if !secondaryActions.isEmpty {
            actionRow.addArrangedSubview(moreActionsButton(for: secondaryActions))
        }

        if actionRow.arrangedSubviews.isEmpty {
            actionRow.isHidden = true
        }
    }

    private func toolbarButton(for action: ResourceAction) -> ToolbarActionButton {
        let button = ToolbarActionButton(title: action.title) { _ in
            action.run()
        }
        button.isEnabled = action.isEnabled
        if let help = action.accessibilityHelp {
            button.setAccessibilityHelp(help)
        }
        return button
    }

    private func moreActionsButton(for actions: [ResourceAction]) -> ToolbarActionButton {
        ToolbarActionButton(title: "More", showsMenuIndicator: true) { button in
            let menu = NSMenu()
            actions.forEach { action in
                let item = ClosureMenuItem(title: action.title, action: action.run)
                if action.isDestructive {
                    item.attributedTitle = NSAttributedString(
                        string: action.title,
                        attributes: [.foregroundColor: AppColors.danger]
                    )
                }
                item.isEnabled = action.isEnabled
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    private func rebuildContainerSelectionActions() {
        let selected = selectedContainerItems
        let running = selected.filter(isRunning)
        let stopped = selected.filter { !isRunning($0) }
        let countLabel = NSTextField.label(
            "\(selected.count) selected",
            font: AppFonts.body,
            color: AppColors.muted
        )
        countLabel.setAccessibilityLabel("\(selected.count) containers selected")
        actionRow.addArrangedSubview(countLabel)

        let start = ResourceAction(
            title: "Start",
            isDestructive: false,
            isEnabled: !isBatchRunning && !stopped.isEmpty,
            accessibilityHelp: stopped.isEmpty
                ? "No selected stopped containers can be started."
                : "Starts \(stopped.count) selected stopped container(s)."
        ) { [weak self] in
            self?.runCheckedContainerBatch(.start)
        }
        let stop = ResourceAction(
            title: "Stop",
            isDestructive: false,
            isEnabled: !isBatchRunning && !running.isEmpty,
            accessibilityHelp: running.isEmpty
                ? "No selected running containers can be stopped."
                : "Stops \(running.count) selected running container(s)."
        ) { [weak self] in
            self?.runCheckedContainerBatch(.stop)
        }
        actionRow.addArrangedSubview(toolbarButton(for: start))
        actionRow.addArrangedSubview(toolbarButton(for: stop))
        actionRow.addArrangedSubview(selectionToolbarButton(
            title: "Delete",
            isDestructive: true,
            isEnabled: !isBatchRunning
        ) { [weak self] in
            self?.runCheckedContainerBatch(.delete)
        })
        actionRow.addArrangedSubview(selectionToolbarButton(
            title: "Clear",
            isDestructive: false,
            isEnabled: !isBatchRunning
        ) { [weak self] in
            self?.setAllVisibleContainersChecked(false)
        })
    }

    private func selectionToolbarButton(
        title: String,
        isDestructive: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.font = AppFonts.body
        if isDestructive {
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: AppColors.danger]
            )
        }
        button.isEnabled = isEnabled
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
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
                    action("Run") { [weak self] in self?.runSelectedImage() },
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
                    action("Run") { [weak self] in self?.runSelectedImage() },
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

    private func action(
        _ title: String,
        destructive: Bool = false,
        isEnabled: Bool = true,
        accessibilityHelp: String? = nil,
        run: @escaping () -> Void
    ) -> ResourceAction {
        ResourceAction(
            title: title,
            isDestructive: destructive,
            isEnabled: isEnabled,
            accessibilityHelp: accessibilityHelp,
            run: run
        )
    }

    private func isRunning(_ item: ResourceListItem) -> Bool {
        if let container = item.container { return container.isRunning }
        let status = item.status.lowercased()
        return status.contains("running") || status == "true"
    }

    private var selectedContainerItems: [ResourceListItem] {
        filteredRows.filter { checkedContainerIDs.contains($0.id) }
    }

    private func setContainerChecked(_ id: String, selected: Bool) {
        guard kind == .containers, !isBatchRunning,
              let row = filteredRows.firstIndex(where: { $0.id == id }) else { return }
        if selected {
            checkedContainerIDs.insert(id)
        } else {
            checkedContainerIDs.remove(id)
        }
        isApplyingRows = true
        if selected {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
        } else {
            tableView.deselectRow(row)
        }
        isApplyingRows = false
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        updateContainerSelectionHeader()
        rebuildActions()
    }

    private func setAllVisibleContainersChecked(_ selected: Bool) {
        guard kind == .containers, !isBatchRunning else { return }
        checkedContainerIDs = selected ? Set(filteredRows.map(\.id)) : []
        isApplyingRows = true
        synchronizeContainerTableSelection()
        isApplyingRows = false
        tableView.reloadData()
        updateContainerSelectionHeader()
        rebuildActions()
    }

    private func toggleFocusedContainerSelection() {
        guard kind == .containers, !isBatchRunning else { return }
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : tableView.clickedRow
        guard filteredRows.indices.contains(row) else { return }
        let id = filteredRows[row].id
        setContainerChecked(id, selected: !checkedContainerIDs.contains(id))
    }

    private func synchronizeContainerTableSelection() {
        let indexes = IndexSet(filteredRows.indices.filter { checkedContainerIDs.contains(filteredRows[$0].id) })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func updateContainerSelectionHeader() {
        guard kind == .containers,
              let header = tableView.headerView as? ContainerSelectionHeaderView else { return }
        let visibleIDs = Set(filteredRows.map(\.id))
        let selectedCount = checkedContainerIDs.intersection(visibleIDs).count
        let state: NSControl.StateValue
        if selectedCount == 0 {
            state = .off
        } else if selectedCount == visibleIDs.count {
            state = .on
        } else {
            state = .mixed
        }
        header.update(state: state, isEnabled: !isBatchRunning && !visibleIDs.isEmpty)
    }

    private func reloadContainerSelectionCells() {
        guard kind == .containers,
              let column = tableView.tableColumns.firstIndex(where: { $0.identifier == ControlColumn.selection }),
              !filteredRows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<filteredRows.count),
            columnIndexes: IndexSet(integer: column)
        )
    }

    private func updateVisibleContainerSelectionCells() {
        guard kind == .containers,
              let column = tableView.tableColumns.firstIndex(where: { $0.identifier == ControlColumn.selection }) else {
            return
        }
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        let upperBound = min(filteredRows.count, visibleRows.location + visibleRows.length)
        for row in visibleRows.location..<upperBound {
            guard let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false)
                    as? ContainerSelectionCellView else { continue }
            let item = filteredRows[row]
            cell.update(
                name: item.title,
                isSelected: checkedContainerIDs.contains(item.id),
                isEnabled: !isBatchRunning
            )
        }
    }

    private func collectionPrimaryActions() -> [ResourceAction] {
        switch kind {
        case .containers:
            [
                action("Run") { [weak self] in self?.runContainerOperation(.run) },
                action("Create") { [weak self] in self?.runContainerOperation(.create) }
            ]
        case .images:
            [
                action("Pull") { [weak self] in self?.runImageOperation(.pull) },
                action("Build") { [weak self] in self?.onBuildRequested?() }
            ]
        case .volumes:
            [action("Create") { [weak self] in self?.runVolumeOperation(.create) }]
        case .networks, .registry, .machines:
            availablePrimaryActions()
        }
    }

    private func collectionSecondaryActions(excluding primaryTitles: Set<String>) -> [ResourceAction] {
        let actions: [ResourceAction]
        switch kind {
        case .containers:
            actions = [action("Prune", destructive: true) { [weak self] in self?.runContainerOperation(.prune) }]
        case .images:
            actions = [action("Prune", destructive: true) { [weak self] in self?.runImageOperation(.prune) }]
        case .volumes:
            actions = [action("Prune", destructive: true) { [weak self] in self?.runVolumeOperation(.prune) }]
        case .networks, .registry, .machines:
            actions = availableSecondaryActions(excluding: primaryTitles)
        }
        return actions.filter { !primaryTitles.contains($0.title) }
    }

    private func sortRows() {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = Column(rawValue: key) else {
            return
        }
        filteredRows = ResourceListPresentation.sorted(filteredRows, by: column, ascending: descriptor.ascending)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredRows.count else {
            return nil
        }

        let item = filteredRows[row]
        if tableColumn?.identifier == ControlColumn.selection {
            let identifier = NSUserInterfaceItemIdentifier("Cell-\(ControlColumn.selection.rawValue)")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ContainerSelectionCellView
                ?? ContainerSelectionCellView()
            cell.identifier = identifier
            let wasSelected = checkedContainerIDs.contains(item.id)
            cell.configure(
                name: item.title,
                isSelected: wasSelected,
                isEnabled: !isBatchRunning
            ) { [weak self] selected in
                self?.setContainerChecked(item.id, selected: selected)
            }
            return cell
        }
        if tableColumn?.identifier == ControlColumn.actions {
            let identifier = NSUserInterfaceItemIdentifier("Cell-\(ControlColumn.actions.rawValue)")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ContainerActionsCellView
                ?? ContainerActionsCellView()
            cell.identifier = identifier
            let running = isRunning(item)
            cell.configure(
                name: item.title,
                isRunning: running,
                isEnabled: !isBatchRunning,
                onPrimary: { [weak self] in
                    self?.runContainerOperation(running ? .stop : .start, target: item)
                },
                onMore: { [weak self] button in
                    self?.showContainerRowActions(for: item, from: button)
                },
                onDelete: { [weak self] in
                    self?.runContainerOperation(.delete, target: item)
                }
            )
            return cell
        }
        let column = tableColumn.flatMap { Column(rawValue: $0.identifier.rawValue) } ?? .name
        let value = column.cell(for: item)

        let identifier = NSUserInterfaceItemIdentifier("Cell-\(tableColumn?.identifier.rawValue ?? Column.name.rawValue)")
        if kind == .containers, column == .name {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ContainerNameLinkCellView
                ?? ContainerNameLinkCellView()
            cell.identifier = identifier
            cell.configure(
                name: item.title,
                fullIdentifier: item.inspectIdentifier ?? item.title
            ) { [weak self] in
                self?.openResourceDetails(itemID: item.id)
            }
            return cell
        }
        if column == .ports {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ResourceAccessTableCellView
                ?? ResourceAccessTableCellView()
            cell.identifier = identifier
            cell.configure(value: value, openURL: openURL)
            return cell
        }
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

        label.stringValue = value.text
        label.toolTip = value.tooltip
        label.font = column == .name ? AppFonts.body : (column == .digest ? AppFonts.mono : AppFonts.small)
        label.textColor = column == .status ? AppColors.muted : AppColors.ink
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel("\(column.title): \(value.text)")
        label.setAccessibilityHelp(value.tooltip)
        return cell
    }

    func focusSearch() {
        showCollection(restoreFocus: false)
        view.window?.makeFirstResponder(searchField)
    }

    var hasSelectedContainer: Bool {
        guard kind == .containers else { return false }
        if detailViewController != nil {
            return selectedItem() != nil
        }
        return selectedContainerItems.count == 1
    }

    var canStartSelectedContainer: Bool {
        guard kind == .containers else { return false }
        if detailViewController != nil {
            return selectedItem().map(isStopped) == true
        }
        return selectedContainerItems.contains(where: isStopped)
    }

    var canStopSelectedContainer: Bool {
        guard kind == .containers else { return false }
        if detailViewController != nil {
            return selectedItem().map(isRunning) == true
        }
        return selectedContainerItems.contains(where: isRunning)
    }

    func startSelectedContainer() {
        guard kind == .containers else { return }
        if detailViewController == nil, !checkedContainerIDs.isEmpty {
            runCheckedContainerBatch(.start)
        } else {
            runContainerOperation(.start)
        }
    }

    func stopSelectedContainer() {
        guard kind == .containers else { return }
        if detailViewController == nil, !checkedContainerIDs.isEmpty {
            runCheckedContainerBatch(.stop)
        } else {
            runContainerOperation(.stop)
        }
    }

    func showSelectedContainerLogs() {
        guard kind == .containers else { return }
        runContainerOperation(.logs)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingRows else { return }
        if kind == .containers {
            checkedContainerIDs = Set(tableView.selectedRowIndexes.compactMap { index in
                filteredRows.indices.contains(index) ? filteredRows[index].id : nil
            })
            updateContainerSelectionHeader()
            updateVisibleContainerSelectionCells()
        }
        rebuildActions()
        guard !kind.usesDedicatedDetail else { return }
        isInspectingSelection = true
        presentSelectedResource()
    }

    @objc private func tableRowActivated() {
        activateResourceRow(tableView.clickedRow, interactiveControl: clickedInteractiveControl())
    }

    @objc private func containerRowDoubleActivated() {
        activateResourceRow(tableView.clickedRow, interactiveControl: clickedInteractiveControl())
    }

    func activateResourceRow(_ row: Int, interactiveControl: Bool = false) {
        guard kind.usesDedicatedDetail, !interactiveControl,
              row >= 0, row < filteredRows.count else { return }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        openSelectedResourceDetails()
    }

    func openSelectedResourceDetails() {
        guard kind.usesDedicatedDetail, let item = focusedItem() else { return }
        showDetail(for: item)
    }

    private func openResourceDetails(itemID: String) {
        guard kind.usesDedicatedDetail,
              let item = filteredRows.first(where: { $0.id == itemID }) ?? rows.first(where: { $0.id == itemID }) else {
            return
        }
        showDetail(for: item)
    }

    private func clickedInteractiveControl() -> Bool {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .leftMouseDown else { return false }
        let point = tableView.convert(event.locationInWindow, from: nil)
        var candidate = tableView.hitTest(point)
        while let view = candidate, view !== tableView {
            if view is NSButton { return true }
            candidate = view.superview
        }
        return false
    }

    private func showDetail(for item: ResourceListItem) {
        invalidateInspection()
        isInspectingSelection = false
        onInspectorUpdate(.empty)
        detailItemID = item.id
        detailViewController?.view.removeFromSuperview()
        detailViewController?.removeFromParent()
        let detail = ResourceDetailViewController(
            kind: kind,
            item: item,
            warning: snapshot?.warningMessage,
            actions: detailActions(for: item),
            openURL: openURL,
            onBack: { [weak self] in self?.showCollection() },
            onRefresh: { [weak self] in self?.refreshVisibleDetail() }
        )
        detailViewController = detail
        stack.isHidden = true
        addChild(detail)
        detail.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(detail.view)
        NSLayoutConstraint.activate([
            detail.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            detail.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detail.view.topAnchor.constraint(equalTo: view.topAnchor),
            detail.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.window?.makeFirstResponder(detail.backButton)
        inspectDetail(item)
    }

    private func refreshVisibleDetail() {
        guard let id = detailItemID else {
            loadResources()
            return
        }
        guard let item = rows.first(where: { $0.id == id }) ?? filteredRows.first(where: { $0.id == id }) else {
            detailViewController?.setRefreshing(false)
            detailViewController?.showUnavailable("This \(kind.detailObjectName.lowercased()) is no longer present in the current list.")
            return
        }
        inspectDetail(item)
    }

    private func updateVisibleDetailFromList(id: String, refreshInspection: Bool) {
        guard let item = rows.first(where: { $0.id == id }) else {
            detailViewController?.setRefreshing(false)
            detailViewController?.showUnavailable("This \(kind.detailObjectName.lowercased()) is no longer available. Return to the list to continue.")
            return
        }
        detailViewController?.apply(item: item, warning: snapshot?.warningMessage, actions: detailActions(for: item))
        if refreshInspection { inspectDetail(item) }
    }

    private func inspectDetail(_ item: ResourceListItem) {
        invalidateInspection()
        let generation = inspectionGeneration
        detailViewController?.setRefreshing(true)
        guard let identifier = item.inspectIdentifier else {
            detailViewController?.setRefreshing(false)
            detailViewController?.apply(
                item: item,
                warning: "This resource does not provide an inspect identifier.",
                actions: []
            )
            return
        }
        inspectionTask = Task { [kind, service, weak self] in
            let inspected: (item: ResourceListItem?, error: String?)
            if kind == .volumes {
                inspected = await service.inspectVolumeItem(identifier: identifier)
            } else {
                inspected = await service.inspectItem(kind: kind, identifier: identifier, imageUsage: item.image?.usage)
            }
            await MainActor.run {
                guard let self, self.inspectionGeneration == generation,
                      self.detailItemID == item.id,
                      self.detailViewController?.representedItemID == item.id else { return }
                self.detailViewController?.setRefreshing(false)
                guard let resolved = inspected.item else {
                    if inspected.error?.localizedCaseInsensitiveContains("no longer available") == true {
                        self.detailViewController?.showUnavailable(inspected.error ?? "This resource is no longer available.")
                    } else {
                        self.detailViewController?.apply(
                            item: item,
                            warning: inspected.error ?? "Details could not be refreshed.",
                            actions: self.detailActions(for: item)
                        )
                    }
                    return
                }
                self.updateBackingItem(resolved)
                let warnings = [self.snapshot?.warningMessage, inspected.error].compactMap { $0 }
                self.detailViewController?.apply(
                    item: resolved,
                    warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"),
                    actions: self.detailActions(for: resolved)
                )
            }
        }
    }

    private func updateBackingItem(_ item: ResourceListItem) {
        if let index = rows.firstIndex(where: { $0.id == item.id }) { rows[index] = item }
        if let index = filteredRows.firstIndex(where: { $0.id == item.id }) { filteredRows[index] = item }
        if let index = snapshot?.items.firstIndex(where: { $0.id == item.id }) { snapshot?.items[index] = item }
        tableView.reloadData()
    }

    private func detailActions(for item: ResourceListItem) -> [ResourceDetailAction] {
        switch kind {
        case .containers:
            if isRunning(item) {
                return [
                    detailAction("Stop", primary: true) { [weak self] in self?.runContainerOperation(.stop, target: item) },
                    detailAction("Logs", primary: true) { [weak self] in self?.runContainerOperation(.logs, target: item) },
                    detailAction("Exec", primary: true) { [weak self] in self?.runContainerOperation(.exec, target: item) },
                    detailAction("Stats") { [weak self] in self?.runContainerOperation(.stats, target: item) },
                    detailAction("Copy") { [weak self] in self?.runContainerOperation(.copy, target: item) },
                    detailAction("Kill", destructive: true) { [weak self] in self?.runContainerOperation(.kill, target: item) },
                    detailAction("Delete", destructive: true) { [weak self] in self?.runContainerOperation(.delete, target: item) }
                ]
            }
            return [
                detailAction("Start", primary: true) { [weak self] in self?.runContainerOperation(.start, target: item) },
                detailAction("Logs", primary: true) { [weak self] in self?.runContainerOperation(.logs, target: item) },
                detailAction("Export") { [weak self] in self?.runContainerOperation(.export, target: item) },
                detailAction("Delete", destructive: true) { [weak self] in self?.runContainerOperation(.delete, target: item) }
            ]
        case .images:
            return [
                detailAction("Run", primary: true) { [weak self] in self?.runSelectedImage() },
                detailAction("Tag", primary: true) { [weak self] in self?.runImageOperation(.tag) },
                detailAction("Push", primary: true) { [weak self] in self?.runImageOperation(.push) },
                detailAction("Delete", destructive: true) { [weak self] in self?.runImageOperation(.delete) }
            ]
        case .volumes:
            return [detailAction("Delete", destructive: true) { [weak self] in self?.runVolumeOperation(.delete) }]
        case .networks, .registry, .machines:
            return []
        }
    }

    private func detailAction(
        _ title: String,
        destructive: Bool = false,
        primary: Bool = false,
        run: @escaping () -> Void
    ) -> ResourceDetailAction {
        ResourceDetailAction(title: title, isDestructive: destructive, isPrimary: primary, run: run)
    }

    private func showContainerRowActions(for item: ResourceListItem, from button: NSButton) {
        let primaryTitle = isRunning(item) ? "Stop" : "Start"
        let actions = [
            ResourceDetailAction(title: "Open Details") { [weak self] in
                self?.openResourceDetails(itemID: item.id)
            }
        ] + detailActions(for: item).filter {
            $0.title != primaryTitle && $0.title != "Delete"
        }
        let menu = NSMenu()
        for action in actions {
            let menuItem = ClosureMenuItem(title: action.title, action: action.run)
            if action.isDestructive {
                menuItem.attributedTitle = NSAttributedString(
                    string: action.title,
                    attributes: [.foregroundColor: AppColors.danger]
                )
            }
            menu.addItem(menuItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + AppSpacing.xs), in: button)
    }

    private func presentSelectedResource() {
        invalidateInspection()
        guard !kind.usesDedicatedDetail else {
            inspectorUpdateHandler(.empty)
            return
        }
        guard let item = selectedItem() else {
            inspectorUpdateHandler(.empty)
            return
        }

        let generation = inspectionGeneration
        inspectorUpdateHandler(
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

        inspectionTask = Task { [kind, service, weak self] in
            let inspected = await service.inspect(kind: kind, identifier: identifier)
            await MainActor.run {
                guard let self, self.inspectionGeneration == generation,
                      self.isInspectingSelection, self.selectedItem()?.id == item.id else { return }
                if let error = inspected.error {
                    self.inspectorUpdateHandler(
                        InspectorSnapshot(
                            title: item.title,
                            subtitle: item.status,
                            command: inspected.command ?? self.snapshot?.command,
                            detail: error,
                            json: item.rawJSON
                        )
                    )
                } else {
                    self.inspectorUpdateHandler(
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

        if kind.usesDedicatedDetail, let selected = selectedItem() {
            let actions = [
                ResourceAction(title: "Open Details", isDestructive: false) { [weak self] in
                    self?.openSelectedResourceDetails()
                }
            ] + detailActions(for: selected).map {
                ResourceAction(title: $0.title, isDestructive: $0.isDestructive, run: $0.run)
            }
            for action in actions {
                let item = ClosureMenuItem(title: action.title, action: action.run)
                if action.isDestructive {
                    item.attributedTitle = NSAttributedString(
                        string: action.title,
                        attributes: [.foregroundColor: AppColors.danger]
                    )
                }
                menu.addItem(item)
            }
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

    private func focusedItem() -> ResourceListItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredRows.count else {
            return nil
        }
        return filteredRows[row]
    }

    private func selectedItem() -> ResourceListItem? {
        if let detailItemID {
            return rows.first(where: { $0.id == detailItemID })
        }
        return focusedItem()
    }

    private func runContainerOperation(_ operation: ContainerOperation, target: ResourceListItem? = nil) {
        guard !isBatchRunning else { return }
        switch operation {
        case .create, .run:
            runContainerCreateOrRun(operation)
            return
        case .copy:
            runContainerCopy(selected: target)
            return
        case .export:
            runContainerExport(selected: target)
            return
        case .exec:
            runContainerExec(selected: target)
            return
        case .start, .stop, .kill, .delete, .logs, .stats, .prune:
            break
        }

        let selected = target ?? selectedItem()
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
                if outcome.succeeded, operation == .delete {
                    self?.showCollection(restoreFocus: false)
                }
                if operation != .logs && operation != .stats {
                    self?.loadResources()
                }
            }

        }
    }

    func runCheckedContainerBatch(_ operation: ContainerOperation) {
        guard kind == .containers, !isBatchRunning else { return }
        let selected = selectedContainerItems
        let targets: [ResourceListItem]
        switch operation {
        case .start:
            targets = selected.filter(isStopped)
        case .stop:
            targets = selected.filter(isRunning)
        case .delete:
            targets = selected
        case .create, .run, .kill, .logs, .stats, .copy, .export, .exec, .prune:
            return
        }
        guard !targets.isEmpty else { return }
        let forceDelete = operation == .delete && targets.contains(where: isRunning)
        if operation == .delete, !confirmBatchDelete(targets, force: forceDelete) {
            return
        }

        let batchTargets: [ContainerBatchTarget] = targets.compactMap { item in
            guard let identifier = item.inspectIdentifier else { return nil }
            return ContainerBatchTarget(
                id: identifier,
                name: item.title,
                state: item.container?.state ?? item.status
            )
        }
        guard batchTargets.count == targets.count else {
            onInspectorUpdate(InspectorSnapshot(
                title: operation.rawValue,
                subtitle: "Could not start the operation",
                command: nil,
                detail: "One or more selected containers do not have a runtime identifier. Refresh the list and try again.",
                json: nil
            ))
            return
        }
        let request = ContainerBatchRequest(
            operation: operation,
            targets: batchTargets,
            forceDelete: forceDelete
        )
        do {
            try request.validate()
        } catch {
            onInspectorUpdate(InspectorSnapshot(
                title: operation.rawValue,
                subtitle: "Could not start the operation",
                command: nil,
                detail: error.localizedDescription,
                json: nil
            ))
            return
        }

        batchGeneration += 1
        let generation = batchGeneration
        setBatchRunning(true)
        let title = "\(operation.rawValue) \(batchTargets.count) container\(batchTargets.count == 1 ? "" : "s")"
        let preview = batchPreview(for: request)
        let skippedCount = selected.count - targets.count
        let skippedDetail: String
        if skippedCount > 0 {
            skippedDetail = operation == .start
                ? "\n\nSkipped \(skippedCount) already running container(s)."
                : "\n\nSkipped \(skippedCount) already stopped container(s)."
        } else {
            skippedDetail = ""
        }
        onInspectorUpdate(InspectorSnapshot(
            title: title,
            subtitle: "Running...",
            command: preview,
            detail: batchTargets.map(\.name).joined(separator: "\n") + skippedDetail,
            json: nil
        ))
        let presenter = preview.map {
            InspectorStreamingPresenter(title: title, command: $0, onInspectorUpdate: onInspectorUpdate)
        }

        Task { [operationService, request, presenter, weak self] in
            let outcome = await operationService.runContainerBatch(request, outputHandler: presenter?.handler)
            await MainActor.run {
                presenter?.finish()
                guard let self, self.batchGeneration == generation else { return }
                self.setBatchRunning(false)
                if operation == .delete {
                    self.checkedContainerIDs.subtract(outcome.succeededIDs)
                }
                let commands = outcome.commands.map(\.displayString)
                let commandDetail = commands.count > 1
                    ? "\n\nCommands:\n" + commands.joined(separator: "\n")
                    : ""
                self.onInspectorUpdate(InspectorSnapshot(
                    title: title,
                    subtitle: outcome.succeeded ? "Succeeded" : "Failed",
                    command: commands.count == 1 ? outcome.commands.first : nil,
                    detail: outcome.output + skippedDetail + commandDetail,
                    json: nil
                ))
                self.loadResources()
            }
        }
    }

    private func setBatchRunning(_ running: Bool) {
        isBatchRunning = running
        tableView.isEnabled = !running
        searchField.isEnabled = !running
        updateContainerSelectionHeader()
        tableView.reloadData()
        rebuildActions()
    }

    private func batchPreview(for request: ContainerBatchRequest) -> CLICommandPreview? {
        let identifiers = request.targets.map(\.id)
        let arguments: [String]
        switch request.operation {
        case .start:
            guard identifiers.count == 1 else { return nil }
            arguments = ["start"] + identifiers
        case .stop:
            arguments = ["stop"] + identifiers
        case .delete:
            arguments = ["delete"] + (request.forceDelete ? ["--force"] : []) + identifiers
        case .create, .run, .kill, .logs, .stats, .copy, .export, .exec, .prune:
            return nil
        }
        return CLICommandPreview(executable: "container", arguments: arguments)
    }

    private func isStopped(_ item: ResourceListItem) -> Bool {
        if let container = item.container {
            return container.state == "stopped"
        }
        return item.status.localizedCaseInsensitiveContains("stopped")
    }

    func runContainerCreateOrRun(
        _ operation: ContainerOperation,
        imageReference: String = "",
        imageIsEditable: Bool = true,
        imageMetadata: ImageMetadata? = nil
    ) {
        if let launchController {
            launchController.view.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let window = view.window, window.attachedSheet == nil else {
            onInspectorUpdate(InspectorSnapshot(
                title: operation.rawValue, subtitle: "Open these settings from the main window after closing any existing dialog.",
                command: nil, detail: nil, json: nil
            ))
            return
        }
        let identifier = UUID()
        launchIdentifier = identifier
        let controller = ContainerLaunchViewController(
            operation: operation, imageReference: imageReference, imageIsEditable: imageIsEditable,
            imageMetadata: imageMetadata, service: service,
            onSubmit: { [weak self, operationService] request in
                guard let self, self.launchIdentifier == identifier, self.isViewLoaded, self.view.window != nil else {
                    return OperationOutcome(
                        title: request.operation.rawValue, command: nil, result: nil,
                        errorMessage: "This resource screen is no longer available. Reopen the container settings."
                    )
                }
                let arguments: [String]
                do {
                    arguments = try request.validatedArguments()
                } catch {
                    return OperationOutcome(title: request.operation.rawValue, command: nil, result: nil, errorMessage: error.localizedDescription)
                }
                let preview = CLICommandPreview(executable: "container", arguments: arguments)
                self.onInspectorUpdate(InspectorSnapshot(title: request.operation.rawValue, subtitle: "Running...", command: preview, detail: nil, json: nil))
                let generation = self.inspectionGeneration
                let publish: @MainActor (InspectorSnapshot) -> Void = { [weak self] snapshot in
                    guard let self, self.launchIdentifier == identifier, self.inspectionGeneration == generation,
                          self.isViewLoaded, self.view.window != nil else { return }
                    self.inspectorUpdateHandler(snapshot)
                }
                let presenter = InspectorStreamingPresenter(title: request.operation.rawValue, command: preview, onInspectorUpdate: publish)
                let outcome = await operationService.runContainerCreateOrRun(request, outputHandler: presenter.handler)
                presenter.finish()
                publish(InspectorSnapshot(
                    title: outcome.title, subtitle: outcome.succeeded ? "Succeeded" : "Failed",
                    command: outcome.command, detail: outcome.output, json: nil
                ))
                return outcome
            },
            onDismiss: { [weak self] succeeded in
                guard let self, self.launchIdentifier == identifier else { return }
                self.launchController = nil
                self.launchIdentifier = nil
                if succeeded { self.loadResources() }
            }
        )
        launchController = controller
        controller.present(asSheetOf: window)
    }

    func runSelectedImage() {
        guard kind == .images, let selected = selectedItem(), let reference = selected.inspectIdentifier else {
            onInspectorUpdate(InspectorSnapshot(title: "Run", subtitle: "Select an image first.", command: nil, detail: nil, json: nil))
            return
        }
        runContainerCreateOrRun(.run, imageReference: reference, imageIsEditable: false, imageMetadata: selected.image)
    }

            private func runContainerCopy(selected explicitSelection: ResourceListItem? = nil) {
                guard let selected = explicitSelection ?? selectedItem() else {
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

            private func runContainerExport(selected explicitSelection: ResourceListItem? = nil) {
                guard let selected = explicitSelection ?? selectedItem(), let identifier = selected.inspectIdentifier else {
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

            private func runContainerExec(selected explicitSelection: ResourceListItem? = nil) {
                guard let selected = explicitSelection ?? selectedItem(), let identifier = selected.inspectIdentifier else {
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

    private func confirmBatchDelete(_ targets: [ResourceListItem], force: Bool) -> Bool {
        if let batchDeleteConfirmation {
            return batchDeleteConfirmation(targets, force)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = force
            ? "Force delete \(targets.count) selected containers?"
            : "Delete \(targets.count) selected containers?"
        let names = targets.prefix(8).map(\.title).joined(separator: "\n")
        let remaining = max(0, targets.count - 8)
        let nameList = remaining == 0 ? names : "\(names)\n…and \(remaining) more"
        if force {
            alert.informativeText = """
            Running containers will be terminated and permanently removed. This cannot be undone.

            \(nameList)
            """
        } else {
            alert.informativeText = """
            The selected stopped containers will be permanently removed. This cannot be undone.

            \(nameList)
            """
        }
        alert.addButton(withTitle: force ? "Force Delete" : "Delete")
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
                if outcome.succeeded, operation == .delete {
                    self?.showCollection(restoreFocus: false)
                }
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
                if outcome.succeeded, operationTitle == "Delete", self?.detailViewController != nil {
                    self?.showCollection(restoreFocus: false)
                }
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
        isInspectingSelection = !kind.usesDedicatedDetail
        applyFilter()
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
