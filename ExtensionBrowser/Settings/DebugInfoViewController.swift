import UIKit

@MainActor
final class DebugInfoViewController: UITableViewController {
    private let informationProvider: () -> [String: String]
    private var rows: [(key: String, value: String)] = []

    init(informationProvider: @escaping () -> [String: String]) {
        self.informationProvider = informationProvider
        super.init(style: .insetGrouped)
        title = "Browser Debug"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self,
            action: #selector(refresh)
        )
        refresh()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = rows[indexPath.row].key
        content.secondaryText = rows[indexPath.row].value
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    @objc private func refresh() {
        rows = informationProvider().sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        tableView.reloadData()
    }
}
