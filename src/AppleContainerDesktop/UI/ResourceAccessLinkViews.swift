import AppKit

@MainActor
final class ResourceAccessLinkButton: NSButton {
    private let link: ResourceAccessLink
    private let openURL: @MainActor (URL) -> Void

    init(link: ResourceAccessLink, openURL: @escaping @MainActor (URL) -> Void) {
        self.link = link
        self.openURL = openURL
        super.init(frame: .zero)
        title = "Open \(link.title)"
        toolTip = "Open \(link.url.absoluteString) in the default browser."
        font = AppFonts.small
        contentTintColor = AppColors.info
        image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        imagePosition = .imageTrailing
        isBordered = false
        alignment = .left
        focusRingType = .exterior
        target = self
        action = #selector(openLink)
        setAccessibilityLabel("Open \(link.title) in browser")
        setAccessibilityHelp(toolTip)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func openLink() {
        openURL(link.url)
    }
}

@MainActor
final class ResourceAccessTableCellView: NSTableCellView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let linkButton = NSButton()
    private var links: [ResourceAccessLink] = []
    private var openURL: @MainActor (URL) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = AppFonts.small
        valueLabel.lineBreakMode = .byTruncatingTail
        addSubview(valueLabel)
        textField = valueLabel

        linkButton.translatesAutoresizingMaskIntoConstraints = false
        linkButton.font = AppFonts.small
        linkButton.contentTintColor = AppColors.info
        linkButton.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        linkButton.imagePosition = .imageTrailing
        linkButton.isBordered = false
        linkButton.alignment = .left
        linkButton.focusRingType = .exterior
        linkButton.target = self
        linkButton.action = #selector(activateLink)
        addSubview(linkButton)

        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: AppSpacing.sm),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -AppSpacing.sm),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            linkButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: AppSpacing.sm),
            linkButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -AppSpacing.sm),
            linkButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(value: ResourceCellValue, openURL: @escaping @MainActor (URL) -> Void) {
        links = value.links
        self.openURL = openURL
        valueLabel.stringValue = value.text
        valueLabel.toolTip = value.tooltip
        valueLabel.setAccessibilityLabel("Port(s): \(value.text)")
        valueLabel.setAccessibilityHelp(value.tooltip)
        valueLabel.isHidden = !links.isEmpty
        linkButton.isHidden = links.isEmpty
        guard let first = links.first else { return }
        linkButton.title = links.count == 1 ? first.title : "\(first.title) (+\(links.count - 1))"
        linkButton.toolTip = value.tooltip
        linkButton.setAccessibilityLabel(
            links.count == 1 ? "Open \(first.title) in browser" : "Choose a published port to open in browser"
        )
        linkButton.setAccessibilityHelp(value.tooltip)
    }

    @objc private func activateLink() {
        guard let first = links.first else { return }
        if links.count == 1 {
            openURL(first.url)
            return
        }
        let menu = NSMenu()
        for link in links {
            let item = NSMenuItem(title: "Open \(link.title)", action: #selector(openMenuLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = link.url as NSURL
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }

    @objc private func openMenuLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openURL(url)
    }
}
