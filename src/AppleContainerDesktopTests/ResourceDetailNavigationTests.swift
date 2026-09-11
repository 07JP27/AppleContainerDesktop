import AppKit
import XCTest
@testable import AppleContainerDesktop

@MainActor
final class ResourceDetailNavigationTests: XCTestCase {
    func testPassiveSelectionKeepsComparableListFullWidth() async throws {
        var snapshots: [InspectorSnapshot] = []
        let controller = resourceController(.containers, runner: ResourceFixtureRunner()) {
            snapshots.append($0)
        }
        let window = host(controller, size: NSSize(width: 1_100, height: 720))
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.detailDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 1 }

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await Task.yield()

        XCTAssertNil(controller.detailViewController)
        XCTAssertTrue(snapshots.allSatisfy { $0.overview == nil })
        let requiredWidth = table.tableColumns.reduce(CGFloat.zero) { $0 + $1.width }
        XCTAssertGreaterThanOrEqual(table.enclosingScrollView?.contentView.bounds.width ?? 0, requiredWidth)
        let listActions = controller.view.detailDescendants(of: ToolbarActionButton.self)
            .compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(listActions.contains("Start"))
        XCTAssertTrue(listActions.contains("Stop"))
        XCTAssertFalse(listActions.contains("Run"))
        XCTAssertFalse(listActions.contains("Create"))
    }

    func testClickAndReturnOpenDetailsButInteractiveCellsDoNot() async throws {
        let controller = resourceController(.containers, runner: ResourceFixtureRunner())
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.detailDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 1 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        controller.activateResourceRow(0, interactiveControl: true)
        XCTAssertNil(controller.detailViewController)

        controller.activateResourceRow(0)
        XCTAssertEqual(controller.detailViewController?.representedItemID, "web")
        XCTAssertNotNil(controller.view.firstDetailTextField(with: "Overview"))
        XCTAssertNil(controller.view.firstDetailTextField(with: "Container overview"))
        let detailActions = controller.detailViewController?.view
            .detailDescendants(of: ToolbarActionButton.self)
            .compactMap { $0.accessibilityLabel() } ?? []
        XCTAssertTrue(detailActions.contains("Stop"))
        XCTAssertTrue(detailActions.contains("Logs"))
        XCTAssertTrue(detailActions.contains("Exec"))
        XCTAssertFalse(detailActions.contains("Run"))

        controller.showCollection()
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
        table.keyDown(with: event)
        XCTAssertEqual(controller.detailViewController?.representedItemID, "web")
    }

    func testAllDockerComparableCollectionsOpenDedicatedDetails() async throws {
        let volumeJSON = """
        [{"id":"project-data","configuration":{"name":"project-data","driver":"local","format":"ext4",
          "source":"/private/project-data.img","creationDate":"2026-09-01T00:00:00Z",
          "labels":{},"options":{},"sizeInBytes":536870912}}]
        """
        let cases: [(ResourceKind, ResourceFixtureRunner, String, String)] = [
            (.containers, ResourceFixtureRunner(), "web", "Container"),
            (.images, ResourceFixtureRunner(), "registry.example:5000/team/web:dev", "Image"),
            (
                .volumes,
                ResourceFixtureRunner(containers: "[]", fallbackJSON: volumeJSON),
                "project-data",
                "Volume"
            )
        ]

        for (kind, runner, expectedID, expectedObjectName) in cases {
            let controller = resourceController(kind, runner: runner)
            let window = host(controller)
            defer { controller.suspendInspection(); window.close() }
            let table = try XCTUnwrap(controller.view.detailDescendants(of: ResourceTableView.self).first)
            await waitUntil { table.numberOfRows == 1 }

            controller.activateResourceRow(0)

            await waitUntil { controller.detailViewController?.representedItemID == expectedID }
            XCTAssertTrue(
                controller.detailViewController?.view.detailDescendants(of: NSScrollView.self).contains {
                    $0.accessibilityLabel() == "\(expectedObjectName) details"
                } == true
            )
        }
    }

    func testBackPreservesSearchSortSelectionAndScrollPosition() async throws {
        let containers = (0..<30).map { index in
            ResourceFixtures.container.replacingOccurrences(of: "\"web\"", with: "\"web-\(index)\"")
        }.joined(separator: ",")
        let controller = resourceController(
            .containers,
            runner: ResourceFixtureRunner(containers: "[\(containers)]")
        )
        let window = host(controller, size: NSSize(width: 1_000, height: 480))
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.detailDescendants(of: ResourceTableView.self).first)
        let search = try XCTUnwrap(controller.view.detailDescendants(of: NSSearchField.self).first)
        await waitUntil { table.numberOfRows == 30 }

        table.sortDescriptors = [NSSortDescriptor(key: ResourceListColumn.name.rawValue, ascending: false)]
        table.selectRowIndexes(IndexSet(integer: 20), byExtendingSelection: false)
        table.scrollRowToVisible(20)
        controller.view.layoutSubtreeIfNeeded()
        let selectedID = table.selectedRow
        let scrollOrigin = table.enclosingScrollView?.contentView.bounds.origin
        search.stringValue = "web"
        search.sendAction(search.action, to: search.target)

        controller.openSelectedResourceDetails()
        let back = try XCTUnwrap(
            controller.view.detailDescendants(of: NSButton.self).first {
                $0.accessibilityLabel() == "Back to Containers"
            }
        )
        back.sendAction(back.action, to: back.target)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertNil(controller.detailViewController)
        XCTAssertEqual(search.stringValue, "web")
        XCTAssertEqual(table.sortDescriptors.first?.key, ResourceListColumn.name.rawValue)
        XCTAssertEqual(table.sortDescriptors.first?.ascending, false)
        XCTAssertEqual(table.selectedRow, selectedID)
        XCTAssertEqual(table.enclosingScrollView?.contentView.bounds.origin, scrollOrigin)
        XCTAssertTrue(window.firstResponder === table)
    }

    func testCommandFFromDetailsReturnsToCollectionSearch() async throws {
        let controller = resourceController(.images, runner: ResourceFixtureRunner())
        let window = host(controller)
        defer { controller.suspendInspection(); window.close() }
        let table = try XCTUnwrap(controller.view.detailDescendants(of: ResourceTableView.self).first)
        let search = try XCTUnwrap(controller.view.detailDescendants(of: NSSearchField.self).first)
        await waitUntil { table.numberOfRows == 1 }
        controller.openSelectedResourceDetails()

        controller.focusSearch()

        XCTAssertNil(controller.detailViewController)
        XCTAssertTrue(window.firstResponder === search.currentEditor())
    }

    func testSidebarRoundTripReturnsToCollectionRatherThanStaleDetails() async throws {
        let runner = ResourceFixtureRunner()
        let shell = AppShellViewController(
            systemService: SystemService(
                preferences: NavigationPreferences(),
                resolver: navigationResolver,
                runner: runner
            ),
            resourceService: ResourceFixtures.service(runner: runner),
            operationService: ResourceFixtures.operations(runner: runner)
        )
        let window = host(shell, size: NSSize(width: 1_120, height: 720))
        defer {
            (shell.currentContentViewController as? ResourceListViewController)?.suspendInspection()
            window.contentViewController = nil
            window.close()
        }
        let containers = try await currentResourceController(in: shell, kind: .containers)
        let table = try XCTUnwrap(containers.view.detailDescendants(of: ResourceTableView.self).first)
        await waitUntil { table.numberOfRows == 1 }
        shell.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(
            table.enclosingScrollView?.contentView.bounds.width ?? 0,
            table.tableColumns.reduce(CGFloat.zero) { $0 + $1.width }
        )
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        containers.openSelectedResourceDetails()
        XCTAssertNotNil(containers.detailViewController)

        shell.showImages()
        shell.showContainers()

        XCTAssertTrue(shell.currentContentViewController === containers)
        XCTAssertNil(containers.detailViewController)
        XCTAssertFalse(shell.isInspectorVisible)
    }

    func testDedicatedDetailUsesReadableMeasureAtCompactAndWideWidths() async throws {
        for width in [CGFloat(620), 1_400] {
            let controller = resourceController(.containers, runner: ResourceFixtureRunner())
            let window = host(controller, size: NSSize(width: width, height: 720))
            defer { controller.suspendInspection(); window.close() }
            let table = try XCTUnwrap(controller.view.detailDescendants(of: ResourceTableView.self).first)
            await waitUntil { table.numberOfRows == 1 }
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            controller.openSelectedResourceDetails()
            await waitUntil {
                controller.view.firstDetailTextField(with: "Connections") != nil
                    && !controller.view.detailDescendants(of: NSTextField.self).contains {
                        $0.stringValue == "Refreshing details..."
                    }
            }
            controller.view.layoutSubtreeIfNeeded()
            let detail = try XCTUnwrap(controller.detailViewController)
            let overview = try XCTUnwrap(detail.view.detailDescendants(of: ResourceOverviewView.self).first)
            XCTAssertLessThanOrEqual(overview.frame.width, 760)
            XCTAssertGreaterThan(overview.frame.width, 400)
            XCTAssertNotNil(detail.view.firstDetailTextField(with: "Open 127.0.0.1:8080") ?? detail.view.firstDetailTextField(with: "Connections"))
        }
    }

    func testDedicatedDetailAppearanceSnapshots() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(620), 1_100] {
                let controller = resourceController(.containers, runner: ResourceFixtureRunner())
                let window = host(controller, size: NSSize(width: width, height: 720))
                defer { controller.suspendInspection(); window.close() }
                controller.view.appearance = NSAppearance(named: appearance)
                let table = try XCTUnwrap(controller.view.detailDescendants(of: ResourceTableView.self).first)
                await waitUntil { table.numberOfRows == 1 }
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                controller.openSelectedResourceDetails()
                await waitUntil {
                    controller.view.firstDetailTextField(with: "Connections") != nil
                        && !controller.view.detailDescendants(of: NSTextField.self).contains {
                            $0.stringValue == "Refreshing details..."
                        }
                }
                controller.view.layoutSubtreeIfNeeded()
                controller.view.displayIfNeeded()
                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                let image = NSImage(size: controller.view.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Container details \(appearance.rawValue) width \(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func resourceController(
        _ kind: ResourceKind,
        runner: ProcessRunning,
        onInspectorUpdate: @escaping @MainActor (InspectorSnapshot) -> Void = { _ in }
    ) -> ResourceListViewController {
        ResourceListViewController(
            kind: kind,
            service: ResourceFixtures.service(runner: runner),
            operationService: ResourceFixtures.operations(runner: runner),
            onInspectorUpdate: onInspectorUpdate
        )
    }

    private func host(_ controller: NSViewController, size: NSSize = NSSize(width: 1_100, height: 720)) -> NSWindow {
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

    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<120 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected resource navigation state was not reached")
    }

    private func currentResourceController(
        in shell: AppShellViewController,
        kind: ResourceKind
    ) async throws -> ResourceListViewController {
        await waitUntil {
            shell.currentContentViewController is ResourceListViewController
                && shell.selectedItem.resourceKind == kind
        }
        return try XCTUnwrap(shell.currentContentViewController as? ResourceListViewController)
    }
}

private let navigationResolver = ContainerCLIResolver(
    fileSystem: NavigationFileSystem(),
    environment: CLIResolverEnvironment(path: nil),
    knownPaths: ["/fake/container"]
)

private final class NavigationPreferences: AppPreferences, @unchecked Sendable {
    var cliExecutablePath: String?
}

private struct NavigationFileSystem: FileSystemChecking {
    func isExecutableFile(atPath path: String) -> Bool { path == "/fake/container" }
}

private extension NSView {
    func detailDescendants<T: NSView>(of type: T.Type) -> [T] {
        let own = (self as? T).map { [$0] } ?? []
        return own + subviews.flatMap { $0.detailDescendants(of: type) }
    }

    func firstDetailTextField(with text: String) -> NSTextField? {
        detailDescendants(of: NSTextField.self).first { $0.stringValue == text }
    }
}
