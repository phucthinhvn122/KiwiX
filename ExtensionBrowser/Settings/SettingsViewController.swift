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
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissSettings)
        )
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? SearchEngine.builtInEngines.count : settingsStore.customSearchEngines.count + 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Search Engine" : "Custom Search Engines"
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)

        if indexPath.section == 1, indexPath.row == settingsStore.customSearchEngines.count {
            var content = cell.defaultContentConfiguration()
            content.text = "Add Custom Engine"
            content.image = UIImage(systemName: "plus.circle")
            content.imageProperties.tintColor = .systemBlue
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        }

        let engine = engine(at: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = engine.name
        content.secondaryText = engine.queryURLTemplate
        content.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.accessoryType = settingsStore.selectedSearchEngine.id == engine.id ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
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
