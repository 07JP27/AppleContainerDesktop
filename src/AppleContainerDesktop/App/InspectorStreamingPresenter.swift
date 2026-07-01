import Foundation

final class InspectorStreamingPresenter: @unchecked Sendable {
    private let title: String
    private let command: CLICommandPreview
    private let onInspectorUpdate: @MainActor (InspectorSnapshot) -> Void
    private let buffer = StreamingOutputBuffer()
    private let lock = NSLock()
    private var latestOutput = ""
    private var updateScheduled = false
    private var finished = false

    init(
        title: String,
        command: CLICommandPreview,
        onInspectorUpdate: @escaping @MainActor (InspectorSnapshot) -> Void
    ) {
        self.title = title
        self.command = command
        self.onInspectorUpdate = onInspectorUpdate
    }

    var handler: ProcessOutputHandler {
        { [weak self] event in
            self?.append(event)
        }
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    private func append(_ event: ProcessOutputEvent) {
        let output = buffer.append(event)
        var shouldSchedule = false
        lock.lock()
        if !finished {
            latestOutput = output
            if !updateScheduled {
                updateScheduled = true
                shouldSchedule = true
            }
        }
        lock.unlock()

        if shouldSchedule {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                await self?.publish()
            }
        }
    }

    @MainActor
    private func publish() {
        let output: String
        lock.lock()
        guard !finished else {
            updateScheduled = false
            lock.unlock()
            return
        }
        output = latestOutput
        updateScheduled = false
        lock.unlock()

        onInspectorUpdate(
            InspectorSnapshot(
                title: title,
                subtitle: "Running...",
                command: command,
                detail: output,
                json: nil
            )
        )
    }
}
