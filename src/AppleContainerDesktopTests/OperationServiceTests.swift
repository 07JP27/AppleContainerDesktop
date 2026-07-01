import XCTest
@testable import AppleContainerDesktop

final class OperationServiceTests: XCTestCase {
    func testContainerOperationBuildsLifecycleCommands() {
        XCTAssertEqual(ContainerOperation.start.arguments(identifier: "web"), ["start", "web"])
        XCTAssertEqual(ContainerOperation.stop.arguments(identifier: "web"), ["stop", "web"])
        XCTAssertEqual(ContainerOperation.kill.arguments(identifier: "web"), ["kill", "web"])
        XCTAssertEqual(ContainerOperation.delete.arguments(identifier: "web"), ["delete", "web"])
        XCTAssertEqual(ContainerOperation.logs.arguments(identifier: "web"), ["logs", "-n", "200", "web"])
        XCTAssertEqual(ContainerOperation.stats.arguments(identifier: "web"), ["stats", "--format", "json", "--no-stream", "web"])
        XCTAssertEqual(ContainerOperation.prune.arguments(identifier: nil), ["prune"])
    }

    func testContainerCreateRunRequestBuildsAdvancedCommands() {
        let runRequest = ContainerCreateRunRequest(
            operation: .run,
            image: "ubuntu:latest",
            name: "web",
            detach: true,
            remove: true,
            cpus: "2",
            memory: "4G",
            environment: "FOO=bar,BAZ=qux",
            volumes: "/host:/container",
            ports: "8080:80",
            networks: "frontend",
            platform: "linux/arm64",
            command: "/bin/sh -lc 'echo hello'"
        )

        XCTAssertEqual(
            runRequest.arguments,
            [
                "run", "--detach", "--rm", "--name", "web",
                "--cpus", "2",
                "--memory", "4G",
                "--env", "FOO=bar",
                "--env", "BAZ=qux",
                "--volume", "/host:/container",
                "--publish", "8080:80",
                "--network", "frontend",
                "--platform", "linux/arm64",
                "ubuntu:latest",
                "/bin/sh", "-lc", "echo hello"
            ]
        )

        let createRequest = ContainerCreateRunRequest(
            operation: .create,
            image: "alpine",
            name: "",
            detach: true,
            remove: true,
            cpus: "",
            memory: "",
            environment: "",
            volumes: "",
            ports: "",
            networks: "",
            platform: "",
            command: ""
        )
        XCTAssertEqual(createRequest.arguments, ["create", "alpine"])
    }

    func testContainerCopyExportExecRequestsBuildCommands() {
        XCTAssertEqual(ContainerCopyRequest(source: "web:/tmp/app.log", destination: "/tmp/app.log").arguments, ["copy", "web:/tmp/app.log", "/tmp/app.log"])
        XCTAssertEqual(ContainerExportRequest(identifier: "web", outputPath: "/tmp/web.tar").arguments, ["export", "-o", "/tmp/web.tar", "web"])
        XCTAssertEqual(ContainerExecRequest(identifier: "web", command: "/bin/sh").arguments, ["exec", "-i", "-t", "web", "/bin/sh"])
    }

    func testImageOperationBuildsCommands() {
        XCTAssertEqual(ImageOperation.pull.arguments(identifier: nil, input: "ubuntu:latest"), ["image", "pull", "ubuntu:latest"])
        XCTAssertEqual(ImageOperation.push.arguments(identifier: "ghcr.io/example/app:latest", input: nil), ["image", "push", "ghcr.io/example/app:latest"])
        XCTAssertEqual(ImageOperation.tag.arguments(identifier: "app:old", input: "app:new"), ["image", "tag", "app:old", "app:new"])
        XCTAssertEqual(ImageOperation.delete.arguments(identifier: "app:old", input: nil), ["image", "delete", "app:old"])
        XCTAssertEqual(ImageOperation.prune.arguments(identifier: nil, input: nil), ["image", "prune"])
    }

    func testBuildRequestBuildsCommand() {
        let request = BuildRequest(
            contextDirectory: ".",
            dockerfilePath: "Dockerfile.dev",
            tag: "example/app:latest",
            platform: "linux/arm64",
            buildArguments: "FOO=bar\nBAZ=qux"
        )

        XCTAssertEqual(
            request.arguments,
            [
                "build", "--progress", "plain",
                "--file", "Dockerfile.dev",
                "--tag", "example/app:latest",
                "--platform", "linux/arm64",
                "--build-arg", "FOO=bar",
                "--build-arg", "BAZ=qux",
                "."
            ]
        )
    }

    func testResourceOperationCommands() {
        XCTAssertEqual(NetworkOperation.create.arguments(identifier: nil, input: "devnet"), ["network", "create", "devnet"])
        XCTAssertEqual(NetworkOperation.delete.arguments(identifier: "devnet", input: nil), ["network", "delete", "devnet"])
        XCTAssertEqual(NetworkOperation.prune.arguments(identifier: nil, input: nil), ["network", "prune"])
        XCTAssertEqual(VolumeOperation.create.arguments(identifier: nil, input: "cache"), ["volume", "create", "cache"])
        XCTAssertEqual(VolumeOperation.delete.arguments(identifier: "cache", input: nil), ["volume", "delete", "cache"])
        XCTAssertEqual(VolumeOperation.prune.arguments(identifier: nil, input: nil), ["volume", "prune"])
        XCTAssertEqual(RegistryOperation.logout.arguments(identifier: "ghcr.io"), ["registry", "logout", "ghcr.io"])
        XCTAssertEqual(MachineOperation.logs.arguments(identifier: "default"), ["machine", "logs", "default"])
        XCTAssertEqual(MachineOperation.stop.arguments(identifier: "default"), ["machine", "stop", "default"])
        XCTAssertEqual(MachineOperation.delete.arguments(identifier: "default"), ["machine", "delete", "default"])
        XCTAssertEqual(MachineOperation.setDefault.arguments(identifier: "default"), ["machine", "set-default", "default"])
        XCTAssertEqual(BuilderOperation.status.arguments(), ["builder", "status", "--format", "json"])
        XCTAssertEqual(BuilderOperation.start.arguments(cpus: "4", memory: "8G"), ["builder", "start", "--cpus", "4", "--memory", "8G"])
        XCTAssertEqual(BuilderOperation.stop.arguments(), ["builder", "stop"])
        XCTAssertEqual(BuilderOperation.delete.arguments(), ["builder", "delete"])
    }

    func testRunContainerOperationRecordsHistory() async {
        let history = InMemoryHistoryStore()
        let runner = OperationStubRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: 0,
                stdout: "web\n",
                stderr: ""
            )
        )
        let service = OperationService(
            preferences: OperationStubPreferences(cliExecutablePath: nil),
            resolver: ContainerCLIResolver(
                fileSystem: OperationStubFileSystem(executablePaths: ["/fake/container"]),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner,
            historyStore: history
        )

        let outcome = await service.runContainerOperation(.stop, identifier: "web")

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(runner.commands.first?.arguments, ["stop", "web"])
        XCTAssertEqual(history.records.first?.title, "Stop")
        XCTAssertEqual(history.records.first?.exitCode, 0)
    }

    func testRunImageOperationUsesImageArguments() async {
        let runner = OperationStubRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: 0,
                stdout: "ubuntu:latest\n",
                stderr: ""
            )
        )
        let service = OperationService(
            preferences: OperationStubPreferences(cliExecutablePath: nil),
            resolver: ContainerCLIResolver(
                fileSystem: OperationStubFileSystem(executablePaths: ["/fake/container"]),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner,
            historyStore: InMemoryHistoryStore()
        )

        let outcome = await service.runImageOperation(.pull, identifier: nil, input: "ubuntu:latest")

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(runner.commands.first?.arguments, ["image", "pull", "ubuntu:latest"])
    }

    func testRunContainerCopyRejectsMissingContainerPath() async {
        let runner = OperationStubRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        )
        let service = OperationService(
            preferences: OperationStubPreferences(cliExecutablePath: nil),
            resolver: ContainerCLIResolver(
                fileSystem: OperationStubFileSystem(executablePaths: ["/fake/container"]),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner,
            historyStore: InMemoryHistoryStore()
        )

        let outcome = await service.runContainerCopy(ContainerCopyRequest(source: "/tmp/a", destination: "/tmp/b"))

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.output, "Exactly one copy path must use container:path syntax.")
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testRunContainerExportRejectsMissingOutputPath() async {
        let runner = OperationStubRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        )
        let service = OperationService(
            preferences: OperationStubPreferences(cliExecutablePath: nil),
            resolver: ContainerCLIResolver(
                fileSystem: OperationStubFileSystem(executablePaths: ["/fake/container"]),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner,
            historyStore: InMemoryHistoryStore()
        )

        let outcome = await service.runContainerExport(ContainerExportRequest(identifier: "web", outputPath: ""))

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.output, "Provide an output tar path.")
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testOpenExecInTerminalUsesOsascript() async {
        let history = InMemoryHistoryStore()
        let runner = OperationStubRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/usr/bin/osascript", arguments: []),
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        )
        let service = OperationService(
            preferences: OperationStubPreferences(cliExecutablePath: nil),
            resolver: ContainerCLIResolver(
                fileSystem: OperationStubFileSystem(executablePaths: ["/fake/container"]),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner,
            historyStore: history
        )

        let outcome = await service.openExecInTerminal(ContainerExecRequest(identifier: "web", command: "/bin/sh"))

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(runner.commands.first?.executableURL.path, "/usr/bin/osascript")
        XCTAssertEqual(runner.commands.first?.arguments.first, "-e")
        XCTAssertTrue(runner.commands.first?.arguments.last?.contains("'/fake/container' 'exec' '-i' '-t' 'web' '/bin/sh'") == true)
        XCTAssertEqual(history.records.first?.title, "Exec")
    }

    func testRegistryLoginUsesPasswordStdin() async {
        let runner = OperationStubRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        )
        let service = OperationService(
            preferences: OperationStubPreferences(cliExecutablePath: nil),
            resolver: ContainerCLIResolver(
                fileSystem: OperationStubFileSystem(executablePaths: ["/fake/container"]),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner,
            historyStore: InMemoryHistoryStore()
        )

        let outcome = await service.runRegistryLogin(
            RegistryLoginRequest(registry: "ghcr.io", username: "octo", password: "secret")
        )

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(runner.commands.first?.arguments, ["registry", "login", "ghcr.io", "--username", "octo", "--password-stdin"])
        XCTAssertEqual(String(data: runner.commands.first?.standardInput ?? Data(), encoding: .utf8), "secret\n")
    }
}

private final class InMemoryHistoryStore: OperationHistoryStoring, @unchecked Sendable {
    private(set) var records: [OperationRecord] = []

    func append(_ record: OperationRecord) {
        records.insert(record, at: 0)
    }

    func recent(limit: Int) -> [OperationRecord] {
        Array(records.prefix(limit))
    }
}

private final class OperationStubPreferences: AppPreferences, @unchecked Sendable {
    var cliExecutablePath: String?

    init(cliExecutablePath: String?) {
        self.cliExecutablePath = cliExecutablePath
    }
}

private struct OperationStubFileSystem: FileSystemChecking {
    var executablePaths: Set<String>

    func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private final class OperationStubRunner: ProcessRunning, @unchecked Sendable {
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
