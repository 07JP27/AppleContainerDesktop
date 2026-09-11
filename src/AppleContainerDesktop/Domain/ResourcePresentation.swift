import Foundation

enum ResourceListColumn: String, CaseIterable, Sendable {
    case name, status, detail, image, ports, lastStarted, tag, digest, created, size, inUse

    static func columns(for kind: ResourceKind) -> [Self] {
        switch kind {
        case .containers: [.name, .status, .image, .ports, .lastStarted]
        case .images: [.name, .tag, .digest, .created, .size, .inUse]
        default: [.name, .status, .detail]
        }
    }

    var title: String {
        switch self {
        case .name: "Name"
        case .status: "Status"
        case .detail: "Detail"
        case .image: "Image"
        case .ports: "Port(s)"
        case .lastStarted: "Last started"
        case .tag: "Tag"
        case .digest: "Digest"
        case .created: "Created"
        case .size: "Size"
        case .inUse: "In use"
        }
    }

    var width: Double {
        switch self {
        case .name: 200
        case .image: 210
        case .detail: 360
        case .ports: 230
        case .created, .lastStarted: 175
        case .digest: 155
        case .tag: 110
        case .status, .size, .inUse: 95
        }
    }

    func cell(for item: ResourceListItem) -> ResourceCellValue {
        switch self {
        case .name:
            return .text(item.image?.reference.displayName ?? item.title, tooltip: item.inspectIdentifier)
        case .status:
            return .text(item.container?.stateTitle ?? item.status)
        case .detail:
            return .text(item.detail)
        case .image:
            return .text(item.container?.imageReference)
        case .ports:
            guard let ports = item.container?.ports else { return .unavailable("Published ports were not provided by the runtime.") }
            guard !ports.isEmpty else {
                return ResourceCellValue(text: "--", tooltip: "No published ports", sortValue: .text(""))
            }
            let text = ports.map(\.displayValue).joined(separator: ", ")
            let links = item.container?.isRunning == true ? ports.compactMap(\.browserAccessLink) : []
            return ResourceCellValue(text: text, tooltip: text, sortValue: .text(text), links: links)
        case .lastStarted:
            return .date(item.container?.startedAt, missing: "No start time was reported. This is not the container creation time.")
        case .tag:
            return ResourceCellValue(
                text: item.image?.reference.tag ?? "<none>",
                tooltip: item.image?.reference.tag ?? "This reference has no tag.",
                sortValue: item.image?.reference.tag.map(ResourceSortValue.text)
            )
        case .digest:
            guard let digest = item.image?.digest ?? item.image?.reference.digest else { return .unavailable() }
            return ResourceCellValue(
                text: digest.count > 24 ? String(digest.prefix(19)) + "..." : digest,
                tooltip: "OCI index/manifest digest (not Docker Image ID):\n\(digest)",
                sortValue: .text(digest)
            )
        case .created:
            return .date(item.image?.createdAt)
        case .size:
            guard let image = item.image, let size = image.sizeBytes else { return .unavailable("Image content size was not provided by the runtime.") }
            return ResourceCellValue(text: ResourceValueFormatter.bytes(size), tooltip: ResourceValueFormatter.sizeDescription(image), sortValue: .number(size))
        case .inUse:
            guard let usage = item.image?.usage, let containers = usage.containers else {
                return .unavailable("Image usage could not be determined.")
            }
            let explanation = containers.isEmpty
                ? "Not referenced by any listed container, including stopped containers."
                : containers.map { "\($0.name) (\($0.state))" }.joined(separator: "\n")
            return ResourceCellValue(text: usage.title, tooltip: explanation, sortValue: .number(containers.isEmpty ? 0 : 1))
        }
    }
}

struct ResourceCellValue: Equatable, Sendable {
    var text: String
    var tooltip: String
    var sortValue: ResourceSortValue?
    var links: [ResourceAccessLink] = []

    static func unavailable(_ reason: String = "Not provided by the runtime.") -> Self {
        Self(text: "--", tooltip: reason, sortValue: nil)
    }

    static func text(_ value: String?, tooltip: String? = nil) -> Self {
        guard let value, !value.isEmpty else { return .unavailable() }
        return Self(text: value, tooltip: tooltip ?? value, sortValue: .text(value))
    }

    static func date(_ value: Date?, missing: String = "No creation time was reported.") -> Self {
        guard let value else { return .unavailable(missing) }
        return Self(
            text: ResourceValueFormatter.date(value),
            tooltip: value.formatted(date: .complete, time: .complete),
            sortValue: .date(value)
        )
    }
}

enum ResourceSortValue: Equatable, Sendable {
    case text(String)
    case number(Int64)
    case date(Date)

    func compare(to other: Self) -> ComparisonResult {
        switch (self, other) {
        case (.text(let lhs), .text(let rhs)): return lhs.localizedStandardCompare(rhs)
        case (.number(let lhs), .number(let rhs)): return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.date(let lhs), .date(let rhs)): return lhs.compare(rhs)
        default: return .orderedSame
        }
    }
}

enum ResourceListPresentation {
    static func sorted(_ rows: [ResourceListItem], by column: ResourceListColumn, ascending: Bool) -> [ResourceListItem] {
        rows.enumerated().map { (offset: $0.offset, item: $0.element, value: column.cell(for: $0.element).sortValue) }
            .sorted { lhs, rhs in
                let result: ComparisonResult
                switch (lhs.value, rhs.value) {
                case (nil, .some): return false
                case (.some, nil): return true
                case (nil, nil): result = .orderedSame
                case (.some(let lhs), .some(let rhs)): result = lhs.compare(to: rhs)
                }
                if result == .orderedSame {
                    let identityOrder = lhs.item.id.localizedStandardCompare(rhs.item.id)
                    return identityOrder == .orderedSame ? lhs.offset < rhs.offset : identityOrder == .orderedAscending
                }
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            .map(\.item)
    }
}

enum ResourceValueFormatter {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .shortened)
    }

    static func sizeDescription(_ image: ImageMetadata) -> String {
        var lines = [
            "Sum of resolved OCI variant content sizes. Shared layers may be counted more than once; this is not physical disk usage."
        ]
        if let variants = image.runtimeVariants {
            lines += variants.map { "\($0.platform): \($0.sizeBytes.map(bytes) ?? "Not provided")" }
        }
        return lines.joined(separator: "\n")
    }
}
