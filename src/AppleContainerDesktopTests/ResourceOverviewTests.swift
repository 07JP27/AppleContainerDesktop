import AppKit
import XCTest
@testable import AppleContainerDesktop

@MainActor
final class ResourceOverviewTests: XCTestCase {
    func testContainerOverviewShowsMeaningfulValuesNotRawJSONOrSecrets() throws {
        let item = try ResourceFixtures.row(ResourceFixtures.container, kind: .containers)
        let snapshot = InspectorSnapshot.resource(item)
        let overview = try XCTUnwrap(snapshot.overview)
        XCTAssertNil(snapshot.json)
        XCTAssertNil(snapshot.command)
        XCTAssertNil(snapshot.detail)
        let values = overview.sections.flatMap(\.fields).map(\.value).joined(separator: "\n")
        let labels = overview.sections.flatMap(\.fields).map(\.label)
        XCTAssertTrue(values.contains("127.0.0.1:8080 -> 80/tcp"))
        XCTAssertTrue(values.contains("site-data"))
        XCTAssertTrue(values.contains("Read-only"))
        XCTAssertTrue(values.contains("/bin/sh -c 'echo ready'"))
        XCTAssertFalse(values.contains("/private/volume.img"))
        XCTAssertFalse(values.contains("private-value"))
        XCTAssertFalse(values.contains("\"configuration\""))
        XCTAssertTrue(labels.contains("Allocated CPUs"))
        XCTAssertTrue(labels.contains("Memory limit"))
        XCTAssertFalse(labels.contains("CPU usage"))
    }

    func testImageOverviewShowsPlatformsAndStoppedContainerUsage() throws {
        var item = try ResourceFixtures.row(ResourceFixtures.image, kind: .images)
        item.setImageUsage(.known([ImageContainerUsage(id: "worker", name: "worker", state: "stopped")]))
        let overview = try XCTUnwrap(ResourceOverview(item: item))
        let fields = overview.sections.flatMap(\.fields)
        XCTAssertTrue(fields.contains { $0.label == "linux/arm64" })
        XCTAssertTrue(fields.contains { $0.label == "linux/amd64" })
        XCTAssertFalse(fields.contains { $0.label == "unknown/unknown" })
        XCTAssertTrue(fields.contains { $0.label == "worker" && $0.value == "Stopped" })
        XCTAssertTrue(fields.contains { $0.label == "Digest" && $0.value == "sha256:index" })
        XCTAssertFalse(fields.contains { $0.label == "Image ID" })
    }

    func testOverviewViewHasReadableSelectableFieldsAndNoJSONControls() throws {
        let overview = try XCTUnwrap(ResourceOverview(item: ResourceFixtures.row(ResourceFixtures.container, kind: .containers)))
        var openedURLs: [URL] = []
        let view = ResourceOverviewView(overview: overview) { openedURLs.append($0) }
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 1_800)
        view.layoutSubtreeIfNeeded()
        let labels = view.descendants(of: NSTextField.self)
        let buttons = view.descendants(of: ResourceAccessLinkButton.self)
        let contentLabels = labels.filter { label in
            !buttons.contains { label.isDescendant(of: $0) }
        }
        XCTAssertTrue(labels.contains { $0.stringValue == "Connections" })
        XCTAssertTrue(labels.contains { $0.stringValue == "Storage" })
        XCTAssertTrue(contentLabels.allSatisfy(\.isSelectable))
        XCTAssertFalse(labels.contains { $0.stringValue == "JSON" || $0.stringValue == "Command" })
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(buttons.first?.title, "Open 127.0.0.1:8080")
        buttons.first?.performClick(nil)
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["http://127.0.0.1:8080/"])
    }

    func testPortTableCellOpensThePublishedHostPort() async throws {
        let runner = ResourceFixtureRunner()
        var openedURLs: [URL] = []
        let controller = ResourceListViewController(
            kind: .containers,
            service: ResourceFixtures.service(runner: runner),
            operationService: ResourceFixtures.operations(runner: runner),
            openURL: { openedURLs.append($0) },
            onInspectorUpdate: { _ in }
        )
        controller.loadViewIfNeeded()
        let table = try XCTUnwrap(controller.view.descendants(of: NSTableView.self).first)
        await waitUntil { table.numberOfRows == 1 }
        let column = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == ResourceListColumn.ports.rawValue })
        let cell = try XCTUnwrap(controller.tableView(table, viewFor: column, row: 0) as? ResourceAccessTableCellView)
        let button = try XCTUnwrap(cell.descendants(of: NSButton.self).first)
        XCTAssertEqual(button.title, "127.0.0.1:8080")
        button.performClick(nil)
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["http://127.0.0.1:8080/"])
        XCTAssertNil(controller.detailViewController)
        controller.suspendInspection()
    }

    func testPublishedPortLinkAppearanceSnapshots() throws {
        let overview = try XCTUnwrap(ResourceOverview(item: ResourceFixtures.row(ResourceFixtures.container, kind: .containers)))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let root = ThemedContainerView(backgroundColor: AppColors.surface)
            root.appearance = NSAppearance(named: appearance)
            root.frame = NSRect(x: 0, y: 0, width: 360, height: 940)
            let overviewView = ResourceOverviewView(overview: overview, openURL: { _ in })
            overviewView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(overviewView)
            NSLayoutConstraint.activate([
                overviewView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: AppSpacing.xl),
                overviewView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -AppSpacing.xl),
                overviewView.topAnchor.constraint(equalTo: root.topAnchor, constant: AppSpacing.xl)
            ])
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let image = NSImage(size: root.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Container published port link \(appearance.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testActualTablesUseTheirColumnsAndNeverFlashJSONOnSelection() async throws {
        for kind in [ResourceKind.containers, .images] {
            let runner = ResourceFixtureRunner()
            var snapshots: [InspectorSnapshot] = []
            let controller = controller(kind, runner: runner) { snapshots.append($0) }
            controller.view.frame = NSRect(x: 0, y: 0, width: 480, height: 720)
            controller.loadViewIfNeeded()
            let table = try XCTUnwrap(controller.view.descendants(of: NSTableView.self).first)
            await waitUntil { table.numberOfRows == 1 }
            let expectedTitles = kind == .containers
                ? [""] + ResourceListColumn.columns(for: kind).map(\.title) + ["Actions"]
                : ResourceListColumn.columns(for: kind).map(\.title)
            XCTAssertEqual(table.tableColumns.map(\.title), expectedTitles)
            XCTAssertEqual(table.numberOfRows, 1)
            XCTAssertTrue(table.enclosingScrollView?.hasHorizontalScroller == true)
            XCTAssertTrue(snapshots.allSatisfy { $0.json == nil && $0.command == nil })
            let nameColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == ResourceListColumn.name.rawValue })
            if kind == .containers {
                let cell = try XCTUnwrap(controller.tableView(table, viewFor: nameColumn, row: 0) as? ContainerNameLinkCellView)
                XCTAssertEqual(cell.linkButton.title, "web")
            } else {
                let cell = try XCTUnwrap(controller.tableView(table, viewFor: nameColumn, row: 0) as? NSTableCellView)
                XCTAssertEqual(cell.textField?.stringValue, "registry.example:5000/team/web")
            }
            XCTAssertNil(controller.detailViewController)
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            controller.openSelectedResourceDetails()
            await waitUntil { controller.detailViewController != nil }
            XCTAssertTrue(snapshots.allSatisfy { $0.overview == nil })
            controller.suspendInspection()
        }
    }

    func testSortingAndFilteringPreserveTheSelectedIdentity() async throws {
        let worker = ResourceFixtures.container.replacingOccurrences(of: "\"web\"", with: "\"worker\"")
        let runner = ResourceFixtureRunner(containers: "[\(ResourceFixtures.container),\(worker)]")
        var snapshots: [InspectorSnapshot] = []
        let controller = controller(.containers, runner: runner) { snapshots.append($0) }
        controller.loadViewIfNeeded()
        let table = try XCTUnwrap(controller.view.descendants(of: NSTableView.self).first)
        await waitUntil { table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.sortDescriptors = [NSSortDescriptor(key: ResourceListColumn.name.rawValue, ascending: false)]
        XCTAssertEqual(table.selectedRow, 0)
        let search = try XCTUnwrap(controller.view.descendants(of: NSSearchField.self).first)
        search.stringValue = "worker"
        search.sendAction(search.action, to: search.target)
        XCTAssertEqual(table.numberOfRows, 1)
        let nameColumn = try XCTUnwrap(table.tableColumns.first {
            $0.identifier.rawValue == ResourceListColumn.name.rawValue
        })
        let name = try XCTUnwrap(controller.tableView(table, viewFor: nameColumn, row: 0) as? ContainerNameLinkCellView)
        XCTAssertEqual(name.linkButton.title, "worker")
        XCTAssertTrue(snapshots.allSatisfy { $0.overview == nil })
        controller.suspendInspection()
    }

    func testInspectFailureKeepsReadableSummaryWithWarning() async {
        let controller = controller(.containers, runner: ResourceFixtureRunner(inspectExitCode: 1)) { _ in }
        controller.loadViewIfNeeded()
        let table = controller.view.descendants(of: NSTableView.self).first
        await waitUntil { table?.numberOfRows == 1 }
        table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.openSelectedResourceDetails()
        await waitUntil {
            controller.detailViewController?.view.descendants(of: NSTextField.self).contains {
                $0.stringValue.localizedCaseInsensitiveContains("could not refresh details")
            } == true
        }
        let labels = controller.detailViewController?.view.descendants(of: NSTextField.self) ?? []
        XCTAssertTrue(labels.contains { $0.stringValue == "web" })
        XCTAssertFalse(labels.contains { $0.stringValue == "JSON" })
        controller.suspendInspection()
    }

    func testOtherResourceInspectorsKeepTheirExistingPresentation() async {
        var snapshots: [InspectorSnapshot] = []
        let runner = ResourceFixtureRunner(fallbackJSON: #"[{"name":"bridge","status":"active"}]"#)
        let controller = controller(.networks, runner: runner) { snapshots.append($0) }
        controller.loadViewIfNeeded()
        await waitUntil { snapshots.last?.json != nil }
        XCTAssertNil(snapshots.last?.overview)
        XCTAssertNotNil(snapshots.last?.command)
        controller.suspendInspection()
    }

    func testOlderInspectCannotOverwriteANewerSelection() async throws {
        let runner = DelayedInspectionRunner()
        var snapshots: [InspectorSnapshot] = []
        let controller = controller(.containers, runner: runner) { snapshots.append($0) }
        controller.loadViewIfNeeded()
        let table = try XCTUnwrap(controller.view.descendants(of: NSTableView.self).first)
        await waitUntil { table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.openSelectedResourceDetails()
        await waitForInspection("web", runner: runner)
        controller.showCollection()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.openSelectedResourceDetails()
        await waitForInspection("worker", runner: runner)
        await runner.resolve("worker")
        await waitUntil { controller.detailViewController?.representedItemID == "worker" }
        await runner.resolve("web")
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(controller.detailViewController?.representedItemID, "worker")
        XCTAssertTrue(controller.detailViewController?.view.descendants(of: NSTextField.self).contains {
            $0.stringValue == "worker"
        } == true)
        XCTAssertTrue(snapshots.allSatisfy { $0.json == nil })
        controller.suspendInspection()
    }

    func testOlderInspectCannotReplaceLogsOrReopenASuspendedInspector() async throws {
        let runner = DelayedInspectionRunner()
        var snapshots: [InspectorSnapshot] = []
        let controller = controller(.containers, runner: runner) { snapshots.append($0) }
        controller.loadViewIfNeeded()
        let table = controller.view.descendants(of: NSTableView.self).first
        await waitUntil { table?.numberOfRows == 2 }
        table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.openSelectedResourceDetails()
        await waitForInspection("web", runner: runner)
        controller.showSelectedContainerLogs()
        await waitUntil { snapshots.last?.detail == "log line" }
        await runner.resolve("web")
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(snapshots.last?.title, "Logs")
        XCTAssertNil(snapshots.last?.overview)
        controller.reloadContent()
        await waitForInspection("web", runner: runner)
        controller.suspendInspection()
        let count = snapshots.count
        await runner.resolve("web")
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(snapshots.count, count)
    }

    private func controller(_ kind: ResourceKind, runner: ProcessRunning, onUpdate: @escaping @MainActor (InspectorSnapshot) -> Void) -> ResourceListViewController {
        ResourceListViewController(kind: kind, service: ResourceFixtures.service(runner: runner), operationService: ResourceFixtures.operations(runner: runner), onInspectorUpdate: onUpdate)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Expected UI state was not reached")
    }

    private func waitForInspection(_ name: String, runner: DelayedInspectionRunner) async {
        for _ in 0..<100 {
            if await runner.hasPending(name) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Inspect request was not started for \(name)")
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        let matches = (self as? T).map { [$0] } ?? []
        return matches + subviews.flatMap { $0.descendants(of: type) }
    }
}

private actor DelayedInspectionRunner: ProcessRunning {
    private struct Pending {
        var command: ProcessCommand
        var continuation: CheckedContinuation<CLIProcessResult, Never>
    }

    private var pending: [String: [Pending]] = [:]

    func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
        if command.arguments.first == "inspect", let name = command.arguments.last {
            return await withCheckedContinuation { continuation in
                pending[name, default: []].append(Pending(command: command, continuation: continuation))
            }
        }
        let worker = ResourceFixtures.container.replacingOccurrences(of: "\"web\"", with: "\"worker\"")
        let output = command.arguments.first == "logs" ? "log line" : "[\(ResourceFixtures.container),\(worker)]"
        return CLIProcessResult(preview: command.preview, exitCode: 0, stdout: output, stderr: "")
    }

    func hasPending(_ name: String) -> Bool { pending[name]?.isEmpty == false }

    func resolve(_ name: String) {
        let output = ResourceFixtures.container.replacingOccurrences(of: "\"web\"", with: "\"\(name)\"")
        for request in pending.removeValue(forKey: name) ?? [] {
            request.continuation.resume(returning: CLIProcessResult(preview: request.command.preview, exitCode: 0, stdout: "[\(output)]", stderr: ""))
        }
    }
}
