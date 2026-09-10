import AppKit
import XCTest
@testable import AppleContainerDesktop

@MainActor
final class LayoutSmokeTests: XCTestCase {
    func testPageHeaderHasStableIntrinsicHeight() {
        let header = PageHeaderView(title: "Containers", subtitle: "Create, run, inspect, and manage local containers.")

        XCTAssertGreaterThan(header.intrinsicContentSize.height, 40)
        XCTAssertLessThan(header.intrinsicContentSize.height, 80)
    }

    func testPrimaryScreensStartNearTop() throws {
        let screens: [(String, NSViewController)] = [
            ("Containers", resourceController(.containers)),
            ("Images", resourceController(.images)),
            ("Networks", resourceController(.networks)),
            ("Volumes", resourceController(.volumes)),
            ("Registries", resourceController(.registry)),
            ("Operations", OperationsViewController(historyStore: InMemoryLayoutHistoryStore())),
            ("Runtime", SystemViewController()),
            ("Settings", SettingsViewController()),
            ("Build image", BuildViewController(onInspectorUpdate: { _ in }))
        ]

        for (title, controller) in screens {
            controller.view.frame = NSRect(x: 0, y: 0, width: 1_100, height: 720)
            controller.loadViewIfNeeded()
            controller.view.layoutSubtreeIfNeeded()

            let titleLabel = try XCTUnwrap(controller.view.firstTextField(with: title), title)
            XCTAssertLessThanOrEqual(controller.view.topDistance(to: titleLabel), 80, title)
        }
    }

    func testEmptyResourceScreensKeepEmptyStateNearTop() async throws {
        for kind in [ResourceKind.containers, .images, .networks, .volumes, .registry] {
            let controller = resourceController(kind)
            controller.view.frame = NSRect(x: 0, y: 0, width: 1_100, height: 720)
            controller.loadViewIfNeeded()

            let emptyTitle = "No \(kind.rawValue.lowercased())"
            let label = await waitForTextField(emptyTitle, in: controller.view)
            let emptyLabel = try XCTUnwrap(label, kind.rawValue)
            controller.view.layoutSubtreeIfNeeded()

            XCTAssertLessThanOrEqual(controller.view.topDistance(to: emptyLabel), 220, kind.rawValue)
        }
    }

    func testRuntimeReloadReportsRenderedStatus() async {
        let statusReported = expectation(description: "Runtime status reported")
        let controller = SystemViewController(
            systemService: SystemService(
                preferences: LayoutPreferences(),
                resolver: ContainerCLIResolver(
                    fileSystem: LayoutFileSystem(executablePaths: ["/fake/container"]),
                    environment: CLIResolverEnvironment(path: nil),
                    knownPaths: ["/fake/container"]
                ),
                runner: LayoutRunner(stdout: "[]")
            ),
            onRuntimeStatusChange: { snapshot in
                XCTAssertEqual(snapshot.health, .unknown)
                statusReported.fulfill()
            }
        )

        controller.loadViewIfNeeded()

        await fulfillment(of: [statusReported], timeout: 1)
    }

    private func resourceController(_ kind: ResourceKind) -> ResourceListViewController {
        ResourceListViewController(
            kind: kind,
            service: ResourceService(
                preferences: LayoutPreferences(),
                resolver: ContainerCLIResolver(
                    fileSystem: LayoutFileSystem(executablePaths: ["/fake/container"]),
                    environment: CLIResolverEnvironment(path: nil),
                    knownPaths: ["/fake/container"]
                ),
                runner: LayoutRunner(stdout: "[]")
            ),
            onInspectorUpdate: { _ in }
        )
    }

    private func waitForTextField(_ text: String, in view: NSView) async -> NSTextField? {
        for _ in 0..<20 {
            view.layoutSubtreeIfNeeded()
            if let label = view.firstTextField(with: text) {
                return label
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }
}

private extension NSView {
    func firstTextField(with value: String) -> NSTextField? {
        if let field = self as? NSTextField, field.stringValue == value {
            return field
        }
        for subview in subviews {
            if let field = subview.firstTextField(with: value) {
                return field
            }
        }
        return nil
    }

    func topDistance(to descendant: NSView) -> CGFloat {
        let rect = convert(descendant.bounds, from: descendant)
        return bounds.maxY - rect.maxY
    }
}

private final class LayoutPreferences: AppPreferences, @unchecked Sendable {
    var cliExecutablePath: String?
}

private struct LayoutFileSystem: FileSystemChecking {
    var executablePaths: Set<String>

    func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private final class LayoutRunner: ProcessRunning, @unchecked Sendable {
    private let stdout: String

    init(stdout: String) {
        self.stdout = stdout
    }

    func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
        CLIProcessResult(preview: command.preview, exitCode: 0, stdout: stdout, stderr: "")
    }
}

private final class InMemoryLayoutHistoryStore: OperationHistoryStoring {
    func append(_ record: OperationRecord) {}
    func recent(limit: Int) -> [OperationRecord] { [] }
}
