import UIKit
import WebKit

@MainActor
final class BrowserViewController: UIViewController {
    private let tabManager: TabManager
    private let settingsStore: BrowserSettingsStore
    private let historyStore: HistoryStore
    private let downloadCoordinator: DownloadCoordinator
    private let faviconService: FaviconService

    private let webContentContainer = UIView()
    private let toolbar = UIView()
    private let toolbarMaterial = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let addressField = UITextField()
    private let addressIconView = UIImageView()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let newTabButton = UIButton(type: .system)
    private let tabsButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private let controlsStack = UIStackView()
    private let snapshotView = UIImageView()
    private let restorationSpinner = UIActivityIndicatorView(style: .medium)
    private let errorView = BrowserErrorView()
    private let startPageView = BrowserStartPageView()

    private weak var displayedWebView: WKWebView?
    private var webViewObservations: [NSKeyValueObservation] = []
    private var faviconTasks: [UUID: Task<Void, Never>] = [:]
    private var faviconGenerations: [UUID: Int] = [:]
    private let externalNavigationRateLimiter = ExternalNavigationRateLimiter()
    private let webDialogRateLimiter = WebDialogRateLimiter()
    private let popupCreationRateLimiter = PopupCreationRateLimiter()

    init(
        tabManager: TabManager? = nil,
        settingsStore: BrowserSettingsStore? = nil,
        historyStore: HistoryStore? = nil,
        downloadCoordinator: DownloadCoordinator? = nil,
        faviconService: FaviconService? = nil
    ) {
        self.tabManager = tabManager ?? TabManager()
        self.settingsStore = settingsStore ?? .shared
        self.historyStore = historyStore ?? HistoryStore()
        self.downloadCoordinator = downloadCoordinator ?? DownloadCoordinator()
        self.faviconService = faviconService ?? FaviconService()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureInterface()

        tabManager.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: .browserSettingsDidChange,
            object: nil
        )

        Task { [weak self] in
            await self?.tabManager.restoreSession()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        addressField.resignFirstResponder()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        BrowserDiagnostics.shared.recordMemoryWarning()
        AppLog.browser.warning("Memory warning received; suspending background tabs")
        tabManager.handleMemoryWarning()
    }

    func prepareForBackground() {
        Task { [weak self] in
            await self?.tabManager.prepareForBackground()
        }
    }

    private func configureInterface() {
        configureContentArea()
        configureToolbar()
        configureStartPage()
        updateControls()
    }

    private func configureContentArea() {
        webContentContainer.translatesAutoresizingMaskIntoConstraints = false
        webContentContainer.backgroundColor = KiwiTheme.canvas
        webContentContainer.clipsToBounds = true

        snapshotView.translatesAutoresizingMaskIntoConstraints = false
        snapshotView.contentMode = .scaleAspectFill
        snapshotView.clipsToBounds = true
        snapshotView.backgroundColor = KiwiTheme.canvas
        snapshotView.isHidden = true

        restorationSpinner.translatesAutoresizingMaskIntoConstraints = false
        restorationSpinner.hidesWhenStopped = true

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .clear
        progressView.tintColor = KiwiTheme.accentDeep
        progressView.isHidden = true

        view.addSubview(webContentContainer)
        webContentContainer.addSubview(snapshotView)
        webContentContainer.addSubview(startPageView)
        webContentContainer.addSubview(restorationSpinner)
        webContentContainer.addSubview(errorView)
        view.addSubview(progressView)

        NSLayoutConstraint.activate([
            webContentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webContentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            snapshotView.topAnchor.constraint(equalTo: webContentContainer.topAnchor),
            snapshotView.leadingAnchor.constraint(equalTo: webContentContainer.leadingAnchor),
            snapshotView.trailingAnchor.constraint(equalTo: webContentContainer.trailingAnchor),
            snapshotView.bottomAnchor.constraint(equalTo: webContentContainer.bottomAnchor),

            startPageView.topAnchor.constraint(equalTo: webContentContainer.topAnchor),
            startPageView.leadingAnchor.constraint(equalTo: webContentContainer.leadingAnchor),
            startPageView.trailingAnchor.constraint(equalTo: webContentContainer.trailingAnchor),
            startPageView.bottomAnchor.constraint(equalTo: webContentContainer.bottomAnchor),

            restorationSpinner.centerXAnchor.constraint(equalTo: webContentContainer.centerXAnchor),
            restorationSpinner.centerYAnchor.constraint(equalTo: webContentContainer.centerYAnchor),

            errorView.topAnchor.constraint(equalTo: webContentContainer.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: webContentContainer.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: webContentContainer.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: webContentContainer.bottomAnchor),

            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: webContentContainer.bottomAnchor)
        ])
    }

    private func configureToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = .clear
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 2, trailing: 12)

        toolbarMaterial.translatesAutoresizingMaskIntoConstraints = false
        toolbarMaterial.isUserInteractionEnabled = false
        toolbar.addSubview(toolbarMaterial)

        configureButton(backButton, imageName: "chevron.backward", label: "Back", action: #selector(goBack))
        configureButton(forwardButton, imageName: "chevron.forward", label: "Forward", action: #selector(goForward))
        configureButton(newTabButton, imageName: "plus", label: "New tab", action: #selector(createRegularTab))
        configureButton(tabsButton, imageName: "square.on.square", label: "Show tabs", action: #selector(showTabSwitcher))
        configureButton(menuButton, imageName: "ellipsis", label: "Browser menu", action: nil)
        menuButton.showsMenuAsPrimaryAction = true

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.backgroundColor = KiwiTheme.fieldSurface
        addressField.layer.cornerRadius = 17
        addressField.layer.cornerCurve = .continuous
        addressField.clipsToBounds = true
        addressField.layer.borderColor = UIColor.clear.cgColor
        addressField.layer.borderWidth = 1.5
        addressField.font = .preferredFont(forTextStyle: .body)
        addressField.adjustsFontForContentSizeCategory = true
        addressField.isUserInteractionEnabled = true
        addressField.placeholder = "Search or enter an address"
        addressField.clearButtonMode = .whileEditing
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.spellCheckingType = .no
        addressField.smartDashesType = .no
        addressField.smartQuotesType = .no
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.enablesReturnKeyAutomatically = true
        addressField.delegate = self
        addressField.accessibilityLabel = "Address and search"
        addressField.addTarget(self, action: #selector(focusAddressField), for: .touchDown)

        addressIconView.translatesAutoresizingMaskIntoConstraints = false
        addressIconView.image = UIImage(systemName: "magnifyingglass")
        addressIconView.tintColor = .secondaryLabel
        addressIconView.contentMode = .scaleAspectFit
        addressIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let addressIconContainer = UIView(frame: CGRect(x: 0, y: 0, width: 46, height: 42))
        addressIconContainer.isUserInteractionEnabled = false
        addressIconContainer.addSubview(addressIconView)
        NSLayoutConstraint.activate([
            addressIconView.leadingAnchor.constraint(equalTo: addressIconContainer.leadingAnchor, constant: 14),
            addressIconView.centerYAnchor.constraint(equalTo: addressIconContainer.centerYAnchor),
            addressIconView.widthAnchor.constraint(equalToConstant: 20),
            addressIconView.heightAnchor.constraint(equalToConstant: 20)
        ])
        addressField.leftView = addressIconContainer
        addressField.leftViewMode = .always

        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.tintColor = .secondaryLabel
        reloadButton.accessibilityLabel = "Reload"
        reloadButton.addTarget(self, action: #selector(reloadOrStop), for: .touchUpInside)
        let reloadContainer = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 42))
        reloadContainer.addSubview(reloadButton)
        NSLayoutConstraint.activate([
            reloadButton.centerXAnchor.constraint(equalTo: reloadContainer.centerXAnchor),
            reloadButton.centerYAnchor.constraint(equalTo: reloadContainer.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 36),
            reloadButton.heightAnchor.constraint(equalToConstant: 36)
        ])
        addressField.rightView = reloadContainer
        addressField.rightViewMode = .unlessEditing

        [backButton, forwardButton, newTabButton, tabsButton, menuButton].forEach {
            controlsStack.addArrangedSubview($0)
        }
        controlsStack.axis = .horizontal
        controlsStack.alignment = .center
        controlsStack.distribution = .equalCentering
        controlsStack.spacing = 12

        let stack = UIStackView(arrangedSubviews: [addressField, controlsStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 2
        toolbar.addSubview(stack)
        view.addSubview(toolbar)

        for button in [backButton, forwardButton, newTabButton, tabsButton, menuButton] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        addressField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        view.keyboardLayoutGuide.followsUndockedKeyboard = true

        NSLayoutConstraint.activate([
            webContentContainer.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toolbarMaterial.topAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbarMaterial.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarMaterial.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarMaterial.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),

            stack.topAnchor.constraint(equalTo: toolbar.layoutMarginsGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: toolbar.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -3)
        ])
    }

    private func configureStartPage() {
        startPageView.onPrivateTab = { [weak self] in
            self?.createNewTab(isPrivate: true)
        }
        startPageView.onHistory = { [weak self] in
            self?.showHistory()
        }
        startPageView.onDownloads = { [weak self] in
            self?.showDownloads()
        }
    }

    private func configureButton(
        _ button: UIButton,
        imageName: String,
        label: String,
        action: Selector?
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: imageName)
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.accessibilityLabel = label
        if let action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
    }

    @objc private func focusAddressField() {
        if !addressField.isFirstResponder {
            addressField.becomeFirstResponder()
        }
    }

    private func display(tab: Tab) {
        detachWebViewObservations()
        displayedWebView?.removeFromSuperview()
        displayedWebView = nil
        errorView.hide()

        updateStartPage(for: tab)

        guard let webView = tab.webView else {
            updateControls()
            return
        }

        webContentContainer.insertSubview(webView, at: 0)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContentContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContentContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContentContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContentContainer.bottomAnchor)
        ])
        displayedWebView = webView
        attachWebViewObservations(to: webView)

        if tab.isRestoringFromSuspension, let snapshot = tab.snapshot {
            snapshotView.image = snapshot
            snapshotView.isHidden = false
            restorationSpinner.stopAnimating()
        } else if tab.isRestoringFromSuspension {
            snapshotView.isHidden = true
            restorationSpinner.startAnimating()
        } else {
            snapshotView.isHidden = true
            restorationSpinner.stopAnimating()
        }

        updateAddress(for: tab)
        updatePrivateAppearance(for: tab)
        updateControls()
        tabManager.loadInitialPageIfNeeded(for: tab.id)
    }

    private func attachWebViewObservations(to webView: WKWebView) {
        webViewObservations = [
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                guard let self, let webView, webView === self.displayedWebView else { return }
                self.updateProgress(for: webView)
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                guard let self, let webView, webView === self.displayedWebView else { return }
                self.updateControls()
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                guard let self, let webView, webView === self.displayedWebView else { return }
                self.updateControls()
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                guard let self, let webView, webView === self.displayedWebView else { return }
                self.updateProgress(for: webView)
                self.updateControls()
            }
        ]
    }

    private func detachWebViewObservations() {
        webViewObservations.forEach { $0.invalidate() }
        webViewObservations.removeAll()
    }

    private func updateAddress(for tab: Tab) {
        guard !addressField.isFirstResponder else { return }
        if tab.url?.absoluteString == "about:blank" || tab.url == nil {
            addressField.text = nil
        } else if let url = tab.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            addressField.text = SafeInput.displayHost(for: url)
        } else {
            addressField.text = tab.url?.absoluteString
        }
        addressField.accessibilityValue = addressField.text
        if let favicon = tab.favicon {
            addressIconView.image = favicon
        } else if tab.isPrivate {
            addressIconView.image = UIImage(systemName: "hand.raised.fill")
        } else if tab.url == nil || tab.url?.absoluteString == "about:blank" {
            addressIconView.image = UIImage(systemName: "magnifyingglass")
        } else if tab.url?.scheme?.lowercased() == "https" {
            addressIconView.image = UIImage(systemName: "lock.fill")
        } else {
            addressIconView.image = UIImage(systemName: "globe")
        }
    }

    private func updatePrivateAppearance(for tab: Tab?) {
        let isPrivate = tab?.isPrivate == true
        addressField.backgroundColor = isPrivate
            ? KiwiTheme.privateAccent.withAlphaComponent(0.14)
            : KiwiTheme.fieldSurface
        addressField.placeholder = isPrivate ? "Private search or address" : "Search or enter an address"
        addressField.accessibilityLabel = isPrivate ? "Private address and search" : "Address and search"
        addressField.accessibilityHint = isPrivate
            ? "Browsing activity in this tab is not saved to history or session restore. Downloads remain on this device."
            : "Enter a website address or search terms."
        toolbarMaterial.effect = UIBlurEffect(
            style: isPrivate ? .systemUltraThinMaterialDark : .systemChromeMaterial
        )
        startPageView.update(
            isPrivate: isPrivate,
            searchEngineName: settingsStore.selectedSearchEngine.name
        )
    }

    private func updateStartPage(for tab: Tab?) {
        let urlText = tab?.url?.absoluteString
        startPageView.isHidden = !(urlText == nil || urlText == "about:blank")
        if !startPageView.isHidden {
            startPageView.update(
                isPrivate: tab?.isPrivate == true,
                searchEngineName: settingsStore.selectedSearchEngine.name
            )
        }
    }

    private func updateProgress(for webView: WKWebView) {
        let progress = Float(webView.estimatedProgress)
        progressView.setProgress(progress, animated: progress > progressView.progress)
        progressView.isHidden = !webView.isLoading || progress >= 1
        if !webView.isLoading {
            progressView.progress = 0
        }
    }

    private func updateControls() {
        let webView = displayedWebView
        backButton.isEnabled = webView?.canGoBack == true
        forwardButton.isEnabled = webView?.canGoForward == true

        let hasPage = tabManager.selectedTab?.url.map { $0.absoluteString != "about:blank" } ?? false
        reloadButton.isEnabled = hasPage
        addressField.rightViewMode = hasPage && !addressField.isFirstResponder ? .always : .never

        let isLoading = webView?.isLoading == true
        reloadButton.setImage(
            UIImage(systemName: isLoading ? "xmark" : "arrow.clockwise"),
            for: .normal
        )
        reloadButton.accessibilityLabel = isLoading ? "Stop loading" : "Reload"

        var tabConfiguration = tabsButton.configuration ?? .plain()
        tabConfiguration.title = "\(tabManager.tabs.count)"
        tabConfiguration.imagePadding = 5
        tabConfiguration.imagePlacement = .leading
        tabConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
                for: .systemFont(ofSize: 12, weight: .bold)
            )
            return outgoing
        }
        tabsButton.configuration = tabConfiguration
        menuButton.menu = makeBrowserMenu()
    }

    private func makeBrowserMenu() -> UIMenu {
        let loading = displayedWebView?.isLoading == true
        let reload = UIAction(
            title: loading ? "Stop" : "Reload",
            image: UIImage(systemName: loading ? "xmark" : "arrow.clockwise")
        ) { [weak self] _ in
            self?.reloadOrStop()
        }
        let unavailableWithoutURL: UIMenuElement.Attributes = tabManager.selectedTab?.url == nil ? [.disabled] : []
        let share = UIAction(
            title: "Share",
            image: UIImage(systemName: "square.and.arrow.up"),
            attributes: unavailableWithoutURL
        ) { [weak self] _ in
            self?.shareCurrentPage()
        }

        let openExternal = UIAction(
            title: "Open in External App",
            image: UIImage(systemName: "arrow.up.forward.app"),
            attributes: unavailableWithoutURL
        ) { [weak self] _ in
            self?.openCurrentPageExternally()
        }

        let newTab = UIAction(title: "New Tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in
            self?.createNewTab(isPrivate: false)
        }
        let privateTab = UIAction(
            title: "New Private Tab",
            image: UIImage(systemName: "hand.raised.fill")
        ) { [weak self] _ in
            self?.createNewTab(isPrivate: true)
        }
        let close = UIAction(title: "Close Tab", image: UIImage(systemName: "xmark.square"), attributes: .destructive) { [weak self] _ in
            guard let self, let id = self.tabManager.selectedTabID else { return }
            self.externalNavigationRateLimiter.remove(tabID: id)
            self.webDialogRateLimiter.remove(tabID: id)
            self.popupCreationRateLimiter.remove(tabID: id)
            self.cancelFaviconLoad(tabID: id)
            self.tabManager.closeTab(id: id)
        }
        let settings = UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.showSettings()
        }
        let history = UIAction(title: "History", image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in
            self?.showHistory()
        }
        let downloads = UIAction(title: "Downloads", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
            self?.showDownloads()
        }
        var children: [UIMenuElement] = [
            reload,
            share,
            openExternal,
            UIMenu(options: .displayInline, children: [newTab, privateTab, close]),
            UIMenu(options: .displayInline, children: [history, downloads, settings])
        ]

        #if DEBUG
        children.append(UIAction(title: "Debug Info", image: UIImage(systemName: "ladybug")) { [weak self] _ in
            self?.showDebugInfo()
        })
        #endif

        return UIMenu(children: children)
    }

    private func createNewTab(isPrivate: Bool) {
        do {
            let tab = try tabManager.createTab(isPrivate: isPrivate, select: true)
            addressField.text = nil
            updatePrivateAppearance(for: tab)
            addressField.becomeFirstResponder()
        } catch {
            presentTabLimitError(error)
        }
    }

    @objc private func createRegularTab() {
        createNewTab(isPrivate: false)
    }

    @objc private func goBack() {
        displayedWebView?.goBack()
    }

    @objc private func goForward() {
        displayedWebView?.goForward()
    }

    @objc private func reloadOrStop() {
        guard let webView = displayedWebView else { return }
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    @objc private func showTabSwitcher() {
        let items = tabManager.tabs.map {
            TabSwitcherViewController.Item(
                id: $0.id,
                title: $0.title,
                urlText: $0.url.map { SafeInput.displayHost(for: $0, fallback: $0.absoluteString) }
                    ?? "New Tab",
                isPrivate: $0.isPrivate,
                lifecycleState: $0.state,
                snapshot: $0.snapshot,
                favicon: $0.favicon
            )
        }
        let switcher = TabSwitcherViewController(items: items, selectedTabID: tabManager.selectedTabID)
        switcher.delegate = self
        let navigation = UINavigationController(rootViewController: switcher)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    private func shareCurrentPage() {
        guard let rawURL = tabManager.selectedTab?.url,
              let url = SafeInput.credentialFreeURL(rawURL) else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = menuButton
            popover.sourceRect = menuButton.bounds
        }
        present(activity, animated: true)
    }

    private func openCurrentPageExternally() {
        guard let rawURL = tabManager.selectedTab?.url,
              let url = SafeInput.credentialFreeURL(rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        UIApplication.shared.open(url)
    }

    private func showSettings() {
        let controller = UINavigationController(
            rootViewController: SettingsViewController(settingsStore: settingsStore)
        )
        controller.modalPresentationStyle = .formSheet
        present(controller, animated: true)
    }

    private func showHistory() {
        let history = HistoryViewController(store: historyStore) { [weak self] url in
            self?.tabManager.navigate(to: url)
        }
        let navigation = UINavigationController(rootViewController: history)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func showDownloads() {
        let downloads = DownloadsViewController(coordinator: downloadCoordinator)
        let navigation = UINavigationController(rootViewController: downloads)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    #if DEBUG
    private func showDebugInfo() {
        let controller = DebugInfoViewController { [weak self] in
            guard let self else { return [:] }
            var information = [
                "Current URL": self.tabManager.selectedTab?.isPrivate == true
                    ? "Private tab (redacted)"
                    : self.tabManager.selectedTab?.url.map { SafeInput.displayURL($0) } ?? "None",
                "Tabs": "\(self.tabManager.tabs.count)",
                "Live WKWebViews": "\(self.tabManager.liveWebViewCount)",
                "Memory warnings": "\(BrowserDiagnostics.shared.memoryWarningCount)",
                "Navigation events": "\(BrowserDiagnostics.shared.navigationEventCount)",
                "Extension host": self.tabManager.webExtensionObserver == nil ? "Not attached" : "Attached"
            ]
            return information
        }
        navigationController?.pushViewController(controller, animated: true)
        if navigationController == nil {
            let navigation = UINavigationController(rootViewController: controller)
            controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(dismissPresentedController)
            )
            present(navigation, animated: true)
        }
    }

    @objc private func dismissPresentedController() {
        dismiss(animated: true)
    }
    #endif

    private func presentTabLimitError(_ error: Error) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Couldn’t Open Tab",
            message: SafeInput.userFacingError(error),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func presentAddressInputError() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Address Not Recognized",
            message: "Enter a valid HTTP or HTTPS address without embedded credentials, or use shorter search terms.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Edit", style: .default) { [weak self] _ in
            self?.addressField.becomeFirstResponder()
        })
        present(alert, animated: true)
    }

    @objc private func handleSettingsChange() {
        updatePrivateAppearance(for: tabManager.selectedTab)
    }

    private func showNavigationError(_ error: Error, for tab: Tab) {
        guard tab.id == tabManager.selectedTabID else { return }
        hideRestorationOverlay(animated: false)
        errorView.show(message: SafeInput.userFacingError(
            error,
            fallback: "Check your connection and try loading the page again."
        )) { [weak self] in
            self?.errorView.hide()
            self?.displayedWebView?.reload()
        }
    }

    private func cancelFaviconLoad(tabID: UUID) {
        faviconGenerations[tabID, default: 0] += 1
        faviconTasks.removeValue(forKey: tabID)?.cancel()
    }

    private func loadFavicon(for tab: Tab, in webView: WKWebView, pageURL: URL) {
        cancelFaviconLoad(tabID: tab.id)
        guard ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return }
        let generation = faviconGenerations[tab.id, default: 0]
        let tabID = tab.id
        let privacyMode: FaviconPrivacyMode = tab.isPrivate ? .private : .normal
        faviconTasks[tabID] = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            defer {
                if self.faviconGenerations[tabID] == generation {
                    self.faviconTasks.removeValue(forKey: tabID)
                }
            }
            do {
                let discovery = try await webView.evaluateJavaScript(FaviconService.discoveryJavaScript)
                try Task.checkCancellation()
                guard self.faviconGenerations[tabID] == generation,
                      self.tabManager.tab(id: tabID) === tab,
                      tab.webView === webView,
                      webView.url == pageURL,
                      let result = await self.faviconService.image(
                        for: pageURL,
                        javaScriptResult: discovery,
                        privacyMode: privacyMode
                      ) else { return }
                try Task.checkCancellation()
                guard self.faviconGenerations[tabID] == generation,
                      tab.webView === webView,
                      webView.url == pageURL else { return }
                self.tabManager.updateFavicon(
                    tabID: tabID,
                    image: result.image,
                    sourceURL: result.sourceURL,
                    expectedPageURL: pageURL
                )
            } catch {
                // Missing/invalid favicons and cancellation never affect navigation.
            }
        }
    }

    private func hideRestorationOverlay(animated: Bool) {
        restorationSpinner.stopAnimating()
        guard !snapshotView.isHidden else { return }
        if animated {
            UIView.animate(withDuration: 0.16, animations: {
                self.snapshotView.alpha = 0
            }, completion: { _ in
                self.snapshotView.isHidden = true
                self.snapshotView.alpha = 1
                self.snapshotView.image = nil
            })
        } else {
            snapshotView.isHidden = true
            snapshotView.alpha = 1
            snapshotView.image = nil
        }
    }

}

extension BrowserViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.rightViewMode = .never
        if let url = tabManager.selectedTab?.url,
           url.absoluteString != "about:blank" {
            textField.text = SafeInput.displayURL(url)
        }
        UIView.animate(withDuration: 0.2) {
            self.controlsStack.isHidden = true
            textField.layer.borderColor = KiwiTheme.accentDeep.cgColor
            textField.backgroundColor = KiwiTheme.elevatedSurface
            self.view.layoutIfNeeded()
        }
        DispatchQueue.main.async {
            textField.selectAll(nil)
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        UIView.animate(withDuration: 0.2) {
            self.controlsStack.isHidden = false
            textField.layer.borderColor = UIColor.clear.cgColor
            self.view.layoutIfNeeded()
        }
        updatePrivateAppearance(for: tabManager.selectedTab)
        if let tab = tabManager.selectedTab {
            updateAddress(for: tab)
        }
        updateControls()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let input = textField.text, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let resolution = URLInputParser(searchEngine: settingsStore.selectedSearchEngine).resolve(input) else {
            presentAddressInputError()
            return false
        }
        errorView.hide()
        tabManager.navigate(to: resolution.url)
        textField.resignFirstResponder()
        return true
    }
}

extension BrowserViewController: TabManagerDelegate {
    func tabManagerDidChangeTabs(_ manager: TabManager) {
        updateControls()
    }

    func tabManager(_ manager: TabManager, didSelect tab: Tab) {
        display(tab: tab)
    }

    func tabManager(_ manager: TabManager, didUpdate tab: Tab) {
        guard tab.id == manager.selectedTabID else { return }
        updateStartPage(for: tab)
        updateAddress(for: tab)
        updatePrivateAppearance(for: tab)
        updateControls()
    }

    func tabManager(_ manager: TabManager, didCreateWebViewFor tab: Tab) {
        tab.webView?.navigationDelegate = self
        tab.webView?.uiDelegate = self
    }

    func tabManager(_ manager: TabManager, willSuspend tab: Tab) {
        AppLog.tabs.debug("Suspending tab \(tab.id.uuidString, privacy: .public)")
    }
}

extension BrowserViewController: TabSwitcherViewControllerDelegate {
    func tabSwitcher(_ controller: TabSwitcherViewController, didSelectTab id: UUID) {
        tabManager.selectTab(id: id)
        controller.dismiss(animated: true)
    }

    func tabSwitcher(_ controller: TabSwitcherViewController, didCloseTab id: UUID) {
        externalNavigationRateLimiter.remove(tabID: id)
        webDialogRateLimiter.remove(tabID: id)
        popupCreationRateLimiter.remove(tabID: id)
        cancelFaviconLoad(tabID: id)
        tabManager.closeTab(id: id)
        controller.removeItem(id: id)
    }

    func tabSwitcher(_ controller: TabSwitcherViewController, createPrivateTab: Bool) {
        do {
            _ = try tabManager.createTab(isPrivate: createPrivateTab, select: true)
            controller.dismiss(animated: true)
            addressField.becomeFirstResponder()
        } catch {
            controller.dismiss(animated: true) { [weak self] in self?.presentTabLimitError(error) }
        }
    }
}

extension BrowserViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tabManager.tab(containing: webView) else { return }
        cancelFaviconLoad(tabID: tab.id)
        BrowserDiagnostics.shared.recordNavigationEvent()
        tabManager.updateTab(id: tab.id, url: webView.url)
        if tab.id == tabManager.selectedTabID {
            errorView.hide()
            updateStartPage(for: tab)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tabManager.tab(containing: webView) else { return }
        BrowserDiagnostics.shared.recordNavigationEvent()
        tabManager.updateTab(id: tab.id, url: webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tabManager.tab(containing: webView) else { return }
        BrowserDiagnostics.shared.recordNavigationEvent()
        tabManager.updateTab(id: tab.id, title: webView.title, url: webView.url)
        tabManager.markRestorationComplete(tabID: tab.id)
        if tab.id == tabManager.selectedTabID {
            hideRestorationOverlay(animated: true)
        }
        if let pageURL = webView.url {
            loadFavicon(for: tab, in: webView, pageURL: pageURL)
        }
        if !tab.isPrivate {
            if let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                let title = webView.title ?? SafeInput.displayHost(for: url, fallback: url.absoluteString)
                Task { [historyStore] in
                    do {
                        try await historyStore.recordVisit(
                            url: url,
                            title: title,
                            isPrivate: tab.isPrivate
                        )
                    } catch {
                        AppLog.browser.error("Could not save history: \(error.localizedDescription, privacy: .private)")
                    }
                }
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error, webView: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error, webView: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === displayedWebView else { return }
        AppLog.browser.warning("Web content process terminated; reloading active page")
        webView.reload()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        let internallySupportedSchemes = ["http", "https", "about", "file", "data", "blob"]
        guard !internallySupportedSchemes.contains(scheme) else {
            guard navigationAction.shouldPerformDownload,
                  let tab = tabManager.tab(containing: webView), tab.isPrivate else {
                decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
                return
            }
            guard tab.id == tabManager.selectedTabID,
                  webView === displayedWebView,
                  UIApplication.shared.applicationState == .active,
                  presentedViewController == nil else {
                decisionHandler(.cancel)
                return
            }
            let message = downloadCoordinator.confirmationMessage(expectedBytes: -1, isPrivate: true)
            let alert = UIAlertController(title: "Download File?", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in decisionHandler(.cancel) })
            alert.addAction(UIAlertAction(title: "Download", style: .default) { _ in decisionHandler(.download) })
            present(alert, animated: true)
            return
        }

        decisionHandler(.cancel)
        guard let tab = tabManager.tab(containing: webView) else { return }
        let decision = ExternalNavigationPolicy.decision(
            for: url,
            isUserActivated: navigationAction.navigationType == .linkActivated,
            isTopLevel: navigationAction.sourceFrame.isMainFrame &&
                (navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == true),
            isActiveTab: tab.id == tabManager.selectedTabID && webView === displayedWebView,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        guard decision != .block, externalNavigationRateLimiter.consume(tabID: tab.id) else { return }

        switch decision {
        case .block:
            return
        case .open:
            UIApplication.shared.open(url, options: [:])
        case .confirm(let displayName):
            guard presentedViewController == nil else { return }
            let alert = UIAlertController(
                title: "Open another app?",
                message: "This website wants to open a \(displayName).",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in
                UIApplication.shared.open(url, options: [:])
            })
            present(alert, animated: true)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard !navigationResponse.canShowMIMEType else {
            decisionHandler(.allow)
            return
        }
        let expectedBytes = navigationResponse.response.expectedContentLength
        if downloadCoordinator.exceedsMaximumSize(expectedBytes: expectedBytes) {
            decisionHandler(.cancel)
            presentDownloadPolicyAlert(
                message: downloadCoordinator.maximumSizeMessage
            )
            return
        }
        let tab = tabManager.tab(containing: webView)
        guard let message = downloadCoordinator.confirmationMessage(
            expectedBytes: expectedBytes,
            isPrivate: tab?.isPrivate == true
        ) else {
            decisionHandler(.download)
            return
        }
        guard tab?.id == tabManager.selectedTabID,
              webView === displayedWebView,
              UIApplication.shared.applicationState == .active,
              presentedViewController == nil else {
            decisionHandler(.cancel)
            return
        }
        let alert = UIAlertController(title: "Download File?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in decisionHandler(.cancel) })
        alert.addAction(UIAlertAction(title: "Download", style: .default) { _ in decisionHandler(.download) })
        present(alert, animated: true)
    }

    private func presentDownloadPolicyAlert(message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Download Blocked", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        let isPrivate = tabManager.tab(containing: webView)?.isPrivate ?? false
        downloadCoordinator.adopt(download, isPrivate: isPrivate)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        let isPrivate = tabManager.tab(containing: webView)?.isPrivate ?? false
        downloadCoordinator.adopt(download, isPrivate: isPrivate)
    }

    private func handleNavigationFailure(_ error: Error, webView: WKWebView) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled,
              let tab = tabManager.tab(containing: webView) else {
            return
        }
        BrowserDiagnostics.shared.recordNavigationEvent()
        showNavigationError(error, for: tab)
    }
}

extension BrowserViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              navigationAction.navigationType == .linkActivated,
              let sourceTab = tabManager.tab(containing: webView),
              sourceTab.id == tabManager.selectedTabID,
              webView === displayedWebView,
              UIApplication.shared.applicationState == .active,
              popupCreationRateLimiter.consume(tabID: sourceTab.id),
              let targetURL = navigationAction.request.url,
              SafePersistence.isSafePersistedURL(targetURL) else { return nil }
        do {
            _ = try tabManager.createTab(
                url: targetURL,
                isPrivate: sourceTab.isPrivate,
                select: true
            )
        } catch {
            presentTabLimitError(error)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        guard let tab = tabManager.tab(containing: webView),
              tab.id == tabManager.selectedTabID,
              webView === displayedWebView,
              UIApplication.shared.applicationState == .active,
              presentedViewController == nil,
              webDialogRateLimiter.consume(tabID: tab.id) else {
            completionHandler()
            return
        }
        let content = WebDialogPolicy.content(pageURL: frame.request.url, message: message)
        let alert = UIAlertController(title: content.title, message: content.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let tab = tabManager.tab(containing: webView),
              tab.id == tabManager.selectedTabID,
              webView === displayedWebView,
              UIApplication.shared.applicationState == .active,
              presentedViewController == nil,
              webDialogRateLimiter.consume(tabID: tab.id) else {
            completionHandler(false)
            return
        }
        let content = WebDialogPolicy.content(pageURL: frame.request.url, message: message)
        let alert = UIAlertController(title: content.title, message: content.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        guard let tab = tabManager.tab(containing: webView),
              tab.id == tabManager.selectedTabID,
              webView === displayedWebView,
              UIApplication.shared.applicationState == .active,
              presentedViewController == nil,
              webDialogRateLimiter.consume(tabID: tab.id) else {
            completionHandler(nil)
            return
        }
        let content = WebDialogPolicy.content(pageURL: frame.request.url, message: prompt, defaultText: defaultText)
        let alert = UIAlertController(title: content.title, message: content.message, preferredStyle: .alert)
        alert.addTextField { $0.text = content.defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text.map {
                SafeInput.utf8Prefix($0, maximumByteCount: WebDialogPolicy.maximumDefaultTextByteCount)
            })
        })
        present(alert, animated: true)
    }
}
