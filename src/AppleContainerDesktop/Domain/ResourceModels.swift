import Foundation

enum ResourceKind: String, CaseIterable, Sendable {
    case containers = "Containers"
    case images = "Images"
    case networks = "Networks"
    case volumes = "Volumes"
    case registry = "Registries"
    case machines = "Machines"

    var listArguments: [String] {
        switch self {
        case .containers:
            ["list", "--all", "--format", "json"]
        case .images:
            ["image", "list", "--format", "json"]
        case .networks:
            ["network", "list", "--format", "json"]
        case .volumes:
            ["volume", "list", "--format", "json"]
        case .registry:
            ["registry", "list", "--format", "json"]
        case .machines:
            ["machine", "list", "--format", "json"]
        }
    }

    func inspectArguments(identifier: String) -> [String]? {
        switch self {
        case .containers:
            ["inspect", identifier]
        case .images:
            ["image", "inspect", identifier]
        case .networks:
            ["network", "inspect", identifier]
        case .volumes:
            ["volume", "inspect", identifier]
        case .registry:
            nil
        case .machines:
            ["machine", "inspect", identifier]
        }
    }

    var emptyMessage: String {
        switch self {
        case .containers:
            "No containers were returned. Run a container, pull an image, or check system status."
        case .images:
            "No local images were returned. Pull an image or build from a Dockerfile."
        case .networks:
            "No networks were returned."
        case .volumes:
            "No volumes were returned."
        case .registry:
            "No logged-in registries were returned."
        case .machines:
            "No machines were returned."
        }
    }
}

struct ResourceListItem: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var status: String
    var detail: String
    var inspectIdentifier: String?
    var rawJSON: String
    var searchableText: String
}

struct ResourceListSnapshot: Equatable, Sendable {
    var kind: ResourceKind
    var detection: CLIDetectionResult
    var command: CLICommandPreview?
    var items: [ResourceListItem]
    var errorMessage: String?
    var errorDetail: String?
}

enum ResourceParserError: Error, Equatable {
    case invalidJSON
}

struct ResourceJSONParser: Sendable {
    func parseList(_ output: String, kind: ResourceKind) throws -> [ResourceListItem] {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(output.utf8), options: [])
        } catch {
            throw ResourceParserError.invalidJSON
        }

        let objects = extractObjects(from: object)
        return objects.enumerated().map { index, object in
            makeItem(index: index, object: object, kind: kind)
        }
    }

    func prettyJSON(_ output: String) -> String {
        guard
            let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return output
        }
        return pretty
    }

    private func extractObjects(from object: Any) -> [[String: Any]] {
        if let array = object as? [[String: Any]] {
            return array
        }

        if let dictionary = object as? [String: Any] {
            for value in dictionary.values {
                if let array = value as? [[String: Any]] {
                    return array
                }
            }
            return [dictionary]
        }

        return []
    }

    private func makeItem(index: Int, object: [String: Any], kind: ResourceKind) -> ResourceListItem {
        let title = firstValue(
            in: object,
            keys: titleKeys(for: kind)
        ) ?? "\(kind.rawValue.dropLast()) \(index + 1)"

        let status = firstValue(
            in: object,
            keys: ["status", "state", "running", "default", "health"]
        ) ?? "unknown"

        let detail = firstValue(
            in: object,
            keys: detailKeys(for: kind)
        ) ?? compactDetails(from: object)

        let inspectIdentifier = firstValue(
            in: object,
            keys: inspectKeys(for: kind)
        )

        let rawJSON = prettyObject(object)
        let searchableText = ([title, status, detail, inspectIdentifier, rawJSON].compactMap { $0 }).joined(separator: " ")

        return ResourceListItem(
            id: inspectIdentifier ?? "\(kind.rawValue)-\(index)",
            title: title,
            status: status,
            detail: detail,
            inspectIdentifier: inspectIdentifier,
            rawJSON: rawJSON,
            searchableText: searchableText
        )
    }

    private func titleKeys(for kind: ResourceKind) -> [String] {
        switch kind {
        case .containers:
            ["configuration.id", "id", "name", "names", "containerID"]
        case .images:
            ["displayReference", "reference", "name", "tag", "digest", "id"]
        case .networks:
            ["name", "id"]
        case .volumes:
            ["name", "id"]
        case .registry:
            ["server", "registry", "name", "host"]
        case .machines:
            ["name", "id"]
        }
    }

    private func detailKeys(for kind: ResourceKind) -> [String] {
        switch kind {
        case .containers:
            ["configuration.image.reference", "image.reference", "image", "ports", "networks", "createdAt", "created"]
        case .images:
            ["digest", "displayDigest", "size", "createdAt", "created"]
        case .networks:
            ["driver", "subnet", "subnetV6", "internal"]
        case .volumes:
            ["mountpoint", "size", "createdAt", "created"]
        case .registry:
            ["username", "server", "host"]
        case .machines:
            ["runtime", "address", "createdAt", "created"]
        }
    }

    private func inspectKeys(for kind: ResourceKind) -> [String] {
        switch kind {
        case .containers:
            ["configuration.id", "id", "name", "containerID"]
        case .images:
            ["displayReference", "reference", "name", "id", "digest"]
        case .networks:
            ["name", "id"]
        case .volumes:
            ["name", "id"]
        case .registry:
            ["server", "registry", "name", "host"]
        case .machines:
            ["name", "id"]
        }
    }

    private func firstValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = value(for: key, in: object) else {
                continue
            }
            let string = stringValue(value)
            if !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private func value(for key: String, in object: [String: Any]) -> Any? {
        if key.contains(".") {
            return value(forPath: key.split(separator: ".").map(String.init), in: object)
        }
        if let direct = object[key] {
            return direct
        }
        if let direct = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
            return direct
        }
        return recursiveValue(for: key, in: object)
    }

    private func value(forPath path: [String], in object: [String: Any]) -> Any? {
        guard let first = path.first else {
            return nil
        }
        let value = object[first] ?? object.first { $0.key.caseInsensitiveCompare(first) == .orderedSame }?.value
        guard path.count > 1 else {
            return value
        }
        guard let nested = value as? [String: Any] else {
            return nil
        }
        return self.value(forPath: Array(path.dropFirst()), in: nested)
    }

    private func recursiveValue(for key: String, in value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            if let direct = dictionary[key] ?? dictionary.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                return direct
            }
            for nested in dictionary.values {
                if let match = recursiveValue(for: key, in: nested) {
                    return match
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let match = recursiveValue(for: key, in: nested) {
                    return match
                }
            }
        }
        return nil
    }

    private func stringValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let strings as [String]:
            return strings.joined(separator: ", ")
        case let array as [Any]:
            return array.map(stringValue).filter { !$0.isEmpty }.joined(separator: ", ")
        case let dictionary as [String: Any]:
            return compactDetails(from: dictionary)
        default:
            return ""
        }
    }

    private func compactDetails(from object: [String: Any]) -> String {
        object
            .prefix(3)
            .map { "\($0.key): \(stringValue($0.value))" }
            .joined(separator: " · ")
    }

    private func prettyObject(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            return "\(object)"
        }
        return string
    }
}
