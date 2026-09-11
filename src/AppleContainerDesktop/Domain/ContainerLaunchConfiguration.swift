import Darwin
import Foundation

struct ContainerEnvironmentInput: Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var value: String = ""
    var inheritFromHost: Bool = false
}

enum ContainerMountKind: String, CaseIterable, Sendable {
    case bind
    case volume
}

struct ContainerMountInput: Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var kind: ContainerMountKind = .bind
    var source: String = ""
    var destination: String = ""
    var readOnly: Bool = false
}

enum ContainerPortTransport: String, CaseIterable, Sendable {
    case tcp
    case udp
}

struct ContainerPortInput: Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var hostAddress: String = ""
    var hostPort: String = ""
    var containerPort: String = ""
    var transport: ContainerPortTransport = .tcp
}

struct ContainerNetworkInput: Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var specification: String = ""
}

enum ContainerLaunchField: Hashable, Sendable {
    case operation
    case image
    case name
    case cpus
    case memory
    case platform
    case command
    case environment(UUID)
    case mount(UUID)
    case port(UUID)
    case network(UUID)
}

struct ContainerLaunchValidationIssue: Equatable, Sendable {
    var field: ContainerLaunchField
    var message: String
}

struct ContainerLaunchValidationError: Error, LocalizedError, Sendable {
    var issues: [ContainerLaunchValidationIssue]

    var errorDescription: String? {
        issues.isEmpty ? "Invalid container settings." : issues.map(\.message).joined(separator: "\n")
    }
}

extension ContainerCreateRunRequest {
    var validationIssues: [ContainerLaunchValidationIssue] {
        launchArgumentsAndIssues().issues
    }

    func validatedArguments() throws(ContainerLaunchValidationError) -> [String] {
        let result = launchArgumentsAndIssues()
        guard result.issues.isEmpty else {
            throw ContainerLaunchValidationError(issues: result.issues)
        }
        return result.arguments
    }

    private func launchArgumentsAndIssues() -> (arguments: [String], issues: [ContainerLaunchValidationIssue]) {
        var arguments = [operation == .run ? "run" : "create"]
        var issues: [ContainerLaunchValidationIssue] = []

        func report(_ field: ContainerLaunchField, _ message: String) {
            issues.append(ContainerLaunchValidationIssue(field: field, message: message))
        }

        func append(_ flag: String, _ value: String) {
            // An environment name may legally start with "-", but must not become another CLI option.
            if value.unicodeScalars.first == "-" {
                arguments.append("\(flag)=\(value)")
            } else {
                arguments += [flag, value]
            }
        }

        let image = ContainerLaunchValidation.trim(image)
        if operation != .run && operation != .create {
            report(.operation, "Choose Run or Create for these container settings.")
        }
        if image.isEmpty {
            report(.image, "Provide an image reference.")
        } else if image.unicodeScalars.first == "-" || image.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) {
            report(.image, "The image reference cannot start with '-' or contain whitespace or control characters.")
        }

        if operation == .run {
            arguments.append("--detach")
            if remove {
                arguments.append("--rm")
            }
        }

        let name = ContainerLaunchValidation.trim(name)
        if !name.isEmpty {
            if name.count < 2 || !ContainerLaunchValidation.isIdentifier(name) {
                report(.name, "Use at least two characters for the container name: start with a letter or number, then use letters, numbers, '.', '_' or '-'.")
            }
            append("--name", name)
        }

        let cpus = ContainerLaunchValidation.trim(cpus)
        if !cpus.isEmpty {
            if Int64(cpus).map({ $0 > 0 }) != true {
                report(.cpus, "CPU allocation must be a positive whole number.")
            }
            append("--cpus", cpus)
        }

        let memory = ContainerLaunchValidation.trim(memory)
        if !memory.isEmpty {
            if !ContainerLaunchValidation.isMemorySize(memory) {
                report(.memory, "Use a positive memory size in bytes or with a K, M, G, T or P suffix, such as 512M or 1.5GiB.")
            }
            append("--memory", memory)
        }

        for row in environment {
            let name = ContainerLaunchValidation.trim(row.name)
            if name.isEmpty && row.value.isEmpty && !row.inheritFromHost {
                continue
            }
            if name.isEmpty {
                report(.environment(row.id), "Provide an environment variable name.")
            } else if name.unicodeScalars.contains("=") || name.utf8.contains(0) || row.value.utf8.contains(0) {
                report(.environment(row.id), "Environment names cannot contain '='; names and values cannot contain a null character.")
            } else {
                append("--env", row.inheritFromHost ? name : "\(name)=\(row.value)")
            }
        }

        for row in volumes {
            let source = row.kind == .volume ? ContainerLaunchValidation.trim(row.source) : row.source
            if source.isEmpty && row.destination.isEmpty && !row.readOnly {
                continue
            }
            if source.isEmpty || row.destination.isEmpty {
                report(.mount(row.id), "Provide both a mount source and a container path.")
            } else if source.utf8.contains(0) || row.destination.utf8.contains(0) {
                report(.mount(row.id), "Mount sources and container paths cannot contain a null character.")
            } else if source.unicodeScalars.contains(":") || row.destination.unicodeScalars.contains(":") {
                report(.mount(row.id), "Mount sources and container paths cannot contain ':' with this CLI volume syntax.")
            } else if row.destination.unicodeScalars.first != "/" {
                report(.mount(row.id), "The container mount path must be absolute, starting with '/'.")
            } else if row.kind == .bind && source.unicodeScalars.first != "/" {
                report(.mount(row.id), "Choose an absolute host folder path, starting with '/', for a bind mount.")
            } else if row.kind == .volume && (!ContainerLaunchValidation.isIdentifier(source) || source.count > 255) {
                report(.mount(row.id), "Use a volume name of up to 255 characters: start with a letter or number, then use letters, numbers, '.', '_' or '-'.")
            } else {
                append("--volume", "\(source):\(row.destination)\(row.readOnly ? ":ro" : "")")
            }
        }

        var publishedPorts: [ContainerLaunchValidation.PublishedPort] = []
        for row in ports {
            let hostAddress = ContainerLaunchValidation.trim(row.hostAddress)
            let hostPort = ContainerLaunchValidation.trim(row.hostPort)
            let containerPort = ContainerLaunchValidation.trim(row.containerPort)
            if hostAddress.isEmpty && hostPort.isEmpty && containerPort.isEmpty {
                continue
            }
            guard !hostPort.isEmpty && !containerPort.isEmpty else {
                report(.port(row.id), "Provide both a host port and a container port.")
                continue
            }
            guard let hostRange = ContainerLaunchValidation.portRange(hostPort),
                let containerRange = ContainerLaunchValidation.portRange(containerPort) else {
                report(.port(row.id), "Ports must be numbers from 1 to 65535 or ascending ranges such as 8000-8002; automatic port 0 is not supported.")
                continue
            }
            guard hostRange.count == containerRange.count else {
                report(.port(row.id), "Host and container port ranges must contain the same number of ports.")
                continue
            }
            guard let address = ContainerLaunchValidation.HostAddress(hostAddress) else {
                report(.port(row.id), "Provide a valid IPv4 or IPv6 host address, or leave it empty for all interfaces.")
                continue
            }
            publishedPorts.append(.init(id: row.id, address: address, range: hostRange, transport: row.transport))
            append("--publish", "\(address.argumentPrefix)\(hostPort):\(containerPort)/\(row.transport.rawValue)")
        }
        for (index, port) in publishedPorts.enumerated() {
            if publishedPorts.enumerated().contains(where: { otherIndex, other in
                index != otherIndex && port.overlaps(other)
            }) {
                report(.port(port.id), "This host address and port range overlap another \(port.transport.rawValue.uppercased()) mapping.")
            }
        }

        for row in networks {
            let specification = ContainerLaunchValidation.trim(row.specification)
            if specification.isEmpty {
                continue
            }
            if let message = ContainerLaunchValidation.networkIssue(specification) {
                report(.network(row.id), message)
            } else {
                append("--network", specification)
            }
        }

        let platform = ContainerLaunchValidation.trim(platform)
        if !platform.isEmpty {
            if !ContainerLaunchValidation.isPlatform(platform) {
                report(.platform, "Use OS/architecture[/variant], such as linux/arm64 or linux/amd64, with a supported OS and variant.")
            }
            append("--platform", platform)
        }

        arguments.append(image)
        do {
            arguments += try CommandLineSplitter.validatedSplit(command)
        } catch {
            report(.command, error.localizedDescription)
        }
        return (arguments, issues)
    }
}

private enum ContainerLaunchValidation {
    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }

    static func isIdentifier(_ value: String) -> Bool {
        matches(value, "^[A-Za-z0-9][A-Za-z0-9_.-]*$")
    }

    static func isMemorySize(_ value: String) -> Bool {
        let number = value.prefix { "0123456789.".contains($0) }
        guard let amount = Double(number), amount > 0, amount.isFinite else {
            return false
        }
        let unit = String(value.dropFirst(number.count)).trimmingCharacters(in: .whitespaces).lowercased()
        let symbol = unit.first ?? "b"
        guard ["", "b", "ib"].contains(String(unit.dropFirst())) else {
            return false
        }
        let exponent: Int
        switch symbol {
        case "b": exponent = 0
        case "k": exponent = 1
        case "m": exponent = 2
        case "g": exponent = 3
        case "t": exponent = 4
        case "p": exponent = 5
        default: return false
        }
        let bytes = amount * pow(1024, Double(exponent))
        return bytes.isFinite && bytes < Double(Int64.max)
    }

    static func isPlatform(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count),
            ["linux", "windows", "darwin"].contains(parts[0]),
            matches(parts[1], "^[A-Za-z0-9][A-Za-z0-9_.-]*$") else {
            return false
        }
        guard parts.count == 3 else {
            return true
        }
        // These variant rules match ContainerizationOCI.Platform used by Apple container 1.0.
        switch parts[1] {
        case "arm": return ["v5", "v6", "v7", "v8"].contains(parts[2])
        case "armhf": return parts[2] == "v7"
        case "armel": return parts[2] == "v6"
        case "aarch64", "arm64": return ["v8", "8"].contains(parts[2])
        case "x86_64", "x86-64", "amd64": return parts[2] == "v1"
        default: return false
        }
    }

    static func portRange(_ value: String) -> ClosedRange<Int>? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
            parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
            let first = Int(parts[0]), let last = Int(parts[parts.count - 1]),
            (1...65535).contains(first), (first...65535).contains(last) else {
            return nil
        }
        return first...last
    }

    static func networkIssue(_ value: String) -> String? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard let name = parts.first, isIdentifier(String(name)) else {
            return "Start the network attachment with a valid network name."
        }
        for property in parts.dropFirst() {
            let pair = property.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                return "Network properties must use mac=address or mtu=number after the network name."
            }
            switch pair[0] {
            case "mac":
                guard matches(String(pair[1]), "^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$") else {
                    return "Provide a network MAC address such as 02:42:ac:11:00:02."
                }
            case "mtu":
                guard let mtu = UInt32(pair[1]), (1280...65535).contains(mtu) else {
                    return "Network MTU must be a whole number from 1280 to 65535."
                }
            default:
                return "Supported network properties are mac and mtu."
            }
        }
        return nil
    }

    struct HostAddress {
        var argumentPrefix: String
        private var bytes: [UInt8]
        private var zone: String?

        init?(_ value: String) {
            let bracketed = value.hasPrefix("[") && value.hasSuffix("]")
            let address = bracketed ? String(value.dropFirst().dropLast()) : value
            guard !address.utf8.contains(0) else {
                return nil
            }
            let parts = address.split(separator: "%", omittingEmptySubsequences: false)
            guard parts.count <= 2 else {
                return nil
            }
            let literal = String(parts.first ?? "")
            if parts.count == 2 {
                let scope = String(parts[1])
                guard !scope.isEmpty, !scope.unicodeScalars.contains(where: {
                    CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                        || "[]/".unicodeScalars.contains($0)
                }) else {
                    return nil
                }
                zone = UInt32(scope).map(String.init) ?? scope
            }
            var ipv4 = in_addr()
            if !bracketed && zone == nil && (address.isEmpty || inet_pton(AF_INET, literal, &ipv4) == 1) {
                bytes = withUnsafeBytes(of: ipv4) { Array($0) }
                argumentPrefix = address.isEmpty ? "" : "\(address):"
                return
            }
            var ipv6 = in6_addr()
            guard inet_pton(AF_INET6, literal, &ipv6) == 1 else {
                return nil
            }
            bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            // IPv4-mapped IPv6 addresses identify the same host binding as their IPv4 spelling.
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                bytes = Array(bytes.suffix(4))
            }
            argumentPrefix = "[\(address)]:"
        }

        func overlaps(_ other: HostAddress) -> Bool {
            guard bytes.count == other.bytes.count else {
                return false
            }
            if let zone, let otherZone = other.zone, zone != otherZone {
                return false
            }
            return bytes == other.bytes || bytes.allSatisfy { $0 == 0 } || other.bytes.allSatisfy { $0 == 0 }
        }
    }

    struct PublishedPort {
        var id: UUID
        var address: HostAddress
        var range: ClosedRange<Int>
        var transport: ContainerPortTransport

        func overlaps(_ other: PublishedPort) -> Bool {
            transport == other.transport && range.overlaps(other.range) && address.overlaps(other.address)
        }
    }
}
