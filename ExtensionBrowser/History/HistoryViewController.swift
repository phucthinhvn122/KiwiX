import UIKit

@MainActor
final class HistoryViewController: UITableViewController {
    private let store: HistoryStore
    private let onOpen: (URL) -> Void
    private var entries: [HistoryEntry] = []
    private let relativeDateFormatter = RelativeDateTimeFormatter()

    init(store: HistoryStore, onOpen: @escaping (URL) -> Void) {
        self.store = store
        self.onOpen = onOpen
        super.init(style: .insetGrouped)
        title = "History"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(close)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Clear",
            style: .plain,
            target: self,
            action: #selector(confirmClear)
        )
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)
        reload()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let entry = entries[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = entry.title
        content.secondaryText = "\(entry.url.host ?? entry.url.absoluteString) · \(relativeDateFormatter.localizedString(for: entry.visitedAt, relativeTo: Date()))"
        content.secondaryTextProperties.numberOfLines = 2
        content.image = UIImage(systemName: "globe")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onOpen(entries[indexPath.row].url)
        dismiss(animated: true)
    }

    @objc private func reload() {
        Task { [weak self] in
            guard let self else { return }
            do {
                self.entries = try await self.store.entries()
            } catch {
                AppLog.browser.error("Could not load history: \(error.localizedDescription, privacy: .public)")
                self.entries = []
            }
            self.tableView.reloadData()
            self.refreshControl?.endRefreshing()
            self.navigationItem.rightBarButtonItem?.isEnabled = !self.entries.isEmpty
            self.updateEmptyState()
        }
    }

    @objc private func confirmClear() {
        let alert = UIAlertController(
            title: "Clear History?",
            message: "This removes browsing history from this device.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear History", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try await self.store.clear()
                } catch {
                    AppLog.browser.error("Could not clear history: \(error.localizedDescription, privacy: .public)")
                }
                self.reload()
            }
        })
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(alert, animated: true)
    }

    private func updateEmptyState() {
        guard entries.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = "No History"
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        tableView.backgroundView = label
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
