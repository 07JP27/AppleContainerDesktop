import Foundation

struct ResourceService: Sendable {
    var preferences: AppPreferences
    var resolver: ContainerCLIResolver
    var runner: ProcessRunning
    var parser: ResourceJSONParser

    init(
        preferences: AppPreferences = UserDefaultsAppPreferences(),
        resolver: ContainerCLIResolver = ContainerCLIResolver(),
        runner: ProcessRunning = ProcessRunner(),
        parser: ResourceJSONParser = ResourceJSONParser()
    ) {
        self.preferences = preferences
        self.resolver = resolver
        self.runner = runner
        self.parser = parser
    }

    func load(kind: ResourceKind) async -> ResourceListSnapshot {
        let detection = resolver.resolve(overridePath: preferences.cliExecutablePath)
        guard let executableURL = detection.executableURL else {
            return ResourceListSnapshot(
                kind: kind,
                detection: detection,
                command: nil,
                items: [],
                errorMessage: detection.problem ?? "Apple container CLI was not found.",
                errorDetail: nil
            )
        }

        let client = ContainerCLIClient(executableURL: executableURL, runner: runner)
        let preview = CLICommandPreview(executable: executableURL.path, arguments: kind.listArguments)

        do {
            let result = try await client.run(arguments: kind.listArguments, timeout: 30)
            guard result.succeeded else {
                return failureSnapshot(kind: kind, detection: detection, command: result.preview, result: result)
            }

            let items = try parser.parseList(result.stdout, kind: kind)
            return ResourceListSnapshot(
                kind: kind,
                detection: detection,
                command: result.preview,
                items: items,
                errorMessage: nil,
                errorDetail: nil
            )
        } catch ResourceParserError.invalidJSON {
            return ResourceListSnapshot(
                kind: kind,
                detection: detection,
                command: preview,
                items: [],
                errorMessage: "Unexpected JSON returned for \(kind.rawValue).",
                errorDetail: nil
            )
        } catch {
            return ResourceListSnapshot(
                kind: kind,
                detection: detection,
                command: preview,
                items: [],
                errorMessage: "Could not load \(kind.rawValue).",
                errorDetail: error.localizedDescription
            )
        }
    }

    func inspect(kind: ResourceKind, identifier: String) async -> (command: CLICommandPreview?, json: String, error: String?) {
        let detection = resolver.resolve(overridePath: preferences.cliExecutablePath)
        guard let executableURL = detection.executableURL else {
            return (nil, "", detection.problem ?? "Apple container CLI was not found.")
        }

        guard let arguments = kind.inspectArguments(identifier: identifier) else {
            return (nil, "", "\(kind.rawValue) does not provide an inspect command in the MVP read-only surface.")
        }

        let client = ContainerCLIClient(executableURL: executableURL, runner: runner)
        do {
            let result = try await client.run(arguments: arguments, timeout: 30)
            guard result.succeeded else {
                let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                return (result.preview, "", detail)
            }
            return (result.preview, parser.prettyJSON(result.stdout), nil)
        } catch {
            return (
                CLICommandPreview(executable: executableURL.path, arguments: arguments),
                "",
                error.localizedDescription
            )
        }
    }

    private func failureSnapshot(
        kind: ResourceKind,
        detection: CLIDetectionResult,
        command: CLICommandPreview,
        result: CLIProcessResult
    ) -> ResourceListSnapshot {
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        return ResourceListSnapshot(
            kind: kind,
            detection: detection,
            command: command,
            items: [],
            errorMessage: "\(kind.rawValue) command failed.",
            errorDetail: detail
        )
    }
}

