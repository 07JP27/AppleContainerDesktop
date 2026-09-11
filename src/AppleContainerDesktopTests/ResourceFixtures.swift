import Foundation
@testable import AppleContainerDesktop

enum ResourceFixtures {
    static let container = """
    {
      "id": "web",
      "configuration": {
        "id": "web",
        "image": {
          "reference": "registry.example:5000/team/web:dev",
          "descriptor": {"digest": "sha256:index", "size": 456}
        },
        "creationDate": "2026-08-01T10:00:00Z",
        "publishedPorts": [
          {"hostAddress": "127.0.0.1", "hostPort": 8080, "containerPort": 80, "proto": "tcp"},
          {"hostAddress": "::1", "hostPort": 9000, "containerPort": 8000, "proto": "udp", "count": 2}
        ],
        "mounts": [
          {"type": {"volume": {"name": "site-data"}}, "source": "/private/volume.img", "destination": "/data", "options": ["ro"]},
          {"type": {"virtiofs": {}}, "source": "/Users/test/project", "destination": "/workspace", "options": []}
        ],
        "resources": {"cpus": 2, "memoryInBytes": 1073741824},
        "initProcess": {
          "executable": "/bin/sh", "arguments": ["-c", "echo ready"],
          "environment": ["PASSWORD=private-value"], "workingDirectory": "/workspace"
        }
      },
      "status": {
        "state": "running",
        "startedDate": "2026-09-10T12:00:00.125Z",
        "networks": [{"network": "default", "ipv4Address": "192.168.64.2/24", "ipv6Address": "fd00::2/64"}]
      }
    }
    """

    static let image = """
    {
      "id": "index",
      "configuration": {
        "name": "registry.example:5000/team/web:dev",
        "creationDate": "2026-08-01T10:00:00Z",
        "descriptor": {"digest": "sha256:index", "size": 456}
      },
      "variants": [
        {"platform": {"os": "linux", "architecture": "arm64"}, "digest": "sha256:arm", "size": 4000000, "config": {"created": "2026-08-01T10:00:00Z"}},
        {"platform": {"os": "linux", "architecture": "amd64"}, "digest": "sha256:amd", "size": 6000000, "config": {"created": "2026-08-02T10:00:00Z"}},
        {"platform": {"os": "unknown", "architecture": "unknown"}, "digest": "sha256:attestation", "size": 90000000, "config": {}}
      ]
    }
    """

    static func row(_ json: String, kind: ResourceKind) throws -> ResourceListItem {
        guard let row = try ResourceJSONParser().parseList("[\(json)]", kind: kind).first else {
            throw ResourceParserError.unexpectedShape(kind)
        }
        return row
    }

    static func service(runner: ProcessRunning) -> ResourceService {
        ResourceService(
            preferences: FixturePreferences(),
            resolver: ContainerCLIResolver(
                fileSystem: FixtureFileSystem(),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner
        )
    }

    static func operations(runner: ProcessRunning) -> OperationService {
        OperationService(
            preferences: FixturePreferences(),
            resolver: ContainerCLIResolver(
                fileSystem: FixtureFileSystem(),
                environment: CLIResolverEnvironment(path: nil),
                knownPaths: ["/fake/container"]
            ),
            runner: runner,
            historyStore: FixtureHistory()
        )
    }
}

actor ResourceFixtureRunner: ProcessRunning {
    let containers: String
    let images: String
    let containerListExitCode: Int32
    let imageListExitCode: Int32
    let inspectExitCode: Int32
    let fallbackJSON: String
    private var commands: [[String]] = []

    init(
        containers: String = "[\(ResourceFixtures.container)]",
        images: String = "[\(ResourceFixtures.image)]",
        containerListExitCode: Int32 = 0,
        imageListExitCode: Int32 = 0,
        inspectExitCode: Int32 = 0,
        fallbackJSON: String = "[]"
    ) {
        self.containers = containers
        self.images = images
        self.containerListExitCode = containerListExitCode
        self.imageListExitCode = imageListExitCode
        self.inspectExitCode = inspectExitCode
        self.fallbackJSON = fallbackJSON
    }

    func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
        commands.append(command.arguments)
        let output: String
        let exitCode: Int32
        if command.arguments.starts(with: ["image", "list"]) {
            output = images
            exitCode = imageListExitCode
        } else if command.arguments.starts(with: ["image", "inspect"]) {
            output = images
            exitCode = inspectExitCode
        } else if command.arguments.first == "list" {
            output = containers
            exitCode = containerListExitCode
        } else if command.arguments.first == "inspect" {
            output = containers
            exitCode = inspectExitCode
        } else if command.arguments.first == "logs" {
            output = "log line"
            exitCode = 0
        } else {
            output = fallbackJSON
            exitCode = 0
        }
        return CLIProcessResult(preview: command.preview, exitCode: exitCode, stdout: output, stderr: exitCode == 0 ? "" : "request failed")
    }

    func recordedCommands() -> [[String]] { commands }
}

private final class FixturePreferences: AppPreferences, @unchecked Sendable {
    var cliExecutablePath: String?
}

private struct FixtureFileSystem: FileSystemChecking {
    func isExecutableFile(atPath path: String) -> Bool { path == "/fake/container" }
}

private struct FixtureHistory: OperationHistoryStoring {
    func append(_ record: OperationRecord) {}
    func recent(limit: Int) -> [OperationRecord] { [] }
}
