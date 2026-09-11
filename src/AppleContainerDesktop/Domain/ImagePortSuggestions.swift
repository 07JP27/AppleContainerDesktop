import Foundation

struct ImageExposedPort: Hashable, Comparable, Sendable {
    let port: UInt16
    let transport: String

    init?(declaration: String) {
        let parts = declaration.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = UInt16(parts[0]), port > 0 else { return nil }
        let transport = parts.count == 2 ? String(parts[1]).lowercased() : "tcp"
        guard transport == "tcp" || transport == "udp" else { return nil }
        self.port = port
        self.transport = transport
    }

    var displayValue: String { "\(port)/\(transport)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.port == rhs.port ? lhs.transport < rhs.transport : lhs.port < rhs.port
    }
}

struct ImagePortSuggestion: Equatable, Identifiable, Sendable {
    let port: ImageExposedPort
    let platforms: [String]

    var id: String { port.displayValue }
}

struct ImagePortSuggestions: Equatable, Sendable {
    let ports: [ImagePortSuggestion]
    let message: String
    let warning: String?

    init(image: ImageMetadata, platform: String = "") {
        let requestedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let variants = (image.runtimeVariants ?? []).filter {
            requestedPlatform.isEmpty || Self.matches($0, platform: requestedPlatform)
        }
        var platformsByPort: [ImageExposedPort: Set<String>] = [:]
        for variant in variants {
            for port in variant.exposedPorts ?? [] {
                platformsByPort[port, default: []].insert(variant.platform.isEmpty ? "Unknown platform" : variant.platform)
            }
        }
        ports = platformsByPort.keys.sorted().map {
            ImagePortSuggestion(port: $0, platforms: (platformsByPort[$0] ?? []).sorted())
        }
        if variants.isEmpty || variants.contains(where: { $0.exposedPorts == nil }) {
            warning = requestedPlatform.isEmpty
                ? "Some image port metadata is unavailable. You can add mappings manually."
                : "Port metadata is unavailable for \(requestedPlatform). You can add mappings manually."
        } else if variants.contains(where: \.hasInvalidPortDeclarations) {
            warning = "Some image port declarations could not be read. You can add missing mappings manually."
        } else {
            warning = nil
        }
        if !ports.isEmpty {
            message = "Declared by the image. Add only the ports you want to publish."
        } else if warning == nil {
            message = "This image does not declare ports. Add a mapping if your app needs one."
        } else {
            message = "You can configure ports without image suggestions."
        }
    }

    private static func matches(_ variant: ImageVariant, platform: String) -> Bool {
        let requested = platform.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(requested.count), requested[0] == variant.os else { return false }
        func architecture(_ value: String, variant: String?) -> (name: String, variant: String?) {
            switch value {
            case "aarch64", "arm64": ("arm64", variant == "8" ? "v8" : variant)
            case "x86_64", "x86-64", "amd64": ("amd64", variant)
            case "armhf": ("arm", variant ?? "v7")
            case "armel": ("arm", variant ?? "v6")
            default: (value, variant)
            }
        }
        let desired = architecture(requested[1], variant: requested.count == 3 ? requested[2] : nil)
        let actual = architecture(variant.architecture ?? "", variant: variant.variant)
        guard desired.name == actual.name else { return false }
        guard let desiredVariant = desired.variant else { return true }
        let defaultVariant = actual.name == "arm64" ? "v8" : actual.name == "amd64" ? "v1" : nil
        return desiredVariant == (actual.variant ?? defaultVariant)
    }
}

struct LaunchImageLookupError: Error, LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}
