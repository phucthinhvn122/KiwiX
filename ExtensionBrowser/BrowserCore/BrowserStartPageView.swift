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
    private let privateButton = BrowserStartPageView.makeActionButton(title: "Private", imageName: "hand.raised.fill")
    private let historyButton = BrowserStartPageView.makeActionButton(title: "History", imageName: "clock.arrow.circlepath")
    private let downloadsButton = BrowserStartPageView.makeActionButton(title: "Downloads", imageName: "arrow.down.circle.fill")
    private let extensionsButton = BrowserStartPageView.makeActionButton(title: "Extensions", imageName: "puzzlepiece.extension.fill")

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
            ? "Pages in this tab won't appear in history."
            : "Fast browsing with Google search."

        var configuration = searchButton.configuration ?? .filled()
        configuration.title = isPrivate
            ? "Private search or type a URL"
            : "Search \(searchEngineName) or type a URL"
        configuration.baseForegroundColor = .label
        searchButton.configuration = configuration

        logoContainer.backgroundColor = (isPrivate ? KiwiTheme.privateAccent : KiwiTheme.accent)
            .withAlphaComponent(0.15)
        logoImageView.tintColor = isPrivate ? KiwiTheme.privateAccent : KiwiTheme.accentDeep
    }

    private func configureView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 16

        logoContainer.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.backgroundColor = KiwiTheme.accent.withAlphaComponent(0.15)
        logoContainer.layer.cornerRadius = 22
        logoContainer.layer.cornerCurve = .continuous

        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.image = UIImage(systemName: "location.north.fill")
        logoImageView.tintColor = KiwiTheme.accentDeep
        logoImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 27, weight: .bold)
        logoContainer.addSubview(logoImageView)

        titleLabel.text = "KiwiX"
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        subtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.textAlignment = .center

        var searchConfiguration = UIButton.Configuration.filled()
        searchConfiguration.image = UIImage(systemName: "magnifyingglass")
        searchConfiguration.imagePadding = 12
        searchConfiguration.cornerStyle = .capsule
        searchConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
        searchConfiguration.baseBackgroundColor = KiwiTheme.elevatedSurface
        searchConfiguration.baseForegroundColor = .label
        searchButton.configuration = searchConfiguration
        searchButton.contentHorizontalAlignment = .leading
        searchButton.layer.shadowColor = UIColor.black.cgColor
        searchButton.layer.shadowOpacity = 0.08
        searchButton.layer.shadowRadius = 12
        searchButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        searchButton.accessibilityHint = "Focuses the address and search field"
        searchButton.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .touchUpInside)

        privateButton.addAction(UIAction { [weak self] _ in self?.onPrivateTab?() }, for: .touchUpInside)
        historyButton.addAction(UIAction { [weak self] _ in self?.onHistory?() }, for: .touchUpInside)
        downloadsButton.addAction(UIAction { [weak self] _ in self?.onDownloads?() }, for: .touchUpInside)
        extensionsButton.addAction(UIAction { [weak self] _ in self?.onExtensions?() }, for: .touchUpInside)

        let brandStack = UIStackView(arrangedSubviews: [logoContainer, titleLabel, subtitleLabel])
        brandStack.axis = .vertical
        brandStack.alignment = .center
        brandStack.spacing = 8
        brandStack.setCustomSpacing(12, after: logoContainer)

        let firstRow = UIStackView(arrangedSubviews: [privateButton, historyButton])
        let secondRow = UIStackView(arrangedSubviews: [downloadsButton, extensionsButton])
        for row in [firstRow, secondRow] {
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 10
        }

        let actionsStack = UIStackView(arrangedSubviews: [firstRow, secondRow])
        actionsStack.axis = .vertical
        actionsStack.spacing = 10

        contentStack.addArrangedSubview(brandStack)
        contentStack.setCustomSpacing(24, after: brandStack)
        contentStack.addArrangedSubview(searchButton)
        contentStack.setCustomSpacing(20, after: searchButton)
        contentStack.addArrangedSubview(actionsStack)

        addSubview(scrollView)
        scrollView.addSubview(contentStack)

        let preferredContentWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -36
        )
        preferredContentWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 28),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -18),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 540),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            preferredContentWidth,

            logoContainer.widthAnchor.constraint(equalToConstant: 64),
            logoContainer.heightAnchor.constraint(equalToConstant: 64),
            logoImageView.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            logoImageView.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),
            searchButton.heightAnchor.constraint(equalToConstant: 54),
            privateButton.heightAnchor.constraint(equalToConstant: 72),
            historyButton.heightAnchor.constraint(equalToConstant: 72),
            downloadsButton.heightAnchor.constraint(equalToConstant: 72),
            extensionsButton.heightAnchor.constraint(equalToConstant: 72)
        ])
    }

    private static func makeActionButton(title: String, imageName: String) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: imageName)
        configuration.imagePlacement = .leading
        configuration.imagePadding = 8
        configuration.titleAlignment = .center
        configuration.cornerStyle = .large
        configuration.baseForegroundColor = KiwiTheme.accentDeep
        configuration.baseBackgroundColor = KiwiTheme.accent.withAlphaComponent(0.11)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 14, weight: .semibold)
            return outgoing
        }
        button.configuration = configuration
        return button
    }
}
