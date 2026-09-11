import XCTest
@testable import AppleContainerDesktop

final class ContainerBatchOperationTests: XCTestCase {
    func testInvalidRequestsHaveNoResolverRunnerOrHistorySideEffects() async {
        let fixture = makeFixture([])
        let validTarget = target("web", name: "Web")
        let requests: [ContainerBatchRequest] = [
            .init(operation: .start, targets: []),
            .init(operation: .start, targets: [validTarget, validTarget]),
            .init(operation: .start, targets: [target("")]),
            .init(operation: .start, targets: [target("   ")]),
            .init(operation: .stop, targets: [target("bad\tid")]),
            .init(operation: .delete, targets: [target("bad\u{0007}id")]),
            .init(operation: .start, targets: [target("-option")]),
            .init(operation: .kill, targets: [validTarget]),
            .init(operation: .stop, targets: [validTarget], forceDelete: true)
        ]

        for request in requests {
            let outcome = await fixture.service.runContainerBatch(request)
            XCTAssertFalse(outcome.succeeded)
            XCTAssertFalse(outcome.output.isEmpty)
            XCTAssertNotNil(outcome.errorMessage)
            XCTAssertTrue(outcome.itemResults.isEmpty)
            XCTAssertTrue(outcome.commands.isEmpty)
            XCTAssertTrue(outcome.succeededIDs.isEmpty)
            XCTAssertTrue(outcome.failedIDs.isEmpty)
        }

        XCTAssertTrue(fixture.fileSystem.checkedPaths.isEmpty)
        XCTAssertTrue(fixture.runner.commands.isEmpty)
        XCTAssertTrue(fixture.history.records.isEmpty)
    }

    func testBatchValidationReportsSpecificFailuresAndAcceptsOrderedUniqueTargets() throws {
        XCTAssertThrowsError(try ContainerBatchRequest(operation: .start, targets: []).validate()) { error in
            XCTAssertEqual(error as? ContainerBatchValidationError, .emptyTargets)
        }
        XCTAssertThrowsError(
            try ContainerBatchRequest(operation: .delete, targets: [target("one"), target("one")]).validate()
        ) { error in
            XCTAssertEqual(error as? ContainerBatchValidationError, .duplicateIdentifier("one"))
        }
        XCTAssertThrowsError(
            try ContainerBatchRequest(operation: .logs, targets: [target("one")]).validate()
        ) { error in
            XCTAssertEqual(error as? ContainerBatchValidationError, .unsupportedOperation(.logs))
        }

        let request = ContainerBatchRequest(
            operation: .delete,
            targets: [target("third"), target("first"), target("second")],
            forceDelete: true
        )
        XCTAssertNoThrow(try request.validate())
        XCTAssertEqual(request.targets.map(\.id), ["third", "first", "second"])
    }

    func testStartRunsOneCommandPerTargetSequentiallyAndRecordsEverySuccess() async {
        let fixture = makeFixture([
            .result(0, "alpha started\n", "", []),
            .result(0, "beta started\n", "", []),
            .result(0, "gamma started\n", "", [])
        ])
        let targets = [
            target("id-alpha", name: "Alpha"),
            target("id-beta", name: "Beta"),
            target("id-gamma", name: "Gamma")
        ]

        let outcome = await fixture.service.runContainerBatch(
            ContainerBatchRequest(operation: .start, targets: targets)
        )

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(fixture.runner.commands.map(\.arguments), [
            ["start", "id-alpha"],
            ["start", "id-beta"],
            ["start", "id-gamma"]
        ])
        XCTAssertEqual(fixture.runner.commands.map(\.timeout), [120, 120, 120])
        XCTAssertEqual(outcome.targets, targets)
        XCTAssertEqual(outcome.itemResults.map(\.target), targets)
        XCTAssertEqual(outcome.itemResults.map(\.succeeded), [true, true, true])
        XCTAssertEqual(outcome.succeededIDs, ["id-alpha", "id-beta", "id-gamma"])
        XCTAssertTrue(outcome.failedIDs.isEmpty)
        XCTAssertEqual(outcome.commands.map(\.arguments), fixture.runner.commands.map(\.arguments))
        XCTAssertEqual(outcome.executedCommands, outcome.commands)
        XCTAssertTrue(outcome.output.contains("Alpha"))
        XCTAssertTrue(outcome.output.contains("Beta"))
        XCTAssertTrue(outcome.output.contains("Gamma"))
        XCTAssertTrue(outcome.output.contains("alpha started"))
        XCTAssertEqual(fixture.history.records.count, 3)
        XCTAssertTrue(fixture.history.records.allSatisfy { $0.title == "Start" && $0.succeeded })
        XCTAssertEqual(
            Set(fixture.history.records.map(\.command)),
            Set(outcome.commands.map(\.displayString))
        )
    }

    func testStartContinuesAfterRuntimeFailureAndMapsOnlyFailedTarget() async {
        let fixture = makeFixture([
            .result(0, "alpha started", "", []),
            .result(125, "", "beta could not start", []),
            .result(0, "gamma started", "", [])
        ])
        let targets = [
            target("alpha", name: "Alpha"),
            target("beta", name: "Beta"),
            target("gamma", name: "Gamma")
        ]

        let outcome = await fixture.service.runContainerBatch(
            ContainerBatchRequest(operation: .start, targets: targets)
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(fixture.runner.commands.map(\.arguments), [
            ["start", "alpha"],
            ["start", "beta"],
            ["start", "gamma"]
        ])
        XCTAssertEqual(outcome.itemResults.map(\.succeeded), [true, false, true])
        XCTAssertEqual(outcome.succeededIDs, ["alpha", "gamma"])
        XCTAssertEqual(outcome.failedIDs, ["beta"])
        XCTAssertTrue(outcome.output.contains("Failed to start 1 of 3 containers"))
        XCTAssertTrue(outcome.output.contains("Beta"))
        XCTAssertTrue(outcome.output.contains("beta could not start"))
        XCTAssertFalse(outcome.output.contains("Started 3 containers"))
        XCTAssertEqual(fixture.history.records.count, 3)
        XCTAssertEqual(
            fixture.history.records.first { $0.command.contains(" beta") }?.exitCode,
            125
        )
    }

    func testStartContinuesAfterThrownRunnerErrorAndRecordsAttempt() async {
        let fixture = makeFixture([
            .failure("runner launch failed", []),
            .result(0, "later target started", "", [])
        ])
        let targets = [
            target("broken", name: "Broken"),
            target("later", name: "Later")
        ]

        let outcome = await fixture.service.runContainerBatch(
            ContainerBatchRequest(operation: .start, targets: targets)
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(fixture.runner.commands.map(\.arguments), [
            ["start", "broken"],
            ["start", "later"]
        ])
        XCTAssertEqual(outcome.succeededIDs, ["later"])
        XCTAssertEqual(outcome.failedIDs, ["broken"])
        XCTAssertEqual(outcome.itemResults.first?.errorMessage, "runner launch failed")
        XCTAssertEqual(outcome.itemResults.last?.result?.stdout, "later target started")
        XCTAssertTrue(outcome.output.contains("Broken"))
        XCTAssertTrue(outcome.output.contains("runner launch failed"))
        XCTAssertEqual(outcome.commands.count, 2)
        XCTAssertEqual(fixture.history.records.count, 2)
        XCTAssertEqual(
            fixture.history.records.first { $0.command.contains(" broken") }?.succeeded,
            false
        )
    }

    func testStartMapsResolverFailuresToEveryTargetWithoutRunningOrRecording() async {
        let fixture = makeFixture([], executableAvailable: false)
        let targets = [
            target("alpha", name: "Alpha"),
            target("beta", name: "Beta")
        ]

        let outcome = await fixture.service.runContainerBatch(
            ContainerBatchRequest(operation: .start, targets: targets)
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.failedIDs, ["alpha", "beta"])
        XCTAssertTrue(outcome.succeededIDs.isEmpty)
        XCTAssertEqual(outcome.itemResults.count, 2)
        XCTAssertTrue(outcome.itemResults.allSatisfy { $0.command == nil && $0.errorMessage != nil })
        XCTAssertTrue(outcome.commands.isEmpty)
        XCTAssertTrue(fixture.runner.commands.isEmpty)
        XCTAssertTrue(fixture.history.records.isEmpty)
        XCTAssertEqual(fixture.fileSystem.checkedPaths, ["/fake/container", "/fake/container"])
        XCTAssertTrue(outcome.output.contains("Alpha"))
        XCTAssertTrue(outcome.output.contains("Beta"))
        XCTAssertTrue(outcome.output.contains("not executable"))
    }

    func testStopUsesOneMultiIdentifierCommandAndPreservesNames() async {
        let fixture = makeFixture([
            .result(0, "containers stopped\n", "", [])
        ])
        let targets = [
            target("first-id", name: "First Container", state: "running"),
            target("second-id", name: "Second Container", state: "running")
        ]

        let outcome = await fixture.service.runContainerBatch(
            ContainerBatchRequest(operation: .stop, targets: targets)
        )

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(fixture.runner.commands.count, 1)
        XCTAssertEqual(fixture.runner.commands.first?.arguments, ["stop", "first-id", "second-id"])
        XCTAssertEqual(fixture.runner.commands.first?.timeout, 60)
        XCTAssertEqual(outcome.targets, targets)
        XCTAssertTrue(outcome.itemResults.isEmpty)
        XCTAssertEqual(outcome.succeededIDs, ["first-id", "second-id"])
        XCTAssertTrue(outcome.failedIDs.isEmpty)
        XCTAssertEqual(outcome.batchResult?.exitCode, 0)
        XCTAssertTrue(outcome.output.contains("First Container"))
        XCTAssertTrue(outcome.output.contains("Second Container"))
        XCTAssertTrue(outcome.output.contains("containers stopped"))
        XCTAssertEqual(fixture.history.records.count, 1)
        XCTAssertEqual(fixture.history.records.first?.title, "Stop")
    }

    func testStopNonzeroExitMapsAllAttemptedIdentifiersToFailure() async {
        let fixture = makeFixture([
            .result(7, "stop diagnostic", "stop failed", [])
        ])
        let targets = [
            target("first", name: "First", state: "running"),
            target("second", name: "Second", state: "running")
        ]

        let outcome = await fixture.service.runContainerBatch(
            ContainerBatchRequest(operation: .stop, targets: targets)
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(fixture.runner.commands.map(\.arguments), [["stop", "first", "second"]])
        XCTAssertTrue(outcome.succeededIDs.isEmpty)
        XCTAssertEqual(outcome.failedIDs, ["first", "second"])
        XCTAssertEqual(outcome.batchResult?.exitCode, 7)
        XCTAssertTrue(outcome.itemResults.isEmpty)
        XCTAssertTrue(outcome.output.contains("Failed to stop 2 containers"))
        XCTAssertTrue(outcome.output.contains("stop diagnostic"))
        XCTAssertTrue(outcome.output.contains("stop failed"))
        XCTAssertEqual(fixture.history.records.count, 1)
        XCTAssertEqual(fixture.history.records.first?.exitCode, 7)
        XCTAssertEqual(fixture.history.records.first?.succeeded, false)
    }

    func testDeleteBuildsOrdinaryAndForcedMultiIdentifierCommands() async {
        let ordinary = makeFixture([
            .result(0, "deleted", "", [])
        ])
        let forced = makeFixture([
            .result(9, "", "forced delete failed", [])
        ])
        let targets = [
            target("alpha", name: "Alpha"),
            target("beta", name: "Beta")
        ]

        let ordinaryOutcome = await ordinary.service.runContainerBatch(
            ContainerBatchRequest(operation: .delete, targets: targets)
        )
        let forcedOutcome = await forced.service.runContainerBatch(
            ContainerBatchRequest(operation: .delete, targets: targets, forceDelete: true)
        )

        XCTAssertEqual(ordinary.runner.commands.map(\.arguments), [["delete", "alpha", "beta"]])
        XCTAssertTrue(ordinaryOutcome.succeeded)
        XCTAssertEqual(ordinaryOutcome.succeededIDs, ["alpha", "beta"])
        XCTAssertEqual(ordinary.history.records.count, 1)

        XCTAssertEqual(forced.runner.commands.map(\.arguments), [["delete", "--force", "alpha", "beta"]])
        XCTAssertFalse(forcedOutcome.succeeded)
        XCTAssertTrue(forcedOutcome.succeededIDs.isEmpty)
        XCTAssertEqual(forcedOutcome.failedIDs, ["alpha", "beta"])
        XCTAssertEqual(forcedOutcome.batchResult?.exitCode, 9)
        XCTAssertTrue(forcedOutcome.output.contains("Failed to delete 2 containers"))
        XCTAssertTrue(forcedOutcome.output.contains("forced delete failed"))
        XCTAssertEqual(forced.history.records.count, 1)
    }

    func testThrownMultiIdentifierCommandMapsAllTargetsToFailure() async {
        let fixture = makeFixture([
            .failure("delete process could not launch", [])
        ])
        let targets = [target("alpha", name: "Alpha"), target("beta", name: "Beta")]

        let outcome = await fixture.service.runContainerBatch(
            ContainerBatchRequest(operation: .delete, targets: targets)
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.failedIDs, ["alpha", "beta"])
        XCTAssertTrue(outcome.succeededIDs.isEmpty)
        XCTAssertNil(outcome.batchResult)
        XCTAssertEqual(outcome.errorMessage, "delete process could not launch")
        XCTAssertEqual(outcome.commands.map(\.arguments), [["delete", "alpha", "beta"]])
        XCTAssertTrue(outcome.output.contains("delete process could not launch"))
        XCTAssertEqual(fixture.runner.commands.count, 1)
        XCTAssertEqual(fixture.history.records.count, 1)
        XCTAssertNil(fixture.history.records.first?.exitCode)
    }

    func testStreamingHandlerReceivesEveryStartStopAndDeleteEvent() async {
        let fixture = makeFixture([
            .result(0, "", "", [.init(source: .stdout, text: "start alpha\n")]),
            .result(0, "", "", [.init(source: .stderr, text: "start beta warning\n")]),
            .result(0, "", "", [.init(source: .stdout, text: "stop batch\n")]),
            .result(0, "", "", [.init(source: .stderr, text: "delete batch warning\n")])
        ])
        let events = BatchEventBuffer()
        let targets = [target("alpha"), target("beta")]

        _ = await fixture.service.runContainerBatch(
            ContainerBatchRequest(operation: .start, targets: targets)
        ) { events.append($0) }
        _ = await fixture.service.runContainerBatch(
            ContainerBatchRequest(operation: .stop, targets: targets)
        ) { events.append($0) }
        _ = await fixture.service.runContainerBatch(
            ContainerBatchRequest(operation: .delete, targets: targets)
        ) { events.append($0) }

        XCTAssertEqual(events.values, [
            "stdout:start alpha\n",
            "stderr:start beta warning\n",
            "stdout:stop batch\n",
            "stderr:delete batch warning\n"
        ])
        XCTAssertEqual(fixture.runner.commands.map(\.arguments), [
            ["start", "alpha"],
            ["start", "beta"],
            ["stop", "alpha", "beta"],
            ["delete", "alpha", "beta"]
        ])
    }

    private func target(_ id: String, name: String? = nil, state: String = "stopped") -> ContainerBatchTarget {
        ContainerBatchTarget(id: id, name: name ?? id, state: state)
    }

    private func makeFixture(
        _ behaviors: [BatchStubBehavior],
        executableAvailable: Bool = true
    ) -> (
        service: OperationService,
        runner: BatchStubRunner,
        history: BatchHistoryStore,
        fileSystem: BatchRecordingFileSystem
    ) {
        let runner = BatchStubRunner(behaviors: behaviors)
        let history = BatchHistoryStore()
        let fileSystem = BatchRecordingFileSystem(executableAvailable: executableAvailable)
        let service = OperationService(
            preferences: BatchStubPreferences(cliExecutablePath: "/fake/container"),
            resolver: ContainerCLIResolver(
                fileSystem: fileSystem,
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: []
            ),
            runner: runner,
            historyStore: history
        )
        return (service, runner, history, fileSystem)
    }
}

private enum BatchStubBehavior: Sendable {
    case result(Int32, String, String, [ProcessOutputEvent])
    case failure(String, [ProcessOutputEvent])
}

private struct BatchStubError: Error, LocalizedError, Sendable {
    var message: String

    var errorDescription: String? {
        message
    }
}

private final class BatchStubRunner: ProcessRunning, @unchecked Sendable {
    private(set) var commands: [ProcessCommand] = []
    private var behaviors: [BatchStubBehavior]

    init(behaviors: [BatchStubBehavior]) {
        self.behaviors = behaviors
    }

    func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
        try await run(command, outputHandler: nil)
    }

    func run(_ command: ProcessCommand, outputHandler: ProcessOutputHandler?) async throws -> CLIProcessResult {
        commands.append(command)
        let behavior = behaviors.isEmpty ? .result(0, "", "", []) : behaviors.removeFirst()
        switch behavior {
        case .result(let exitCode, let stdout, let stderr, let events):
            events.forEach { outputHandler?($0) }
            return CLIProcessResult(
                preview: command.preview,
                exitCode: exitCode,
                stdout: stdout,
                stderr: stderr
            )
        case .failure(let message, let events):
            events.forEach { outputHandler?($0) }
            throw BatchStubError(message: message)
        }
    }
}

private final class BatchHistoryStore: OperationHistoryStoring, @unchecked Sendable {
    private(set) var records: [OperationRecord] = []

    func append(_ record: OperationRecord) {
        records.insert(record, at: 0)
    }

    func recent(limit: Int) -> [OperationRecord] {
        Array(records.prefix(limit))
    }
}

private final class BatchStubPreferences: AppPreferences, @unchecked Sendable {
    var cliExecutablePath: String?

    init(cliExecutablePath: String?) {
        self.cliExecutablePath = cliExecutablePath
    }
}

private final class BatchRecordingFileSystem: FileSystemChecking, @unchecked Sendable {
    private(set) var checkedPaths: [String] = []
    private let executableAvailable: Bool

    init(executableAvailable: Bool) {
        self.executableAvailable = executableAvailable
    }

    func isExecutableFile(atPath path: String) -> Bool {
        checkedPaths.append(path)
        return executableAvailable
    }
}

private final class BatchEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: ProcessOutputEvent) {
        let source: String
        switch event.source {
        case .stdout:
            source = "stdout"
        case .stderr:
            source = "stderr"
        }
        lock.lock()
        storage.append("\(source):\(event.text)")
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        let result = storage
        lock.unlock()
        return result
    }
}
