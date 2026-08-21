import UIKit
import UniformTypeIdentifiers

/// What is installed, and the way in.
///
/// Import is deliberately the only source: there is no store, no URL field, no auto-update. A file
/// the user chose from Files is a file the user can point at afterwards, which is the whole trust
/// model on a browser that runs third-party code.
@MainActor
final class ExtensionsViewController: UITableViewController, UIDocumentPickerDelegate {
    private let coordinator: ExtensionInstallCoordinator
    private var records: [InstalledExtensionRecord] = []
    private var isBusy = false {
        didSet { navigationItem.rightBarButtonItem?.isEnabled = !isBusy }
    }
    /// A file handed over by another app. Held until the view is on screen, because the permission
    /// sheet has to be presented from a view controller the window is actually showing.
    private var pendingImportURL: URL?
    /// Staging directory of the package currently waiting on the consent sheet, if any.
    ///
    /// A `PreparedExtensionInstall` owns an unpacked directory until somebody answers for it, and
    /// the answer normally comes from one of the sheet's two buttons. It does not always come:
    /// `BrowserViewController.presentExtensions(importing:)` dismisses whatever is on screen when
    /// another app hands KiwiX a package, and that can be this controller with the sheet still up.
    /// The decision handler is released without running and nobody is left to call `cancel`.
    private var unansweredStagingRoot: URL?

    init(coordinator: ExtensionInstallCoordinator) {
        self.coordinator = coordinator
        super.init(style: .insetGrouped)
        title = "Extensions"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Last owner of an unanswered staging directory.
    ///
    /// Being dismissed out from under the consent sheet is the case this covers; by then nothing
    /// else retains this controller, so deallocation is the last moment the directory has an owner.
    /// `FileManager` directly rather than `coordinator.cancel`: a `deinit` cannot hop to the main
    /// actor, and the whole operation is one `removeItem` on a path this object produced.
    deinit {
        guard let unansweredStagingRoot else { return }
        try? FileManager.default.removeItem(at: unansweredStagingRoot)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = KiwiTheme.canvas
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(close)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(importPackage)
        )

        coordinator.onRecordsChanged = { [weak self] records in
            guard let self else { return }
            self.records = records
            self.tableView.reloadData()
            self.updateEmptyState()
        }
        records = coordinator.records
        tableView.reloadData()
        updateEmptyState()

        Task { [weak self] in
            await self?.coordinator.reload()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let url = pendingImportURL else { return }
        pendingImportURL = nil
        beginImport(fileURL: url)
    }

    // MARK: - Import

    /// Entry point for a file another app opened in KiwiX. Same flow as the picker: read, show what
    /// it wants, install only on a yes.
    func importOnAppearance(fileURL: URL) {
        pendingImportURL = fileURL
    }

    @objc private func importPackage() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: Self.packageContentTypes,
            // A copy: the app never needs the original, and copying sidesteps security-scoped
            // access on a file that is about to be unzipped anyway.
            asCopy: true
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        beginImport(fileURL: url)
    }

    private func beginImport(fileURL: URL) {
        guard !isBusy else { return }
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                let prepared = try await self.coordinator.prepare(fileURL: fileURL)
                self.presentPermissionSheet(for: prepared)
            } catch {
                self.showError(
                    SafeInput.userFacingError(error, fallback: "That file could not be read as an extension.")
                )
            }
            // Both entry points hand over a copy the system made for us — the picker's because of
            // `asCopy`, an opened document's because it lands in the app inbox. Staging has read it
            // by now, so the copy is dead weight either way.
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func presentPermissionSheet(for prepared: PreparedExtensionInstall) {
        // Handed to `deinit` in case the sheet never gets an answer; see `unansweredStagingRoot`.
        unansweredStagingRoot = prepared.staged.stagingRoot

        let sheet = ExtensionPermissionSheetViewController(
            summary: prepared.summary,
            requiresExplicitTrust: prepared.requiresExplicitTrust,
            publisherIdentifier: prepared.publisherIdentifier
        ) { [weak self] shouldInstall in
            guard let self else { return }
            // Answered: whichever way this goes, `install` or `cancel` owns the directory now.
            self.unansweredStagingRoot = nil
            // Installing after the dismissal completes, not alongside it: `showError` refuses to
            // stack on top of another presentation, so an error raised mid-animation would vanish.
            self.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                guard shouldInstall else {
                    self.coordinator.cancel(prepared)
                    return
                }
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.coordinator.install(prepared)
                    } catch {
                        self.showError(
                            SafeInput.userFacingError(error, fallback: "That extension could not be installed.")
                        )
                    }
                }
            }
        }

        let navigation = UINavigationController(rootViewController: sheet)
        navigation.modalPresentationStyle = .formSheet
        // Set on the presented controller, which is the navigation controller: a swipe-away is not
        // an answer, and the staging directory has an owner until one of the buttons is pressed.
        navigation.isModalInPresentation = true
        present(navigation, animated: true)
    }

    private static var packageContentTypes: [UTType] {
        var types: [UTType] = []
        for identifier in ["com.extensionbrowser.web-extension", "com.extensionbrowser.crx-extension"] {
            if let declared = UTType(identifier) {
                types.append(declared)
            }
        }
        // A .zip produced by another app is typed as the system archive type, which does not
        // conform to ours, so it has to be listed too or the picker greys it out.
        types.append(.zip)
        return types
    }

    // MARK: - Table view

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        records.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let record = records[indexPath.row]

        var content = UIListContentConfiguration.subtitleCell()
        content.text = record.displayName
        content.secondaryText = subtitle(for: record)
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(systemName: "puzzlepiece.extension.fill")
        content.imageProperties.tintColor = record.isEnabled ? KiwiTheme.accentDeep : .tertiaryLabel
        cell.contentConfiguration = content
        cell.backgroundColor = KiwiTheme.elevatedSurface
        cell.selectionStyle = .none

        // Rebuilt per row rather than reused: the action captures this record's identifier, and a
        // recycled switch would carry the previous row's closure.
        let toggle = UISwitch()
        toggle.isOn = record.isEnabled
        toggle.onTintColor = KiwiTheme.accent
        let identifier = record.identifier
        toggle.addAction(
            UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                self.setEnabled(toggle.isOn, for: identifier, revertOnFailure: toggle)
            },
            for: .valueChanged
        )
        cell.accessoryView = toggle

        return cell
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.row < records.count else { return nil }
        let record = records[indexPath.row]
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            self.confirmRemoval(of: record, completion: completion)
        }
        remove.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [remove])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    // MARK: - Actions

    private func setEnabled(_ isEnabled: Bool, for identifier: String, revertOnFailure toggle: UISwitch) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.setEnabled(isEnabled, for: identifier)
            } catch {
                toggle.setOn(!isEnabled, animated: true)
                self.showError(SafeInput.userFacingError(error, fallback: "That extension could not be updated."))
            }
        }
    }

    private func confirmRemoval(of record: InstalledExtensionRecord, completion: @escaping (Bool) -> Void) {
        guard presentedViewController == nil else {
            completion(false)
            return
        }
        let alert = UIAlertController(
            title: "Remove \"\(record.displayName)\"?",
            message: "Its files and the permissions you granted are deleted. You can add the package again later.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        alert.addAction(
            UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
                guard let self else {
                    completion(false)
                    return
                }
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.coordinator.remove(identifier: record.identifier)
                        completion(true)
                    } catch {
                        completion(false)
                        self.showError(SafeInput.userFacingError(error, fallback: "That extension could not be removed."))
                    }
                }
            }
        )
        present(alert, animated: true)
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: - Presentation helpers

    private func subtitle(for record: InstalledExtensionRecord) -> String {
        var parts: [String] = [record.isSignatureVerified ? "Signed" : "Unsigned"]
        parts.append(record.grantedPermissions.count == 1 ? "1 permission" : "\(record.grantedPermissions.count) permissions")
        if !record.grantedMatchPatterns.isEmpty {
            parts.append(record.grantedMatchPatterns.count == 1 ? "1 site rule" : "\(record.grantedMatchPatterns.count) site rules")
        }
        if !record.isEnabled {
            parts.append("Off")
        }
        return parts.joined(separator: " · ")
    }

    private func updateEmptyState() {
        guard records.isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        contentUnavailableConfiguration = KiwiTheme.emptyConfiguration(
            title: "No Extensions",
            message: "Add a .crx or .zip package from Files. KiwiX shows you what it asks for before anything is installed.",
            systemImage: "puzzlepiece.extension"
        )
    }

    private func showError(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Extensions", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
