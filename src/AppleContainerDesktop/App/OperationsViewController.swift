import AppKit

final class OperationsViewController: NSViewController, ContentReloading {
    private let historyStore: OperationHistoryStoring
    private let stack = NSStackView()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    init(historyStore: OperationHistoryStoring = UserDefaultsOperationHistoryStore()) {
        self.historyStore = historyStore
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

        let scrollView = NSScrollView()
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
        stack.setViews([], in: .top)
        stack.addFullWidthArrangedSubview(PageHeaderView(title: "Operations", subtitle: "Command history."))

        let records = historyStore.recent(limit: 50)
        let card = CardView(spacing: AppSpacing.md)
        card.stack.addArrangedSubview(NSTextField.label("Recent operations", font: AppFonts.heading))

        guard !records.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: "No operations yet.")
            empty.font = AppFonts.body
            empty.textColor = AppColors.muted
            empty.maximumNumberOfLines = 3
            card.stack.addArrangedSubview(empty)
            stack.addFullWidthArrangedSubview(card)
            return
        }

        for record in records {
            card.stack.addArrangedSubview(operationRow(record))
        }
        stack.addFullWidthArrangedSubview(card)
    }

    private func operationRow(_ record: OperationRecord) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = AppSpacing.xs

        let status = record.succeeded ? "Succeeded" : "Failed"
        let title = NSTextField.label("\(record.title) · \(status)", font: AppFonts.body)
        title.textColor = record.succeeded ? AppColors.ink : AppColors.danger
        row.addArrangedSubview(title)

        let detail = NSTextField(wrappingLabelWithString: "\(formatter.string(from: record.timestamp)) · exit \(record.exitCode.map(String.init) ?? "unknown") · \(record.command)")
        detail.font = AppFonts.mono
        detail.textColor = AppColors.muted
        detail.maximumNumberOfLines = 3
        row.addArrangedSubview(detail)

        return row
    }
}
