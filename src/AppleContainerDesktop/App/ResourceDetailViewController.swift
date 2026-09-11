import AppKit

@MainActor
struct ResourceDetailAction {
    var title: String
    var isDestructive: Bool = false
    var isPrimary: Bool = false
    var run: () -> Void
}

final class ResourceTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onToggleFocusedSelection: (() -> Void)?
    var onSelectAllVisible: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let actionModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if event.modifierFlags.intersection(actionModifiers) == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            onSelectAllVisible?()
            return
        }
        if event.modifierFlags.intersection(actionModifiers).isEmpty,
           event.charactersIgnoringModifiers == " " {
            onToggleFocusedSelection?()
            return
        }
        if event.modifierFlags.intersection(actionModifiers).isEmpty,
           (event.keyCode == 36 || event.keyCode == 76) {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

final class ResourceDetailViewController: NSViewController {
    private let kind: ResourceKind
    private let openURL: @MainActor (URL) -> Void
    private let onBack: @MainActor () -> Void
    private let onRefresh: @MainActor () -> Void
    private let titleLabel = NSTextField.label("", font: AppFonts.title)
    private let subtitleLabel = NSTextField.label("", color: AppColors.muted)
    private let refreshStatusLabel = NSTextField.label("", font: AppFonts.small, color: AppColors.muted)
    private let actionRow = NSStackView()
    private let detailHost = NSView()
    private let scrollView = NSScrollView()
    private var detailView: NSView?
    private(set) var representedItemID: String
    private(set) var backButton: NSButton!

    init(
        kind: ResourceKind,
        item: ResourceListItem,
        warning: String? = nil,
        actions: [ResourceDetailAction],
        openURL: @escaping @MainActor (URL) -> Void,
        onBack: @escaping @MainActor () -> Void,
        onRefresh: @escaping @MainActor () -> Void
    ) {
        self.kind = kind
        self.openURL = openURL
        self.onBack = onBack
        self.onRefresh = onRefresh
        representedItemID = item.id
        super.init(nibName: nil, bundle: nil)
        loadViewIfNeeded()
        apply(item: item, warning: warning, actions: actions)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = ThemedContainerView(backgroundColor: AppColors.background)

        let page = NSStackView()
        page.orientation = .vertical
        page.alignment = .width
        page.spacing = AppSpacing.lg
        page.translatesAutoresizingMaskIntoConstraints = false

        let navigation = NSStackView()
        navigation.orientation = .horizontal
        navigation.alignment = .centerY
        navigation.spacing = AppSpacing.sm
        let back = ClosureButton(title: kind.rawValue) { [weak self] in self?.onBack() }
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        back.imagePosition = .imageLeading
        back.isBordered = false
        back.font = AppFonts.body
        back.setAccessibilityLabel("Back to \(kind.rawValue)")
        backButton = back
        let navigationSpacer = NSView()
        let refresh = ClosureButton(title: "Refresh") { [weak self] in self?.onRefresh() }
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.imagePosition = .imageLeading
        refresh.bezelStyle = .rounded
        refresh.font = AppFonts.body
        refresh.setAccessibilityHelp("Refresh this \(kind.detailObjectName.lowercased()) without returning to the list.")
        navigation.addArrangedSubview(back)
        navigation.addArrangedSubview(navigationSpacer)
        refreshStatusLabel.isHidden = true
        navigation.addArrangedSubview(refreshStatusLabel)
        navigation.addArrangedSubview(refresh)

        let heading = NSStackView()
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = AppSpacing.xs
        heading.addArrangedSubview(titleLabel)
        heading.addArrangedSubview(subtitleLabel)

        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 6
        actionRow.setContentHuggingPriority(.required, for: .vertical)
        actionRow.setContentCompressionResistancePriority(.required, for: .vertical)

        page.addFullWidthArrangedSubview(navigation)
        page.addFullWidthArrangedSubview(heading)
        page.addFullWidthArrangedSubview(actionRow)

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: AppSpacing.xxl),
            page.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -AppSpacing.xxl),
            page.topAnchor.constraint(equalTo: header.topAnchor, constant: AppSpacing.xl),
            page.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -AppSpacing.lg)
        ])

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        detailHost.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(detailHost)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityLabel("\(kind.detailObjectName) details")

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(separator)
        view.addSubview(scrollView)
        let readableWidth = detailHost.widthAnchor.constraint(
            equalTo: document.widthAnchor,
            constant: -2 * AppSpacing.xxl
        )
        readableWidth.priority = NSLayoutConstraint.Priority.defaultHigh
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            detailHost.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: AppSpacing.xxl),
            detailHost.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -AppSpacing.xxl),
            detailHost.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            detailHost.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            readableWidth,
            detailHost.topAnchor.constraint(equalTo: document.topAnchor, constant: AppSpacing.xl),
            detailHost.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -AppSpacing.xxl)
        ])
    }

    func apply(item: ResourceListItem, warning: String?, actions: [ResourceDetailAction]) {
        representedItemID = item.id
        titleLabel.stringValue = item.image?.reference.displayName ?? item.title
        titleLabel.toolTip = item.inspectIdentifier ?? item.title
        subtitleLabel.stringValue = detailSubtitle(for: item)
        subtitleLabel.setAccessibilityLabel("\(kind.detailObjectName) \(titleLabel.stringValue), \(subtitleLabel.stringValue)")
        rebuildActions(actions)
        guard let overview = ResourceOverview(item: item, warning: warning) else {
            showUnavailable("Details are not available for this resource.")
            return
        }
        replaceDetail(with: ResourceOverviewView(overview: overview, showsHeader: false, openURL: openURL))
    }

    func setRefreshing(_ refreshing: Bool) {
        refreshStatusLabel.stringValue = refreshing ? "Refreshing details..." : ""
        refreshStatusLabel.isHidden = !refreshing
    }

    func showUnavailable(_ message: String) {
        rebuildActions([])
        let state = NSStackView()
        state.orientation = .vertical
        state.alignment = .leading
        state.spacing = AppSpacing.sm
        state.addArrangedSubview(NSTextField.label("Details unavailable", font: AppFonts.heading))
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = AppFonts.body
        label.textColor = AppColors.muted
        label.maximumNumberOfLines = 0
        state.addArrangedSubview(label)
        replaceDetail(with: state)
    }

    private func replaceDetail(with next: NSView) {
        detailView?.removeFromSuperview()
        detailView = next
        next.translatesAutoresizingMaskIntoConstraints = false
        detailHost.addSubview(next)
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: detailHost.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: detailHost.trailingAnchor),
            next.topAnchor.constraint(equalTo: detailHost.topAnchor),
            next.bottomAnchor.constraint(equalTo: detailHost.bottomAnchor)
        ])
    }

    private func rebuildActions(_ actions: [ResourceDetailAction]) {
        actionRow.setViews([], in: .leading)
        let primary = actions.filter { $0.isPrimary && !$0.isDestructive }
        for action in primary {
            actionRow.addArrangedSubview(ToolbarActionButton(title: action.title) { _ in action.run() })
        }
        let secondary = actions.filter { action in
            action.isDestructive || !action.isPrimary
        }
        if !secondary.isEmpty {
            actionRow.addArrangedSubview(ToolbarActionButton(title: "More", showsMenuIndicator: true) { button in
                let menu = NSMenu()
                for action in secondary {
                    let item = ClosureMenuItem(title: action.title, action: action.run)
                    if action.isDestructive {
                        item.attributedTitle = NSAttributedString(
                            string: action.title,
                            attributes: [.foregroundColor: AppColors.danger]
                        )
                    }
                    menu.addItem(item)
                }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + AppSpacing.xs), in: button)
            })
        }
        actionRow.isHidden = actionRow.arrangedSubviews.isEmpty
    }

    private func detailSubtitle(for item: ResourceListItem) -> String {
        switch kind {
        case .containers:
            item.container?.stateTitle ?? item.status
        case .images:
            item.image?.reference.tag.map { "Image tag \($0)" } ?? "Image details"
        case .volumes:
            item.volume?.isAnonymous == true ? "Anonymous volume" : "Named volume"
        case .networks, .registry, .machines:
            item.status
        }
    }
}

extension ResourceKind {
    var usesDedicatedDetail: Bool {
        self == .containers || self == .images || self == .volumes
    }

    var detailObjectName: String {
        switch self {
        case .containers: "Container"
        case .images: "Image"
        case .volumes: "Volume"
        case .networks: "Network"
        case .registry: "Registry"
        case .machines: "Machine"
        }
    }
}
