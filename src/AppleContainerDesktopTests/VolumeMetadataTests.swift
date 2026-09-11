import Foundation
import XCTest
@testable import AppleContainerDesktop

final class VolumeMetadataTests: XCTestCase {
    func testCurrentVolumeMetadataUsesExactNameAndSafeListPresentation() throws {
        let item = try volumeItem(VolumeTestFixtures.named)
        let volume = try XCTUnwrap(item.volume)

        XCTAssertEqual(item.id, "team/data.v1")
        XCTAssertEqual(item.title, "team/data.v1")
        XCTAssertEqual(item.inspectIdentifier, "team/data.v1")
        XCTAssertEqual(item.status, "--")
        XCTAssertEqual(volume.name, "team/data.v1")
        XCTAssertEqual(volume.driver, "local")
        XCTAssertEqual(volume.format, "ext4")
        XCTAssertEqual(volume.capacityBytes, 536_870_912)
        XCTAssertEqual(volume.labels["team"], "private-label-value")
        XCTAssertEqual(volume.options["journal"], "private-option-value")
        XCTAssertFalse(volume.isAnonymous)
        XCTAssertNotNil(volume.createdAt)

        XCTAssertTrue(item.detail.contains("local"))
        XCTAssertTrue(item.detail.contains("ext4"))
        XCTAssertFalse(item.detail.contains(VolumeTestFixtures.backingSource))
        XCTAssertFalse(item.detail.contains("private-label-value"))
        XCTAssertFalse(item.detail.contains("private-option-value"))
        XCTAssertTrue(item.searchableText.contains("team/data.v1"))
        XCTAssertTrue(item.searchableText.contains("local"))
        XCTAssertFalse(item.searchableText.contains(VolumeTestFixtures.backingSource))
        XCTAssertFalse(item.searchableText.contains("private-label-value"))
        XCTAssertFalse(item.searchableText.contains("private-option-value"))
        XCTAssertFalse(Mirror(reflecting: volume).children.compactMap(\.label).contains("source"))
    }

    func testCurrentAndLegacyDatesAndReservedAnonymousLabel() throws {
        let current = try XCTUnwrap(volumeItem(VolumeTestFixtures.named).volume)
        let legacy = try XCTUnwrap(volumeItem(VolumeTestFixtures.legacy).volume)
        let anonymous = try XCTUnwrap(volumeItem(VolumeTestFixtures.anonymous).volume)
        let uuidNamed = try XCTUnwrap(volumeItem(VolumeTestFixtures.uuidNamed).volume)
        let epoch = try XCTUnwrap(volumeItem(VolumeTestFixtures.epoch).volume)

        XCTAssertEqual(try XCTUnwrap(current.createdAt).timeIntervalSince1970, 1_788_783_845, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(legacy.createdAt).timeIntervalSince1970, 1_757_145_600, accuracy: 0.001)
        XCTAssertTrue(anonymous.isAnonymous)
        XCTAssertEqual(anonymous.labels[VolumeMetadata.anonymousLabel], "")
        XCTAssertFalse(uuidNamed.isAnonymous)
        XCTAssertNil(epoch.createdAt)
    }

    func testCapacityRejectsOverflowMalformedFractionalAndNegativeValues() throws {
        for size in ["9223372036854775808", #""not-a-size""#, "1.5", "-1"] {
            let json = VolumeTestFixtures.volume(size: size)
            XCTAssertNil(try volumeItem(json).volume?.capacityBytes, "Expected \(size) to be unavailable")
        }
        XCTAssertEqual(
            try volumeItem(VolumeTestFixtures.volume(size: "9223372036854775807")).volume?.capacityBytes,
            Int64.max
        )
    }

    func testVolumeNameIsRequiredAndNeverInventedFromRootID() {
        let missingName = """
        {"id":"root-only","configuration":{"driver":"local","format":"ext4","source":"/private/backing"}}
        """
        let whitespaceName = """
        {"id":"root-id","configuration":{"name":"two words","driver":"local","format":"ext4","source":"/private/backing"}}
        """

        XCTAssertThrowsError(try ResourceJSONParser().parseList("[\(missingName)]", kind: .volumes)) {
            XCTAssertEqual($0 as? ResourceParserError, .missingIdentity(.volumes))
        }
        XCTAssertThrowsError(try ResourceJSONParser().parseList("[\(whitespaceName)]", kind: .volumes)) {
            XCTAssertEqual($0 as? ResourceParserError, .missingIdentity(.volumes))
        }
    }

    func testVolumeOverviewShowsConfiguredCapacityAndRunningAndStoppedUsers() throws {
        var item = try volumeItem(VolumeTestFixtures.named)
        item.setVolumeUsage(.known([
            VolumeContainerUsage(id: "web", name: "web", state: "running", mountTarget: "/srv/data"),
            VolumeContainerUsage(id: "worker", name: "worker", state: "stopped", mountTarget: "/var/work")
        ]))

        let overview = try XCTUnwrap(ResourceOverview(item: item))
        let fields = overview.sections.flatMap(\.fields)
        let rendered = fields.flatMap { [$0.label, $0.value, $0.tooltip].compactMap { $0 } }.joined(separator: "\n")

        XCTAssertEqual(overview.title, "team/data.v1")
        XCTAssertTrue(fields.contains { $0.label == "Type" && $0.value == "Named" })
        XCTAssertTrue(fields.contains { $0.label == "Driver" && $0.value == "local" })
        XCTAssertTrue(fields.contains { $0.label == "Filesystem format" && $0.value == "ext4" })
        XCTAssertTrue(fields.contains { $0.label == "Configured capacity" && $0.value != "Not provided" })
        XCTAssertFalse(fields.contains { $0.label == "Disk usage" || $0.label == "Stored data" })
        XCTAssertTrue(fields.contains { $0.label == "web" && $0.value.contains("Running") && $0.value.contains("/srv/data") })
        XCTAssertTrue(fields.contains { $0.label == "worker" && $0.value.contains("Stopped") && $0.value.contains("/var/work") })
        XCTAssertFalse(rendered.contains(VolumeTestFixtures.backingSource))
        XCTAssertFalse(rendered.contains("private-label-value"))
        XCTAssertFalse(rendered.contains("private-option-value"))
        XCTAssertFalse(rendered.contains("\"configuration\""))
    }

    func testInspectVolumeUsesOneAllContainerRequestAndIncludesStoppedNamedMounts() async throws {
        let runner = VolumeTestRunner(containers: VolumeTestFixtures.containers)
        let result = await volumeService(runner: runner).inspectVolumeItem(identifier: "team/data.v1")
        let item = try XCTUnwrap(result.item)
        let users = try XCTUnwrap(item.volume?.usage.containers)

        XCTAssertNil(result.error)
        XCTAssertEqual(item.id, "team/data.v1")
        XCTAssertEqual(item.inspectIdentifier, "team/data.v1")
        XCTAssertEqual(item.status, "In use")
        XCTAssertEqual(users.map(\.name), ["web", "worker"])
        XCTAssertEqual(users.map(\.state), ["running", "stopped"])
        XCTAssertEqual(users.map(\.mountTarget), ["/srv/data", "/var/work"])
        XCTAssertFalse(users.contains { $0.name == "bind-only" })
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [
            ["volume", "inspect", "team/data.v1"],
            ["list", "--all", "--format", "json"]
        ])
    }

    func testValidEmptyContainerListProvesVolumeUnused() async throws {
        let runner = VolumeTestRunner(containers: "[]")
        let result = await volumeService(runner: runner).inspectVolumeItem(identifier: "team/data.v1")
        let item = try XCTUnwrap(result.item)

        XCTAssertNil(result.error)
        XCTAssertEqual(item.volume?.usage, .known([]))
        XCTAssertEqual(item.status, "Unused")
        let overview = try XCTUnwrap(ResourceOverview(item: item))
        XCTAssertTrue(overview.sections.flatMap(\.fields).contains {
            $0.label == "Containers" && $0.value == "No containers use this volume"
        })
    }

    func testContainerQueryFailureKeepsReadableVolumeUsageUnavailable() async throws {
        let runner = VolumeTestRunner(containers: "[]", containerExitCode: 2)
        let result = await volumeService(runner: runner).inspectVolumeItem(identifier: "team/data.v1")
        let item = try XCTUnwrap(result.item)

        XCTAssertEqual(item.volume?.usage, .unavailable)
        XCTAssertEqual(item.status, "--")
        XCTAssertNotNil(result.error)
        XCTAssertEqual(ResourceOverview(item: item, warning: result.error)?.warning, result.error)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.count, 2)
    }

    func testMalformedOrIncompleteContainerDataNeverProvesVolumeUnused() async throws {
        for output in [
            "not JSON",
            #"[{"configuration":{"mounts":[]},"status":{"state":"stopped"}}]"#,
            #"[{"id":"missing-mounts","status":{"state":"stopped"}}]"#
        ] {
            let runner = VolumeTestRunner(containers: output)
            let result = await volumeService(runner: runner).inspectVolumeItem(identifier: "team/data.v1")
            let item = try XCTUnwrap(result.item)

            XCTAssertEqual(item.volume?.usage, .unavailable)
            XCTAssertNotNil(result.error)
            let commands = await runner.recordedCommands()
            XCTAssertEqual(commands.count, 2)
        }
    }

    func testInspectFailureReturnsNoItemAndSkipsContainerList() async {
        let runner = VolumeTestRunner(volumeExitCode: 3)
        let result = await volumeService(runner: runner).inspectVolumeItem(identifier: "team/data.v1")

        XCTAssertNil(result.item)
        XCTAssertNotNil(result.error)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [["volume", "inspect", "team/data.v1"]])
    }

    func testGenericInspectCanPreserveKnownVolumeUsage() async throws {
        let usage = VolumeUsage.known([
            VolumeContainerUsage(id: "web", name: "web", state: "running", mountTarget: "/srv/data")
        ])
        let result = await volumeService(runner: VolumeTestRunner()).inspectItem(
            kind: .volumes,
            identifier: "team/data.v1",
            volumeUsage: usage
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.item?.volume?.usage, usage)
        XCTAssertEqual(result.item?.status, "In use")
    }

    private func volumeItem(_ json: String) throws -> ResourceListItem {
        try XCTUnwrap(ResourceJSONParser().parseList("[\(json)]", kind: .volumes).first)
    }

    private func volumeService(runner: ProcessRunning) -> ResourceService {
        ResourceService(
            preferences: VolumeTestPreferences(),
            resolver: ContainerCLIResolver(
                fileSystem: VolumeTestFileSystem(),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner
        )
    }
}

private enum VolumeTestFixtures {
    static let backingSource = "/Users/example/Library/Application Support/com.apple.container/volumes/team-data/volume.img"

    static let named = volume()

    static let legacy = volume(
        dateField: #""createdAt":"2025-09-06T08:00:00Z""#
    )

    static let anonymous = volume(
        name: "4c876388-df85-4d30-9e1a-3a294d732aca",
        labels: #""com.apple.container.resource.anonymous":"""#
    )

    static let uuidNamed = volume(
        name: "91ec411b-468a-4ec4-8479-d779348247bb",
        labels: #""purpose":"cache""#
    )

    static let epoch = volume(
        dateField: #""creationDate":"1970-01-01T00:00:00Z""#
    )

    static let containers = """
    [
      {
        "id": "web",
        "configuration": {
          "id": "web",
          "mounts": [
            {
              "type": {"volume": {"name": "team/data.v1"}},
              "source": "/private/runtime/backing.img",
              "destination": "/srv/data",
              "options": []
            }
          ]
        },
        "status": {"state": "running"}
      },
      {
        "id": "worker",
        "configuration": {
          "id": "worker",
          "mounts": [
            {
              "type": {"volume": {"name": "team/data.v1"}},
              "source": "/private/runtime/backing.img",
              "destination": "/var/work",
              "options": []
            }
          ]
        },
        "status": {"state": "stopped"}
      },
      {
        "id": "bind-only",
        "configuration": {
          "id": "bind-only",
          "mounts": [
            {
              "type": {"virtiofs": {}},
              "source": "team/data.v1",
              "destination": "/bind",
              "options": []
            }
          ]
        },
        "status": {"state": "running"}
      }
    ]
    """

    static func volume(
        name: String = "team/data.v1",
        dateField: String = #""creationDate":"2026-09-07T12:24:05Z""#,
        labels: String = #""team":"private-label-value""#,
        size: String = "536870912"
    ) -> String {
        """
        {
          "id": "opaque-runtime-id",
          "configuration": {
            "name": "\(name)",
            "driver": "local",
            "format": "ext4",
            \(dateField),
            "source": "\(backingSource)",
            "labels": {\(labels)},
            "options": {"journal": "private-option-value"},
            "sizeInBytes": \(size)
          }
        }
        """
    }
}

private actor VolumeTestRunner: ProcessRunning {
    let volume: String
    let containers: String
    let volumeExitCode: Int32
    let containerExitCode: Int32
    private var commands: [[String]] = []

    init(
        volume: String = "[\(VolumeTestFixtures.named)]",
        containers: String = "[]",
        volumeExitCode: Int32 = 0,
        containerExitCode: Int32 = 0
    ) {
        self.volume = volume
        self.containers = containers
        self.volumeExitCode = volumeExitCode
        self.containerExitCode = containerExitCode
    }

    func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
        commands.append(command.arguments)
        let isVolumeInspect = command.arguments.starts(with: ["volume", "inspect"])
        let isContainerList = command.arguments == ["list", "--all", "--format", "json"]
        let output = isVolumeInspect ? volume : (isContainerList ? containers : "")
        let exitCode = isVolumeInspect ? volumeExitCode : (isContainerList ? containerExitCode : 64)
        return CLIProcessResult(
            preview: command.preview,
            exitCode: exitCode,
            stdout: output,
            stderr: exitCode == 0 ? "" : "request failed"
        )
    }

    func recordedCommands() -> [[String]] {
        commands
    }
}

private final class VolumeTestPreferences: AppPreferences, @unchecked Sendable {
    var cliExecutablePath: String?
}

private struct VolumeTestFileSystem: FileSystemChecking {
    func isExecutableFile(atPath path: String) -> Bool {
        path == "/fake/container"
    }
}
