import UIKit

@MainActor
final class BrowserStartPageView: UIView {
    var onSearch: (() -> Void)?
    var onPrivateTab: (() -> Void)?
    var onHistory: (() -> Void)?
    var onDownloads: (() -> Void)?
    var onExtensions: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let logoContainer = UIView()
    private let logoImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let searchButton = UIButton(type: .system)
    private let privacyPill = UILabel()
    private let privateButton = BrowserStartPageView.makeActionButton(
        title: "Private tab",
        subtitle: "Leave no history",
        imageName: "hand.raised.fill"
    )
    private let historyButton = BrowserStartPageView.makeActionButton(
        title: "History",
        subtitle: "Pick up where you left off",
        imageName: "clock.arrow.circlepath"
    )
    private let downloadsButton = BrowserStartPageView.makeActionButton(
        title: "Downloads",
        subtitle: "Files in one place",
        imageName: "arrow.down.circle.fill"
    )
    private let extensionsButton = BrowserStartPageView.makeActionButton(
        title: "Extensions",
        subtitle: "Make KiwiX yours",
        imageName: "puzzlepiece.extension.fill"
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = KiwiTheme.canvas
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(isPrivate: Bool, searchEngineName: String) {
        subtitleLabel.text = isPrivate
            ? "Private browsing is on. This tab won't be saved to history."
            : "A cleaner place to browse, search, and extend."
        privacyPill.text = isPrivate ? "  PRIVATE BROWSING  " : "  NO IN-APP ADS  "
        privacyPill.textColor = isPrivate ? KiwiTheme.privateAccent : KiwiTheme.accentDeep
        privacyPill.backgroundColor = (isPrivate ? KiwiTheme.privateAccent : KiwiTheme.accent)
            .withAlphaComponent(0.14)

        var configuration = searchButton.configuration ?? .filled()
        configuration.title = "Search with \(searchEngineName)"
        configuration.baseBackgroundColor = isPrivate ? KiwiTheme.privateAccent : KiwiTheme.elevatedSurface
        configuration.baseForegroundColor = isPrivate ? .white : .label
        searchButton.configuration = configuration
    }

    private func configureView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 18

        logoContainer.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.backgroundColor = KiwiTheme.accent.withAlphaComponent(0.16)
        logoContainer.layer.cornerRadius = 25
        logoContainer.layer.cornerCurve = .continuous
        logoContainer.layer.borderWidth = 1
        logoContainer.layer.borderColor = KiwiTheme.accent.withAlphaComponent(0.28).cgColor

        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.image = UIImage(systemName: "location.north.fill")
        logoImageView.tintColor = KiwiTheme.accentDeep
        logoImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)
        logoContainer.addSubview(logoImageView)

        titleLabel.text = "KiwiX"
        titleLabel.font = .systemFont(ofSize: 38, weight: .bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center

        privacyPill.font = .systemFont(ofSize: 11, weight: .bold)
        privacyPill.textAlignment = .center
        privacyPill.layer.cornerRadius = 11
        privacyPill.layer.cornerCurve = .continuous
        privacyPill.clipsToBounds = true
        privacyPill.setContentHuggingPriority(.required, for: .horizontal)

        var searchConfiguration = UIButton.Configuration.filled()
        searchConfiguration.image = UIImage(systemName: "magnifyingglass")
        searchConfiguration.imagePadding = 10
        searchConfiguration.cornerStyle = .large
        searchConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18)
        searchConfiguration.baseBackgroundColor = KiwiTheme.elevatedSurface
        searchConfiguration.baseForegroundColor = .label
        searchButton.configuration = searchConfiguration
        searchButton.contentHorizontalAlignment = .leading
        searchButton.layer.shadowColor = UIColor.black.cgColor
        searchButton.layer.shadowOpacity = 0.08
        searchButton.layer.shadowRadius = 18
        searchButton.layer.shadowOffset = CGSize(width: 0, height: 7)
        searchButton.accessibilityHint = "Focuses the address and search field"
        searchButton.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .touchUpInside)

        privateButton.addAction(UIAction { [weak self] _ in self?.onPrivateTab?() }, for: .touchUpInside)
        historyButton.addAction(UIAction { [weak self] _ in self?.onHistory?() }, for: .touchUpInside)
        downloadsButton.addAction(UIAction { [weak self] _ in self?.onDownloads?() }, for: .touchUpInside)
        extensionsButton.addAction(UIAction { [weak self] _ in self?.onExtensions?() }, for: .touchUpInside)

        let brandStack = UIStackView(arrangedSubviews: [logoContainer, titleLabel, subtitleLabel, privacyPill])
        brandStack.axis = .vertical
        brandStack.alignment = .center
        brandStack.spacing = 9
        brandStack.setCustomSpacing(13, after: logoContainer)

        let firstRow = UIStackView(arrangedSubviews: [privateButton, historyButton])
        let secondRow = UIStackView(arrangedSubviews: [downloadsButton, extensionsButton])
        for row in [firstRow, secondRow] {
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 12
        }

        let actionsStack = UIStackView(arrangedSubviews: [firstRow, secondRow])
        actionsStack.axis = .vertical
        actionsStack.spacing = 12

        let sectionLabel = UILabel()
        sectionLabel.text = "QUICK ACTIONS"
        sectionLabel.font = .systemFont(ofSize: 12, weight: .bold)
        sectionLabel.textColor = .secondaryLabel

        contentStack.addArrangedSubview(brandStack)
        contentStack.setCustomSpacing(28, after: brandStack)
        contentStack.addArrangedSubview(searchButton)
        contentStack.setCustomSpacing(28, after: searchButton)
        contentStack.addArrangedSubview(sectionLabel)
        contentStack.setCustomSpacing(10, after: sectionLabel)
        contentStack.addArrangedSubview(actionsStack)

        addSubview(scrollView)
        scrollView.addSubview(contentStack)

        let preferredContentWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -44
        )
        preferredContentWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 42),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 22),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -22),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -34),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            preferredContentWidth,

            logoContainer.widthAnchor.constraint(equalToConstant: 72),
            logoContainer.heightAnchor.constraint(equalToConstant: 72),
            logoImageView.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            logoImageView.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),
            searchButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            privateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
            historyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
            downloadsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
            extensionsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 88)
        ])
    }

    private static func makeActionButton(title: String, subtitle: String, imageName: String) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.image = UIImage(systemName: imageName)
        configuration.imagePlacement = .top
        configuration.imagePadding = 8
        configuration.titleAlignment = .center
        configuration.cornerStyle = .large
        configuration.baseForegroundColor = KiwiTheme.accentDeep
        configuration.baseBackgroundColor = KiwiTheme.accent.withAlphaComponent(0.14)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
        button.configuration = configuration
        return button
    }
}
