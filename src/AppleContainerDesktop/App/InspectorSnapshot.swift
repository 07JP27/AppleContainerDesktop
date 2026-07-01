import Foundation

struct InspectorSnapshot: Sendable {
    var title: String
    var subtitle: String?
    var command: CLICommandPreview?
    var detail: String?
    var json: String?

    static let empty = InspectorSnapshot(
        title: "Inspector",
        subtitle: "Select a resource to inspect command output, JSON, metadata, and actions.",
        command: nil,
        detail: nil,
        json: nil
    )
}

