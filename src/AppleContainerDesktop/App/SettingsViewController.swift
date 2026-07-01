import AppKit

final class SettingsViewController: NSViewController, ContentReloading {
    private var preferences: AppPreferences
    private let systemService: SystemService
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let pathField = NSTextField()

    init(
        preferences: AppPreferences = UserDefaultsAppPreferences(),
        systemService: SystemService = SystemService()
    ) {
        self.preferences = preferences
        self.systemService = systemService
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
        renderLoading()
        loadSettings()
    }

    func reloadContent() {
        loadSettings()
    }

    private func renderLoading() {
        stack.setViews([], in: .top)
        stack.addFullWidthArrangedSubview(PageHeaderView(title: "Settings", subtitle: "Loading..."))
    }

    private func loadSettings() {
        Task { [systemService, weak self] in
            let snapshot = await systemService.loadSettingsSnapshot()
            await MainActor.run {
                self?.render(snapshot)
            }
        }
    }

    private func render(_ snapshot: SettingsSnapshot) {
        stack.setViews([], in: .top)
        stack.addFullWidthArrangedSubview(PageHeaderView(title: "Settings", subtitle: "CLI path and runtime details."))

        let cliCard = CardView(spacing: AppSpacing.md)
        cliCard.stack.addArrangedSubview(NSTextField.label("CLI executable", font: AppFonts.heading))

        pathField.stringValue = preferences.cliExecutablePath ?? ""
        pathField.placeholderString = "/usr/local/bin/container"
        pathField.font = AppFonts.mono
        pathField.setAccessibilityLabel("Container CLI executable path")
        pathField.setAccessibilityHelp("Optional path override for the Apple container executable.")
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.widthAnchor.constraint(equalToConstant: 460).isActive = true
        cliCard.stack.addArrangedSubview(pathField)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = AppSpacing.sm
        buttonRow.addArrangedSubview(ClosureButton(title: "Save Path") { [weak self] in
            self?.savePath()
        })
        buttonRow.addArrangedSubview(ClosureButton(title: "Clear Override") { [weak self] in
            self?.clearPath()
        })
        cliCard.stack.addArrangedSubview(buttonRow)

        if let problem = snapshot.detection.problem {
            cliCard.stack.addArrangedSubview(keyValue("Detection", problem))
        } else if let path = snapshot.detection.executableURL?.path {
            cliCard.stack.addArrangedSubview(keyValue("Detected path", path, monospaced: true))
        }

        if let cliVersion = snapshot.version?.cliVersion {
            cliCard.stack.addArrangedSubview(keyValue("CLI version", cliVersion))
        }
        if let apiServerVersion = snapshot.version?.apiServerVersion {
            cliCard.stack.addArrangedSubview(keyValue("API server", apiServerVersion))
        }
        stack.addFullWidthArrangedSubview(cliCard)

        let propertiesCard = CardView(spacing: AppSpacing.md)
        propertiesCard.stack.addArrangedSubview(NSTextField.label("Runtime properties", font: AppFonts.heading))
        if let errorMessage = snapshot.errorMessage {
            propertiesCard.stack.addArrangedSubview(keyValue("Error", errorMessage))
        }
        if let propertiesJSON = snapshot.propertiesJSON {
            let detailsStack = NSStackView()
            detailsStack.orientation = .vertical
            detailsStack.alignment = .width
            detailsStack.spacing = AppSpacing.sm

            var detailButton: ClosureButton?
            detailButton = ClosureButton(title: "Show properties JSON") { [weak self, weak detailsStack] in
                guard let self, let detailsStack else { return }
                if detailsStack.arrangedSubviews.isEmpty {
                    if let command = snapshot.command {
                        detailsStack.addArrangedSubview(self.keyValue("Command", command.displayString, monospaced: true))
                    }
                    detailsStack.addArrangedSubview(self.keyValue("JSON", propertiesJSON, monospaced: true, maxLines: 80))
                    detailButton?.title = "Hide properties JSON"
                } else {
                    detailsStack.setViews([], in: .top)
                    detailButton?.title = "Show properties JSON"
                }
            }
            if let detailButton {
                detailButton.controlSize = .small
                detailButton.bezelStyle = .texturedRounded
                propertiesCard.stack.addArrangedSubview(detailButton)
            }
            propertiesCard.stack.addArrangedSubview(detailsStack)
            detailsStack.widthAnchor.constraint(equalTo: propertiesCard.stack.widthAnchor).isActive = true
        }
        stack.addFullWidthArrangedSubview(propertiesCard)
    }

    private func savePath() {
        let value = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.cliExecutablePath = value.isEmpty ? nil : value
        loadSettings()
    }

    private func clearPath() {
        preferences.cliExecutablePath = nil
        pathField.stringValue = ""
        loadSettings()
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
}
