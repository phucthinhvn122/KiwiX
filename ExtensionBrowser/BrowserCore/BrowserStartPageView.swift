import UIKit

@MainActor
final class BrowserStartPageView: UIView {
    var onPrivateTab: (() -> Void)?
    var onHistory: (() -> Void)?
    var onDownloads: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentContainer = UIView()
    private let contentStack = UIStackView()
    private let logoContainer = UIView()
    private let logoImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let privateButton = BrowserStartPageView.makeActionButton(title: "Private", imageName: "hand.raised.fill")
    private let historyButton = BrowserStartPageView.makeActionButton(title: "History", imageName: "clock.arrow.circlepath")
    private let downloadsButton = BrowserStartPageView.makeActionButton(title: "Downloads", imageName: "arrow.down.circle.fill")

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
            ? "Use the address bar below for private browsing."
            : "Search \(searchEngineName) or enter a website below."

        logoContainer.backgroundColor = (isPrivate ? KiwiTheme.privateAccent : KiwiTheme.accent)
            .withAlphaComponent(0.15)
        logoImageView.tintColor = isPrivate ? KiwiTheme.privateAccent : KiwiTheme.accentDeep
    }

    private func configureView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.contentInsetAdjustmentBehavior = .never

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
        titleLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
            for: .systemFont(ofSize: 34, weight: .bold)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.textAlignment = .center

        privateButton.addAction(UIAction { [weak self] _ in self?.onPrivateTab?() }, for: .touchUpInside)
        historyButton.addAction(UIAction { [weak self] _ in self?.onHistory?() }, for: .touchUpInside)
        downloadsButton.addAction(UIAction { [weak self] _ in self?.onDownloads?() }, for: .touchUpInside)

        let brandStack = UIStackView(arrangedSubviews: [logoContainer, titleLabel, subtitleLabel])
        brandStack.axis = .vertical
        brandStack.alignment = .center
        brandStack.spacing = 8
        brandStack.setCustomSpacing(12, after: logoContainer)

        let firstRow = UIStackView(arrangedSubviews: [privateButton, historyButton])
        let secondRow = UIStackView(arrangedSubviews: [downloadsButton])
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
        contentStack.addArrangedSubview(actionsStack)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        scrollView.addSubview(contentContainer)
        contentContainer.addSubview(contentStack)

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

            contentContainer.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentContainer.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentContainer.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

            contentStack.topAnchor.constraint(greaterThanOrEqualTo: contentContainer.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -18),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 540),
            contentStack.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor, constant: -8),
            preferredContentWidth,

            logoContainer.widthAnchor.constraint(equalToConstant: 64),
            logoContainer.heightAnchor.constraint(equalToConstant: 64),
            logoImageView.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            logoImageView.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),
            privateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            historyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            downloadsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 72)
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
            outgoing.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .systemFont(ofSize: 14, weight: .semibold)
            )
            return outgoing
        }
        button.configuration = configuration
        return button
    }
}
