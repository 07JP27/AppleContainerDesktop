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

            var items = try parser.parseList(result.stdout, kind: kind)
            var warning: String?
            if kind == .images, !items.isEmpty {
                let usage = await applyingImageUsage(to: items, client: client)
                items = usage.items
                warning = usage.warning
            }
            return ResourceListSnapshot(
                kind: kind,
                detection: detection,
                command: result.preview,
                items: items,
                errorMessage: nil,
                errorDetail: nil,
                warningMessage: warning
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

    func inspectItem(
        kind: ResourceKind,
        identifier: String,
        imageUsage: ImageUsage? = nil,
        volumeUsage: VolumeUsage? = nil
    ) async -> (item: ResourceListItem?, error: String?) {
        let inspected = await inspect(kind: kind, identifier: identifier)
        if let error = inspected.error {
            return (nil, "Could not refresh details: \(error)")
        }
        do {
            let items = try parser.parseList(inspected.json, kind: kind)
            guard var item = items.first(where: { item in
                if let image = item.image {
                    return image.reference.normalized == ImageReference(identifier).normalized
                }
                if let volume = item.volume {
                    return volume.name == identifier
                }
                return item.inspectIdentifier == identifier
            }) else {
                return (nil, "This resource is no longer available. Refresh the list.")
            }
            if let imageUsage { item.setImageUsage(imageUsage) }
            if let volumeUsage { item.setVolumeUsage(volumeUsage) }
            return (item, nil)
        } catch {
            return (nil, "Could not read resource details: \(error.localizedDescription)")
        }
    }

    func inspectVolumeItem(identifier: String) async -> (item: ResourceListItem?, error: String?) {
        let inspected = await inspectItem(kind: .volumes, identifier: identifier)
        guard var item = inspected.item else { return inspected }
        guard let volumeName = item.volume?.name else {
            return (nil, "Could not read volume details.")
        }

        let detection = resolver.resolve(overridePath: preferences.cliExecutablePath)
        guard let executableURL = detection.executableURL else {
            return volumeUsageUnavailable(
                item,
                reason: "Volume usage is unavailable: \(detection.problem ?? "Apple container CLI was not found.")"
            )
        }

        let client = ContainerCLIClient(executableURL: executableURL, runner: runner)
        do {
            let result = try await client.run(arguments: ResourceKind.containers.listArguments, timeout: 30)
            guard result.succeeded else {
                return volumeUsageUnavailable(
                    item,
                    reason: "Volume usage is unavailable: the container list command failed (exit \(result.exitCode))."
                )
            }

            let containers = try parser.parseList(result.stdout, kind: .containers).compactMap(\.container)
            guard containers.allSatisfy({ $0.mounts != nil }) else {
                return volumeUsageUnavailable(
                    item,
                    reason: "Volume usage is unavailable: container mount data was incomplete."
                )
            }

            let usages = containers.flatMap { container in
                (container.mounts ?? [])
                    .filter { $0.kind == "Volume" && $0.source == volumeName }
                    .map {
                        VolumeContainerUsage(
                            id: container.name,
                            name: container.name,
                            state: container.state,
                            mountTarget: $0.destination
                        )
                    }
            }
            item.setVolumeUsage(.known(usages))
            return (item, nil)
        } catch {
            return volumeUsageUnavailable(
                item,
                reason: "Volume usage is unavailable: \(error.localizedDescription)"
            )
        }
    }

    func inspectLaunchImage(reference: String) async -> Result<ImageMetadata, LaunchImageLookupError> {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, !reference.hasPrefix("-"),
              reference.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            return .failure(LaunchImageLookupError(message: "Enter an image reference to look up its declared ports."))
        }
        let result = await inspectItem(kind: .images, identifier: reference)
        guard let image = result.item?.image else {
            return .failure(LaunchImageLookupError(message: result.error ?? "Image port metadata is unavailable."))
        }
        return .success(image)
    }

    private func applyingImageUsage(to images: [ResourceListItem], client: ContainerCLIClient) async -> (items: [ResourceListItem], warning: String?) {
        do {
            let result = try await client.run(arguments: ResourceKind.containers.listArguments, timeout: 30)
            guard result.succeeded else {
                return (images, "Image usage is unavailable: the container list command failed (exit \(result.exitCode)). Refresh to try again.")
            }
            let containers = try parser.parseList(result.stdout, kind: .containers).compactMap(\.container)
            var isComplete = true
            let items = images.map { original in
                var item = original
                guard let image = item.image else { return item }
                let comparisons = containers.map { (container: $0, matches: image.usageMatch(for: $0)) }
                let canDetermineUsage = comparisons.allSatisfy { $0.matches != nil }
                isComplete = isComplete && canDetermineUsage
                let matches = comparisons.filter { $0.matches == true }.map {
                    ImageContainerUsage(id: $0.container.name, name: $0.container.name, state: $0.container.state)
                }
                item.setImageUsage(canDetermineUsage || !matches.isEmpty ? .known(matches) : .unavailable)
                return item
            }
            return (items, isComplete ? nil : "Image usage is incomplete: some image identities could not be compared.")
        } catch {
            return (images, "Image usage is unavailable: \(error.localizedDescription)")
        }
    }

    private func volumeUsageUnavailable(
        _ original: ResourceListItem,
        reason: String
    ) -> (item: ResourceListItem?, error: String?) {
        var item = original
        item.setVolumeUsage(.unavailable)
        return (item, reason)
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
