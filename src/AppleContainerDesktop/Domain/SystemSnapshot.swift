import Foundation

enum ServiceHealth: Equatable, Sendable {
    case missingCLI
    case running
    case stopped
    case unhealthy
    case unknown

    var label: String {
        switch self {
        case .missingCLI:
            "Missing CLI"
        case .running:
            "Running"
        case .stopped:
            "Stopped"
        case .unhealthy:
            "Unhealthy"
        case .unknown:
            "Unknown"
        }
    }
}

struct SystemSnapshot: Equatable, Sendable {
    var detection: CLIDetectionResult
    var health: ServiceHealth
    var version: VersionSummary?
    var statusJSON: String?
    var diskUsageJSON: String?
    var message: String
    var lastCommand: CLICommandPreview?
    var errorDetail: String?
}
