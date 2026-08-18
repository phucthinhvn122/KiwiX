import UIKit

@MainActor
final class DownloadsViewController: UITableViewController, UIDocumentInteractionControllerDelegate {
    private let coordinator: DownloadCoordinator
    private var items: [DownloadItem] = []
    private var documentInteractionController: UIDocumentInteractionController?

    init(coordinator: DownloadCoordinator) {
        self.coordinator = coordinator
        super.init(style: .insetGrouped)
        title = "Downloads"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = KiwiTheme.canvas
        navigationItem.largeTitleDisplayMode = .always
        tableView.register(DownloadTableViewCell.self, forCellReuseIdentifier: DownloadTableViewCell.reuseIdentifier)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(close)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Clear",
            style: .plain,
            target: self,
            action: #selector(confirmClearFinished)
        )
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)

        coordinator.onItemsChanged = { [weak self] items in
            guard let self else { return }
            self.items = items
            self.tableView.reloadData()
            self.refreshControl?.endRefreshing()
            self.updateEmptyState()
            self.navigationItem.rightBarButtonItem?.isEnabled = items.contains { $0.status.isFinished }
        }
        coordinator.onError = { [weak self] message in
            self?.showError(message)
        }
        reload()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: DownloadTableViewCell.reuseIdentifier,
            for: indexPath
        ) as? DownloadTableViewCell else {
            assertionFailure("Download cell registration is inconsistent")
            return UITableViewCell()
        }
        let item = items[indexPath.row]
        let canOpen = coordinator.openableFileURL(for: item.id) != nil
        cell.configure(with: item, canOpen: canOpen)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = items[indexPath.row]
        guard let fileURL = coordinator.openableFileURL(for: item.id) else { return }
        open(fileURL)
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let item = items[indexPath.row]
        var actions: [UIContextualAction] = []

        if !item.status.isFinished {
            let cancel = UIContextualAction(style: .normal, title: "Cancel") { [weak self] _, _, completion in
                self?.coordinator.cancel(id: item.id)
                completion(true)
            }
            cancel.backgroundColor = .systemOrange
            cancel.image = UIImage(systemName: "xmark.circle")
            actions.append(cancel)
        }

        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            self.confirmDelete(item: item, completion: completion)
        }
        delete.image = UIImage(systemName: "trash")
        actions.append(delete)

        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    @objc private func reload() {
        coordinator.reload()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func confirmClearFinished() {
        let alert = UIAlertController(
            title: "Clear Finished Downloads?",
            message: "Completed, failed, and cancelled download records and files will be removed.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            self?.coordinator.clearFinished()
        })
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(alert, animated: true)
    }

    private func confirmDelete(item: DownloadItem, completion: @escaping (Bool) -> Void) {
        guard presentedViewController == nil else {
            completion(false)
            return
        }
        let alert = UIAlertController(
            title: "Delete Download?",
            message: "This permanently removes \(item.fileName) and its downloaded file from this device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.coordinator.delete(id: item.id)
            completion(self != nil)
        })
        present(alert, animated: true)
    }

    private func open(_ fileURL: URL) {
        let controller = UIDocumentInteractionController(url: fileURL)
        controller.delegate = self
        documentInteractionController = controller
        guard !controller.presentPreview(animated: true) else { return }

        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(activity, animated: true)
    }

    private func updateEmptyState() {
        guard items.isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        contentUnavailableConfiguration = KiwiTheme.emptyConfiguration(
            title: "Nothing Downloaded",
            message: "Files you download from the web will be collected here.",
            systemImage: "arrow.down.circle"
        )
    }

    private func showError(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Downloads Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func documentInteractionControllerViewControllerForPreview(
        _ controller: UIDocumentInteractionController
    ) -> UIViewController {
        self
    }
}

@MainActor
private final class DownloadTableViewCell: UITableViewCell {
    static let reuseIdentifier = "DownloadCell"

    private let progressView = UIProgressView(progressViewStyle: .default)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with item: DownloadItem, canOpen: Bool) {
        var content = defaultContentConfiguration()
        content.text = item.fileName
        content.secondaryText = secondaryText(for: item)
        content.secondaryTextProperties.numberOfLines = 2
        content.image = UIImage(systemName: imageName(for: item.status))
        content.imageProperties.tintColor = tintColor(for: item.status)
        contentConfiguration = content

        progressView.isHidden = item.status != .downloading
        progressView.progress = Float(item.progress ?? 0)
        accessoryType = canOpen ? .disclosureIndicator : .none
        selectionStyle = canOpen ? .default : .none
        isAccessibilityElement = true
        accessibilityLabel = item.fileName
        accessibilityValue = accessibilityDescription(for: item)
        accessibilityHint = canOpen ? "Double tap to preview or share this file." : nil
    }

    private func secondaryText(for item: DownloadItem) -> String {
        let privacySuffix = item.isPrivate ? " · Private" : ""
        switch item.status {
        case .queued:
            return "Preparing\(privacySuffix)"
        case .downloading:
            if let total = item.totalBytesExpected {
                let receivedText = ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file)
                let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                let percentage = Int((item.progress ?? 0) * 100)
                return "\(receivedText) of \(totalText) · \(percentage)%\(privacySuffix)"
            }
            let receivedText = ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file)
            return "\(receivedText) downloaded\(privacySuffix)"
        case .completed:
            let size = ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file)
            return "Completed · \(size)\(privacySuffix)"
        case .failed:
            return "Failed: \(item.errorDescription ?? "Unknown error")\(privacySuffix)"
        case .cancelled:
            return "Cancelled\(privacySuffix)"
        }
    }

    private func imageName(for status: DownloadStatus) -> String {
        switch status {
        case .queued:
            return "arrow.down.circle"
        case .downloading:
            return "arrow.down.circle.fill"
        case .completed:
            return "doc.circle.fill"
        case .failed:
            return "exclamationmark.circle"
        case .cancelled:
            return "xmark.circle"
        }
    }

    private func tintColor(for status: DownloadStatus) -> UIColor {
        switch status {
        case .queued, .downloading: return KiwiTheme.cyan
        case .completed: return KiwiTheme.accentDeep
        case .failed: return .systemRed
        case .cancelled: return .secondaryLabel
        }
    }

    private func accessibilityDescription(for item: DownloadItem) -> String {
        let privacy = item.isPrivate ? "Private download, " : ""
        switch item.status {
        case .downloading:
            return "\(privacy)downloading, \(Int((item.progress ?? 0) * 100)) percent"
        default:
            return privacy + item.status.rawValue.capitalized
        }
    }
}
