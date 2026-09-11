import AppKit

final class ResourceOverviewView: NSView {
    init(
        overview: ResourceOverview,
        showsHeader: Bool = true,
        openURL: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = AppSpacing.xl
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if showsHeader {
            let header = verticalStack(spacing: AppSpacing.xs)
            header.addFullWidthArrangedSubview(label(overview.title, font: AppFonts.heading))
            header.addFullWidthArrangedSubview(label(overview.subtitle, font: AppFonts.small, color: AppColors.muted))
            stack.addFullWidthArrangedSubview(header)
        }

        if let warning = overview.warning {
            stack.addFullWidthArrangedSubview(label(warning, font: AppFonts.body))
        }

        for section in overview.sections {
            let sectionStack = verticalStack(spacing: AppSpacing.md)
            let heading = label(section.title, font: .systemFont(ofSize: AppFonts.small.pointSize, weight: .semibold))
            sectionStack.addFullWidthArrangedSubview(heading)
            for field in section.fields {
                let row = verticalStack(spacing: AppSpacing.xs)
                row.addFullWidthArrangedSubview(label(field.label, font: AppFonts.small, color: AppColors.muted))
                let value = label(field.value, font: field.monospaced ? AppFonts.mono : AppFonts.body)
                value.toolTip = field.tooltip ?? field.value
                value.setAccessibilityLabel("\(field.label): \(field.value)")
                row.addFullWidthArrangedSubview(value)
                for link in field.links {
                    let linkRow = NSStackView()
                    linkRow.orientation = .horizontal
                    linkRow.alignment = .centerY
                    linkRow.spacing = 0
                    let button = ResourceAccessLinkButton(link: link, openURL: openURL)
                    button.setContentHuggingPriority(.required, for: .horizontal)
                    linkRow.addArrangedSubview(button)
                    linkRow.addArrangedSubview(NSView())
                    row.addFullWidthArrangedSubview(linkRow)
                }
                sectionStack.addFullWidthArrangedSubview(row)
            }
            stack.addFullWidthArrangedSubview(sectionStack)
        }
        setAccessibilityLabel(overview.subtitle)
    }

    required init?(coder: NSCoder) { nil }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = spacing
        return stack
    }

    private func label(_ text: String, font: NSFont, color: NSColor = AppColors.ink) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
