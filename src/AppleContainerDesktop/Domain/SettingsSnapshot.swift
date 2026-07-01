import Foundation

struct SettingsSnapshot: Equatable, Sendable {
    var detection: CLIDetectionResult
    var version: VersionSummary?
    var propertiesJSON: String?
    var errorMessage: String?
    var command: CLICommandPreview?
}

