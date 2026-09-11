import Foundation

struct OperationService: Sendable {
    var preferences: AppPreferences
    var resolver: ContainerCLIResolver
    var runner: ProcessRunning
    var historyStore: OperationHistoryStoring

    init(
        preferences: AppPreferences = UserDefaultsAppPreferences(),
        resolver: ContainerCLIResolver = ContainerCLIResolver(),
        runner: ProcessRunning = ProcessRunner(),
        historyStore: OperationHistoryStoring = UserDefaultsOperationHistoryStore()
    ) {
        self.preferences = preferences
        self.resolver = resolver
        self.runner = runner
        self.historyStore = historyStore
    }

    func runContainerOperation(_ operation: ContainerOperation, identifier: String?, outputHandler: ProcessOutputHandler? = nil) async -> OperationOutcome {
        guard let arguments = operation.arguments(identifier: identifier) else {
            return OperationOutcome(
                title: operation.rawValue,
                command: nil,
                result: nil,
                errorMessage: "Select a container before running \(operation.rawValue)."
            )
        }

        return await runOperation(title: operation.rawValue, arguments: arguments, timeout: timeout(for: operation), outputHandler: outputHandler)
    }

    func runContainerBatch(_ request: ContainerBatchRequest, outputHandler: ProcessOutputHandler? = nil) async -> ContainerBatchOutcome {
        do {
            try request.validate()
        } catch {
            let message = error.localizedDescription
            return ContainerBatchOutcome(
                operation: request.operation,
                targets: request.targets,
                itemResults: [],
                commands: [],
                batchResult: nil,
                succeededIDs: [],
                failedIDs: [],
                errorMessage: message,
                output: message
            )
        }

        switch request.operation {
        case .start:
            return await runSequentialContainerStarts(request.targets, outputHandler: outputHandler)
        case .stop, .delete:
            return await runMultiContainerBatch(request, outputHandler: outputHandler)
        case .create, .run, .kill, .logs, .stats, .copy, .export, .exec, .prune:
            let error = ContainerBatchValidationError.unsupportedOperation(request.operation)
            return ContainerBatchOutcome(
                operation: request.operation,
                targets: request.targets,
                itemResults: [],
                commands: [],
                batchResult: nil,
                succeededIDs: [],
                failedIDs: [],
                errorMessage: error.localizedDescription,
                output: error.localizedDescription
            )
        }
    }

    func runContainerCreateOrRun(_ request: ContainerCreateRunRequest, outputHandler: ProcessOutputHandler? = nil) async -> OperationOutcome {
        do {
            let arguments = try request.validatedArguments()
            return await runOperation(title: request.operation.rawValue, arguments: arguments, timeout: 60 * 30, outputHandler: outputHandler)
        } catch {
            return OperationOutcome(title: request.operation.rawValue, command: nil, result: nil, errorMessage: error.localizedDescription)
        }
    }

    func runContainerCopy(_ request: ContainerCopyRequest, outputHandler: ProcessOutputHandler? = nil) async -> OperationOutcome {
        guard !request.source.isEmpty, !request.destination.isEmpty else {
            return OperationOutcome(title: "Copy", command: nil, result: nil, errorMessage: "Provide both source and destination paths.")
        }
        guard request.source.isContainerPath != request.destination.isContainerPath else {
            return OperationOutcome(title: "Copy", command: nil, result: nil, errorMessage: "Exactly one copy path must use container:path syntax.")
        }
        return await runOperation(title: "Copy", arguments: request.arguments, timeout: 60 * 10, outputHandler: outputHandler)
    }

    func runContainerExport(_ request: ContainerExportRequest, outputHandler: ProcessOutputHandler? = nil) async -> OperationOutcome {
        guard !request.outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return OperationOutcome(title: "Export", command: nil, result: nil, errorMessage: "Provide an output tar path.")
        }
        return await runOperation(title: "Export", arguments: request.arguments, timeout: 60 * 10, outputHandler: outputHandler)
    }

    func openExecInTerminal(_ request: ContainerExecRequest) async -> OperationOutcome {
        let detection = resolver.resolve(overridePath: preferences.cliExecutablePath)
        guard let executableURL = detection.executableURL else {
            return OperationOutcome(title: "Exec", command: nil, result: nil, errorMessage: detection.problem ?? "Apple container CLI was not found.")
        }

        let preview = CLICommandPreview(executable: executableURL.path, arguments: request.arguments)
        let terminalCommand = terminalShellCommand(executable: executableURL.path, arguments: request.arguments)
        let script = "tell application \"Terminal\" to do script \"\(appleScriptEscaped(terminalCommand))\""
        do {
            let result = try await runner.run(
                ProcessCommand(
                    executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                    arguments: ["-e", script],
                    timeout: 30
                )
            )
            historyStore.append(OperationRecord(title: "Exec", command: preview.displayString, exitCode: result.exitCode, succeeded: result.succeeded))
            return OperationOutcome(title: "Exec", command: preview, result: result, errorMessage: nil)
        } catch {
            historyStore.append(OperationRecord(title: "Exec", command: preview.displayString, exitCode: nil, succeeded: false))
            return OperationOutcome(title: "Exec", command: preview, result: nil, errorMessage: error.localizedDescription)
        }
    }

    func runImageOperation(_ operation: ImageOperation, identifier: String?, input: String?, outputHandler: ProcessOutputHandler? = nil) async -> OperationOutcome {
        guard let arguments = operation.arguments(identifier: identifier, input: input) else {
            return OperationOutcome(
                title: operation.rawValue,
                command: nil,
                result: nil,
                errorMessage: "Provide the required image reference before running \(operation.rawValue)."
            )
        }
        return await runOperation(title: operation.rawValue, arguments: arguments, timeout: timeout(for: operation), outputHandler: outputHandler)
    }

    func runBuild(_ request: BuildRequest, outputHandler: ProcessOutputHandler? = nil) async -> OperationOutcome {
        await runOperation(title: "Build", arguments: request.arguments, timeout: 60 * 30, outputHandler: outputHandler)
    }

    func runNetworkOperation(_ operation: NetworkOperation, identifier: String?, input: String?, outputHandler: ProcessOutputHandler? = nil) async -> OperationOutcome {
        guard let arguments = operation.arguments(identifier: identifier, input: input) else {
            return OperationOutcome(title: operation.rawValue, command: nil, result: nil, errorMessage: "Provide a network name before running \(operation.rawValue).")
        }
        return await runOperation(title: "Network \(operation.rawValue)", arguments: arguments, timeout: 60, outputHandler: outputHandler)
    }

    func runVolumeOperation(_ operation: VolumeOperation, identifier: String?, input: String?, outputHandler: ProcessOutputHandler? = nil) async -> OperationOutcome {
        guard let arguments = operation.arguments(identifier: identifier, input: input) else {
            return OperationOutcome(title: operation.rawValue, command: nil, result: nil, errorMessage: "Provide a volume name before running \(operation.rawValue).")
        }
        return await runOperation(title: "Volume \(operation.rawValue)", arguments: arguments, timeout: 60, outputHandler: outputHandler)
    }

    func runRegistryLogout(identifier: String?) async -> OperationOutcome {
        guard let arguments = RegistryOperation.logout.arguments(identifier: identifier) else {
            return OperationOutcome(title: "Logout", command: nil, result: nil, errorMessage: "Select a registry before logging out.")
        }
        return await runOperation(title: "Registry Logout", arguments: arguments, timeout: 60)
    }

    func runRegistryLogin(_ request: RegistryLoginRequest) async -> OperationOutcome {
        let detection = resolver.resolve(overridePath: preferences.cliExecutablePath)
        guard let executableURL = detection.executableURL else {
            return OperationOutcome(title: "Registry Login", command: nil, result: nil, errorMessage: detection.problem ?? "Apple container CLI was not found.")
        }

        let client = ContainerCLIClient(executableURL: executableURL, runner: runner)
        let command = CLICommandPreview(
            executable: executableURL.path,
            arguments: ["registry", "login", request.registry, "--username", request.username, "--password-stdin"]
        )

        do {
            let result = try await client.registryLogin(registry: request.registry, username: request.username, password: request.password)
            historyStore.append(OperationRecord(title: "Registry Login", command: command.displayString, exitCode: result.exitCode, succeeded: result.succeeded))
            return OperationOutcome(title: "Registry Login", command: command, result: result, errorMessage: nil)
        } catch {
            historyStore.append(OperationRecord(title: "Registry Login", command: command.displayString, exitCode: nil, succeeded: false))
            return OperationOutcome(title: "Registry Login", command: command, result: nil, errorMessage: error.localizedDescription)
        }
    }

    func runMachineOperation(_ operation: MachineOperation, identifier: String?, outputHandler: ProcessOutputHandler? = nil) async -> OperationOutcome {
        guard let arguments = operation.arguments(identifier: identifier) else {
            return OperationOutcome(title: operation.rawValue, command: nil, result: nil, errorMessage: "Select a machine before running \(operation.rawValue).")
        }
        return await runOperation(title: "Machine \(operation.rawValue)", arguments: arguments, timeout: operation == .logs ? 30 : 120, outputHandler: outputHandler)
    }

    func runBuilderOperation(_ operation: BuilderOperation, cpus: String = "", memory: String = "", outputHandler: ProcessOutputHandler? = nil) async -> OperationOutcome {
        let timeout: TimeInterval = operation == .start ? 60 * 30 : 60
        return await runOperation(title: "Builder \(operation.rawValue)", arguments: operation.arguments(cpus: cpus, memory: memory), timeout: timeout, outputHandler: outputHandler)
    }

    private func runSequentialContainerStarts(
        _ targets: [ContainerBatchTarget],
        outputHandler: ProcessOutputHandler?
    ) async -> ContainerBatchOutcome {
        var itemResults: [ContainerBatchItemResult] = []
        var commands: [CLICommandPreview] = []
        var succeededIDs: [String] = []
        var failedIDs: [String] = []

        for target in targets {
            let outcome = await runOperation(
                title: ContainerOperation.start.rawValue,
                arguments: ["start", target.id],
                timeout: timeout(for: .start),
                outputHandler: outputHandler
            )
            let itemResult = ContainerBatchItemResult(
                target: target,
                command: outcome.command,
                result: outcome.result,
                errorMessage: outcome.errorMessage
            )
            itemResults.append(itemResult)
            if let command = itemResult.command {
                commands.append(command)
            }
            if itemResult.succeeded {
                succeededIDs.append(target.id)
            } else {
                failedIDs.append(target.id)
            }
        }

        return ContainerBatchOutcome(
            operation: .start,
            targets: targets,
            itemResults: itemResults,
            commands: commands,
            batchResult: nil,
            succeededIDs: succeededIDs,
            failedIDs: failedIDs,
            errorMessage: nil,
            output: startBatchOutput(itemResults)
        )
    }

    private func runMultiContainerBatch(
        _ request: ContainerBatchRequest,
        outputHandler: ProcessOutputHandler?
    ) async -> ContainerBatchOutcome {
        let identifiers = request.targets.map(\.id)
        var arguments = [request.operation == .stop ? "stop" : "delete"]
        if request.operation == .delete, request.forceDelete {
            arguments.append("--force")
        }
        arguments.append(contentsOf: identifiers)

        let operationOutcome = await runOperation(
            title: request.operation.rawValue,
            arguments: arguments,
            timeout: timeout(for: request.operation),
            outputHandler: outputHandler
        )
        let succeededIDs = operationOutcome.succeeded ? identifiers : []
        let failedIDs = operationOutcome.succeeded ? [] : identifiers
        let commands = operationOutcome.command.map { [$0] } ?? []

        return ContainerBatchOutcome(
            operation: request.operation,
            targets: request.targets,
            itemResults: [],
            commands: commands,
            batchResult: operationOutcome.result,
            succeededIDs: succeededIDs,
            failedIDs: failedIDs,
            errorMessage: operationOutcome.errorMessage,
            output: multiContainerBatchOutput(
                operation: request.operation,
                targets: request.targets,
                succeeded: operationOutcome.succeeded,
                operationOutcome: operationOutcome
            )
        )
    }

    private func startBatchOutput(_ results: [ContainerBatchItemResult]) -> String {
        let failures = results.filter { !$0.succeeded }
        let headline: String
        if failures.isEmpty {
            headline = "Started \(containerCount(results.count)): \(results.map { targetLabel($0.target) }.joined(separator: ", "))."
        } else {
            let succeededCount = results.count - failures.count
            let failureNames = failures.map { targetLabel($0.target) }.joined(separator: ", ")
            headline = "Failed to start \(failures.count) of \(containerCount(results.count)): \(failureNames)."
                + (succeededCount == 0 ? "" : " \(containerCount(succeededCount)) succeeded.")
        }

        let details = results.compactMap { result -> String? in
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? nil : "\(targetLabel(result.target)): \(output)"
        }
        return ([headline] + details).joined(separator: "\n")
    }

    private func multiContainerBatchOutput(
        operation: ContainerOperation,
        targets: [ContainerBatchTarget],
        succeeded: Bool,
        operationOutcome: OperationOutcome
    ) -> String {
        let names = targets.map(targetLabel).joined(separator: ", ")
        let action: String
        if succeeded {
            action = operation == .stop ? "Stopped" : "Deleted"
        } else {
            action = operation == .stop ? "Failed to stop" : "Failed to delete"
        }
        let headline = "\(action) \(containerCount(targets.count)): \(names)."
        let detail = operationRuntimeOutput(operationOutcome).trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? headline : "\(headline)\n\(detail)"
    }

    private func operationRuntimeOutput(_ outcome: OperationOutcome) -> String {
        if let errorMessage = outcome.errorMessage {
            return errorMessage
        }
        guard let result = outcome.result else {
            return ""
        }
        let output = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: result.stdout.isEmpty || result.stderr.isEmpty ? "" : "\n")
        if !output.isEmpty {
            return output
        }
        return result.succeeded ? "" : "Command failed with exit code \(result.exitCode)."
    }

    private func containerCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "container" : "containers")"
    }

    private func targetLabel(_ target: ContainerBatchTarget) -> String {
        target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? target.id : target.name
    }

    private func runOperation(title: String, arguments: [String], timeout: TimeInterval, outputHandler: ProcessOutputHandler? = nil) async -> OperationOutcome {
        let detection = resolver.resolve(overridePath: preferences.cliExecutablePath)
        guard let executableURL = detection.executableURL else {
            return OperationOutcome(
                title: title,
                command: nil,
                result: nil,
                errorMessage: detection.problem ?? "Apple container CLI was not found."
            )
        }

        let client = ContainerCLIClient(executableURL: executableURL, runner: runner)
        let command = CLICommandPreview(executable: executableURL.path, arguments: arguments)

        do {
            let result = try await client.run(arguments: arguments, timeout: timeout, outputHandler: outputHandler)
            historyStore.append(
                OperationRecord(
                    title: title,
                    command: result.preview.displayString,
                    exitCode: result.exitCode,
                    succeeded: result.succeeded
                )
            )
            return OperationOutcome(title: title, command: result.preview, result: result, errorMessage: nil)
        } catch {
            historyStore.append(
                OperationRecord(
                    title: title,
                    command: command.displayString,
                    exitCode: nil,
                    succeeded: false
                )
            )
            return OperationOutcome(title: title, command: command, result: nil, errorMessage: error.localizedDescription)
        }
    }

    private func timeout(for operation: ContainerOperation) -> TimeInterval {
        switch operation {
        case .logs, .stats:
            30
        case .stop, .kill, .delete, .copy, .export, .prune:
            60
        case .create, .run, .start, .exec:
            120
        }
    }

    private func timeout(for operation: ImageOperation) -> TimeInterval {
        switch operation {
        case .pull, .push:
            60 * 30
        case .tag, .delete, .prune:
            60
        }
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func terminalShellCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(posixSingleQuoted).joined(separator: " ")
    }

    private func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var isContainerPath: Bool {
        guard let delimiter = range(of: ":/") else {
            return false
        }
        return delimiter.lowerBound > startIndex && delimiter.upperBound <= endIndex
    }
}
