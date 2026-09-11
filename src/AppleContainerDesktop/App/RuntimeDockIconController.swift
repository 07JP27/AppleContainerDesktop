import AppKit
import OSLog

@MainActor
final class RuntimeDockIconController {
    static let runningAssetName = "RuntimeRunningIcon"

    private let loadImage: (String) -> NSImage?
    private let applyImage: (NSImage?) -> Void
    private let reportError: (String) -> Void
    private var runningImage: NSImage?
    private var isShowingRunningIcon = false
    private var reportedMissingImage = false

    init(
        loadImage: @escaping (String) -> NSImage? = { NSImage(named: NSImage.Name($0)) },
        applyImage: @escaping (NSImage?) -> Void = { NSApplication.shared.applicationIconImage = $0 },
        reportError: @escaping (String) -> Void = {
            Logger(subsystem: "dev.jp27.AppleContainerDesktop", category: "RuntimeDockIcon")
                .error("\($0, privacy: .public)")
        }
    ) {
        self.loadImage = loadImage
        self.applyImage = applyImage
        self.reportError = reportError
    }

    func update(_ health: ServiceHealth) {
        guard health == .running else {
            if isShowingRunningIcon { reset() }
            return
        }
        guard !isShowingRunningIcon else { return }
        if runningImage == nil {
            runningImage = loadImage(Self.runningAssetName)
        }
        guard let runningImage, runningImage.isValid else {
            if !reportedMissingImage {
                reportError("Could not load \(Self.runningAssetName). The Dock will keep the default orange app icon.")
                reportedMissingImage = true
            }
            return
        }
        applyImage(runningImage)
        isShowingRunningIcon = true
    }

    func reset() {
        // nil restores the bundled orange icon without modifying the app on disk.
        applyImage(nil)
        isShowingRunningIcon = false
    }
}
