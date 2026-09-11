import Foundation

struct InspectorSnapshot: Sendable {
    var title: String
    var subtitle: String?
    var command: CLICommandPreview?
    var detail: String?
    var json: String?
    var overview: ResourceOverview? = nil

    static func resource(_ item: ResourceListItem, warning: String? = nil) -> InspectorSnapshot {
        InspectorSnapshot(
            title: item.title,
            subtitle: nil,
            command: nil,
            detail: nil,
            json: nil,
            overview: ResourceOverview(item: item, warning: warning)
        )
    }

    static let empty = InspectorSnapshot(
        title: "Inspector",
        subtitle: "Select a resource to view its details.",
        command: nil,
        detail: nil,
        json: nil
    )
}
