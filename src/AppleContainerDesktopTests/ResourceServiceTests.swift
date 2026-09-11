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

    func testImageUsageIncludesStoppedContainersAndAliasesWithoutPerImageRequests() async throws {
        let worker = ResourceFixtures.container
            .replacingOccurrences(of: "\"web\"", with: "\"worker\"")
            .replacingOccurrences(of: "\"running\"", with: "\"stopped\"")
        let alias = ResourceFixtures.image.replacingOccurrences(of: "registry.example:5000/team/web:dev", with: "example/alias:stable")
        let runner = ResourceFixtureRunner(containers: "[\(ResourceFixtures.container),\(worker)]", images: "[\(ResourceFixtures.image),\(alias)]")
        let snapshot = await ResourceFixtures.service(runner: runner).load(kind: .images)
        XCTAssertNil(snapshot.errorMessage)
        XCTAssertNil(snapshot.warningMessage)
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertNotEqual(snapshot.items.first?.id, snapshot.items.last?.id)
        for item in snapshot.items {
            let users = try XCTUnwrap(item.image?.usage.containers)
            XCTAssertEqual(Set(users.map(\.name)), ["web", "worker"])
            XCTAssertTrue(users.contains { $0.state == "stopped" })
            XCTAssertEqual(ResourceListColumn.inUse.cell(for: item).text, "In use")
        }
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [ResourceKind.images.listArguments, ResourceKind.containers.listArguments])
    }

    func testReusedTagWithDifferentDigestIsNotReportedInUse() async throws {
        let image = ResourceFixtures.image.replacingOccurrences(of: "sha256:index", with: "sha256:new-index")
        let snapshot = await ResourceFixtures.service(runner: ResourceFixtureRunner(images: "[\(image)]")).load(kind: .images)
        XCTAssertEqual(snapshot.items.first?.image?.usage, .known([]))
    }

    func testUsageRequestFailureKeepsImagesButDoesNotMarkThemUnused() async {
        let snapshot = await ResourceFixtures.service(runner: ResourceFixtureRunner(containerListExitCode: 1)).load(kind: .images)
        XCTAssertNil(snapshot.errorMessage)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items.first?.image?.usage, .unavailable)
        XCTAssertNotNil(snapshot.warningMessage)
    }

    func testMalformedUsageDataIsVisibleAsUnavailable() async {
        let snapshot = await ResourceFixtures.service(runner: ResourceFixtureRunner(containers: "not JSON")).load(kind: .images)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items.first?.image?.usage, .unavailable)
        XCTAssertNotNil(snapshot.warningMessage)
    }

    func testIncompleteContainerIdentityDoesNotProveImagesUnused() async {
        let runner = ResourceFixtureRunner(containers: #"[{"id":"mystery","status":"stopped"}]"#)
        let snapshot = await ResourceFixtures.service(runner: runner).load(kind: .images)
        XCTAssertEqual(snapshot.items.first?.image?.usage, .unavailable)
        XCTAssertNotNil(snapshot.warningMessage)
    }

    func testIncomparableDigestOnlyContainerDoesNotProveLegacyImageUnused() async {
        let runner = ResourceFixtureRunner(
            containers: #"[{"id":"mystery","imageDigest":"sha256:index","status":"stopped"}]"#,
            images: #"[{"reference":"example/web:dev"}]"#
        )
        let snapshot = await ResourceFixtures.service(runner: runner).load(kind: .images)
        XCTAssertEqual(snapshot.items.first?.image?.usage, .unavailable)
        XCTAssertNotNil(snapshot.warningMessage)
    }

    func testEmptyImageListSkipsUsageRequest() async {
        let runner = ResourceFixtureRunner(images: "[]")
        let snapshot = await ResourceFixtures.service(runner: runner).load(kind: .images)
        XCTAssertTrue(snapshot.items.isEmpty)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [ResourceKind.images.listArguments])
    }

    func testImageListFailureStillUsesExistingErrorState() async {
        let snapshot = await ResourceFixtures.service(runner: ResourceFixtureRunner(imageListExitCode: 2)).load(kind: .images)
        XCTAssertNotNil(snapshot.errorMessage)
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testInspectItemPreservesUsageAndCanonicalIdentity() async {
        let usage = ImageUsage.known([ImageContainerUsage(id: "web", name: "web", state: "running")])
        let result = await ResourceFixtures.service(runner: ResourceFixtureRunner()).inspectItem(
            kind: .images, identifier: "registry.example:5000/team/web:dev", imageUsage: usage
        )
        XCTAssertNil(result.error)
        XCTAssertEqual(result.item?.inspectIdentifier, "registry.example:5000/team/web:dev")
        XCTAssertEqual(result.item?.image?.usage, usage)
    }

    func testInspectItemRejectsAnotherResource() async {
        let result = await ResourceFixtures.service(runner: ResourceFixtureRunner()).inspectItem(kind: .containers, identifier: "different")
        XCTAssertNil(result.item)
        XCTAssertNotNil(result.error)
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
