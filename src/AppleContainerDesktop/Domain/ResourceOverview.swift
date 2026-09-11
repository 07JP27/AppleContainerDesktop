import Foundation

struct ResourceAccessLink: Equatable, Sendable {
    var title: String
    var url: URL
}

struct ResourceOverviewField: Equatable, Sendable {
    var label: String
    var value: String
    var tooltip: String? = nil
    var monospaced: Bool = false
    var links: [ResourceAccessLink] = []
}

struct ResourceOverviewSection: Equatable, Sendable {
    var title: String
    var fields: [ResourceOverviewField]
}

struct ResourceOverview: Equatable, Sendable {
    var title: String
    var subtitle: String
    var sections: [ResourceOverviewSection]
    var warning: String?

    init?(item: ResourceListItem, warning: String? = nil) {
        self.warning = warning
        if let container = item.container {
            title = container.name
            subtitle = "Container overview"
            sections = Self.containerSections(container)
        } else if let image = item.image {
            title = image.reference.displayName
            subtitle = "Image overview"
            sections = Self.imageSections(image)
        } else if let volume = item.volume {
            title = volume.name
            subtitle = "Volume overview"
            sections = Self.volumeSections(volume)
        } else {
            return nil
        }
    }

    private static func date(_ value: Date?) -> String {
        value.map(ResourceValueFormatter.date) ?? "Not provided"
    }

    private static func containerSections(_ container: ContainerMetadata) -> [ResourceOverviewSection] {
        let ports: [ResourceOverviewField]
        if let published = container.ports {
            if published.isEmpty {
                ports = [.init(label: "Published ports", value: "No published ports")]
            } else {
                ports = published.map { port in
                    .init(
                        label: "Published port",
                        value: port.displayValue,
                        links: container.isRunning ? [port.browserAccessLink].compactMap { $0 } : []
                    )
                }
            }
        } else {
            ports = [.init(label: "Published ports", value: "Not provided")]
        }
        let networks: [ResourceOverviewField]
        if let attachments = container.networks {
            networks = attachments.isEmpty ? [.init(label: "Networks", value: "No active network attachments")] : attachments.map { network in
                var addresses: [String] = []
                if let address = network.ipv4Address { addresses.append("IPv4: \(address)") }
                if let address = network.ipv6Address { addresses.append("IPv6: \(address)") }
                return .init(label: network.name, value: addresses.isEmpty ? "Address not provided" : addresses.joined(separator: "\n"))
            }
        } else {
            networks = [.init(label: "Networks", value: "Not provided")]
        }
        let mounts: [ResourceOverviewField]
        if let configuration = container.mounts {
            mounts = configuration.isEmpty ? [.init(label: "Mounts", value: "No mounts")] : configuration.map { mount in
                let access = mount.readOnly.map { $0 ? "Read-only" : "Read-write" } ?? "Not provided"
                return .init(label: mount.kind, value: "\(mount.source)\nMount point: \(mount.destination)\nAccess: \(access)")
            }
        } else {
            mounts = [.init(label: "Mounts", value: "Not provided")]
        }
        return [
            .init(title: "Overview", fields: [
                .init(label: "Status", value: container.stateTitle),
                .init(label: "Image", value: container.imageReference ?? "Not provided"),
                .init(label: "Created", value: date(container.createdAt)),
                .init(label: "Last started", value: date(container.startedAt))
            ]),
            .init(title: "Connections", fields: ports + networks),
            .init(title: "Storage", fields: mounts),
            .init(title: "Runtime", fields: [
                .init(label: "Allocated CPUs", value: container.allocatedCPUs.map(String.init) ?? "Not provided"),
                .init(label: "Memory limit", value: container.memoryLimitBytes.map(ResourceValueFormatter.bytes) ?? "Not provided"),
                .init(label: "Workload command", value: container.command?.displayValue ?? "Not provided", monospaced: true),
                .init(label: "Working directory", value: container.workingDirectory ?? "Not provided")
            ])
        ]
    }

    private static func imageSections(_ image: ImageMetadata) -> [ResourceOverviewSection] {
        let platforms: [ResourceOverviewField]
        if let variants = image.runtimeVariants, !variants.isEmpty {
            platforms = variants.map {
                .init(label: $0.platform.isEmpty ? "Platform not provided" : $0.platform, value: $0.sizeBytes.map(ResourceValueFormatter.bytes) ?? "Size not provided")
            }
        } else {
            platforms = [.init(label: "Platforms", value: "Not provided")]
        }
        let users: [ResourceOverviewField]
        if let containers = image.usage.containers {
            users = containers.isEmpty ? [.init(label: "Containers", value: "No containers use this image")] : containers.map {
                .init(label: $0.name, value: $0.state.capitalized)
            }
        } else {
            users = [.init(label: "Containers", value: "Usage could not be determined")]
        }
        return [
            .init(title: "Overview", fields: [
                .init(label: "Tag", value: image.reference.tag ?? "<none>"),
                .init(label: "In use", value: image.usage == .unavailable ? "Not available" : image.usage.title),
                .init(label: "Created", value: date(image.createdAt)),
                .init(label: "Size", value: image.sizeBytes.map(ResourceValueFormatter.bytes) ?? "Not provided", tooltip: ResourceValueFormatter.sizeDescription(image)),
                .init(label: "Reference", value: image.reference.fullValue),
                .init(label: "Digest", value: image.digest ?? image.reference.digest ?? "Not provided", tooltip: "OCI index/manifest digest, not Docker Image ID.", monospaced: true)
            ]),
            .init(title: "Platforms", fields: platforms),
            .init(title: "Used by", fields: users)
        ]
    }

    private static func volumeSections(_ volume: VolumeMetadata) -> [ResourceOverviewSection] {
        let users: [ResourceOverviewField]
        if let containers = volume.usage.containers {
            users = containers.isEmpty
                ? [.init(label: "Containers", value: "No containers use this volume")]
                : containers.map { container in
                    let target = container.mountTarget ?? "Not provided"
                    return .init(
                        label: container.name,
                        value: "\(container.state.capitalized)\nMount target: \(target)"
                    )
                }
        } else {
            users = [.init(label: "Containers", value: "Usage could not be determined")]
        }
        return [
            .init(title: "Overview", fields: [
                .init(label: "Type", value: volume.isAnonymous ? "Anonymous" : "Named"),
                .init(label: "Driver", value: volume.driver ?? "Not provided"),
                .init(label: "Filesystem format", value: volume.format ?? "Not provided"),
                .init(label: "Created", value: date(volume.createdAt)),
                .init(
                    label: "Configured capacity",
                    value: volume.capacityBytes.map(ResourceValueFormatter.bytes) ?? "Not provided",
                    tooltip: "Maximum configured capacity reported by the runtime; this is not current disk usage."
                )
            ]),
            .init(title: "Used by", fields: users)
        ]
    }
}
