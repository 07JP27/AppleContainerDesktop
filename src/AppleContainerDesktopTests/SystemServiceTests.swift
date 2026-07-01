import XCTest
@testable import AppleContainerDesktop

final class SystemServiceTests: XCTestCase {
    func testWaitForRunningSystemSnapshotPollsUntilRuntimeIsRunning() async {
        let runner = SequencedStatusRunner(statusExitCodes: [1, 0])
        let service = makeSystemService(runner: runner)

        let snapshot = await service.waitForRunningSystemSnapshot(maxAttempts: 3, delay: .zero)

        XCTAssertEqual(snapshot.health, .running)
        XCTAssertEqual(runner.statusCommandCount, 2)
    }

    func testWaitForRunningSystemSnapshotStopsAfterMaxAttempts() async {
        let runner = SequencedStatusRunner(statusExitCodes: [1, 1])
        let service = makeSystemService(runner: runner)

        let snapshot = await service.waitForRunningSystemSnapshot(maxAttempts: 2, delay: .zero)

        XCTAssertEqual(snapshot.health, .stopped)
        XCTAssertEqual(runner.statusCommandCount, 2)
    }

    func testStopSystemRunsStopCommand() async {
        let runner = SequencedStatusRunner(statusExitCodes: [])
        let service = makeSystemService(runner: runner)

        let outcome = await service.stopSystem()

        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(runner.commands.contains { $0.arguments == ["system", "stop"] })
    }

    func testRestartSystemStopsBeforeStarting() async {
        let runner = SequencedStatusRunner(statusExitCodes: [])
        let service = makeSystemService(runner: runner)

        let outcome = await service.restartSystem()

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(
            runner.commands.map(\.arguments).filter { arguments in
                arguments == ["system", "stop"] || arguments.starts(with: ["system", "start"])
            },
            [
                ["system", "stop"],
                ["system", "start", "--disable-kernel-install", "--timeout", "120"]
            ]
        )
    }

    private func makeSystemService(runner: SequencedStatusRunner) -> SystemService {
        SystemService(
            preferences: StubSystemPreferences(cliExecutablePath: nil),
            resolver: ContainerCLIResolver(
                fileSystem: StubSystemFileSystem(executablePaths: ["/fake/container"]),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner
        )
    }
}

private final class StubSystemPreferences: AppPreferences, @unchecked Sendable {
    var cliExecutablePath: String?

    init(cliExecutablePath: String?) {
        self.cliExecutablePath = cliExecutablePath
    }
}

private struct StubSystemFileSystem: FileSystemChecking {
    var executablePaths: Set<String>

    func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private final class SequencedStatusRunner: ProcessRunning, @unchecked Sendable {
    private(set) var commands: [ProcessCommand] = []
    private var statusExitCodes: [Int32]

    var statusCommandCount: Int {
        commands.filter { $0.arguments == ["system", "status", "--format", "json"] }.count
    }

    init(statusExitCodes: [Int32]) {
        self.statusExitCodes = statusExitCodes
    }

    func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
        commands.append(command)

        switch command.arguments {
        case ["system", "version", "--format", "json"]:
            return CLIProcessResult(
                preview: command.preview,
                exitCode: 0,
                stdout: """
                [
                  {"appName":"container","version":"1.0.0"},
                  {"appName":"container-apiserver","version":"1.0.0"}
                ]
                """,
                stderr: ""
            )
        case ["system", "status", "--format", "json"]:
            let exitCode = statusExitCodes.isEmpty ? statusExitCodes.last ?? 1 : statusExitCodes.removeFirst()
            return CLIProcessResult(
                preview: command.preview,
                exitCode: exitCode,
                stdout: exitCode == 0 ? "{}" : "",
                stderr: exitCode == 0 ? "" : "runtime is not ready"
            )
        case ["system", "df", "--format", "json"]:
            return CLIProcessResult(preview: command.preview, exitCode: 0, stdout: "{}", stderr: "")
        case ["system", "stop"]:
            return CLIProcessResult(preview: command.preview, exitCode: 0, stdout: "", stderr: "")
        case ["system", "start", "--disable-kernel-install", "--timeout", "120"]:
            return CLIProcessResult(preview: command.preview, exitCode: 0, stdout: "", stderr: "")
        default:
            XCTFail("Unexpected command: \(command.arguments)")
            return CLIProcessResult(preview: command.preview, exitCode: 1, stdout: "", stderr: "unexpected command")
        }
    }
}
