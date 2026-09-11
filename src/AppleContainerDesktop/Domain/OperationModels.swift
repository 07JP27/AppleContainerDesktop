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

struct ContainerBatchTarget: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var state: String
}

struct ContainerBatchRequest: Equatable, Sendable {
    var operation: ContainerOperation
    var targets: [ContainerBatchTarget]
    var forceDelete: Bool = false

    func validate() throws(ContainerBatchValidationError) {
        switch operation {
        case .start, .stop, .delete:
            break
        case .create, .run, .kill, .logs, .stats, .copy, .export, .exec, .prune:
            throw .unsupportedOperation(operation)
        }

        guard !forceDelete || operation == .delete else {
            throw .forceDeleteRequiresDelete
        }
        guard !targets.isEmpty else {
            throw .emptyTargets
        }

        var identifiers = Set<String>()
        for (index, target) in targets.enumerated() {
            guard !target.id.isEmpty else {
                throw .emptyIdentifier(index: index)
            }
            guard !target.id.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }) else {
                throw .identifierContainsWhitespaceOrControl(index: index)
            }
            guard !target.id.hasPrefix("-") else {
                throw .optionLikeIdentifier(index: index)
            }
            guard identifiers.insert(target.id).inserted else {
                throw .duplicateIdentifier(target.id)
            }
        }
    }
}

enum ContainerBatchValidationError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedOperation(ContainerOperation)
    case emptyTargets
    case forceDeleteRequiresDelete
    case emptyIdentifier(index: Int)
    case identifierContainsWhitespaceOrControl(index: Int)
    case optionLikeIdentifier(index: Int)
    case duplicateIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOperation:
            "Batch container operations support only Start, Stop, or Delete."
        case .emptyTargets:
            "Select at least one container."
        case .forceDeleteRequiresDelete:
            "Force delete can be used only with Delete."
        case .emptyIdentifier(let index):
            "Container ID \(index + 1) cannot be empty."
        case .identifierContainsWhitespaceOrControl(let index):
            "Container ID \(index + 1) cannot contain whitespace or control characters."
        case .optionLikeIdentifier(let index):
            "Container ID \(index + 1) cannot begin with a hyphen."
        case .duplicateIdentifier(let identifier):
            "Container ID \(identifier) appears more than once."
        }
    }
}

struct ContainerBatchItemResult: Equatable, Sendable, Identifiable {
    var target: ContainerBatchTarget
    var command: CLICommandPreview?
    var result: CLIProcessResult?
    var errorMessage: String?

    var id: String {
        target.id
    }

    var succeeded: Bool {
        result?.succeeded == true && errorMessage == nil
    }

    var success: Bool {
        succeeded
    }

    var output: String {
        if let errorMessage {
            return errorMessage
        }
        guard let result else {
            return ""
        }
        let runtimeOutput = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: result.stdout.isEmpty || result.stderr.isEmpty ? "" : "\n")
        if !runtimeOutput.isEmpty {
            return runtimeOutput
        }
        return result.succeeded ? "" : "Command failed with exit code \(result.exitCode)."
    }
}

struct ContainerBatchOutcome: Equatable, Sendable {
    var operation: ContainerOperation
    var targets: [ContainerBatchTarget]
    var itemResults: [ContainerBatchItemResult]
    var commands: [CLICommandPreview]
    var batchResult: CLIProcessResult?
    var succeededIDs: [String]
    var failedIDs: [String]
    var errorMessage: String?
    var output: String

    var executedCommands: [CLICommandPreview] {
        commands
    }

    var succeeded: Bool {
        guard errorMessage == nil, !targets.isEmpty, failedIDs.isEmpty else {
            return false
        }
        return succeededIDs == targets.map(\.id)
    }
}

struct ContainerCreateRunRequest: Equatable, Sendable {
    var operation: ContainerOperation
    var image: String = ""
    var name: String = ""
    var remove: Bool = false
    var cpus: String = ""
    var memory: String = ""
    var environment: [ContainerEnvironmentInput] = []
    var volumes: [ContainerMountInput] = []
    var ports: [ContainerPortInput] = []
    var networks: [ContainerNetworkInput] = []
    var platform: String = ""
    var command: String = ""
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
    enum TokenizationError: Error, LocalizedError, Equatable, Sendable {
        case unmatchedQuote
        case trailingEscape
        case nullCharacter

        var errorDescription: String? {
            switch self {
            case .unmatchedQuote:
                "Close the unmatched quote in the command."
            case .trailingEscape:
                "Complete or remove the trailing backslash in the command."
            case .nullCharacter:
                "The command cannot contain a null character."
            }
        }
    }

    static func split(_ command: String) -> [String] {
        tokenize(command, strict: false).arguments
    }

    static func validatedSplit(_ command: String) throws(TokenizationError) -> [String] {
        guard !command.utf8.contains(0) else {
            throw TokenizationError.nullCharacter
        }
        let result = tokenize(command, strict: true)
        if let error = result.error {
            throw error
        }
        return result.arguments
    }

    private static func tokenize(_ command: String, strict: Bool) -> (arguments: [String], error: TokenizationError?) {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var tokenStarted = false
        let characters = strict ? command.unicodeScalars.map { Character(String($0)) } : Array(command)

        for character in characters {
            if escaping {
                if strict, character == "\n" {
                    escaping = false
                    continue
                }
                if strict, quote == "\"", !"$`\"\\".contains(character) {
                    current.append("\\")
                }
                current.append(character)
                tokenStarted = true
                escaping = false
                continue
            }

            // Exec keeps its existing permissive escaping; launch validation honors literal single quotes.
            if character == "\\", !strict || quote != "'" {
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
                tokenStarted = true
                continue
            }

            if character.isWhitespace {
                if !current.isEmpty || (strict && tokenStarted) {
                    result.append(current)
                    current = ""
                }
                tokenStarted = false
                continue
            }

            current.append(character)
            tokenStarted = true
        }

        if !current.isEmpty || (strict && tokenStarted) {
            result.append(current)
        }
        if strict, escaping {
            return (result, .trailingEscape)
        }
        if strict, quote != nil {
            return (result, .unmatchedQuote)
        }
        return (result, nil)
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
