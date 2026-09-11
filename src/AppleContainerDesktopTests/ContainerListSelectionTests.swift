import AppKit
import XCTest
@testable import AppleContainerDesktop

@MainActor
final class ContainerListSelectionTests: XCTestCase {
    func testContainerListStartsWithDockerStyleControlColumnsAndNoCheckedRows() async throws {
        let controller = controller(runner: ResourceFixtureRunner())
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 1 }
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            table.tableColumns.map(\.identifier.rawValue),
            [
                "container-selection", "name", "status", "image",
                "ports", "lastStarted", "container-actions"
            ]
        )
        XCTAssertTrue(controller.checkedContainerIDs.isEmpty)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet())
        XCTAssertTrue(toolbarControls(in: controller.view).contains("Run"))
        XCTAssertTrue(toolbarControls(in: controller.view).contains("Create"))
        XCTAssertFalse(toolbarControls(in: controller.view).contains("Start"))
        XCTAssertLessThanOrEqual(
            table.tableColumns.reduce(CGFloat.zero) { $0 + $1.width },
            table.enclosingScrollView?.contentView.bounds.width ?? 0
        )
        let header = try XCTUnwrap(table.headerView as? ContainerSelectionHeaderView)
        XCTAssertEqual(header.selectionButton.state, .off)
        XCTAssertEqual(header.selectionButton.accessibilityLabel(), "Select all visible containers")
    }

    func testSingleClickSelectsWithoutOpeningDetailsAndShowsEligibleBulkActions() async throws {
        let controller = controller(runner: ResourceFixtureRunner())
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 1 }

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await Task.yield()

        XCTAssertEqual(controller.checkedContainerIDs, ["web"])
        XCTAssertNil(controller.detailViewController)
        let controls = toolbarControlMap(in: controller.view)
        XCTAssertEqual(controls["Start"]?.isEnabled, false)
        XCTAssertEqual(controls["Stop"]?.isEnabled, true)
        XCTAssertEqual(controls["Delete"]?.isEnabled, true)
        XCTAssertEqual(controls["Clear"]?.isEnabled, true)
        XCTAssertNotNil(controller.view.firstContainerListTextField(with: "1 selected"))
    }

    func testMixedSelectionEnablesStartAndStopAndHeaderTracksThreeStates() async throws {
        let controller = controller(runner: mixedRunner())
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 2 }
        let header = try XCTUnwrap(table.headerView as? ContainerSelectionHeaderView)

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await Task.yield()
        XCTAssertEqual(header.selectionButton.state, .mixed)

        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
        await Task.yield()
        XCTAssertEqual(controller.checkedContainerIDs, ["web", "worker"])
        XCTAssertEqual(header.selectionButton.state, .on)
        let controls = toolbarControlMap(in: controller.view)
        XCTAssertEqual(controls["Start"]?.isEnabled, true)
        XCTAssertEqual(controls["Stop"]?.isEnabled, true)

        header.selectionButton.state = .off
        header.selectionButton.sendAction(header.selectionButton.action, to: header.selectionButton.target)
        XCTAssertTrue(controller.checkedContainerIDs.isEmpty)
        XCTAssertEqual(header.selectionButton.state, .off)
    }

    func testSelectAllAndSpaceKeyboardBehavior() async throws {
        let controller = controller(runner: mixedRunner())
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 2 }
        window.makeFirstResponder(table)

        table.keyDown(with: try keyEvent("a", keyCode: 0, modifiers: [.command], window: window))
        XCTAssertEqual(controller.checkedContainerIDs, ["web", "worker"])

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.keyDown(with: try keyEvent(" ", keyCode: 49, window: window))
        XCTAssertTrue(controller.checkedContainerIDs.isEmpty)
    }

    func testFilteringDropsHiddenCheckedTargetsWhileSortingPreservesVisibleIdentities() async throws {
        let controller = controller(runner: mixedRunner())
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        let search = try XCTUnwrap(controller.view.containerListDescendants(of: NSSearchField.self).first)
        await waitUntil { table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
        table.sortDescriptors = [NSSortDescriptor(key: ResourceListColumn.name.rawValue, ascending: false)]
        XCTAssertEqual(controller.checkedContainerIDs, ["web", "worker"])

        search.stringValue = "worker"
        search.sendAction(search.action, to: search.target)

        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(controller.checkedContainerIDs, ["worker"])
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
        XCTAssertNotNil(controller.view.firstContainerListTextField(with: "1 selected"))
    }

    func testNameLinkAndReturnOpenDetailsButCheckboxAndRowActionDoNot() async throws {
        let runner = mixedRunner()
        let controller = controller(runner: runner)
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 2 }

        let selectionColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "container-selection" })
        let selectionCell = try XCTUnwrap(
            controller.tableView(table, viewFor: selectionColumn, row: 1) as? ContainerSelectionCellView
        )
        selectionCell.selectionButton.state = .on
        selectionCell.selectionButton.sendAction(selectionCell.selectionButton.action, to: selectionCell.selectionButton.target)
        XCTAssertEqual(controller.checkedContainerIDs, ["worker"])
        XCTAssertNil(controller.detailViewController)

        let actionsColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "container-actions" })
        let actionCell = try XCTUnwrap(
            controller.tableView(table, viewFor: actionsColumn, row: 0) as? ContainerActionsCellView
        )
        actionCell.primaryButton.sendAction(actionCell.primaryButton.action, to: actionCell.primaryButton.target)
        await waitUntil {
            await runner.recordedCommands().contains(["stop", "web"])
        }
        XCTAssertEqual(controller.checkedContainerIDs, ["worker"])
        XCTAssertNil(controller.detailViewController)

        let nameColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "name" })
        let nameCell = try XCTUnwrap(
            controller.tableView(table, viewFor: nameColumn, row: 1) as? ContainerNameLinkCellView
        )
        nameCell.linkButton.sendAction(nameCell.linkButton.action, to: nameCell.linkButton.target)
        XCTAssertEqual(controller.detailViewController?.representedItemID, "worker")

        controller.showCollection()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.keyDown(with: try keyEvent("\r", keyCode: 36, window: window))
        XCTAssertEqual(controller.detailViewController?.representedItemID, "worker")
    }

    func testControlColumnsRemainUsableAtConstrainedWidth() async throws {
        let controller = controller(runner: mixedRunner())
        let window = host(controller, size: NSSize(width: 620, height: 520))
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 2 }
        controller.view.layoutSubtreeIfNeeded()

        let selection = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "container-selection" })
        let actions = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "container-actions" })
        XCTAssertEqual(selection.width, 34)
        XCTAssertEqual(actions.width, 96)
        XCTAssertTrue(table.enclosingScrollView?.hasHorizontalScroller == true)
        let cell = try XCTUnwrap(
            controller.tableView(table, viewFor: actions, row: 0) as? ContainerActionsCellView
        )
        cell.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(cell.primaryButton.frame.height, 24)
        XCTAssertEqual(cell.moreButton.accessibilityLabel(), "More actions for container web")
        XCTAssertEqual(cell.deleteButton.accessibilityLabel(), "Delete container web")
    }

    func testBulkStartAndStopUseOnlyEligibleMixedStateTargets() async throws {
        let runner = mixedRunner()
        var snapshots: [InspectorSnapshot] = []
        let controller = controller(runner: runner) { snapshots.append($0) }
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)

        controller.runCheckedContainerBatch(.start)
        controller.runCheckedContainerBatch(.start)
        await waitUntil { !controller.isBatchRunning && snapshots.last?.subtitle == "Succeeded" }
        var commands = await runner.recordedCommands()
        XCTAssertEqual(commands.filter { $0.first == "start" }, [["start", "worker"]])
        XCTAssertEqual(controller.checkedContainerIDs, ["web", "worker"])

        controller.runCheckedContainerBatch(.stop)
        await waitUntil {
            let commands = await runner.recordedCommands()
            return !controller.isBatchRunning && commands.contains(["stop", "web"])
        }
        commands = await runner.recordedCommands()
        XCTAssertEqual(commands.filter { $0.first == "stop" }, [["stop", "web"]])
        XCTAssertFalse(commands.contains(["start", "web"]))
        XCTAssertFalse(commands.contains(["stop", "worker"]))
    }

    func testBulkForceDeleteRequiresConfirmationAndCancelHasNoSideEffects() async throws {
        let runner = mixedRunner()
        var confirmations: [(names: [String], force: Bool)] = []
        let controller = controller(
            runner: runner,
            batchDeleteConfirmation: { items, force in
                confirmations.append((items.map(\.title), force))
                return false
            }
        )
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)

        controller.runCheckedContainerBatch(.delete)

        XCTAssertEqual(confirmations.count, 1)
        XCTAssertEqual(confirmations.first?.names, ["web", "worker"])
        XCTAssertEqual(confirmations.first?.force, true)
        XCTAssertFalse(controller.isBatchRunning)
        let commands = await runner.recordedCommands()
        XCTAssertTrue(commands.allSatisfy { $0.first != "delete" })
        XCTAssertEqual(controller.checkedContainerIDs, ["web", "worker"])
    }

    func testConfirmedForceDeleteUsesExactCommandAndClearsSuccessfulSelection() async throws {
        let runner = mixedRunner()
        var confirmedForce: Bool?
        let controller = controller(
            runner: runner,
            batchDeleteConfirmation: { _, force in
                confirmedForce = force
                return true
            }
        )
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)

        controller.runCheckedContainerBatch(.delete)
        await waitUntil { !controller.isBatchRunning && controller.checkedContainerIDs.isEmpty }

        let commands = await runner.recordedCommands()
        XCTAssertEqual(confirmedForce, true)
        XCTAssertEqual(
            commands.filter { $0.first == "delete" },
            [["delete", "--force", "web", "worker"]]
        )
    }

    func testFailedBatchKeepsTargetsSelectedAndRefreshesOnlyOnce() async throws {
        let worker = ResourceFixtures.container
            .replacingOccurrences(of: "\"web\"", with: "\"worker\"")
            .replacingOccurrences(of: "\"running\"", with: "\"stopped\"")
        let runner = ContainerListBatchRunner(
            containers: "[\(ResourceFixtures.container),\(worker)]",
            operationExitCode: 9
        )
        var snapshots: [InspectorSnapshot] = []
        let controller = controller(
            runner: runner,
            onInspectorUpdate: { snapshots.append($0) },
            batchDeleteConfirmation: { _, _ in true }
        )
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)

        controller.runCheckedContainerBatch(.delete)
        await waitUntil { !controller.isBatchRunning && snapshots.last?.subtitle == "Failed" }
        await waitUntil { await runner.listCount == 2 }

        let listCount = await runner.listCount
        let commands = await runner.recordedCommands()
        XCTAssertEqual(controller.checkedContainerIDs, ["web", "worker"])
        XCTAssertEqual(listCount, 2)
        XCTAssertEqual(
            commands.filter { $0.first == "delete" },
            [["delete", "--force", "web", "worker"]]
        )
        XCTAssertTrue(snapshots.last?.detail?.contains("Failed to delete 2 containers") == true)
    }

    func testPartialStartFailureContinuesAndKeepsRetryableSelection() async throws {
        let first = ResourceFixtures.container.replacingOccurrences(of: "\"running\"", with: "\"stopped\"")
        let second = first.replacingOccurrences(of: "\"web\"", with: "\"worker\"")
        let runner = ContainerPartialStartRunner(containers: "[\(first),\(second)]")
        var snapshots: [InspectorSnapshot] = []
        let controller = controller(runner: runner) { snapshots.append($0) }
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)

        controller.runCheckedContainerBatch(.start)
        await waitUntil { !controller.isBatchRunning && snapshots.last?.subtitle == "Failed" }
        await waitUntil { await runner.listCount == 2 }

        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.filter { $0.first == "start" }, [["start", "web"], ["start", "worker"]])
        XCTAssertEqual(controller.checkedContainerIDs, ["web", "worker"])
        XCTAssertTrue(snapshots.last?.detail?.contains("Failed to start 1 of 2 containers") == true)
        XCTAssertTrue(snapshots.last?.detail?.contains("worker failed to start") == true)
    }

    func testContainerSelectionAppearanceSnapshots() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(620), 1_120] {
                let controller = controller(runner: mixedRunner())
                let window = host(controller, size: NSSize(width: width, height: 560))
                defer { controller.suspendInspection(); window.close() }
                controller.view.appearance = NSAppearance(named: appearance)
                let table = try XCTUnwrap(controller.view.containerListDescendants(of: ResourceTableView.self).first)
                await waitUntil { table.numberOfRows == 2 }
                table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
                controller.view.layoutSubtreeIfNeeded()
                controller.view.displayIfNeeded()

                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                let image = NSImage(size: controller.view.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Container selection \(appearance.rawValue) width \(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func controller(
        runner: ProcessRunning,
        onInspectorUpdate: @escaping @MainActor (InspectorSnapshot) -> Void = { _ in },
        batchDeleteConfirmation: (@MainActor ([ResourceListItem], Bool) -> Bool)? = nil
    ) -> ResourceListViewController {
        ResourceListViewController(
            kind: .containers,
            service: ResourceFixtures.service(runner: runner),
            operationService: ResourceFixtures.operations(runner: runner),
            onInspectorUpdate: onInspectorUpdate,
            batchDeleteConfirmation: batchDeleteConfirmation
        )
    }

    private actor ContainerListBatchRunner: ProcessRunning {
        let containers: String
        let operationExitCode: Int32
        private(set) var listCount = 0
        private var commands: [[String]] = []

        init(containers: String, operationExitCode: Int32) {
            self.containers = containers
            self.operationExitCode = operationExitCode
        }

        func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
            commands.append(command.arguments)
            if command.arguments.first == "list" {
                listCount += 1
                return CLIProcessResult(preview: command.preview, exitCode: 0, stdout: containers, stderr: "")
            }
            if command.arguments.first == "delete" {
                return CLIProcessResult(
                    preview: command.preview,
                    exitCode: operationExitCode,
                    stdout: "",
                    stderr: operationExitCode == 0 ? "" : "batch delete failed"
                )
            }
            return CLIProcessResult(preview: command.preview, exitCode: 0, stdout: "", stderr: "")
        }

        func recordedCommands() -> [[String]] {
            commands
        }
    }

    private actor ContainerPartialStartRunner: ProcessRunning {
        let containers: String
        private(set) var listCount = 0
        private var commands: [[String]] = []

        init(containers: String) {
            self.containers = containers
        }

        func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
            commands.append(command.arguments)
            if command.arguments.first == "list" {
                listCount += 1
                return CLIProcessResult(preview: command.preview, exitCode: 0, stdout: containers, stderr: "")
            }
            if command.arguments == ["start", "worker"] {
                return CLIProcessResult(
                    preview: command.preview,
                    exitCode: 9,
                    stdout: "",
                    stderr: "worker failed to start"
                )
            }
            return CLIProcessResult(preview: command.preview, exitCode: 0, stdout: "started", stderr: "")
        }

        func recordedCommands() -> [[String]] {
            commands
        }
    }

    private func mixedRunner() -> ResourceFixtureRunner {
        let worker = ResourceFixtures.container
            .replacingOccurrences(of: "\"web\"", with: "\"worker\"")
            .replacingOccurrences(of: "\"running\"", with: "\"stopped\"")
        return ResourceFixtureRunner(containers: "[\(ResourceFixtures.container),\(worker)]")
    }

    private func host(
        _ controller: NSViewController,
        size: NSSize = NSSize(width: 1_120, height: 720)
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func toolbarControls(in view: NSView) -> [String] {
        toolbarControlMap(in: view).keys.sorted()
    }

    private func toolbarControlMap(in view: NSView) -> [String: NSControl] {
        let controls = view.containerListDescendants(of: NSControl.self).filter {
            ["Run", "Create", "Start", "Stop", "Delete", "Clear"].contains($0.accessibilityLabel() ?? "")
        }
        return Dictionary(uniqueKeysWithValues: controls.compactMap { control in
            control.accessibilityLabel().map { ($0, control) }
        })
    }

    private func keyEvent(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<150 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected container-list state was not reached")
    }
}

private extension NSView {
    func containerListDescendants<T: NSView>(of type: T.Type) -> [T] {
        let own = (self as? T).map { [$0] } ?? []
        return own + subviews.flatMap { $0.containerListDescendants(of: type) }
    }

    func firstContainerListTextField(with text: String) -> NSTextField? {
        containerListDescendants(of: NSTextField.self).first { $0.stringValue == text }
    }
}
