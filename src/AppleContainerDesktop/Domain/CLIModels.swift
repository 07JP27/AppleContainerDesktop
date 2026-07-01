import Foundation

enum CLIExecutableSource: Equatable, Sendable {
    case settingsOverride
    case path
    case knownLocation
}

struct CLIDetectionResult: Equatable, Sendable {
    var executableURL: URL?
    var source: CLIExecutableSource?
    var problem: String?

    var isAvailable: Bool {
        executableURL != nil
    }
}

struct VersionComponent: Decodable, Equatable, Sendable {
    var appName: String
    var buildType: String?
    var commit: String?
    var version: String?
}

struct VersionSummary: Equatable, Sendable {
    var cliVersion: String?
    var apiServerVersion: String?

    init(components: [VersionComponent]) {
        cliVersion = components.first { $0.appName == "container" }?.version
        apiServerVersion = components.first { $0.appName == "container-apiserver" }?.version
    }
}

struct CLICommandPreview: Equatable, Sendable {
    var executable: String
    var arguments: [String]

    var displayString: String {
        ([executable] + arguments.map(Self.shellEscaped)).joined(separator: " ")
    }

    private static func shellEscaped(_ value: String) -> String {
        if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\"'"))) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct CLIProcessResult: Equatable, Sendable {
    var preview: CLICommandPreview
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool {
        exitCode == 0
    }
}

struct SystemStartOutcome: Equatable, Sendable {
    var command: CLICommandPreview?
    var result: CLIProcessResult?
    var errorMessage: String?

    var succeeded: Bool {
        result?.succeeded == true && errorMessage == nil
    }

    var detail: String {
        if let errorMessage {
            return errorMessage
        }
        guard let result else {
            return ""
        }
        return result.stderr.isEmpty ? result.stdout : result.stderr
    }
}

enum CLIClientError: Error, Equatable, Sendable {
    case processFailed(CLIProcessResult)
    case decodingFailed(command: CLICommandPreview, output: String)
}

extension CLIClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .processFailed(let result):
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            return detail.isEmpty ? "Command failed with exit code \(result.exitCode)." : detail
        case .decodingFailed:
            return "Command returned JSON in an unexpected shape."
        }
    }
}
