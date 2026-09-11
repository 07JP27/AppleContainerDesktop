import CoreFoundation
import Darwin
import Foundation

enum ResourceMetadata: Equatable, Sendable {
    case container(ContainerMetadata)
    case image(ImageMetadata)
    case volume(VolumeMetadata)
}

struct ImageReference: Equatable, Sendable {
    let fullValue: String
    let repository: String
    let tag: String?
    let digest: String?

    init(_ value: String) {
        fullValue = value
        if let colon = value.firstIndex(of: ":") {
            let algorithm = value[..<colon]
            let hash = value[value.index(after: colon)...]
            if ((algorithm == "sha256" && hash.count == 64) || (algorithm == "sha512" && hash.count == 128)),
               hash.allSatisfy(\.isHexDigit) {
                repository = ""
                tag = nil
                digest = value
                return
            }
        }
        let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let namedPart = String(parts[0])
        digest = parts.count == 2 ? String(parts[1]) : nil
        if let colon = namedPart.lastIndex(of: ":"),
           namedPart.lastIndex(of: "/").map({ colon > $0 }) ?? true {
            repository = String(namedPart[..<colon])
            tag = String(namedPart[namedPart.index(after: colon)...])
        } else {
            repository = namedPart
            tag = nil
        }
    }

    var displayName: String {
        if repository.isEmpty { return "<none>" }
        for prefix in ["docker.io/library/", "docker.io/"] where repository.hasPrefix(prefix) {
            return String(repository.dropFirst(prefix.count))
        }
        return repository
    }

    var normalized: String {
        if repository.isEmpty { return fullValue }
        var name = repository
        let firstComponent = name.split(separator: "/").first.map(String.init) ?? name
        if !name.contains("/") || (!firstComponent.contains(".") && !firstComponent.contains(":") && firstComponent != "localhost") {
            name = "docker.io/" + name
        }
        if name.hasPrefix("index.docker.io/") {
            name = "docker.io/" + name.dropFirst("index.docker.io/".count)
        }
        if name.hasPrefix("docker.io/"), name.split(separator: "/").count == 2 {
            name = "docker.io/library/" + name.dropFirst("docker.io/".count)
        }
        if let digest {
            return "\(name)@\(digest)"
        }
        return "\(name):\(tag ?? "latest")"
    }
}

struct ContainerMetadata: Equatable, Sendable {
    var name: String
    var state: String
    var imageReference: String?
    var imageDigest: String?
    var ports: [PublishedPort]?
    var createdAt: Date?
    var startedAt: Date?
    var networks: [ContainerNetwork]?
    var mounts: [ContainerMount]?
    var allocatedCPUs: Int64?
    var memoryLimitBytes: Int64?
    var command: WorkloadCommand?
    var workingDirectory: String?

    var stateTitle: String { state.capitalized }
    var isRunning: Bool { state == "running" }
}

struct PublishedPort: Equatable, Sendable {
    var hostAddress: String
    var hostPort: Int64
    var containerPort: Int64
    var portCount: Int64
    var transport: String

    var displayValue: String {
        let address = hostAddress.contains(":") && !hostAddress.hasPrefix("[") ? "[\(hostAddress)]" : hostAddress
        let hostRange = portCount == 1 ? "\(hostPort)" : "\(hostPort)-\(hostPort + portCount - 1)"
        let containerRange = portCount == 1 ? "\(containerPort)" : "\(containerPort)-\(containerPort + portCount - 1)"
        return "\(address):\(hostRange) -> \(containerRange)/\(transport)"
    }

    var browserAccessLink: ResourceAccessLink? {
        guard transport.caseInsensitiveCompare("tcp") == .orderedSame,
              (1...65_535).contains(hostPort),
              let address = browserAddress else { return nil }
        let title = portCount > 1
            ? "\(address.title):\(hostPort) (first in range)"
            : "\(address.title):\(hostPort)"
        let encodedHost = address.urlHost.replacingOccurrences(of: "%", with: "%25")
        let authority = address.isIPv6 ? "[\(encodedHost)]" : encodedHost
        guard let url = URL(string: "http://\(authority):\(hostPort)/") else { return nil }
        return ResourceAccessLink(title: title, url: url)
    }

    private var browserAddress: (title: String, urlHost: String, isIPv6: Bool)? {
        var address = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty || address == "0.0.0.0" {
            return ("localhost", "localhost", false)
        }
        if address == "::" || address == "[::]" {
            return ("[::1]", "::1", true)
        }
        if address.hasPrefix("[") && address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        let parts = address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let literal = String(parts[0])
        if parts.count == 2 {
            let zone = String(parts[1])
            guard !zone.isEmpty, zone.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
            }) else { return nil }
        }
        var ipv4 = in_addr()
        if parts.count == 1, inet_pton(AF_INET, literal, &ipv4) == 1 {
            return (literal, literal, false)
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, literal, &ipv6) == 1 else { return nil }
        return ("[\(address)]", address, true)
    }
}

struct ContainerNetwork: Equatable, Sendable {
    var name: String
    var ipv4Address: String?
    var ipv6Address: String?
}

struct ContainerMount: Equatable, Sendable {
    var source: String
    var destination: String
    var kind: String
    var readOnly: Bool?
}

struct WorkloadCommand: Equatable, Sendable {
    var executable: String
    var arguments: [String]

    var displayValue: String {
        CLICommandPreview(executable: executable, arguments: arguments).displayString
    }
}

struct ImageVariant: Equatable, Sendable {
    var os: String?
    var architecture: String?
    var variant: String?
    var digest: String?
    var sizeBytes: Int64?
    var createdAt: Date?
    var exposedPorts: [ImageExposedPort]? = nil
    var hasInvalidPortDeclarations = false

    var isAttestation: Bool { os == "unknown" && architecture == "unknown" }
    var platform: String { [os, architecture, variant].compactMap { $0 }.joined(separator: "/") }
}

struct ImageContainerUsage: Equatable, Sendable {
    var id: String
    var name: String
    var state: String
}

enum ImageUsage: Equatable, Sendable {
    case unavailable
    case known([ImageContainerUsage])

    var title: String {
        switch self {
        case .unavailable: "--"
        case .known(let containers): containers.isEmpty ? "Unused" : "In use"
        }
    }

    var containers: [ImageContainerUsage]? {
        if case .known(let containers) = self { return containers }
        return nil
    }
}

struct VolumeContainerUsage: Equatable, Sendable {
    var id: String
    var name: String
    var state: String
    var mountTarget: String?
}

enum VolumeUsage: Equatable, Sendable {
    case unavailable
    case known([VolumeContainerUsage])

    var title: String {
        switch self {
        case .unavailable: "--"
        case .known(let containers): containers.isEmpty ? "Unused" : "In use"
        }
    }

    var containers: [VolumeContainerUsage]? {
        if case .known(let containers) = self { return containers }
        return nil
    }
}

struct VolumeMetadata: Equatable, Sendable {
    static let anonymousLabel = "com.apple.container.resource.anonymous"

    var name: String
    var driver: String?
    var format: String?
    var createdAt: Date?
    var capacityBytes: Int64?
    var isAnonymous: Bool
    var labels: [String: String] = [:]
    var options: [String: String] = [:]
    var usage: VolumeUsage = .unavailable
}

struct ImageMetadata: Equatable, Sendable {
    var reference: ImageReference
    var digest: String?
    var createdAt: Date?
    var variants: [ImageVariant]?
    var reportedSizeBytes: Int64?
    var usage: ImageUsage = .unavailable

    var runtimeVariants: [ImageVariant]? {
        variants?.filter { !$0.isAttestation }
    }

    var sizeBytes: Int64? {
        guard let variants = runtimeVariants else { return reportedSizeBytes }
        guard !variants.isEmpty else { return nil }
        var seen = Set<String>()
        var total: Int64 = 0
        for variant in variants {
            if let digest = variant.digest, !seen.insert(digest).inserted { continue }
            guard let size = variant.sizeBytes else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    var digests: Set<String> {
        Set(([digest, reference.digest] + (runtimeVariants ?? []).map(\.digest)).compactMap { $0 })
    }

    func isUsed(by container: ContainerMetadata) -> Bool {
        usageMatch(for: container) == true
    }

    func usageMatch(for container: ContainerMetadata) -> Bool? {
        if let containerDigest = container.imageDigest, !digests.isEmpty {
            // A reused tag may point at a different image than the container was created from.
            return digests.contains(containerDigest)
        }
        if let pinnedDigest = container.imageReference.flatMap({ ImageReference($0).digest }), !digests.isEmpty {
            return digests.contains(pinnedDigest)
        }
        guard let containerReference = container.imageReference else { return nil }
        return reference.normalized == ImageReference(containerReference).normalized
    }
}

struct ResourceMetadataParser {
    func container(from object: [String: Any]) throws -> ContainerMetadata {
        let fields = JSONFields(object)
        guard let name = fields.string("configuration.id", "id", "name", "containerID"),
              name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ResourceParserError.missingIdentity(.containers)
        }
        var state = fields.string("status.state", "state", "status")?.lowercased()
        if state == nil, let running = fields.boolean("running", "status") {
            state = running ? "running" : "stopped"
        }
        let command: WorkloadCommand?
        if let executable = fields.string("configuration.initProcess.executable"),
           let arguments = fields.strings("configuration.initProcess.arguments") {
            command = WorkloadCommand(executable: executable, arguments: arguments)
        } else {
            command = nil
        }
        return ContainerMetadata(
            name: name,
            state: state ?? "unknown",
            imageReference: fields.string("configuration.image.reference", "image.reference", "image"),
            imageDigest: fields.string("configuration.image.descriptor.digest", "image.descriptor.digest", "imageDigest"),
            ports: fields.records("configuration.publishedPorts", "publishedPorts").flatMap { records in
                let ports = records.compactMap(publishedPort)
                return ports.count == records.count ? ports : nil
            },
            createdAt: fields.date("configuration.creationDate", "createdAt", "created"),
            startedAt: fields.date("status.startedDate", "startedDate"),
            networks: fields.records("status.networks", "networks").flatMap { records in
                let networks = records.compactMap { record -> ContainerNetwork? in
                    guard let name = record.string("network", "name") else { return nil }
                    return ContainerNetwork(name: name, ipv4Address: record.string("ipv4Address", "address"), ipv6Address: record.string("ipv6Address"))
                }
                return networks.count == records.count ? networks : nil
            },
            mounts: fields.records("configuration.mounts", "mounts").flatMap { records in
                let mounts = records.compactMap(mount)
                return mounts.count == records.count ? mounts : nil
            },
            allocatedCPUs: fields.integer("configuration.resources.cpus").flatMap { $0 > 0 ? $0 : nil },
            memoryLimitBytes: fields.integer("configuration.resources.memoryInBytes"),
            command: command,
            workingDirectory: fields.string("configuration.initProcess.workingDirectory")
        )
    }

    func image(from object: [String: Any]) throws -> ImageMetadata {
        let fields = JSONFields(object)
        guard let reference = fields.string("configuration.name", "configuration.reference", "reference", "displayReference", "name"),
              reference.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ResourceParserError.missingIdentity(.images)
        }
        let variants = fields.records("variants")?.map { record in
            let ports = imagePorts(from: record)
            return ImageVariant(
                os: record.string("platform.os"),
                architecture: record.string("platform.architecture"),
                variant: record.string("platform.variant"),
                digest: record.string("digest"),
                sizeBytes: record.integer("size"),
                createdAt: record.date("config.created"),
                exposedPorts: ports.values,
                hasInvalidPortDeclarations: ports.hasInvalidDeclarations
            )
        }
        return ImageMetadata(
            reference: ImageReference(reference),
            digest: fields.string("configuration.descriptor.digest", "descriptor.digest", "digest", "displayDigest"),
            createdAt: fields.date("configuration.creationDate", "createdAt", "created")
                ?? variants?.filter { !$0.isAttestation }.compactMap(\.createdAt).min(),
            variants: variants,
            reportedSizeBytes: fields.integer("size")
        )
    }

    func volume(from object: [String: Any]) throws -> VolumeMetadata {
        let fields = JSONFields(object)
        guard let name = fields.string("configuration.name"),
              name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ResourceParserError.missingIdentity(.volumes)
        }
        let labels = fields.stringDictionary("configuration.labels") ?? [:]
        return VolumeMetadata(
            name: name,
            driver: fields.string("configuration.driver"),
            format: fields.string("configuration.format"),
            createdAt: fields.date("configuration.creationDate", "configuration.createdAt", "createdAt"),
            capacityBytes: fields.integer("configuration.sizeInBytes"),
            isAnonymous: fields.containsKey(VolumeMetadata.anonymousLabel, inDictionaryAt: "configuration.labels"),
            labels: labels,
            options: fields.stringDictionary("configuration.options") ?? [:]
        )
    }

    private func imagePorts(from fields: JSONFields) -> (values: [ImageExposedPort]?, hasInvalidDeclarations: Bool) {
        guard let config = fields.value(at: "config"), !(config is NSNull) else { return (nil, false) }
        guard config is [String: Any] else { return (nil, true) }
        if let settings = fields.value(at: "config.config"), !(settings is NSNull), !(settings is [String: Any]) {
            return (nil, true)
        }
        guard let raw = fields.value(at: "config.config.ExposedPorts"), !(raw is NSNull) else { return ([], false) }
        guard let declarations = raw as? [String: Any] else { return (nil, true) }
        let ports = declarations.compactMap { key, value in
            value is [String: Any] ? ImageExposedPort(declaration: key) : nil
        }
        return (Array(Set(ports)).sorted(), ports.count != declarations.count)
    }

    private func publishedPort(_ fields: JSONFields) -> PublishedPort? {
        guard let host = fields.string("hostAddress"),
              let hostPort = fields.integer("hostPort"),
              let containerPort = fields.integer("containerPort"),
              let transport = fields.string("proto", "protocol")?.lowercased(),
              ["tcp", "udp"].contains(transport) else { return nil }
        let count = fields.value(at: "count") == nil ? 1 : fields.integer("count")
        guard let count, count > 0, count <= 65_536,
              hostPort <= 65_535 - count + 1, containerPort <= 65_535 - count + 1 else { return nil }
        return PublishedPort(hostAddress: host, hostPort: hostPort, containerPort: containerPort, portCount: count, transport: transport)
    }

    private func mount(_ fields: JSONFields) -> ContainerMount? {
        guard let destination = fields.string("destination"),
              let source = fields.string("type.volume.name", "source") else { return nil }
        let kind: String
        if fields.value(at: "type.volume") != nil { kind = "Volume" }
        else if fields.value(at: "type.virtiofs") != nil { kind = "Bind mount" }
        else if fields.value(at: "type.tmpfs") != nil { kind = "Temporary storage" }
        else if fields.value(at: "type.block") != nil { kind = "Block device" }
        else { kind = fields.string("type") ?? "Mount" }
        return ContainerMount(source: source, destination: destination, kind: kind, readOnly: fields.strings("options").map { $0.contains("ro") })
    }
}

private struct JSONFields {
    let object: [String: Any]

    init(_ object: [String: Any]) { self.object = object }

    func value(at path: String) -> Any? {
        var value: Any = object
        for component in path.split(separator: ".") {
            guard let dictionary = value as? [String: Any],
                  let next = dictionary[String(component)] ?? dictionary.first(where: { $0.key.caseInsensitiveCompare(String(component)) == .orderedSame })?.value else {
                return nil
            }
            value = next
        }
        return value
    }

    func string(_ paths: String...) -> String? {
        for path in paths {
            if let value = value(at: path) as? String, !value.isEmpty { return value }
        }
        return nil
    }

    func strings(_ path: String) -> [String]? { value(at: path) as? [String] }

    func stringDictionary(_ path: String) -> [String: String]? {
        guard let values = value(at: path) as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (key, value) in values {
            guard let string = value as? String else { return nil }
            result[key] = string
        }
        return result
    }

    func containsKey(_ key: String, inDictionaryAt path: String) -> Bool {
        (value(at: path) as? [String: Any])?[key] != nil
    }

    func boolean(_ paths: String...) -> Bool? {
        for path in paths {
            if let number = value(at: path) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
        }
        return nil
    }

    func integer(_ paths: String...) -> Int64? {
        for path in paths {
            let raw = value(at: path)
            let integer: Int64?
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                integer = Int64(number.stringValue)
            } else if let string = raw as? String {
                integer = Int64(string)
            } else {
                integer = nil
            }
            if let integer, integer >= 0 { return integer }
        }
        return nil
    }

    func date(_ paths: String...) -> Date? {
        for path in paths {
            guard let string = value(at: path) as? String else { continue }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = formatter.date(from: string)
            if date == nil {
                formatter.formatOptions = [.withInternetDateTime]
                date = formatter.date(from: string)
            }
            if let date, date.timeIntervalSince1970 != 0 { return date }
        }
        return nil
    }

    func records(_ paths: String...) -> [JSONFields]? {
        for path in paths {
            if let records = value(at: path) as? [[String: Any]] { return records.map(JSONFields.init) }
        }
        return nil
    }
}
