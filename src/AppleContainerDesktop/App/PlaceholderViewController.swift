import AppKit

final class PlaceholderViewController: NSViewController {
    private let item: SidebarItem

    init(item: SidebarItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppColors.background.cgColor

        let empty = EmptyStateView(
            title: item.rawValue,
            message: "\(item.rawValue) will be implemented as part of the MVP stages after the CLI bridge and dashboard are stable."
        )
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            empty.topAnchor.constraint(equalTo: view.topAnchor),
            empty.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

