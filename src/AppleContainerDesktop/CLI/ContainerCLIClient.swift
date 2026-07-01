import Foundation

struct ContainerCLIClient: Sendable {
    var executableURL: URL
    var runner: ProcessRunning

    init(executableURL: URL, runner: ProcessRunning = ProcessRunner()) {
        self.executableURL = executableURL
        self.runner = runner
    }

    func systemVersion() async throws -> [VersionComponent] {
        let output = try await runSuccessfulJSON(arguments: ["system", "version", "--format", "json"])
        do {
            return try JSONDecoder().decode([VersionComponent].self, from: Data(output.utf8))
        } catch {
            throw CLIClientError.decodingFailed(
                command: CLICommandPreview(executable: executableURL.path, arguments: ["system", "version", "--format", "json"]),
                output: output
            )
        }
    }

    func systemStatusJSON() async throws -> String {
        try await runSuccessfulJSON(arguments: ["system", "status", "--format", "json"])
    }

    func systemDiskUsageJSON() async throws -> String {
        try await runSuccessfulJSON(arguments: ["system", "df", "--format", "json"])
    }

    func systemPropertiesJSON() async throws -> String {
        try await runSuccessfulJSON(arguments: ["system", "property", "list", "--format", "json"])
    }

    func startSystem(enableKernelInstall: Bool, timeout: TimeInterval = 120) async throws -> CLIProcessResult {
        let kernelFlag = enableKernelInstall ? "--enable-kernel-install" : "--disable-kernel-install"
        return try await run(arguments: ["system", "start", kernelFlag, "--timeout", "\(Int(timeout))"], timeout: timeout + 5)
    }

    func stopSystem(timeout: TimeInterval = 60) async throws -> CLIProcessResult {
        try await run(arguments: ["system", "stop"], timeout: timeout)
    }

    func registryLogin(registry: String, username: String, password: String) async throws -> CLIProcessResult {
        let input = Data((password + "\n").utf8)
        return try await run(
            arguments: ["registry", "login", registry, "--username", username, "--password-stdin"],
            standardInput: input,
            timeout: 120
        )
    }

    @discardableResult
    func run(
        arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        outputHandler: ProcessOutputHandler? = nil
    ) async throws -> CLIProcessResult {
        try await runner.run(
            ProcessCommand(
                executableURL: executableURL,
                arguments: arguments,
                standardInput: standardInput,
                timeout: timeout
            ),
            outputHandler: outputHandler
        )
    }

    private func runSuccessfulJSON(arguments: [String]) async throws -> String {
        let result = try await run(arguments: arguments, timeout: 30)
        guard result.succeeded else {
            throw CLIClientError.processFailed(result)
        }
        return result.stdout
    }
}
