import Foundation

enum ContainerOperation: String, CaseIterable, Sendable {
    case create = "Create"
    case run = "Run"
    case start = "Start"
    case stop = "Stop"
    case kill = "Kill"
    case delete = "Delete"
    case logs = "Logs"
    case stats = "Stats"
    case copy = "Copy"
    case export = "Export"
    case exec = "Exec"
    case prune = "Prune"

    var isDestructive: Bool {
        switch self {
        case .kill, .delete, .prune:
            true
        case .create, .run, .start, .stop, .logs, .stats, .copy, .export, .exec:
            false
        }
    }

    func arguments(identifier: String?) -> [String]? {
        switch self {
        case .create, .run, .copy, .export, .exec:
            return nil
        case .start:
            guard let identifier else { return nil }
            return ["start", identifier]
        case .stop:
            guard let identifier else { return nil }
            return ["stop", identifier]
        case .kill:
            guard let identifier else { return nil }
            return ["kill", identifier]
        case .delete:
            guard let identifier else { return nil }
            return ["delete", identifier]
        case .logs:
            guard let identifier else { return nil }
            return ["logs", "-n", "200", identifier]
        case .stats:
            guard let identifier else { return nil }
            return ["stats", "--format", "json", "--no-stream", identifier]
        case .prune:
            return ["prune"]
        }
    }
}

struct ContainerCreateRunRequest: Equatable, Sendable {
    var operation: ContainerOperation
    var image: String
    var name: String
    var detach: Bool
    var remove: Bool
    var cpus: String
    var memory: String
    var environment: String
    var volumes: String
    var ports: String
    var networks: String
    var platform: String
    var command: String

    var arguments: [String] {
        var result = [operation == .run ? "run" : "create"]
        if operation == .run, detach {
            result.append("--detach")
        }
        if operation == .run, remove {
            result.append("--rm")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            result += ["--name", trimmedName]
        }
        appendFlag("--cpus", value: cpus, to: &result)
        appendFlag("--memory", value: memory, to: &result)
        appendLines(environment, flag: "--env", to: &result)
        appendLines(volumes, flag: "--volume", to: &result)
        appendLines(ports, flag: "--publish", to: &result)
        appendLines(networks, flag: "--network", to: &result)
        appendFlag("--platform", value: platform, to: &result)
        result.append(image.trimmingCharacters(in: .whitespacesAndNewlines))
        result += CommandLineSplitter.split(command)
        return result
    }

    private func appendFlag(_ flag: String, value: String, to result: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result += [flag, trimmed]
        }
    }

    private func appendLines(_ value: String, flag: String, to result: inout [String]) {
        for line in value.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ","))) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result += [flag, trimmed]
            }
        }
    }
}

struct ContainerCopyRequest: Equatable, Sendable {
    var source: String
    var destination: String

    var arguments: [String] {
        ["copy", source, destination]
    }
}

struct ContainerExportRequest: Equatable, Sendable {
    var identifier: String
    var outputPath: String

    var arguments: [String] {
        let trimmedOutput = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput.isEmpty {
            return ["export", identifier]
        }
        return ["export", "-o", trimmedOutput, identifier]
    }
}

struct ContainerExecRequest: Equatable, Sendable {
    var identifier: String
    var command: String

    var arguments: [String] {
        ["exec", "-i", "-t", identifier] + CommandLineSplitter.split(command.isEmpty ? "/bin/sh" : command)
    }
}

enum CommandLineSplitter {
    static func split(_ command: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }

            if character == "\\" {
                escaping = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}

enum ImageOperation: String, CaseIterable, Sendable {
    case pull = "Pull"
    case push = "Push"
    case tag = "Tag"
    case delete = "Delete"
    case prune = "Prune"

    var isDestructive: Bool {
        switch self {
        case .delete, .prune:
            true
        case .pull, .push, .tag:
            false
        }
    }

    var requiresInput: Bool {
        switch self {
        case .pull, .tag:
            true
        case .push, .delete, .prune:
            false
        }
    }

    func arguments(identifier: String?, input: String?) -> [String]? {
        switch self {
        case .pull:
            guard let input, !input.isEmpty else { return nil }
            return ["image", "pull", input]
        case .push:
            guard let identifier else { return nil }
            return ["image", "push", identifier]
        case .tag:
            guard let identifier, let input, !input.isEmpty else { return nil }
            return ["image", "tag", identifier, input]
        case .delete:
            guard let identifier else { return nil }
            return ["image", "delete", identifier]
        case .prune:
            return ["image", "prune"]
        }
    }
}

struct BuildRequest: Equatable, Sendable {
    var contextDirectory: String
    var dockerfilePath: String
    var tag: String
    var platform: String
    var buildArguments: String

    var arguments: [String] {
        var result = ["build", "--progress", "plain"]

        if !dockerfilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += ["--file", dockerfilePath]
        }

        if !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += ["--tag", tag]
        }

        if !platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += ["--platform", platform]
        }

        let buildArgValues = buildArguments
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for value in buildArgValues {
            result += ["--build-arg", value]
        }

        let context = contextDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        result.append(context.isEmpty ? "." : context)
        return result
    }
}

enum NetworkOperation: String, CaseIterable, Sendable {
    case create = "Create"
    case delete = "Delete"
    case prune = "Prune"

    var isDestructive: Bool { self != .create }

    func arguments(identifier: String?, input: String?) -> [String]? {
        switch self {
        case .create:
            guard let input, !input.isEmpty else { return nil }
            return ["network", "create", input]
        case .delete:
            guard let identifier else { return nil }
            return ["network", "delete", identifier]
        case .prune:
            return ["network", "prune"]
        }
    }
}

enum VolumeOperation: String, CaseIterable, Sendable {
    case create = "Create"
    case delete = "Delete"
    case prune = "Prune"

    var isDestructive: Bool { self != .create }

    func arguments(identifier: String?, input: String?) -> [String]? {
        switch self {
        case .create:
            guard let input, !input.isEmpty else { return nil }
            return ["volume", "create", input]
        case .delete:
            guard let identifier else { return nil }
            return ["volume", "delete", identifier]
        case .prune:
            return ["volume", "prune"]
        }
    }
}

enum RegistryOperation: String, CaseIterable, Sendable {
    case login = "Login"
    case logout = "Logout"

    var isDestructive: Bool { self == .logout }

    func arguments(identifier: String?) -> [String]? {
        switch self {
        case .login:
            return nil
        case .logout:
            guard let identifier else { return nil }
            return ["registry", "logout", identifier]
        }
    }
}

struct RegistryLoginRequest: Equatable, Sendable {
    var registry: String
    var username: String
    var password: String
}

enum MachineOperation: String, CaseIterable, Sendable {
    case logs = "Logs"
    case stop = "Stop"
    case delete = "Delete"
    case setDefault = "Set Default"

    var isDestructive: Bool { self == .delete }

    func arguments(identifier: String?) -> [String]? {
        guard let identifier else { return nil }
        switch self {
        case .logs:
            return ["machine", "logs", identifier]
        case .stop:
            return ["machine", "stop", identifier]
        case .delete:
            return ["machine", "delete", identifier]
        case .setDefault:
            return ["machine", "set-default", identifier]
        }
    }
}

enum BuilderOperation: String, CaseIterable, Sendable {
            case status = "Status"
            case start = "Start"
            case stop = "Stop"
            case delete = "Delete"

            var isDestructive: Bool { self == .delete }

            func arguments(cpus: String = "", memory: String = "") -> [String] {
                switch self {
                case .status:
                    return ["builder", "status", "--format", "json"]
                case .start:
                    var result = ["builder", "start"]
                    let trimmedCPUs = cpus.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedCPUs.isEmpty {
                        result += ["--cpus", trimmedCPUs]
                    }
                    let trimmedMemory = memory.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedMemory.isEmpty {
                        result += ["--memory", trimmedMemory]
                    }
                    return result
                case .stop:
                    return ["builder", "stop"]
                case .delete:
                    return ["builder", "delete"]
                }
            }
}

struct OperationRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var command: String
    var exitCode: Int32?
    var succeeded: Bool
    var timestamp: Date

    init(
        id: UUID = UUID(),
        title: String,
        command: String,
        exitCode: Int32?,
        succeeded: Bool,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.exitCode = exitCode
        self.succeeded = succeeded
        self.timestamp = timestamp
    }
}

struct OperationOutcome: Equatable, Sendable {
    var title: String
    var command: CLICommandPreview?
    var result: CLIProcessResult?
    var errorMessage: String?

    var succeeded: Bool {
        result?.succeeded == true && errorMessage == nil
    }

    var output: String {
        if let errorMessage {
            return errorMessage
        }
        guard let result else {
            return ""
        }
        if !result.stderr.isEmpty {
            return result.stderr
        }
        return result.stdout
    }
}
