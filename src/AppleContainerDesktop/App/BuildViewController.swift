import AppKit

final class BuildViewController: NSViewController, ContentReloading {
    private let operationService: OperationService
    private let onInspectorUpdate: @MainActor (InspectorSnapshot) -> Void
    private let onBack: @MainActor () -> Void
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let contextField = NSTextField(string: ".")
    private let dockerfileField = NSTextField(string: "Dockerfile")
    private let tagField = NSTextField(string: "")
    private let platformField = NSTextField(string: "")
    private let buildArgsField = NSTextField(string: "")

    init(
        operationService: OperationService = OperationService(),
        onInspectorUpdate: @escaping @MainActor (InspectorSnapshot) -> Void,
        onBack: @escaping @MainActor () -> Void = {}
    ) {
        self.operationService = operationService
        self.onInspectorUpdate = onInspectorUpdate
        self.onBack = onBack
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
        onInspectorUpdate(.empty)
        render()
    }

    func reloadContent() {
        // Refresh should not discard a half-completed build form.
    }

    private func render() {
        stack.setViews([], in: .top)
        stack.addFullWidthArrangedSubview(PageHeaderView(title: "Build image", subtitle: "Build a Dockerfile into a local image."))

        let buildCard = CardView(spacing: AppSpacing.md)
        buildCard.stack.addArrangedSubview(NSTextField.label("Dockerfile build", font: AppFonts.heading))
        buildCard.stack.addArrangedSubview(field(title: "Build context", textField: contextField))
        buildCard.stack.addArrangedSubview(field(title: "Dockerfile path", textField: dockerfileField))
        buildCard.stack.addArrangedSubview(field(title: "Tag", textField: tagField, placeholder: "example/app:latest"))
        buildCard.stack.addArrangedSubview(field(title: "Platform", textField: platformField, placeholder: "linux/arm64"))
        buildCard.stack.addArrangedSubview(field(title: "Build args", textField: buildArgsField, placeholder: "KEY=value, one per line or comma separated"))

        let button = ClosureButton(title: "Build") { [weak self] in
            self?.runBuild()
        }
        button.bezelStyle = .rounded
        button.setAccessibilityHelp("Builds the Dockerfile using the generated container build command.")
        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = AppSpacing.sm
        actionRow.addArrangedSubview(button)
        let backButton = ClosureButton(title: "Back to Images") { [weak self] in
            self?.onBack()
        }
        backButton.bezelStyle = .texturedRounded
        actionRow.addArrangedSubview(backButton)
        buildCard.stack.addArrangedSubview(actionRow)
        stack.addFullWidthArrangedSubview(buildCard)
    }

    private func field(title: String, textField: NSTextField, placeholder: String? = nil) -> NSView {
        textField.placeholderString = placeholder
        textField.font = AppFonts.mono
        textField.setAccessibilityLabel(title)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.widthAnchor.constraint(equalToConstant: 460).isActive = true

        let fieldStack = NSStackView()
        fieldStack.orientation = .vertical
        fieldStack.alignment = .leading
        fieldStack.spacing = AppSpacing.xs
        fieldStack.addArrangedSubview(NSTextField.label(title, font: AppFonts.small, color: AppColors.muted))
        fieldStack.addArrangedSubview(textField)
        return fieldStack
    }

    private func runBuild() {
        let request = BuildRequest(
            contextDirectory: contextField.stringValue,
            dockerfilePath: dockerfileField.stringValue,
            tag: tagField.stringValue,
            platform: platformField.stringValue,
            buildArguments: buildArgsField.stringValue
        )
        let preview = CLICommandPreview(executable: "container", arguments: request.arguments)
        onInspectorUpdate(
            InspectorSnapshot(
                title: "Build",
                subtitle: "Running...",
                command: preview,
                detail: nil,
                json: nil
            )
        )

        let presenter = streamingOutputPresenter(title: "Build", command: preview)
        Task { [operationService, request, presenter, weak self] in
            let outcome = await operationService.runBuild(request, outputHandler: presenter.handler)
            await MainActor.run {
                presenter.finish()
                self?.onInspectorUpdate(
                    InspectorSnapshot(
                        title: "Build",
                        subtitle: outcome.succeeded ? "Succeeded" : "Failed",
                        command: outcome.command,
                        detail: outcome.output,
                        json: nil
                    )
                )
            }
        }
    }

    private func streamingOutputPresenter(title: String, command: CLICommandPreview) -> InspectorStreamingPresenter {
        InspectorStreamingPresenter(title: title, command: command, onInspectorUpdate: onInspectorUpdate)
    }
}
