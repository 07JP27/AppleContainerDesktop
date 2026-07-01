import Foundation

struct SystemService: Sendable {
    var preferences: AppPreferences
    var resolver: ContainerCLIResolver
    var runner: ProcessRunning

    init(
        preferences: AppPreferences = UserDefaultsAppPreferences(),
        resolver: ContainerCLIResolver = ContainerCLIResolver(),
        runner: ProcessRunning = ProcessRunner()
    ) {
        self.preferences = preferences
        self.resolver = resolver
        self.runner = runner
    }

    func loadSystemSnapshot() async -> SystemSnapshot {
        let detection = resolver.resolve(overridePath: preferences.cliExecutablePath)
        guard let executableURL = detection.executableURL else {
            return SystemSnapshot(
                detection: detection,
                health: .missingCLI,
                version: nil,
                statusJSON: nil,
                diskUsageJSON: nil,
                message: detection.problem ?? "Apple container CLI is missing.",
                lastCommand: nil,
                errorDetail: nil
            )
        }

        let client = ContainerCLIClient(executableURL: executableURL, runner: runner)
        let version = try? await client.systemVersion()
        let versionSummary = version.map(VersionSummary.init(components:))

        do {
            let status = try await client.systemStatusJSON()
            let diskUsage = try? await client.systemDiskUsageJSON()
            let health: ServiceHealth = versionSummary?.apiServerVersion == nil ? .unknown : .running
            return SystemSnapshot(
                detection: detection,
                health: health,
                version: versionSummary,
                statusJSON: status,
                diskUsageJSON: diskUsage,
                message: health == .running ? "System service is running." : "System status was returned, but API server version was unavailable.",
                lastCommand: CLICommandPreview(executable: executableURL.path, arguments: ["system", "status", "--format", "json"]),
                errorDetail: nil
            )
        } catch let error as CLIClientError {
            return stoppedSnapshot(detection: detection, executableURL: executableURL, version: versionSummary, error: error)
        } catch {
            return SystemSnapshot(
                detection: detection,
                health: .unhealthy,
                version: versionSummary,
                statusJSON: nil,
                diskUsageJSON: nil,
                message: "System status could not be read.",
                lastCommand: CLICommandPreview(executable: executableURL.path, arguments: ["system", "status", "--format", "json"]),
                errorDetail: error.localizedDescription
            )
        }
    }

    func loadSettingsSnapshot() async -> SettingsSnapshot {
        let detection = resolver.resolve(overridePath: preferences.cliExecutablePath)
        guard let executableURL = detection.executableURL else {
            return SettingsSnapshot(
                detection: detection,
                version: nil,
                propertiesJSON: nil,
                errorMessage: detection.problem,
                command: nil
            )
        }

        let client = ContainerCLIClient(executableURL: executableURL, runner: runner)
        let version = try? await client.systemVersion()
        let versionSummary = version.map(VersionSummary.init(components:))
        let command = CLICommandPreview(executable: executableURL.path, arguments: ["system", "property", "list", "--format", "json"])

        do {
            let properties = try await client.systemPropertiesJSON()
            return SettingsSnapshot(
                detection: detection,
                version: versionSummary,
                propertiesJSON: ResourceJSONParser().prettyJSON(properties),
                errorMessage: nil,
                command: command
            )
        } catch let error as CLIClientError {
            return SettingsSnapshot(
                detection: detection,
                version: versionSummary,
                propertiesJSON: nil,
                errorMessage: error.localizedDescription,
                command: command
            )
        } catch {
            return SettingsSnapshot(
                detection: detection,
                version: versionSummary,
                propertiesJSON: nil,
                errorMessage: error.localizedDescription,
                command: command
            )
        }
    }

    func startSystem(enableKernelInstall: Bool, timeout: TimeInterval = 120) async -> SystemStartOutcome {
        let detection = resolver.resolve(overridePath: preferences.cliExecutablePath)
        guard let executableURL = detection.executableURL else {
            return SystemStartOutcome(command: nil, result: nil, errorMessage: detection.problem ?? "Apple container CLI was not found.")
        }

        let client = ContainerCLIClient(executableURL: executableURL, runner: runner)
        let kernelFlag = enableKernelInstall ? "--enable-kernel-install" : "--disable-kernel-install"
        let command = CLICommandPreview(executable: executableURL.path, arguments: ["system", "start", kernelFlag, "--timeout", "\(Int(timeout))"])
        do {
            let result = try await client.startSystem(enableKernelInstall: enableKernelInstall, timeout: timeout)
            return SystemStartOutcome(command: result.preview, result: result, errorMessage: nil)
        } catch {
            return SystemStartOutcome(command: command, result: nil, errorMessage: error.localizedDescription)
        }
    }

    private func stoppedSnapshot(
        detection: CLIDetectionResult,
        executableURL: URL,
        version: VersionSummary?,
        error: CLIClientError
    ) -> SystemSnapshot {
        switch error {
        case .processFailed(let result):
            return SystemSnapshot(
                detection: detection,
                health: .stopped,
                version: version,
                statusJSON: nil,
                diskUsageJSON: nil,
                message: "System service appears to be stopped or unreachable.",
                lastCommand: result.preview,
                errorDetail: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        case .decodingFailed(let command, let output):
            return SystemSnapshot(
                detection: detection,
                health: .unhealthy,
                version: version,
                statusJSON: nil,
                diskUsageJSON: nil,
                message: "System status returned unexpected output.",
                lastCommand: command,
                errorDetail: output
            )
        }
    }
}
