import UIKit

@MainActor
protocol TabSwitcherViewControllerDelegate: AnyObject {
    func tabSwitcher(_ controller: TabSwitcherViewController, didSelectTab id: UUID)
    func tabSwitcher(_ controller: TabSwitcherViewController, didCloseTab id: UUID)
    func tabSwitcher(_ controller: TabSwitcherViewController, createPrivateTab: Bool)
}

@MainActor
final class TabSwitcherViewController: UIViewController {
    struct Item {
        let id: UUID
        let title: String
        let urlText: String
        let isPrivate: Bool
        let lifecycleState: TabLifecycleState
        let snapshot: UIImage?
        let favicon: UIImage?
    }

    weak var delegate: TabSwitcherViewControllerDelegate?
    private var items: [Item]
    private let selectedTabID: UUID?
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())

    init(items: [Item], selectedTabID: UUID?) {
        self.items = items
        self.selectedTabID = selectedTabID
        super.init(nibName: nil, bundle: nil)
        title = "Open Tabs"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = KiwiTheme.canvas
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.prompt = tabCountText

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TabCardCell.self, forCellWithReuseIdentifier: TabCardCell.reuseIdentifier)
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(dismissSwitcher)
        )
        let newTab = UIAction(title: "New Tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in
            guard let self else { return }
            self.delegate?.tabSwitcher(self, createPrivateTab: false)
        }
        let newPrivateTab = UIAction(
            title: "New Private Tab",
            image: UIImage(systemName: "hand.raised.fill")
        ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.tabSwitcher(self, createPrivateTab: true)
        }
        let addButton = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: UIMenu(children: [
            newTab,
            newPrivateTab
        ]))
        addButton.accessibilityLabel = "Create tab"
        navigationItem.rightBarButtonItem = addButton
    }

    func removeItem(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        collectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
        navigationItem.prompt = tabCountText
    }

    private var tabCountText: String {
        "\(items.count) \(items.count == 1 ? "tab" : "tabs")"
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let availableWidth = environment.container.effectiveContentSize.width
            let columnCount = availableWidth >= 760 ? 3 : (availableWidth >= 500 ? 2 : 1)
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0 / CGFloat(columnCount)),
                heightDimension: .estimated(268)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            item.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 7, bottom: 7, trailing: 7)

            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(268)
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: groupSize,
                repeatingSubitem: item,
                count: columnCount
            )
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 32, trailing: 10)
            return section
        }
    }

    @objc private func dismissSwitcher() {
        dismiss(animated: true)
    }
}

extension TabSwitcherViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TabCardCell.reuseIdentifier,
            for: indexPath
        ) as? TabCardCell else {
            return UICollectionViewCell()
        }
        let item = items[indexPath.item]
        cell.configure(item: item, isSelectedTab: item.id == selectedTabID)
        cell.onClose = { [weak self] in
            guard let self else { return }
            self.delegate?.tabSwitcher(self, didCloseTab: item.id)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        delegate?.tabSwitcher(self, didSelectTab: items[indexPath.item].id)
    }
}

@MainActor
private final class TabCardCell: UICollectionViewCell {
    static let reuseIdentifier = "TabCardCell"

    var onClose: (() -> Void)?

    private let snapshotView = UIImageView()
    private let faviconView = UIImageView()
    private let titleLabel = UILabel()
    private let urlLabel = UILabel()
    private let stateLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = KiwiTheme.elevatedSurface
        contentView.layer.cornerRadius = 20
        contentView.layer.cornerCurve = .continuous
        contentView.layer.masksToBounds = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 5)

        snapshotView.translatesAutoresizingMaskIntoConstraints = false
        snapshotView.backgroundColor = KiwiTheme.fieldSurface
        snapshotView.contentMode = .scaleAspectFit
        snapshotView.clipsToBounds = true
        snapshotView.image = UIImage(systemName: "globe")
        snapshotView.tintColor = .tertiaryLabel

        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 16, weight: .semibold)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2

        faviconView.contentMode = .scaleAspectFit
        faviconView.tintColor = .secondaryLabel
        faviconView.setContentHuggingPriority(.required, for: .horizontal)
        faviconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            faviconView.widthAnchor.constraint(equalToConstant: 20),
            faviconView.heightAnchor.constraint(equalToConstant: 20)
        ])

        urlLabel.font = .preferredFont(forTextStyle: .caption1)
        urlLabel.adjustsFontForContentSizeCategory = true
        urlLabel.textColor = .secondaryLabel
        urlLabel.numberOfLines = 1

        stateLabel.font = .preferredFont(forTextStyle: .caption2)
        stateLabel.adjustsFontForContentSizeCategory = true
        stateLabel.textColor = KiwiTheme.accentDeep

        var closeConfiguration = UIButton.Configuration.tinted()
        closeConfiguration.image = UIImage(systemName: "xmark")
        closeConfiguration.cornerStyle = .capsule
        closeConfiguration.baseForegroundColor = .secondaryLabel
        closeConfiguration.baseBackgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.12)
        closeConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        closeButton.configuration = closeConfiguration
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityLabel = "Close tab"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])

        let titleRow = UIStackView(arrangedSubviews: [faviconView, titleLabel, closeButton])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 6
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let stateSpacer = UIView()
        let stateRow = UIStackView(arrangedSubviews: [stateLabel, stateSpacer])
        stateRow.axis = .horizontal
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)

        let details = UIStackView(arrangedSubviews: [titleRow, urlLabel, stateRow])
        details.translatesAutoresizingMaskIntoConstraints = false
        details.axis = .vertical
        details.spacing = 3

        contentView.addSubview(snapshotView)
        contentView.addSubview(details)
        NSLayoutConstraint.activate([
            snapshotView.topAnchor.constraint(equalTo: contentView.topAnchor),
            snapshotView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            snapshotView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            snapshotView.heightAnchor.constraint(equalTo: snapshotView.widthAnchor, multiplier: 0.92),

            details.topAnchor.constraint(equalTo: snapshotView.bottomAnchor, constant: 12),
            details.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 13),
            details.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            details.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -13)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onClose = nil
        snapshotView.image = UIImage(systemName: "globe")
        faviconView.image = UIImage(systemName: "globe")
        contentView.layer.borderWidth = 0
    }

    func configure(item: TabSwitcherViewController.Item, isSelectedTab: Bool) {
        snapshotView.image = item.snapshot ?? UIImage(systemName: item.isPrivate ? "hand.raised.fill" : "safari.fill")
        snapshotView.contentMode = item.snapshot == nil ? .scaleAspectFit : .scaleAspectFill
        faviconView.image = item.favicon ?? UIImage(systemName: item.isPrivate ? "hand.raised.fill" : "globe")
        titleLabel.text = item.title
        urlLabel.text = item.urlText
        stateLabel.text = statusText(for: item, isSelectedTab: isSelectedTab)
        stateLabel.textColor = item.isPrivate ? KiwiTheme.privateAccent : KiwiTheme.accentDeep
        contentView.layer.borderColor = (item.isPrivate ? KiwiTheme.privateAccent : KiwiTheme.accentDeep).cgColor
        contentView.layer.borderWidth = isSelectedTab ? 2 : 0
        closeButton.accessibilityLabel = "Close \(SafeInput.displayText(item.title, maximumByteCount: 256)) tab"
        accessibilityLabel = "\(titleLabel.text ?? "Tab"), \(urlLabel.text ?? "")"
        accessibilityValue = statusText(for: item, isSelectedTab: isSelectedTab)
    }

    private func statusText(
        for item: TabSwitcherViewController.Item,
        isSelectedTab: Bool
    ) -> String {
        var parts: [String] = []
        if item.isPrivate { parts.append("Private") }
        if isSelectedTab {
            parts.append("Current")
        } else {
            switch item.lifecycleState {
            case .active: parts.append("Active")
            case .warm: parts.append("Ready")
            case .suspended: parts.append("Sleeping")
            }
        }
        return parts.joined(separator: "  •  ")
    }
}
