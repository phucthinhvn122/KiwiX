import UIKit

enum KiwiTheme {
    static let accent = UIColor(
        red: 0.48,
        green: 0.82,
        blue: 0.16,
        alpha: 1
    )
    static let accentDeep = UIColor(
        red: 0.20,
        green: 0.54,
        blue: 0.12,
        alpha: 1
    )
    static let cyan = UIColor(
        red: 0.18,
        green: 0.78,
        blue: 0.86,
        alpha: 1
    )
    static let privateAccent = UIColor(
        red: 0.56,
        green: 0.38,
        blue: 0.92,
        alpha: 1
    )

    static let canvas = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.025, green: 0.055, blue: 0.10, alpha: 1)
            : UIColor(red: 0.955, green: 0.975, blue: 0.965, alpha: 1)
    }

    static let elevatedSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.105, blue: 0.15, alpha: 1)
            : .white
    }

    static let fieldSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.09)
            : UIColor(red: 0.92, green: 0.945, blue: 0.93, alpha: 1)
    }

    static func applyGlobalAppearance() {
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = canvas
        navigationAppearance.shadowColor = .clear
        navigationAppearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navigationAppearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor.label,
            .font: UIFont.systemFont(ofSize: 34, weight: .bold)
        ]

        UINavigationBar.appearance().standardAppearance = navigationAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
        UINavigationBar.appearance().compactAppearance = navigationAppearance
        UITableView.appearance().backgroundColor = canvas
    }

    static func emptyConfiguration(
        title: String,
        message: String,
        systemImage: String
    ) -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: systemImage)
        configuration.imageProperties.tintColor = accentDeep
        configuration.text = title
        configuration.textProperties.font = .preferredFont(forTextStyle: .title3)
        configuration.secondaryText = message
        configuration.secondaryTextProperties.color = .secondaryLabel
        return configuration
    }
}
