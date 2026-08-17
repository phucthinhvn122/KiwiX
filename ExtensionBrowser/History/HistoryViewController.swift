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
        tableView.backgroundColor = KiwiTheme.canvas
        navigationItem.largeTitleDisplayMode = .always
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
        content.image = UIImage(systemName: "clock.fill")
        content.imageProperties.tintColor = KiwiTheme.accentDeep
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onOpen(entries[indexPath.row].url)
        dismiss(animated: true)
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let entry = entries[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            Task {
                do {
                    try await self.store.remove(id: entry.id)
                    self.entries.removeAll { $0.id == entry.id }
                    self.tableView.reloadData()
                    self.navigationItem.rightBarButtonItem?.isEnabled = !self.entries.isEmpty
                    self.updateEmptyState()
                    completion(true)
                } catch {
                    completion(false)
                }
            }
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
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
            contentUnavailableConfiguration = nil
            return
        }
        contentUnavailableConfiguration = KiwiTheme.emptyConfiguration(
            title: "No History Yet",
            message: "Pages you visit in regular tabs will appear here. Private tabs are never saved.",
            systemImage: "clock.arrow.circlepath"
        )
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
