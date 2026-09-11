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

    func testContainerCreateRunRequestBuildsAdvancedCommands() throws {
        let runRequest = ContainerCreateRunRequest(
            operation: .run,
            image: "ubuntu:latest",
            name: "web",
            remove: true,
            cpus: "2",
            memory: "4G",
            environment: [.init(name: "FOO", value: "bar"), .init(name: "BAZ", value: "qux")],
            volumes: [.init(source: "/host", destination: "/container")],
            ports: [.init(hostPort: "8080", containerPort: "80")],
            networks: [.init(specification: "frontend")],
            platform: "linux/arm64",
            command: "/bin/sh -lc 'echo hello'"
        )

        XCTAssertEqual(
            try runRequest.validatedArguments(),
            [
                "run", "--detach", "--rm", "--name", "web",
                "--cpus", "2",
                "--memory", "4G",
                "--env", "FOO=bar",
                "--env", "BAZ=qux",
                "--volume", "/host:/container",
                "--publish", "8080:80/tcp",
                "--network", "frontend",
                "--platform", "linux/arm64",
                "ubuntu:latest",
                "/bin/sh", "-lc", "echo hello"
            ]
        )

        let createRequest = ContainerCreateRunRequest(
            operation: .create,
            image: "alpine",
            remove: true
        )
        XCTAssertEqual(try createRequest.validatedArguments(), ["create", "alpine"])
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

    func testRunContainerCreateOrRunValidatesBeforeResolvingOrExecutingCLI() async {
        let runner = makeLaunchFixture().runner
        let history = InMemoryHistoryStore()
        let fileSystem = OperationRecordingFileSystem()
        let service = OperationService(
            preferences: OperationStubPreferences(cliExecutablePath: "/fake/container"),
            resolver: ContainerCLIResolver(
                fileSystem: fileSystem,
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner,
            historyStore: history
        )
        let requests: [ContainerCreateRunRequest] = [
            .init(operation: .run),
            .init(operation: .stop, image: "alpine"),
            .init(operation: .create, image: "--help"),
            .init(operation: .run, image: "alpine", name: "_invalid"),
            .init(operation: .run, image: "alpine", cpus: "0"),
            .init(operation: .run, image: "alpine", memory: "invalid"),
            .init(operation: .run, image: "alpine", environment: [.init(value: "value")]),
            .init(operation: .run, image: "alpine", environment: [.init(name: "KEY", value: "value\0")]),
            .init(operation: .run, image: "alpine", volumes: [.init(source: "/host")]),
            .init(operation: .run, image: "alpine", ports: [.init(hostPort: "0", containerPort: "80")]),
            .init(operation: .run, image: "alpine", networks: [.init(specification: "network,mtu=")]),
            .init(operation: .run, image: "alpine", platform: "linux/arm64/v9"),
            .init(operation: .run, image: "alpine", command: "echo 'unfinished"),
            .init(operation: .run, image: "", cpus: "0", memory: "invalid", command: "trailing\\")
        ]

        for request in requests {
            let outcome = await service.runContainerCreateOrRun(request)
            let error = ContainerLaunchValidationError(issues: request.validationIssues)
            XCTAssertFalse(outcome.succeeded)
            XCTAssertNil(outcome.command)
            XCTAssertNil(outcome.result)
            XCTAssertEqual(outcome.title, request.operation.rawValue)
            XCTAssertEqual(outcome.errorMessage, error.localizedDescription)
            XCTAssertEqual(outcome.output, error.localizedDescription)
        }
        XCTAssertTrue(fileSystem.checkedPaths.isEmpty)
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertTrue(history.records.isEmpty)
    }

    func testRunContainerCreateOrRunPreservesStructuredArgumentsStreamingAndHistory() async {
        let fixture = makeLaunchFixture(
            stdout: "launch-test\n",
            outputEvents: [
                ProcessOutputEvent(source: .stdout, text: "Fetching image\n"),
                ProcessOutputEvent(source: .stderr, text: "A runtime warning\n")
            ]
        )
        let output = StreamingOutputBuffer()
        let request = ContainerCreateRunRequest(
            operation: .run,
            image: "localhost:5000/team/image:tag@sha256:" + String(repeating: "a", count: 64),
            name: "launch-test",
            remove: true,
            cpus: "2",
            memory: "1.5GiB",
            environment: [
                .init(name: "TEXT", value: " leading, commas=a=b trailing "),
                .init(name: "EMPTY"),
                .init(name: "HOST", inheritFromHost: true)
            ],
            volumes: [
                .init(source: "/Users/test/path, with spaces", destination: "/work =x", readOnly: true),
                .init(kind: .volume, source: "cache", destination: "/cache")
            ],
            ports: [
                .init(hostAddress: "127.0.0.1", hostPort: "8000-8001", containerPort: "80-81"),
                .init(hostAddress: "::1", hostPort: "5300", containerPort: "53", transport: .udp)
            ],
            networks: [
                .init(specification: "default,mac=02:42:ac:11:00:02"),
                .init(specification: "backend,mtu=9000")
            ],
            platform: "linux/arm64/v8",
            command: #"printf '%s\n' '' 'a,b=c' '--not-a-cli-flag'"#
        )

        let outcome = await fixture.service.runContainerCreateOrRun(request) { event in
            _ = output.append(event)
        }

        let expected = [
            "run", "--detach", "--rm", "--name", "launch-test",
            "--cpus", "2", "--memory", "1.5GiB",
            "--env", "TEXT= leading, commas=a=b trailing ",
            "--env", "EMPTY=", "--env", "HOST",
            "--volume", "/Users/test/path, with spaces:/work =x:ro",
            "--volume", "cache:/cache",
            "--publish", "127.0.0.1:8000-8001:80-81/tcp",
            "--publish", "[::1]:5300:53/udp",
            "--network", "default,mac=02:42:ac:11:00:02",
            "--network", "backend,mtu=9000",
            "--platform", "linux/arm64/v8",
            request.image, "printf", "%s\\n", "", "a,b=c", "--not-a-cli-flag"
        ]
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(fixture.runner.commands.count, 1)
        XCTAssertEqual(fixture.runner.commands.first?.arguments, expected)
        XCTAssertEqual(fixture.runner.commands.first?.timeout, 60 * 30)
        XCTAssertEqual(outcome.command?.arguments, expected)
        XCTAssertEqual(outcome.output, "launch-test\n")
        XCTAssertEqual(output.append(.init(source: .stdout, text: "")), "Fetching image\n[stderr] A runtime warning\n")
        XCTAssertEqual(fixture.history.records.count, 1)
        XCTAssertEqual(fixture.history.records.first?.title, "Run")
        XCTAssertEqual(fixture.history.records.first?.command, outcome.command?.displayString)
        XCTAssertEqual(fixture.history.records.first?.exitCode, 0)
        XCTAssertEqual(fixture.history.records.first?.succeeded, true)
    }

    func testRunContainerCreateOrRunKeepsSemanticDefaultsAtServiceBoundary() async {
        let cases: [(ContainerOperation, Bool, [String])] = [
            (.run, false, ["run", "--detach", "alpine"]),
            (.run, true, ["run", "--detach", "--rm", "alpine"]),
            (.create, false, ["create", "alpine"]),
            (.create, true, ["create", "alpine"])
        ]
        for (operation, remove, expected) in cases {
            let fixture = makeLaunchFixture()
            let outcome = await fixture.service.runContainerCreateOrRun(
                .init(operation: operation, image: "alpine", remove: remove)
            )
            XCTAssertTrue(outcome.succeeded)
            XCTAssertEqual(fixture.runner.commands.first?.arguments, expected)
            XCTAssertEqual(fixture.runner.commands.first?.timeout, 60 * 30)
            XCTAssertNil(fixture.runner.commands.first?.standardInput)
            XCTAssertEqual(fixture.history.records.first?.title, operation.rawValue)
        }
    }

    func testRunContainerCreateOrRunPreservesRuntimeFailure() async {
        let fixture = makeLaunchFixture(exitCode: 125, stderr: "The host port is already in use.")
        let outcome = await fixture.service.runContainerCreateOrRun(.init(operation: .run, image: "alpine"))

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.output, "The host port is already in use.")
        XCTAssertEqual(outcome.command?.arguments, ["run", "--detach", "alpine"])
        XCTAssertEqual(fixture.runner.commands.count, 1)
        XCTAssertEqual(fixture.history.records.first?.exitCode, 125)
        XCTAssertEqual(fixture.history.records.first?.succeeded, false)
    }

    func testRunContainerCreateOrRunCanRetryAnEditedInvalidDraft() async {
        let fixture = makeLaunchFixture()
        var request = ContainerCreateRunRequest(operation: .run, image: "alpine", cpus: "0")
        let failed = await fixture.service.runContainerCreateOrRun(request)
        XCTAssertFalse(failed.succeeded)
        XCTAssertTrue(fixture.runner.commands.isEmpty)
        XCTAssertTrue(fixture.history.records.isEmpty)

        request.cpus = "2"
        let succeeded = await fixture.service.runContainerCreateOrRun(request)
        XCTAssertTrue(succeeded.succeeded)
        XCTAssertEqual(fixture.runner.commands.count, 1)
        XCTAssertEqual(fixture.runner.commands.first?.arguments, ["run", "--detach", "--cpus", "2", "alpine"])
        XCTAssertEqual(fixture.history.records.count, 1)
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

    private func makeLaunchFixture(
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = "",
        outputEvents: [ProcessOutputEvent] = []
    ) -> (service: OperationService, runner: OperationStubRunner, history: InMemoryHistoryStore) {
        let runner = OperationStubRunner(
            result: CLIProcessResult(
                preview: CLICommandPreview(executable: "/fake/container", arguments: []),
                exitCode: exitCode,
                stdout: stdout,
                stderr: stderr
            ),
            outputEvents: outputEvents
        )
        let history = InMemoryHistoryStore()
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
        return (service, runner, history)
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

private final class OperationRecordingFileSystem: FileSystemChecking, @unchecked Sendable {
    private(set) var checkedPaths: [String] = []

    func isExecutableFile(atPath path: String) -> Bool {
        checkedPaths.append(path)
        return false
    }
}

private final class OperationStubRunner: ProcessRunning, @unchecked Sendable {
    private(set) var commands: [ProcessCommand] = []
    private let result: CLIProcessResult
    private let outputEvents: [ProcessOutputEvent]

    init(result: CLIProcessResult, outputEvents: [ProcessOutputEvent] = []) {
        self.result = result
        self.outputEvents = outputEvents
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

    func run(_ command: ProcessCommand, outputHandler: ProcessOutputHandler?) async throws -> CLIProcessResult {
        for event in outputEvents {
            outputHandler?(event)
        }
        return try await run(command)
    }
}
