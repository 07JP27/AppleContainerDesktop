import AppKit

final class MainWindowController: NSWindowController {
    let shellViewController: AppShellViewController
    private let defaultContentSize = NSSize(width: 1120, height: 720)

    init() {
        shellViewController = AppShellViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultContentSize.width, height: defaultContentSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = shellViewController
        window.title = "Apple Container Desktop"
        window.minSize = NSSize(width: 880, height: 560)
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .managed]
        window.toolbarStyle = .unifiedCompact
        window.toolbar = shellViewController.makeToolbar()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showMainWindow() {
        guard let window else {
            return
        }

        if !window.isVisible || window.frame.height < 200 || window.frame.width < 400 {
            placeWindowOnActiveScreen()
        }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func placeWindowOnActiveScreen() {
        guard let window else {
            return
        }
        guard let visibleFrame = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            window.center()
            return
        }

        let size = NSSize(
            width: min(defaultContentSize.width, visibleFrame.width - 40),
            height: min(defaultContentSize.height, visibleFrame.height - 40)
        )
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
