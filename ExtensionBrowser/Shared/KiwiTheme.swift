import UIKit

enum KiwiTheme {
    static let accent = UIColor(
        red: 0.26,
        green: 0.52,
        blue: 0.96,
        alpha: 1
    )
    static let accentDeep = UIColor(
        red: 0.10,
        green: 0.45,
        blue: 0.91,
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
            ? UIColor(red: 0.125, green: 0.129, blue: 0.141, alpha: 1)
            : UIColor(red: 0.973, green: 0.976, blue: 0.980, alpha: 1)
    }

    static let elevatedSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.18, green: 0.184, blue: 0.196, alpha: 1)
            : .white
    }

    static let fieldSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.235, green: 0.239, blue: 0.251, alpha: 1)
            : UIColor(red: 0.925, green: 0.933, blue: 0.945, alpha: 1)
    }

    static func applyGlobalAppearance() {
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = canvas
        navigationAppearance.shadowColor = .clear
        navigationAppearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navigationAppearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor.label,
            .font: UIFont.preferredFont(forTextStyle: .largeTitle)
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
