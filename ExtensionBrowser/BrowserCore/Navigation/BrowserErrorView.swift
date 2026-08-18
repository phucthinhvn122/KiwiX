import UIKit

@MainActor
final class BrowserErrorView: UIView {
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var retryHandler: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = KiwiTheme.canvas
        isHidden = true

        let icon = UIImageView(image: UIImage(systemName: "wifi.exclamationmark"))
        icon.tintColor = KiwiTheme.accentDeep
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .medium)

        titleLabel.text = "Page Not Available"
        titleLabel.font = UIFontMetrics(forTextStyle: .title1).scaledFont(
            for: .systemFont(ofSize: 27, weight: .bold)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Try Again"
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.imagePadding = 7
        configuration.baseBackgroundColor = KiwiTheme.accentDeep
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        retryButton.configuration = configuration
        retryButton.addAction(UIAction { [weak self] _ in self?.retryHandler?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, messageLabel, retryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 13
        stack.setCustomSpacing(20, after: messageLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(message: String, retry: @escaping () -> Void) {
        messageLabel.text = message
        retryHandler = retry
        isHidden = false
        accessibilityViewIsModal = true
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    func hide() {
        isHidden = true
        retryHandler = nil
        accessibilityViewIsModal = false
    }
}
