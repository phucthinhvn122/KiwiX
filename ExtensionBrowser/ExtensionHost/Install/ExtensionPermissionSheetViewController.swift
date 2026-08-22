import UIKit

/// The consent screen. Spec §7: nothing installs until the user has seen what it asks for.
///
/// Three things get emphasis rather than being buried in a list, because they are the three ways an
/// install goes wrong: access to every site, a package nobody signed, and a name dressed up to look
/// like something else. Everything else is a plain row.
@MainActor
final class ExtensionPermissionSheetViewController: UITableViewController {
    private enum Row {
        case header(title: String, subtitle: String?)
        case warning(text: String, isBold: Bool)
        case value(text: String, systemImage: String)
        case note(String)
    }

    private struct Section {
        let title: String?
        let footer: String?
        let rows: [Row]
    }

    private let summary: ExtensionPermissionSummary
    private let requiresExplicitTrust: Bool
    private let publisherIdentifier: String?
    private let onDecision: (Bool) -> Void

    private var sections: [Section] = []
    private var hasDecided = false

    init(
        summary: ExtensionPermissionSummary,
        requiresExplicitTrust: Bool,
        publisherIdentifier: String?,
        onDecision: @escaping (Bool) -> Void
    ) {
        self.summary = summary
        self.requiresExplicitTrust = requiresExplicitTrust
        self.publisherIdentifier = publisherIdentifier
        self.onDecision = onDecision
        super.init(style: .insetGrouped)
        title = "Add Extension"
        // The sheet is a decision, not a browse: swiping it away would be an answer the user did
        // not knowingly give, so the only ways out are the two buttons.
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = KiwiTheme.canvas
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Add",
            style: .done,
            target: self,
            action: #selector(confirm)
        )
        sections = makeSections()
    }

    // MARK: - Content

    private func makeSections() -> [Section] {
        var sections: [Section] = []

        sections.append(
            Section(
                title: nil,
                footer: nil,
                rows: [.header(title: summary.displayName, subtitle: summary.version.map { "Version \($0)" })]
            )
        )

        var warnings: [Row] = []
        if summary.requestsAllURLs {
            warnings.append(
                .warning(
                    text: "Can read and change everything you do on every website, including passwords and payment details.",
                    isBold: true
                )
            )
        }
        if requiresExplicitTrust {
            warnings.append(
                .warning(
                    text: "This package has no signature KiwiX can check. Nothing proves who built it or that it has not been altered since.",
                    isBold: false
                )
            )
        }
        if summary.hasUnsafeDisplayName {
            warnings.append(
                .warning(
                    text: "The name in this package contains hidden characters. It may be dressed up to look like a different extension.",
                    isBold: false
                )
            )
        }
        // Said before the install, not discovered after it. An extension whose whole purpose is
        // blocking requests installs cleanly here and then does nothing, because the platform takes
        // the rules and ignores them — measured on every CI run, see R-21. Without this the user
        // has a switch that is on, an extension that looks installed, and no explanation.
        if !summary.inertPermissions.isEmpty {
            warnings.append(
                .warning(
                    text: "This extension asks to block or inspect network requests (\(summary.inertPermissions.joined(separator: ", "))). "
                        + "KiwiX accepts the request and the system does not act on it, so that part will not work. "
                        + "If blocking is the whole point of this extension, it will do nothing.",
                    isBold: true
                )
            )
        }
        if !warnings.isEmpty {
            sections.append(Section(title: "Before you add this", footer: nil, rows: warnings))
        }

        sections.append(
            Section(
                title: "Permissions",
                footer: nil,
                rows: summary.permissions.isEmpty
                    ? [.note("None requested.")]
                    : summary.permissions.map { .value(text: $0, systemImage: "key.fill") }
            )
        )

        sections.append(
            Section(
                title: "Site access",
                footer: summary.matchPatterns.isEmpty
                    ? nil
                    : "The extension runs on these sites and can read their contents.",
                rows: summary.matchPatterns.isEmpty
                    ? [.note("No sites requested.")]
                    : summary.matchPatterns.map { .value(text: $0, systemImage: "globe") }
            )
        )

        let optional = summary.optionalPermissions + summary.optionalMatchPatterns
        if !optional.isEmpty {
            sections.append(
                Section(
                    title: "Optional — not granted",
                    // Honest about what the runtime does: `.userGranted` marks anything outside the
                    // granted set as denied, and the host answers runtime prompts with nothing. The
                    // extension may ask; it will not get these.
                    footer: "KiwiX denies these. If the extension asks for them while running, the request is refused.",
                    rows: optional.map { .value(text: $0, systemImage: "lock.fill") }
                )
            )
        }

        sections.append(
            Section(
                title: "Package",
                footer: nil,
                rows: [
                    publisherIdentifier.map {
                        Row.value(text: "Signed by \($0)", systemImage: "checkmark.seal.fill")
                    } ?? Row.value(text: "Unsigned package", systemImage: "exclamationmark.triangle.fill")
                ]
            )
        )

        return sections
    }

    // MARK: - Decision

    @objc private func cancel() {
        finish(install: false)
    }

    @objc private func confirm() {
        guard requiresExplicitTrust else {
            finish(install: true)
            return
        }

        // §7: an unverifiable signature is never installed silently. The banner above is the first
        // step; this is the second, and its default action is the safe one.
        let alert = UIAlertController(
            title: "Add an unsigned extension?",
            message: "KiwiX cannot tell who made \"\(summary.displayName)\" or whether it was changed after it was built. It will be able to use everything listed on the previous screen.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "Add Anyway", style: .destructive) { [weak self] _ in
                self?.finish(install: true)
            }
        )
        present(alert, animated: true)
    }

    private func finish(install: Bool) {
        // Double-tap on Add while the alert animates in must not install twice.
        guard !hasDecided else { return }
        hasDecided = true
        onDecision(install)
    }

    // MARK: - Table view

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = KiwiTheme.elevatedSurface

        switch sections[indexPath.section].rows[indexPath.row] {
        case .header(let title, let subtitle):
            var content = UIListContentConfiguration.subtitleCell()
            content.text = title
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryText = subtitle
            content.image = UIImage(systemName: "puzzlepiece.extension.fill")
            content.imageProperties.tintColor = KiwiTheme.accentDeep
            cell.contentConfiguration = content

        case .warning(let text, let isBold):
            var content = UIListContentConfiguration.cell()
            content.text = text
            content.textProperties.numberOfLines = 0
            content.textProperties.color = .systemRed
            content.textProperties.font = isBold
                ? .preferredFont(forTextStyle: .headline)
                : .preferredFont(forTextStyle: .footnote)
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemRed
            cell.contentConfiguration = content

        case .value(let text, let systemImage):
            var content = UIListContentConfiguration.cell()
            content.text = text
            content.textProperties.numberOfLines = 0
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.image = UIImage(systemName: systemImage)
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content

        case .note(let text):
            var content = UIListContentConfiguration.cell()
            content.text = text
            content.textProperties.color = .secondaryLabel
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            cell.contentConfiguration = content
        }

        return cell
    }
}
