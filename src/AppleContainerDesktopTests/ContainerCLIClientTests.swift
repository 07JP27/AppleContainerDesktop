import XCTest
@testable import AppleContainerDesktop

final class ContainerCLIClientTests: XCTestCase {
    func testSystemVersionDecodesComponentArray() async throws {
        let runner = RecordingRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: 0,
                stdout: """
                [
                  {"appName":"container","buildType":"release","commit":"abcdef1","version":"1.2.3"},
                  {"appName":"container-apiserver","buildType":"release","commit":"1234567","version":"container-apiserver version 1.2.3"}
                ]
                """,
                stderr: ""
            )
        )
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/fake/container"), runner: runner)

        let components = try await client.systemVersion()
        let summary = VersionSummary(components: components)

        XCTAssertEqual(runner.commands.first?.arguments, ["system", "version", "--format", "json"])
        XCTAssertEqual(summary.cliVersion, "1.2.3")
        XCTAssertEqual(summary.apiServerVersion, "container-apiserver version 1.2.3")
    }

    func testSystemStartAvoidsInteractiveKernelPrompt() async throws {
        let runner = RecordingRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        )
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/fake/container"), runner: runner)

        _ = try await client.startSystem(enableKernelInstall: false, timeout: 90)

        XCTAssertEqual(
            runner.commands.first?.arguments,
            ["system", "start", "--disable-kernel-install", "--timeout", "90"]
        )
        XCTAssertEqual(runner.commands.first?.timeout, 95)
    }

    func testSystemStopUsesStopCommand() async throws {
        let runner = RecordingRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        )
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/fake/container"), runner: runner)

        _ = try await client.stopSystem(timeout: 45)

        XCTAssertEqual(runner.commands.first?.arguments, ["system", "stop"])
        XCTAssertEqual(runner.commands.first?.timeout, 45)
    }

    func testRegistryLoginWritesPasswordToStdin() async throws {
        let runner = RecordingRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        )
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/fake/container"), runner: runner)

        _ = try await client.registryLogin(registry: "ghcr.io", username: "octo", password: "secret")

        XCTAssertEqual(
            runner.commands.first?.arguments,
            ["registry", "login", "ghcr.io", "--username", "octo", "--password-stdin"]
        )
        XCTAssertEqual(String(data: runner.commands.first?.standardInput ?? Data(), encoding: .utf8), "secret\n")
    }

    func testSystemPropertiesUsesExplicitJSONFormat() async throws {
        let runner = RecordingRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: 0,
                stdout: "{}",
                stderr: ""
            )
        )
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/fake/container"), runner: runner)

        _ = try await client.systemPropertiesJSON()

        XCTAssertEqual(runner.commands.first?.arguments, ["system", "property", "list", "--format", "json"])
    }
}

private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
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
