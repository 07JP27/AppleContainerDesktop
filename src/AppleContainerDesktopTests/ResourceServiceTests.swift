import XCTest
@testable import AppleContainerDesktop

final class ResourceServiceTests: XCTestCase {
    func testLoadUsesResourceListArguments() async {
        let preferences = StubPreferences(cliExecutablePath: nil)
        let service = ResourceService(
            preferences: preferences,
            resolver: ContainerCLIResolver(
                fileSystem: StubFileSystem(executablePaths: ["/fake/container"]),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: StubRunner(
                result: CLIProcessResult(
                    preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                    exitCode: 0,
                    stdout: "[{\"name\":\"bridge\",\"status\":\"active\"}]",
                    stderr: ""
                )
            )
        )

        let snapshot = await service.load(kind: .networks)

        XCTAssertEqual(snapshot.command?.arguments, ["network", "list", "--format", "json"])
        XCTAssertEqual(snapshot.items.first?.title, "bridge")
    }

    func testInspectDoesNotPassFormatFlag() async {
        let runner = StubRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: 0,
                stdout: "[{\"name\":\"web\"}]",
                stderr: ""
            )
        )
        let service = ResourceService(
            preferences: StubPreferences(cliExecutablePath: nil),
            resolver: ContainerCLIResolver(
                fileSystem: StubFileSystem(executablePaths: ["/fake/container"]),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner
        )

        let result = await service.inspect(kind: .containers, identifier: "web")

        XCTAssertEqual(runner.commands.first?.arguments, ["inspect", "web"])
        XCTAssertNil(result.error)
        XCTAssertTrue(result.json.contains("\"name\" : \"web\""))
    }
}

private final class StubPreferences: AppPreferences, @unchecked Sendable {
    var cliExecutablePath: String?

    init(cliExecutablePath: String?) {
        self.cliExecutablePath = cliExecutablePath
    }
}

private struct StubFileSystem: FileSystemChecking {
    var executablePaths: Set<String>

    func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private final class StubRunner: ProcessRunning, @unchecked Sendable {
    private(set) var commands: [ProcessCommand] = []
    private let result: CLIProcessResult

    init(result: CLIProcessResult) {
        self.result = result
    }

    func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
        commands.append(command)
        return CLIProcessResult(
            preview: command.preview,
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }
}

