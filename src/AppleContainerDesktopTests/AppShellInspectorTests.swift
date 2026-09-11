import AppKit
import XCTest
@testable import AppleContainerDesktop

@MainActor
final class AppShellInspectorTests: XCTestCase {
    func testComparableResourceOverviewCannotOpenPassiveInspector() throws {
        let shell = makeShell()
        let window = host(shell)
        defer { release(window) }
        let item = try ResourceFixtures.row(ResourceFixtures.container, kind: .containers)

        shell.updateInspector(.resource(item), from: .containers)

        XCTAssertFalse(shell.isInspectorVisible)
        XCTAssertNil(shell.view.inspectorTextField(with: "Container overview"))
    }

    func testAppleSpecificInspectStillOpensAndClosesWithoutKeepingTheNarrowWidth() {
        let shell = makeShell()
        let window = host(shell)
        defer { release(window) }
        shell.showNetworks()
        shell.view.layoutSubtreeIfNeeded()

        shell.updateInspector(
            InspectorSnapshot(
                title: "default",
                subtitle: "active",
                command: CLICommandPreview(executable: "container", arguments: ["network", "inspect", "default"]),
                detail: nil,
                json: #"{"name":"default"}"#
            ),
            from: .networks
        )
        shell.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(shell.isInspectorVisible)
        XCTAssertEqual(shell.inspectorWidth, 320)

        XCTAssertNotNil(shell.view.inspectorDescendants(of: NSButton.self).first {
            $0.accessibilityLabel() == "Close inspector"
        })
        shell.closeInspector()
        shell.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(shell.isInspectorVisible)
        XCTAssertEqual(shell.inspectorWidth, 0)
    }

    func testClosingRunningOperationSuppressesItsStreamButNotTheNextOperation() {
        let shell = makeShell()
        let window = host(shell)
        defer { release(window) }
        let command = CLICommandPreview(executable: "container", arguments: ["logs", "web"])
        let running = InspectorSnapshot(title: "Logs", subtitle: "Running...", command: command, detail: "first", json: nil)

        shell.updateInspector(running, from: .containers)
        XCTAssertTrue(shell.isInspectorVisible)
        shell.closeInspector()
        XCTAssertFalse(shell.isInspectorVisible)

        shell.updateInspector(
            InspectorSnapshot(title: "Logs", subtitle: "Running...", command: command, detail: "second", json: nil),
            from: .containers
        )
        shell.updateInspector(
            InspectorSnapshot(
                title: "Logs",
                subtitle: "Succeeded",
                command: CLICommandPreview(executable: "/usr/local/bin/container", arguments: ["logs", "web"]),
                detail: "complete",
                json: nil
            ),
            from: .containers
        )
        XCTAssertFalse(shell.isInspectorVisible)

        shell.updateInspector(running, from: .containers)
        XCTAssertTrue(shell.isInspectorVisible)
    }

    func testLateUpdateFromAnotherSidebarItemCannotReopenInspector() {
        let shell = makeShell()
        let window = host(shell)
        defer { release(window) }
        shell.showImages()
        shell.showContainers()

        shell.updateInspector(
            InspectorSnapshot(
                title: "Pull",
                subtitle: "Succeeded",
                command: CLICommandPreview(executable: "container", arguments: ["image", "pull", "alpine"]),
                detail: "done",
                json: nil
            ),
            from: .images
        )

        XCTAssertFalse(shell.isInspectorVisible)
    }

    private func makeShell() -> AppShellViewController {
        let runner = ResourceFixtureRunner()
        let resolver = ContainerCLIResolver(
            fileSystem: InspectorFileSystem(),
            environment: CLIResolverEnvironment(path: nil),
            knownPaths: ["/fake/container"]
        )
        return AppShellViewController(
            systemService: SystemService(
                preferences: InspectorPreferences(),
                resolver: resolver,
                runner: runner
            ),
            resourceService: ResourceFixtures.service(runner: runner),
            operationService: ResourceFixtures.operations(runner: runner)
        )
    }

    private func host(_ controller: NSViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func release(_ window: NSWindow) {
        window.contentViewController = nil
        window.close()
    }
}

private final class InspectorPreferences: AppPreferences, @unchecked Sendable {
    var cliExecutablePath: String?
}

private struct InspectorFileSystem: FileSystemChecking {
    func isExecutableFile(atPath path: String) -> Bool { path == "/fake/container" }
}

private extension NSView {
    func inspectorDescendants<T: NSView>(of type: T.Type) -> [T] {
        let own = (self as? T).map { [$0] } ?? []
        return own + subviews.flatMap { $0.inspectorDescendants(of: type) }
    }

    func inspectorTextField(with text: String) -> NSTextField? {
        inspectorDescendants(of: NSTextField.self).first { $0.stringValue == text }
    }
}
