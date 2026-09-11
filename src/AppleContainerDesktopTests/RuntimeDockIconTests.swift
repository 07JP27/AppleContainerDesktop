import AppKit
import XCTest
@testable import AppleContainerDesktop

@MainActor
final class RuntimeDockIconTests: XCTestCase {
    func testOnlyConfirmedRunningHealthUsesTheGreenIcon() {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in true }
        var applied: [NSImage?] = []
        var loads = 0
        let controller = RuntimeDockIconController(
            loadImage: { name in
                XCTAssertEqual(name, RuntimeDockIconController.runningAssetName)
                loads += 1
                return image
            },
            applyImage: { applied.append($0) },
            reportError: { XCTFail($0) }
        )
        controller.reset()
        for state in [ServiceHealth.unknown, .stopped, .missingCLI, .unhealthy] {
            controller.update(state)
        }
        XCTAssertEqual(applied.count, 1)
        XCTAssertNil(applied[0])
        XCTAssertEqual(loads, 0)

        controller.update(.running)
        controller.update(.running)
        XCTAssertEqual(applied.count, 2)
        XCTAssertTrue(applied[1] === image)
        XCTAssertEqual(loads, 1)

        for state in [ServiceHealth.stopped, .unknown, .unhealthy, .missingCLI] {
            controller.update(state)
            XCTAssertNil(applied.last!)
            controller.update(.running)
            XCTAssertTrue(applied.last! === image)
        }
        XCTAssertEqual(loads, 1, "State transitions reuse the loaded icon.")
    }

    func testTerminationResetRestoresBundledOrangeIconAndAllowsReuse() {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in true }
        var applied: [NSImage?] = []
        let controller = RuntimeDockIconController(
            loadImage: { _ in image }, applyImage: { applied.append($0) }, reportError: { XCTFail($0) }
        )
        controller.update(.running)
        controller.reset()
        XCTAssertEqual(applied.count, 2)
        XCTAssertNil(applied[1])
        controller.update(.running)
        XCTAssertTrue(applied[2] === image)
    }

    func testMissingGreenAssetReportsOnceAndKeepsTheDefaultIcon() {
        var errors: [String] = []
        var applied: [NSImage?] = []
        let controller = RuntimeDockIconController(
            loadImage: { _ in nil }, applyImage: { applied.append($0) }, reportError: { errors.append($0) }
        )
        controller.reset()
        controller.update(.running)
        controller.update(.running)
        controller.update(.unknown)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains(RuntimeDockIconController.runningAssetName))
        XCTAssertEqual(applied.count, 1)
        XCTAssertNil(applied[0])
    }

    func testRunningImageIsBundledAndHasHighResolutionRepresentations() throws {
        let image = try XCTUnwrap(NSImage(named: NSImage.Name(RuntimeDockIconController.runningAssetName)))
        XCTAssertTrue(image.isValid)
        XCTAssertEqual(image.size, NSSize(width: 512, height: 512))
        for size in [512, 1_024] {
            var proposedRect = NSRect(x: 0, y: 0, width: size, height: size)
            let representation = try XCTUnwrap(image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil))
            XCTAssertGreaterThanOrEqual(representation.width, 512)
            XCTAssertGreaterThanOrEqual(representation.height, 512)
        }
    }

    func testRunningIconIncludesNativeTilePaddingAndTransparentCorners() throws {
        let image = try XCTUnwrap(NSImage(named: NSImage.Name(RuntimeDockIconController.runningAssetName)))
        var rect = NSRect(x: 0, y: 0, width: 1_024, height: 1_024)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        XCTAssertTrue(bitmap.hasAlpha, "Dock overrides must include their own transparent margins and corner mask.")
        XCTAssertEqual(bitmap.pixelsWide, bitmap.pixelsHigh)
        let size = bitmap.pixelsWide
        let inset = size * 100 / 1_024
        let center = size / 2
        let farEdge = size - inset - 1
        let transparentPoints = [
            (0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1),
            (inset, inset), (farEdge, inset), (inset, farEdge), (farEdge, farEdge)
        ]
        for (x, y) in transparentPoints {
            XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0.01, "\(x), \(y)")
        }
        for (x, y) in [(inset + 1, center), (farEdge - 1, center), (center, inset + 1), (center, farEdge - 1)] {
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0.95, "\(x), \(y)")
        }
        for (x, y) in [(inset - 1, center), (farEdge + 1, center), (center, inset - 1), (center, farEdge + 1)] {
            XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0.25, "\(x), \(y)")
        }
    }

    func testShellDeliversRuntimeHealthWithoutAddingAnIconPollingLoop() async {
        let runner = DockStatusRunner()
        let resources = ResourceFixtures.service(runner: runner)
        var health: [ServiceHealth] = []
        let shell = AppShellViewController(
            systemService: SystemService(preferences: resources.preferences, resolver: resources.resolver, runner: runner),
            resourceService: resources,
            operationService: ResourceFixtures.operations(runner: runner),
            onRuntimeHealthChange: { health.append($0) }
        )
        shell.loadViewIfNeeded()
        await waitFor { health.last == .running }

        await runner.setRunning(false)
        shell.refreshContent()
        await waitFor { health.last == .stopped }

        await runner.setRunning(true)
        shell.refreshContent()
        await waitFor { health.last == .running }
        XCTAssertEqual(health, [.running, .stopped, .running])
        let statusCalls = await runner.statusCalls
        XCTAssertEqual(statusCalls, 3)
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                XCTFail("Interrupted while waiting for runtime health: \(error)")
                return
            }
        }
        XCTFail("The runtime health update did not arrive.")
    }
}

private actor DockStatusRunner: ProcessRunning {
    private var running = true
    private(set) var statusCalls = 0

    func setRunning(_ running: Bool) { self.running = running }

    func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
        let output: String
        var exitCode: Int32 = 0
        switch command.arguments {
        case ["system", "status", "--format", "json"]:
            statusCalls += 1
            exitCode = running ? 0 : 1
            output = "{}"
        case ["system", "version", "--format", "json"]:
            output = #"[{"appName":"container-apiserver","version":"1.0.0"}]"#
        case ["system", "df", "--format", "json"]:
            output = "{}"
        default:
            output = "[]"
        }
        return CLIProcessResult(
            preview: command.preview, exitCode: exitCode,
            stdout: exitCode == 0 ? output : "", stderr: exitCode == 0 ? "" : "Runtime is stopped"
        )
    }
}
