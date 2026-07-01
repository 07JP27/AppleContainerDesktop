import Foundation

protocol FileSystemChecking: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
}

struct LocalFileSystemChecker: FileSystemChecking, Sendable {
    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

struct CLIResolverEnvironment: Sendable {
    var path: String?

    static var process: CLIResolverEnvironment {
        CLIResolverEnvironment(path: ProcessInfo.processInfo.environment["PATH"])
    }
}

struct ContainerCLIResolver: Sendable {
    var fileSystem: FileSystemChecking
    var environment: CLIResolverEnvironment
    var knownPaths: [String]

    init(
        fileSystem: FileSystemChecking = LocalFileSystemChecker(),
        environment: CLIResolverEnvironment = .process,
        knownPaths: [String] = [
            "/usr/local/bin/container",
            "/Library/Apple/usr/bin/container"
        ]
    ) {
        self.fileSystem = fileSystem
        self.environment = environment
        self.knownPaths = knownPaths
    }

    func resolve(overridePath: String?) -> CLIDetectionResult {
        if let overridePath, !overridePath.isEmpty {
            if fileSystem.isExecutableFile(atPath: overridePath) {
                return CLIDetectionResult(
                    executableURL: URL(fileURLWithPath: overridePath),
                    source: .settingsOverride,
                    problem: nil
                )
            }

            return CLIDetectionResult(
                executableURL: nil,
                source: .settingsOverride,
                problem: "The configured container executable is not executable: \(overridePath)"
            )
        }

        if let pathCandidate = resolveFromPATH() {
            return CLIDetectionResult(
                executableURL: URL(fileURLWithPath: pathCandidate),
                source: .path,
                problem: nil
            )
        }

        if let knownCandidate = knownPaths.first(where: fileSystem.isExecutableFile(atPath:)) {
            return CLIDetectionResult(
                executableURL: URL(fileURLWithPath: knownCandidate),
                source: .knownLocation,
                problem: nil
            )
        }

        return CLIDetectionResult(
            executableURL: nil,
            source: nil,
            problem: "Apple container CLI was not found. Install Apple's signed package from the container releases page."
        )
    }

    private func resolveFromPATH() -> String? {
        guard let path = environment.path, !path.isEmpty else {
            return nil
        }

        return path
            .split(separator: ":")
            .map { String($0) + "/container" }
            .first(where: fileSystem.isExecutableFile(atPath:))
    }
}
