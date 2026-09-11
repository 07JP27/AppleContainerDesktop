import AppKit
import XCTest
@testable import AppleContainerDesktop

@MainActor
final class ContainerLaunchViewControllerTests: XCTestCase {
    func testCommonSettingsStartEmptyAndAdvancedIsCollapsed() throws {
        let controller = controller()
        controller.loadViewIfNeeded()
        defer { controller.cancel() }
        XCTAssertTrue(controller.advancedStack.isHidden)
        XCTAssertTrue(controller.draft.ports.isEmpty)
        XCTAssertTrue(controller.draft.volumes.isEmpty)
        XCTAssertTrue(controller.draft.environment.isEmpty)
        XCTAssertEqual(try controller.draft.validatedArguments(), ["run", "--detach", "registry.example:5000/web:dev"])
        XCTAssertEqual(controller.imageInput.accessibilityLabel(), "Image")
        XCTAssertEqual(controller.nameInput.accessibilityLabel(), "Container name")
        XCTAssertEqual(controller.submitButton.keyEquivalent, "\r")
        XCTAssertEqual(controller.cancelButton.keyEquivalent, "\u{1b}")
        XCTAssertFalse(controller.view.launchDescendants(of: NSButton.self).contains { $0.title.contains("Detach") })
    }

    func testDeclaredPortsRequireOptInAndAnExplicitHostPort() async throws {
        let submitter = LaunchSubmissionStub()
        let controller = controller(submitter: submitter)
        controller.loadViewIfNeeded()
        defer { controller.cancel() }
        await waitUntil { !controller.suggestions.isEmpty }
        XCTAssertTrue(controller.draft.ports.isEmpty)
        XCTAssertFalse(try controller.draft.validatedArguments().contains("--publish"))
        let suggestion = try XCTUnwrap(controller.suggestions.first { $0.id == "80/tcp" })
        controller.addSuggestedPort(suggestion)
        let row = try XCTUnwrap(controller.portRows.first)
        XCTAssertEqual(row.containerPort.stringValue, "80")
        XCTAssertEqual(row.hostPort.stringValue, "")
        controller.submit()
        XCTAssertTrue(submitter.requests.isEmpty)
        XCTAssertFalse(row.errorLabel.isHidden)
        row.hostPort.stringValue = "18080"
        row.hostPort.onChange?()
        XCTAssertTrue(row.errorLabel.isHidden)
        controller.submit()
        await waitUntil { controller.didDismiss }
        XCTAssertEqual(submitter.requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(submitter.requests.first).validatedArguments().contains("18080:80/tcp"))
    }

    func testAdvancedDisclosureKeepsDraftAndRevealsInvalidFields() throws {
        let controller = controller()
        let window = host(controller, size: NSSize(width: 680, height: 720))
        defer { controller.cancel(); window.close() }
        controller.cpuInput.stringValue = "-1"
        controller.submit()
        XCTAssertTrue(controller.advancedExpanded)
        XCTAssertFalse(controller.advancedStack.isHidden)
        XCTAssertTrue(controller.cpuInput.currentEditor() === window.firstResponder)
        controller.cpuInput.stringValue = "2"
        controller.memoryInput.stringValue = "2G"
        controller.cpuInput.onChange?()
        controller.setAdvancedExpanded(false)
        XCTAssertEqual(controller.draft.cpus, "2")
        XCTAssertEqual(controller.draft.memory, "2G")
        XCTAssertTrue(controller.cpuInput.isHiddenOrHasHiddenAncestor)
        controller.setAdvancedExpanded(true)
        XCTAssertEqual(controller.cpuInput.stringValue, "2")
    }

    func testRowsPreserveLiteralValuesAndCanBeRemovedWithoutRetainingTheirDraft() throws {
        weak var removed: LaunchEnvironmentRowView?
        try autoreleasepool {
            let controller = controller()
            controller.loadViewIfNeeded()
            defer { controller.cancel() }
            controller.addEnvironment(ContainerEnvironmentInput(name: "OPTIONS", value: "  first,second=a b  "), focus: false)
            controller.addMount(ContainerMountInput(source: "/Users/example/project, files", destination: "/app", readOnly: true), focus: false)
            controller.addNetwork(ContainerNetworkInput(specification: "frontend,mtu=1500"), focus: false)
            XCTAssertEqual(controller.draft.environment.first?.value, "  first,second=a b  ")
            XCTAssertEqual(controller.draft.volumes.first?.source, "/Users/example/project, files")
            XCTAssertEqual(controller.draft.networks.first?.specification, "frontend,mtu=1500")
            let arguments = try controller.draft.validatedArguments()
            XCTAssertTrue(arguments.contains("OPTIONS=  first,second=a b  "))
            XCTAssertTrue(arguments.contains("/Users/example/project, files:/app:ro"))
            XCTAssertTrue(arguments.contains("frontend,mtu=1500"))
            let row = controller.environmentRows[0]
            removed = row
            row.removeButton.performClick(nil)
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertTrue(controller.environmentRows.isEmpty)
            XCTAssertTrue(controller.draft.environment.isEmpty)
        }
        XCTAssertNil(removed)
    }

    func testEnvironmentInheritanceIsExplicitAndDoesNotEraseLiteralDraft() {
        let controller = controller()
        controller.loadViewIfNeeded()
        defer { controller.cancel() }
        controller.addEnvironment(ContainerEnvironmentInput(name: "MODE", value: "local"), focus: false)
        let row = controller.environmentRows[0]
        row.inherit.performClick(nil)
        XCTAssertTrue(row.input.inheritFromHost)
        XCTAssertFalse(row.value.isEnabled)
        row.inherit.performClick(nil)
        XCTAssertFalse(row.input.inheritFromHost)
        XCTAssertTrue(row.value.isEnabled)
        XCTAssertEqual(row.value.stringValue, "local")
    }

    func testSubmissionFailureKeepsEveryInputAndRetrySucceeds() async throws {
        let submitter = LaunchSubmissionStub(outcomes: [.launchFailure, .launchSuccess])
        var dismissed: [Bool] = []
        let controller = controller(submitter: submitter) { dismissed.append($0) }
        controller.loadViewIfNeeded()
        controller.nameInput.stringValue = "test-web"
        controller.addEnvironment(ContainerEnvironmentInput(name: "MODE", value: "dev,debug"), focus: false)
        controller.addMount(ContainerMountInput(kind: .volume, source: "app-data", destination: "/data"), focus: false)
        controller.setAdvancedExpanded(true)
        controller.cpuInput.stringValue = "2"
        let original = controller.draft
        controller.submit()
        await waitUntil { !controller.isSubmitting && !submitter.requests.isEmpty }
        XCTAssertFalse(controller.didDismiss)
        XCTAssertFalse(controller.operationError.isHidden)
        XCTAssertTrue(controller.operationError.stringValue.contains("already exists"))
        XCTAssertEqual(controller.draft, original)
        XCTAssertTrue(dismissed.isEmpty)
        controller.nameInput.stringValue = "test-web-retry"
        controller.nameInput.onChange?()
        controller.submit()
        await waitUntil { controller.didDismiss }
        XCTAssertEqual(dismissed, [true])
        XCTAssertEqual(submitter.requests.count, 2)
        XCTAssertEqual(submitter.requests.last?.name, "test-web-retry")
        XCTAssertEqual(submitter.requests.last?.environment, original.environment)
    }

    func testActiveSubmissionCannotBeDuplicatedOrMisrepresentedAsCancelled() async {
        let submitter = LaunchSubmissionStub()
        submitter.suspends = true
        let controller = controller(submitter: submitter)
        controller.loadViewIfNeeded()
        controller.submit()
        controller.submit()
        await waitUntil { submitter.requests.count == 1 }
        XCTAssertTrue(controller.isSubmitting)
        XCTAssertFalse(controller.submitButton.isEnabled)
        XCTAssertFalse(controller.cancelButton.isEnabled)
        controller.cancel()
        XCTAssertFalse(controller.didDismiss)
        XCTAssertTrue(controller.footerStatus.stringValue.contains("still running"))
        submitter.finish(.launchSuccess)
        await waitUntil { controller.didDismiss }
        XCTAssertEqual(submitter.requests.count, 1)
    }

    func testCancelBeforeSubmissionHasNoExecutionSideEffects() async {
        let submitter = LaunchSubmissionStub()
        let runner = ResourceFixtureRunner(images: "[\(ImagePortSuggestionsTests.imageJSON)]")
        var dismissals: [Bool] = []
        let controller = controller(runner: runner, submitter: submitter) { dismissals.append($0) }
        controller.loadViewIfNeeded()
        controller.addEnvironment(ContainerEnvironmentInput(name: "MODE", value: "dev"), focus: false)
        controller.cancel()
        controller.submit()
        XCTAssertEqual(dismissals, [false])
        XCTAssertTrue(submitter.requests.isEmpty)
        let commands = await runner.recordedCommands()
        XCTAssertTrue(commands.allSatisfy { $0.starts(with: ["image", "inspect"]) })
    }

    func testCreateKeepsItsSemanticsWithoutDetachOrAutoRemove() throws {
        let controller = controller(operation: .create)
        controller.loadViewIfNeeded()
        defer { controller.cancel() }
        controller.removeInput.state = .on
        XCTAssertFalse(controller.removeInput.isEnabled)
        XCTAssertEqual(try controller.draft.validatedArguments(), ["create", "registry.example:5000/web:dev"])
        XCTAssertEqual(controller.submitButton.title, "Create")
    }

    func testPlatformChangesOnlyFilterSuggestionsAndNeverOverwriteMappings() async throws {
        let controller = controller()
        controller.loadViewIfNeeded()
        defer { controller.cancel() }
        await waitUntil { controller.suggestions.count == 4 }
        controller.addPort(ContainerPortInput(hostPort: "18080", containerPort: "8080"), focus: false)
        let ports = controller.draft.ports
        controller.platformInput.stringValue = "linux/amd64"
        controller.platformInput.onChange?()
        XCTAssertEqual(controller.suggestions.map(\.id), ["80/tcp", "9090/tcp"])
        XCTAssertEqual(controller.draft.ports, ports)
        controller.platformInput.stringValue = "linux/arm64"
        controller.platformInput.onChange?()
        XCTAssertEqual(controller.suggestions.map(\.id), ["53/udp", "80/tcp", "8080/tcp"])
        XCTAssertEqual(controller.draft.ports, ports)
    }

    func testOlderImageLookupCannotReplaceNewImageOrCancelledSheet() async {
        let runner = DelayedLaunchImageRunner()
        let controller = controller(reference: "first:dev", runner: runner)
        controller.loadViewIfNeeded()
        await waitUntil { await runner.hasPending("first:dev") }
        controller.imageInput.stringValue = "second:dev"
        controller.imageInput.onChange?()
        controller.refreshPortSuggestions()
        await waitUntil { await runner.hasPending("second:dev") }
        await runner.resolve("second:dev", port: "443/tcp")
        await waitUntil { controller.suggestions.map(\.id) == ["443/tcp"] }
        await runner.resolve("first:dev", port: "80/tcp")
        await Task.yield()
        XCTAssertEqual(controller.suggestions.map(\.id), ["443/tcp"])
        controller.imageInput.stringValue = "third:dev"
        controller.imageInput.onChange?()
        controller.refreshPortSuggestions()
        await waitUntil { await runner.hasPending("third:dev") }
        controller.cancel()
        await runner.resolve("third:dev", port: "9000/tcp")
        await Task.yield()
        XCTAssertTrue(controller.suggestions.isEmpty)
        XCTAssertTrue(controller.didDismiss)
    }

    func testMetadataFailureDoesNotPreventManualConfiguration() async throws {
        let runner = ResourceFixtureRunner(inspectExitCode: 1)
        let controller = controller(runner: runner)
        controller.loadViewIfNeeded()
        defer { controller.cancel() }
        controller.addPort(ContainerPortInput(hostPort: "18080", containerPort: "80"), focus: false)
        let ports = controller.draft.ports
        await waitUntil { !controller.suggestionWarning.isHidden }
        XCTAssertFalse(controller.suggestionWarning.stringValue.isEmpty)
        XCTAssertEqual(controller.draft.ports, ports)
        XCTAssertTrue(controller.draft.validationIssues.isEmpty)
    }

    func testExistingVolumeNamesDoNotReplaceTypedSource() async {
        let volume = """
        [{"id":"existing-volume","configuration":{"name":"existing-volume","driver":"local","format":"ext4",
          "source":"/private/existing.img","creationDate":"2026-09-01T00:00:00Z","labels":{},"options":{}}}]
        """
        let runner = ResourceFixtureRunner(images: "[\(ImagePortSuggestionsTests.imageJSON)]", fallbackJSON: volume)
        let controller = controller(runner: runner)
        controller.loadViewIfNeeded()
        defer { controller.cancel() }
        controller.addMount(ContainerMountInput(kind: .volume, source: "my-new-data", destination: "/data"), focus: false)
        let row = controller.mountRows[0]
        await waitUntil { row.source.objectValues.contains { ($0 as? String) == "existing-volume" } }
        XCTAssertEqual(row.source.stringValue, "my-new-data")
        XCTAssertEqual(controller.draft.volumes[0].source, "my-new-data")
    }

    func testLayoutHasNativeControlHeightsScrollableRowsAndPersistentFooter() throws {
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
        for appearance in appearances {
            for size in [NSSize(width: 680, height: 720), NSSize(width: 560, height: 420)] {
                let controller = controller()
                let window = host(controller, size: size)
                defer { controller.cancel(); window.close() }
                controller.view.appearance = NSAppearance(named: appearance)
                for index in 0..<8 {
                    controller.addPort(ContainerPortInput(hostPort: "\(18080 + index)", containerPort: "80"), focus: false)
                }
                controller.addMount(ContainerMountInput(source: "/Users/example/a folder, with a long path", destination: "/app"), focus: false)
                controller.addEnvironment(ContainerEnvironmentInput(name: "MODE", value: "development"), focus: false)
                controller.setAdvancedExpanded(true)
                controller.view.layoutSubtreeIfNeeded()
                for input in [controller.imageInput, controller.nameInput, controller.cpuInput, controller.memoryInput, controller.commandInput]
                    + controller.portRows.flatMap({ [$0.hostPort, $0.containerPort] }) {
                    XCTAssertGreaterThanOrEqual(input.frame.height, 26, input.accessibilityLabel() ?? "")
                    let rect = controller.view.convert(input.bounds, from: input)
                    XCTAssertGreaterThanOrEqual(rect.minX, 0)
                    XCTAssertLessThanOrEqual(rect.maxX, size.width)
                }
                let document = try XCTUnwrap(controller.scrollView.documentView)
                XCTAssertGreaterThan(document.frame.height, controller.scrollView.contentView.bounds.height)
                XCTAssertGreaterThan(controller.scrollView.frame.height, 100)
                for row in controller.portRows {
                    let remove = row.convert(row.removeButton.bounds, from: row.removeButton)
                    XCTAssertEqual(remove.maxX, row.bounds.maxX, accuracy: 1)
                }
                let footer = controller.view.convert(controller.submitButton.bounds, from: controller.submitButton)
                XCTAssertGreaterThanOrEqual(footer.minY, 0)
                XCTAssertLessThan(footer.maxY, 80)
                XCTAssertFalse(controller.scrollView.hasHorizontalScroller)
                controller.setAdvancedExpanded(false)
                controller.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(controller.imageInput.frame.height, 28)
                XCTAssertEqual(controller.nameInput.frame.height, 28)
            }
        }
    }

    func testNativeFormAppearanceSnapshots() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for populated in [false, true] {
                let controller = controller()
                let size = populated ? NSSize(width: 560, height: 480) : NSSize(width: 680, height: 720)
                let window = host(controller, size: size)
                defer { controller.cancel(); window.close() }
                controller.view.appearance = NSAppearance(named: appearance)
                await waitUntil { !controller.suggestions.isEmpty }
                if populated {
                    controller.nameInput.stringValue = "local-web"
                    controller.addPort(ContainerPortInput(hostPort: "8080", containerPort: "80"), focus: false)
                    controller.addMount(ContainerMountInput(source: "/Users/example/web", destination: "/app"), focus: false)
                    controller.addEnvironment(ContainerEnvironmentInput(name: "NODE_ENV", value: "development"), focus: false)
                    controller.setAdvancedExpanded(true)
                }
                window.orderFront(nil)
                controller.view.layoutSubtreeIfNeeded()
                if populated, let document = controller.scrollView.documentView {
                    let rect = document.convert(controller.advancedStack.bounds, from: controller.advancedStack)
                    _ = document.scrollToVisible(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))
                }
                controller.view.displayIfNeeded()
                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                let image = NSImage(size: controller.view.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Container settings \(appearance.rawValue) \(populated ? "compact populated" : "basic")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testAllEntryPointsUseTheSheetAndImageRunPreservesTheFullTag() async throws {
        for operation in [ContainerOperation.run, .create] {
            let runner = ResourceFixtureRunner(containers: "[]")
            let resource = ResourceListViewController(kind: .containers, service: ResourceFixtures.service(runner: runner), operationService: ResourceFixtures.operations(runner: runner), onInspectorUpdate: { _ in })
            let window = host(resource, size: NSSize(width: 1_100, height: 780))
            defer { resource.launchController?.cancel(); resource.suspendInspection(); window.close() }
            resource.runContainerCreateOrRun(operation)
            let launch = try XCTUnwrap(resource.launchController)
            XCTAssertTrue(launch.imageInput.isEditable)
            XCTAssertEqual(launch.draft.operation, operation)
            XCTAssertEqual(launch.submitButton.title, operation.rawValue)
            resource.runContainerCreateOrRun(operation)
            XCTAssertTrue(resource.launchController === launch)
            launch.cancel()
            XCTAssertNil(resource.launchController)
        }

        let runner = ResourceFixtureRunner()
        let resource = ResourceListViewController(kind: .images, service: ResourceFixtures.service(runner: runner), operationService: ResourceFixtures.operations(runner: runner), onInspectorUpdate: { _ in })
        let window = host(resource, size: NSSize(width: 1_100, height: 780))
        defer { resource.launchController?.cancel(); resource.suspendInspection(); window.close() }
        let table = try XCTUnwrap(resource.view.launchDescendants(of: NSTableView.self).first)
        await waitUntil { table.numberOfRows == 1 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        resource.runSelectedImage()
        let launch = try XCTUnwrap(resource.launchController)
        XCTAssertFalse(launch.imageInput.isEditable)
        XCTAssertEqual(launch.draft.image, "registry.example:5000/team/web:dev")
        launch.submit()
        await waitUntil { launch.didDismiss }
        let commands = await runner.recordedCommands()
        XCTAssertTrue(commands.contains(["run", "--detach", "registry.example:5000/team/web:dev"]))
        XCTAssertNil(resource.launchController)
    }

    private func controller(
        operation: ContainerOperation = .run,
        reference: String = "registry.example:5000/web:dev",
        runner: ProcessRunning = ResourceFixtureRunner(images: "[\(ImagePortSuggestionsTests.imageJSON)]"),
        submitter: LaunchSubmissionStub = LaunchSubmissionStub(),
        onDismiss: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> ContainerLaunchViewController {
        ContainerLaunchViewController(
            operation: operation, imageReference: reference, service: ResourceFixtures.service(runner: runner),
            onSubmit: { await submitter.submit($0) }, onDismiss: onDismiss
        )
    }

    private func host(_ controller: NSViewController, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<150 {
            if await condition() { return }
            await Task.yield()
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                XCTFail("Waiting for the UI was interrupted: \(error)")
                return
            }
        }
        XCTFail("Expected launch UI state was not reached")
    }
}

@MainActor
private final class LaunchSubmissionStub {
    var requests: [ContainerCreateRunRequest] = []
    var suspends = false
    private var pending: CheckedContinuation<OperationOutcome, Never>?
    private var outcomes: [OperationOutcome]

    init(outcomes: [OperationOutcome] = [.launchSuccess]) { self.outcomes = outcomes }

    func submit(_ request: ContainerCreateRunRequest) async -> OperationOutcome {
        requests.append(request)
        if suspends {
            return await withCheckedContinuation { pending = $0 }
        }
        return outcomes.removeFirst()
    }

    func finish(_ outcome: OperationOutcome) {
        pending?.resume(returning: outcome)
        pending = nil
    }
}

private extension OperationOutcome {
    static let launchSuccess = OperationOutcome(
        title: "Run", command: nil,
        result: CLIProcessResult(preview: CLICommandPreview(executable: "/fake/container", arguments: []), exitCode: 0, stdout: "web", stderr: ""),
        errorMessage: nil
    )
    static let launchFailure = OperationOutcome(
        title: "Run", command: nil, result: nil, errorMessage: "A container with this name already exists."
    )
}

private actor DelayedLaunchImageRunner: ProcessRunning {
    private var pending: [String: (ProcessCommand, CheckedContinuation<CLIProcessResult, Never>)] = [:]

    func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
        guard let reference = command.arguments.last, command.arguments.starts(with: ["image", "inspect"]) else {
            return CLIProcessResult(preview: command.preview, exitCode: 1, stdout: "", stderr: "Unexpected fixture command")
        }
        return await withCheckedContinuation { pending[reference] = (command, $0) }
    }

    func hasPending(_ reference: String) -> Bool { pending[reference] != nil }

    func resolve(_ reference: String, port: String) {
        guard let (command, continuation) = pending.removeValue(forKey: reference) else { return }
        let output = """
        [{"name":"\(reference)","variants":[{"platform":{"os":"linux","architecture":"arm64"},
          "config":{"config":{"ExposedPorts":{"\(port)":{}}}}}]}]
        """
        continuation.resume(returning: CLIProcessResult(preview: command.preview, exitCode: 0, stdout: output, stderr: ""))
    }
}

private extension NSView {
    func launchDescendants<T: NSView>(of type: T.Type) -> [T] {
        let own = (self as? T).map { [$0] } ?? []
        return own + subviews.flatMap { $0.launchDescendants(of: type) }
    }
}
