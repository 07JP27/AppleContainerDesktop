import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let windowController = MainWindowController()
        self.windowController = windowController
        installMainMenu(target: windowController.shellViewController)
        windowController.showMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.showMainWindow()
        return true
    }

    private func installMainMenu(target: AppShellViewController) {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Apple Container Desktop")
        appMenu.addItem(withTitle: "About Apple Container Desktop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        addMenuItem("Settings...", key: ",", action: #selector(AppShellViewController.showSettings), target: target, to: appMenu)
        appMenu.addItem(.separator())
        let servicesMenuItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesMenuItem.submenu = servicesMenu
        appMenu.addItem(servicesMenuItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Apple Container Desktop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        addMenuItem("Hide Others", key: "h", modifiers: [.command, .option], action: #selector(NSApplication.hideOtherApplications(_:)), target: NSApp, to: appMenu)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Apple Container Desktop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        addMenuItem("Refresh", key: "r", action: #selector(AppShellViewController.refreshContent), target: target, to: viewMenu)
        addMenuItem("Focus Search", key: "f", action: #selector(AppShellViewController.focusSearch), target: target, to: viewMenu)
        viewMenu.addItem(.separator())
        addMenuItem("Containers", key: "1", action: #selector(AppShellViewController.showContainers), target: target, to: viewMenu)
        addMenuItem("Images", key: "2", action: #selector(AppShellViewController.showImages), target: target, to: viewMenu)
        addMenuItem("Networks", key: "3", action: #selector(AppShellViewController.showNetworks), target: target, to: viewMenu)
        addMenuItem("Volumes", key: "4", action: #selector(AppShellViewController.showVolumes), target: target, to: viewMenu)
        addMenuItem("Registries", key: "5", action: #selector(AppShellViewController.showRegistries), target: target, to: viewMenu)
        addMenuItem("Operations", key: "6", action: #selector(AppShellViewController.showOperations), target: target, to: viewMenu)
        viewMenu.addItem(.separator())
        addMenuItem("Runtime Status", key: "0", action: #selector(AppShellViewController.showSystem), target: target, to: viewMenu)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let containerMenuItem = NSMenuItem()
        let containerMenu = NSMenu(title: "Container")
        addMenuItem("Start Selected Container", key: "\r", action: #selector(AppShellViewController.startSelectedContainer), target: target, to: containerMenu)
        addMenuItem("Stop Selected Container", key: "s", modifiers: [.command, .option], action: #selector(AppShellViewController.stopSelectedContainer), target: target, to: containerMenu)
        addMenuItem("Show Selected Container Logs", key: "l", action: #selector(AppShellViewController.showSelectedContainerLogs), target: target, to: containerMenu)
        containerMenuItem.submenu = containerMenu
        mainMenu.addItem(containerMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func addMenuItem(
        _ title: String,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command,
        action: Selector,
        target: AnyObject,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
    }
}
