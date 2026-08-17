import UIKit

@MainActor
final class SettingsViewController: UITableViewController {
    private let settingsStore: BrowserSettingsStore

    init(settingsStore: BrowserSettingsStore = .shared) {
        self.settingsStore = settingsStore
        super.init(style: .insetGrouped)
        title = "Settings"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = KiwiTheme.canvas
        tableView.sectionHeaderTopPadding = 18
        tableView.tableHeaderView = makeHeaderView()
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissSettings)
        )
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        3
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return SearchEngine.builtInEngines.count
        case 1: return settingsStore.customSearchEngines.count + 1
        default: return 2
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Default Search"
        case 1: return "Custom Search Engines"
        default: return "Privacy"
        }
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)

        if indexPath.section == 2 {
            var content = cell.defaultContentConfiguration()
            if indexPath.row == 0 {
                content.text = "No in-app advertising"
                content.secondaryText = "KiwiX contains no advertising or third-party analytics SDKs."
                content.image = UIImage(systemName: "checkmark.shield.fill")
                content.imageProperties.tintColor = KiwiTheme.accentDeep
            } else {
                content.text = "Private tabs stay private"
                content.secondaryText = "Private tabs use a temporary data store and are not saved to history."
                content.image = UIImage(systemName: "hand.raised.fill")
                content.imageProperties.tintColor = KiwiTheme.privateAccent
            }
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }

        if indexPath.section == 1, indexPath.row == settingsStore.customSearchEngines.count {
            var content = cell.defaultContentConfiguration()
            content.text = "Add Custom Engine"
            content.image = UIImage(systemName: "plus.circle")
            content.imageProperties.tintColor = KiwiTheme.accentDeep
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        }

        let engine = engine(at: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = engine.name
        content.secondaryText = engine.queryURLTemplate
        content.secondaryTextProperties.numberOfLines = 1
        content.image = UIImage(systemName: searchEngineIcon(for: engine))
        content.imageProperties.tintColor = KiwiTheme.accentDeep
        cell.contentConfiguration = content
        cell.accessoryType = settingsStore.selectedSearchEngine.id == engine.id ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section < 2 else { return }
        if indexPath.section == 1, indexPath.row == settingsStore.customSearchEngines.count {
            presentAddEnginePrompt()
            return
        }

        settingsStore.selectSearchEngine(id: engine(at: indexPath).id)
        tableView.reloadData()
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1,
              indexPath.row < settingsStore.customSearchEngines.count else {
            return nil
        }
        let engine = settingsStore.customSearchEngines[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, finish in
            self?.settingsStore.removeCustomSearchEngine(id: engine.id)
            self?.tableView.reloadData()
            finish(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func engine(at indexPath: IndexPath) -> SearchEngine {
        if indexPath.section == 0 {
            return SearchEngine.builtInEngines[indexPath.row]
        }
        return settingsStore.customSearchEngines[indexPath.row]
    }

    private func presentAddEnginePrompt() {
        let alert = UIAlertController(
            title: "Custom Search Engine",
            message: "Use {query} where the encoded search text belongs.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Name"
            field.autocapitalizationType = .words
        }
        alert.addTextField { field in
            field.placeholder = "https://example.com/search?q={query}"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let name = alert?.textFields?.first?.text,
                  let template = alert?.textFields?.last?.text,
                  self.settingsStore.addCustomSearchEngine(name: name, template: template) != nil else {
                self?.presentInvalidTemplateAlert()
                return
            }
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func searchEngineIcon(for engine: SearchEngine) -> String {
        switch engine.id {
        case SearchEngine.duckDuckGo.id: return "shield.lefthalf.filled"
        case SearchEngine.google.id: return "g.circle.fill"
        case SearchEngine.bing.id: return "b.circle.fill"
        case SearchEngine.brave.id: return "flame.fill"
        default: return "magnifyingglass.circle.fill"
        }
    }

    private func makeHeaderView() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 150))

        let iconView = UIImageView(image: UIImage(systemName: "location.north.fill"))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = KiwiTheme.accentDeep
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 25, weight: .bold)
        iconView.backgroundColor = KiwiTheme.accent.withAlphaComponent(0.16)
        iconView.layer.cornerRadius = 20
        iconView.layer.cornerCurve = .continuous
        iconView.contentMode = .center

        let titleLabel = UILabel()
        titleLabel.text = "KiwiX"
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)

        let detailLabel = UILabel()
        detailLabel.text = "Fast, focused, and yours."
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel

        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.axis = .vertical
        labels.spacing = 3

        header.addSubview(iconView)
        header.addSubview(labels)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 58),
            iconView.heightAnchor.constraint(equalToConstant: 58),
            iconView.leadingAnchor.constraint(equalTo: header.layoutMarginsGuide.leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: header.layoutMarginsGuide.trailingAnchor),
            labels.centerYAnchor.constraint(equalTo: iconView.centerYAnchor)
        ])
        return header
    }

    private func presentInvalidTemplateAlert() {
        let alert = UIAlertController(
            title: "Invalid Template",
            message: "Enter an HTTPS or HTTP URL containing {query}.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func dismissSettings() {
        dismiss(animated: true)
    }
}
