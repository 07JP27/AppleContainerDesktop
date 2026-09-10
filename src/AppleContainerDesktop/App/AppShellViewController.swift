import AppKit

final class AppShellViewController: NSViewController, NSMenuItemValidation {
    private let sidebarContainer = NSView()
    private let sidebarStack = NSStackView()
    private let runtimeStatusView = SidebarStatusView(title: "Checking runtime...", health: .unknown)
    private let contentContainer = NSView()
    private let inspectorContainer = NSView()
    private let inspectorStack = NSStackView()
    private let inspectorScrollView = NSScrollView()
    private let systemService = SystemService()
    private var splitView: NSSplitView?
    private var inspectorWidthConstraint: NSLayoutConstraint?
    private var selectedItem = SidebarItem.containers
    private var sidebarRows: [SidebarItem: SidebarRowView] = [:]
    private var currentContentViewController: NSViewController?
    private var cachedContentViewControllers: [SidebarItem: NSViewController] = [:]
    private var runtimeStatusRefreshTask: Task<Void, Never>?

    deinit {
        runtimeStatusRefreshTask?.cancel()
    }

    override func loadView() {
        let rootView = ThemedContainerView(backgroundColor: AppColors.background)
        rootView.onAppearanceChange = { [weak self] in
            self?.applyShellColors()
            self?.applySidebarSelectionStyles()
        }
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        select(.containers)
        startRuntimeStatusRefreshing()
    }

    private func buildLayout() {
        let splitView = NSSplitView()
        self.splitView = splitView
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = makeSidebar()
        let main = makeMainContainer()
        let inspector = makeInspector()

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(main)
        splitView.addArrangedSubview(inspector)

        view.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 196)
        ])
        inspectorWidthConstraint = inspector.widthAnchor.constraint(equalToConstant: 0)
        inspectorWidthConstraint?.isActive = true
        inspector.isHidden = true
    }

    private func makeSidebar() -> NSView {
        let container = sidebarContainer
        container.wantsLayer = true

        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .width
        sidebarStack.spacing = 1
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        addSidebarRows([.containers, .images, .networks, .volumes, .registries])
        addSidebarRows([.operations, .settings])

        runtimeStatusView.target = self
        runtimeStatusView.action = #selector(runtimeStatusPressed)

        container.addSubview(sidebarStack)
        container.addSubview(runtimeStatusView)
        NSLayoutConstraint.activate([
            sidebarStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: AppSpacing.sm),
            sidebarStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -AppSpacing.sm),
            sidebarStack.topAnchor.constraint(equalTo: container.topAnchor, constant: AppSpacing.md),
            sidebarStack.bottomAnchor.constraint(lessThanOrEqualTo: runtimeStatusView.topAnchor, constant: -AppSpacing.xl),
            runtimeStatusView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: AppSpacing.sm),
            runtimeStatusView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -AppSpacing.sm),
            runtimeStatusView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -AppSpacing.sm)
        ])
        return container
    }

    private func addSidebarRows(_ items: [SidebarItem]) {
        for item in items {
            let row = SidebarRowView(item: item)
            row.target = self
            row.action = #selector(sidebarRowPressed(_:))
            row.identifier = NSUserInterfaceItemIdentifier(item.rawValue)
            sidebarRows[item] = row
            sidebarStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        }
    }

    private func makeMainContainer() -> NSView {
        contentContainer.wantsLayer = true
        return contentContainer
    }

    private func makeInspector() -> NSView {
        let container = inspectorContainer
        container.wantsLayer = true

        inspectorStack.orientation = .vertical
        inspectorStack.alignment = .leading
        inspectorStack.spacing = AppSpacing.md
        inspectorStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(inspectorStack)
        inspectorScrollView.documentView = documentView
        inspectorScrollView.hasVerticalScroller = true
        inspectorScrollView.drawsBackground = false
        inspectorScrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(inspectorScrollView)
        NSLayoutConstraint.activate([
            inspectorScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            inspectorScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            inspectorScrollView.topAnchor.constraint(equalTo: container.topAnchor),
            inspectorScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: inspectorScrollView.contentView.widthAnchor),
            inspectorStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: AppSpacing.lg),
            inspectorStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -AppSpacing.lg),
            inspectorStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: AppSpacing.xl),
            inspectorStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -AppSpacing.lg)
        ])
        return container
    }

    @objc private func sidebarRowPressed(_ sender: SidebarRowView) {
        guard let value = sender.identifier?.rawValue, let item = SidebarItem(rawValue: value) else {
            return
        }
        select(item)
    }

    private func select(_ item: SidebarItem) {
        selectedItem = item
        applySidebarSelectionStyles()
        if item.resourceKind == nil {
            updateInspector(.empty)
        }

        let nextViewController = viewController(for: item)
        replaceContent(with: nextViewController)
        if let reloadable = nextViewController as? ContentReloading {
            reloadable.reloadContent()
        }
    }

    private func viewController(for item: SidebarItem) -> NSViewController {
        if let cached = cachedContentViewControllers[item] {
            return cached
        }

        let nextViewController: NSViewController
        if item == .system {
            nextViewController = SystemViewController(
                onRuntimeStatusChange: { [weak self] snapshot in
                    self?.updateRuntimeStatus(snapshot)
                }
            )
            updateInspector(.empty)
        } else if let resourceKind = item.resourceKind {
            nextViewController = ResourceListViewController(
                kind: resourceKind,
                onInspectorUpdate: { [weak self] snapshot in
                    self?.updateInspector(snapshot, from: item)
                },
                onRuntimeStatusRequested: { [weak self] in
                    self?.select(.system)
                },
                onBuildRequested: item == .images ? { [weak self] in
                    self?.showImageBuild()
                } : nil
            )
        } else if item == .operations {
            nextViewController = OperationsViewController()
            updateInspector(.empty)
        } else if item == .settings {
            nextViewController = SettingsViewController()
            updateInspector(.empty)
        } else {
            nextViewController = PlaceholderViewController(item: item)
            updateInspector(
                InspectorSnapshot(
                    title: item.rawValue,
                    subtitle: "This surface is scheduled for a later MVP stage.",
                    command: nil,
                    detail: nil,
                    json: nil
                )
            )
        }
        cachedContentViewControllers[item] = nextViewController
        return nextViewController
    }

    private func replaceContent(with viewController: NSViewController) {
        if currentContentViewController === viewController {
            return
        }

        currentContentViewController?.view.removeFromSuperview()
        currentContentViewController?.removeFromParent()
        currentContentViewController = viewController
        addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(viewController.view)
        NSLayoutConstraint.activate([
            viewController.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            viewController.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
    }

    @objc private func refresh() {
        refreshRuntimeStatus()
        if let reloadable = currentContentViewController as? ContentReloading {
            reloadable.reloadContent()
        } else {
            select(selectedItem)
        }
    }

    @objc func refreshContent() {
        refresh()
    }

    @objc func focusSearch() {
        if let searchable = currentContentViewController as? SearchFocusHandling {
            searchable.focusSearch()
        }
    }

    @objc func showSettings() {
        select(.settings)
    }

    @objc func showSystem() { select(.system) }
    @objc func showContainers() { select(.containers) }
    @objc func showImages() { select(.images) }
    @objc func showNetworks() { select(.networks) }
    @objc func showVolumes() { select(.volumes) }
    @objc func showRegistries() { select(.registries) }
    @objc func showOperations() { select(.operations) }

    @objc func startSelectedContainer() {
        activeContainerShortcuts()?.startSelectedContainer()
    }

    @objc func stopSelectedContainer() {
        activeContainerShortcuts()?.stopSelectedContainer()
    }

    @objc func showSelectedContainerLogs() {
        activeContainerShortcuts()?.showSelectedContainerLogs()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(focusSearch):
            return currentContentViewController is SearchFocusHandling
        case #selector(startSelectedContainer), #selector(stopSelectedContainer), #selector(showSelectedContainerLogs):
            return activeContainerShortcuts()?.hasSelectedContainer == true
        default:
            return true
        }
    }

    private func activeContainerShortcuts() -> ContainerShortcutHandling? {
        guard selectedItem == .containers else {
            return nil
        }
        return currentContentViewController as? ContainerShortcutHandling
    }

    @objc private func runtimeStatusPressed() {
        select(.system)
    }

    private func refreshRuntimeStatus() {
        Task { [systemService, weak self] in
            let snapshot = await systemService.loadSystemSnapshot()
            await MainActor.run {
                self?.updateRuntimeStatus(snapshot)
            }
        }
    }

    private func startRuntimeStatusRefreshing() {
        runtimeStatusRefreshTask = Task { [systemService, weak self] in
            while true {
                guard !Task.isCancelled else { return }
                let snapshot = await systemService.loadSystemSnapshot()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.updateRuntimeStatus(snapshot)
                }
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
    }

    private func updateRuntimeStatus(_ snapshot: SystemSnapshot) {
        runtimeStatusView.update(title: runtimeStatusTitle(for: snapshot), health: snapshot.health)
    }

    private func runtimeStatusTitle(for snapshot: SystemSnapshot) -> String {
        switch snapshot.health {
        case .running:
            "Runtime ready"
        case .stopped:
            "Runtime stopped"
        case .missingCLI:
            "Runtime unavailable"
        case .unhealthy:
            "Runtime issue"
        case .unknown:
            "Runtime unknown"
        }
    }

    private func updateInspector(_ snapshot: InspectorSnapshot, from sourceItem: SidebarItem? = nil) {
        if let sourceItem, sourceItem != selectedItem {
            return
        }

        inspectorStack.setViews([], in: .top)
        let shouldShowInspector = snapshot.title != InspectorSnapshot.empty.title
            || snapshot.command != nil
            || snapshot.detail != nil
            || snapshot.json != nil
        inspectorContainer.isHidden = !shouldShowInspector
        inspectorWidthConstraint?.constant = shouldShowInspector ? 320 : 0
        splitView?.adjustSubviews()
        guard shouldShowInspector else {
            return
        }

        let titleLabel = NSTextField.label(snapshot.title, font: AppFonts.heading)
        titleLabel.alignment = .left
        addInspectorView(titleLabel)

        if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
            let label = NSTextField(wrappingLabelWithString: subtitle)
            label.font = AppFonts.body
            label.textColor = AppColors.muted
            label.alignment = .left
            label.maximumNumberOfLines = 3
            addInspectorView(label)
        }

        if let command = snapshot.command {
            addInspectorView(inspectorBlock(title: "Command", value: command.displayString, monospaced: true))
        }

        if let detail = snapshot.detail, !detail.isEmpty {
            addInspectorView(inspectorBlock(title: "Detail", value: detail, monospaced: false))
        }

        if let json = snapshot.json, !json.isEmpty {
            addInspectorView(inspectorBlock(title: "JSON", value: json, monospaced: true))
        }
    }

    private func addInspectorView(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        inspectorStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: inspectorStack.widthAnchor).isActive = true
    }

    private func applyShellColors() {
        view.layer?.backgroundColor = view.resolvedCGColor(AppColors.background)
        sidebarContainer.layer?.backgroundColor = sidebarContainer.resolvedCGColor(AppColors.sidebar)
        contentContainer.layer?.backgroundColor = contentContainer.resolvedCGColor(AppColors.background)
        inspectorContainer.layer?.backgroundColor = inspectorContainer.resolvedCGColor(AppColors.surface)
    }

    private func applySidebarSelectionStyles() {
        for (sidebarItem, row) in sidebarRows {
            let isSelected = sidebarItem == selectedItem
            row.isRowSelected = isSelected
        }
        runtimeStatusView.isStatusSelected = selectedItem == .system
    }

    private func showImageBuild() {
        selectedItem = .images
        applySidebarSelectionStyles()
        updateInspector(.empty)
        let buildViewController = BuildViewController(
            onInspectorUpdate: { [weak self] snapshot in
                self?.updateInspector(snapshot, from: .images)
            },
            onBack: { [weak self] in
                self?.select(.images)
            }
        )
        replaceContent(with: buildViewController)
    }

    private func inspectorBlock(title: String, value: String, monospaced: Bool) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AppSpacing.xs

        let titleLabel = NSTextField.label(title, font: AppFonts.small, color: AppColors.muted)
        titleLabel.alignment = .left
        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = monospaced ? AppFonts.mono : AppFonts.body
        valueLabel.textColor = AppColors.ink
        valueLabel.maximumNumberOfLines = monospaced ? 120 : 12
        valueLabel.alignment = .left

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(valueLabel)
        titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        valueLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
}

@MainActor
protocol SearchFocusHandling: AnyObject {
    func focusSearch()
}

@MainActor
protocol ContainerShortcutHandling: AnyObject {
    var hasSelectedContainer: Bool { get }
    func startSelectedContainer()
    func stopSelectedContainer()
    func showSelectedContainerLogs()
}

@MainActor
protocol ContentReloading: AnyObject {
    func reloadContent()
}
