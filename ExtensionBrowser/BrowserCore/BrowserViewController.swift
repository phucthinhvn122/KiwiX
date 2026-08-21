import UIKit
import WebKit

@MainActor
final class BrowserViewController: UIViewController {
    private let tabManager: TabManager
    private let settingsStore: BrowserSettingsStore
    private let historyStore: HistoryStore
    private let downloadCoordinator: DownloadCoordinator
    private let faviconService: FaviconService
    /// Absent when the scene could not build an extension host, which is how the menu entry
    /// disappears instead of leading to a screen that cannot install anything.
    private let extensionCoordinator: ExtensionInstallCoordinator?

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
    /// Which tab the address bar is being edited for.
    ///
    /// The selected tab can change while the keyboard is up — an extension calling `tabs.update`,
    /// a background page opening one — and Return would then send what the user typed to whichever
    /// tab happened to be in front by the time they finished.
    private var editingTabID: UUID?
    /// Keeps the app alive long enough to finish writing the session on the way to the background.
    private var backgroundFlushAssertion: UIBackgroundTaskIdentifier = .invalid

    /// Named so a test can find the recogniser without the view hierarchy being made public.
    static let dismissKeyboardTapName = "browser.dismissKeyboardTap"

    init(
        tabManager: TabManager? = nil,
        settingsStore: BrowserSettingsStore? = nil,
        historyStore: HistoryStore? = nil,
        downloadCoordinator: DownloadCoordinator? = nil,
        faviconService: FaviconService? = nil,
        extensionCoordinator: ExtensionInstallCoordinator? = nil
    ) {
        self.tabManager = tabManager ?? TabManager()
        self.settingsStore = settingsStore ?? .shared
        self.historyStore = historyStore ?? HistoryStore()
        self.downloadCoordinator = downloadCoordinator ?? DownloadCoordinator()
        self.faviconService = faviconService ?? FaviconService()
        self.extensionCoordinator = extensionCoordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The strip the hardware takes — beside the content in landscape, under the status bar in
        // portrait — is painted like the page canvas instead of being left as a contrasting slab.
        view.backgroundColor = KiwiTheme.canvas
        configureInterface()

        tabManager.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: .browserSettingsDidChange,
            object: nil
        )

        // Startup reconciliation, which is where interrupted transfers are failed and hidden
        // `.kiwix-<uuid>.partial` orphans are deleted. Nothing else calls it at launch: the only
        // other callers are the Downloads screen appearing and its pull-to-refresh, so a partial
        // left behind by a crash survived until the user happened to open that screen — and if they
        // never did, forever.
        downloadCoordinator.reload()

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

    /// Captures a snapshot of the foreground tab and flushes the session, under an expiration
    /// assertion.
    ///
    /// The work is asynchronous — `takeSnapshot` round-trips to the web content process, then the
    /// session is encoded and written through an actor — and `sceneDidEnterBackground` returns long
    /// before any of it finishes. Without an assertion the app can be suspended in the middle, and
    /// what is lost is the tab session: the thing whose whole job is to survive being backgrounded.
    func prepareForBackground() {
        // Held as a property rather than a local: both the expiration handler and the Task have to
        // be able to clear it, and a `var` captured by a `@Sendable` closure cannot be mutated.
        endBackgroundFlushAssertion()
        backgroundFlushAssertion = UIApplication.shared.beginBackgroundTask(
            withName: "kiwix.session-flush",
            expirationHandler: { [weak self] in
                // Out of time. Ending it here is mandatory — iOS kills an app that holds an
                // assertion past its expiration. Documented as called on the main thread.
                MainActor.assumeIsolated { self?.endBackgroundFlushAssertion() }
            }
        )

        Task { [weak self] in
            await self?.tabManager.prepareForBackground()
            self?.endBackgroundFlushAssertion()
        }
    }

    private func endBackgroundFlushAssertion() {
        guard backgroundFlushAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundFlushAssertion)
        backgroundFlushAssertion = .invalid
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
        webContentContainer.accessibilityIdentifier = "browser.content"

        // Tapping the page while the address bar is being edited puts the keyboard away, the way a
        // browser is expected to behave — there is no Cancel button, because the controls row
        // hides itself during editing.
        //
        // The recogniser only begins while the field is first responder (see
        // `gestureRecognizerShouldBegin`), so nothing about an ordinary tap on a link changes. While
        // it does begin it swallows the touch, which is deliberate: a tap meant to dismiss must not
        // also activate whatever happened to be underneath it.
        let dismissKeyboardTap = UITapGestureRecognizer(
            target: self,
            action: #selector(dismissAddressEditing)
        )
        dismissKeyboardTap.delegate = self
        dismissKeyboardTap.name = Self.dismissKeyboardTapName
        webContentContainer.addGestureRecognizer(dismissKeyboardTap)

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
            // Horizontal edges follow the safe area too, not just the top one. On a notched phone
            // held sideways the inset is on the side, and a view pinned to the raw edge puts page
            // content under the cut-out.
            webContentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webContentContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webContentContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),

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

            progressView.leadingAnchor.constraint(equalTo: webContentContainer.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: webContentContainer.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: webContentContainer.bottomAnchor)
        ])
    }

    private func configureToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = .clear
        toolbar.accessibilityIdentifier = "browser.toolbar"
        // Left full width on purpose: the blur is meant to run under the cut-out and the home
        // indicator. What must stay clear of both is the controls inside it, and those are pinned
        // to `layoutMarginsGuide`, which insets itself from the safe area.
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
        // Stated, not inherited. Every background this field can wear is a KiwiTheme colour that
        // flips with the interface style; the text colour has to flip with it or the address is
        // drawn in a fixed shade against a surface that moved out from under it. The placeholder
        // never showed the fault because UIKit does hand that one a dynamic default.
        addressField.textColor = .label
        addressField.tintColor = KiwiTheme.accentDeep
        addressField.accessibilityIdentifier = "browser.addressField"
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
        // AddressAccessoryView, not a plain UIView: a plain one reports no intrinsic size, and the
        // field responds by handing the overlay its entire width, which leaves the text rect 0pt
        // wide and the address bar unable to draw a single character. See AddressAccessoryView.
        let addressIconContainer = AddressAccessoryView(size: CGSize(width: 46, height: 42))
        addressIconContainer.isUserInteractionEnabled = false
        addressIconContainer.addSubview(addressIconView)
        NSLayoutConstraint.activate([
            addressIconView.leadingAnchor.constraint(equalTo: addressIconContainer.leadingAnchor, constant: 14),
            // The trailing pin is what makes the container's width follow from its content instead
            // of being left for the layout engine to guess at.
            addressIconContainer.trailingAnchor.constraint(equalTo: addressIconView.trailingAnchor, constant: 12),
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
        let reloadContainer = AddressAccessoryView(size: CGSize(width: 44, height: 42))
        reloadContainer.addSubview(reloadButton)
        NSLayoutConstraint.activate([
            reloadButton.centerXAnchor.constraint(equalTo: reloadContainer.centerXAnchor),
            reloadButton.centerYAnchor.constraint(equalTo: reloadContainer.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 36),
            reloadButton.heightAnchor.constraint(equalToConstant: 36),
            // Same reason as the icon container: centring a button inside a view says nothing about
            // how wide that view is, so the overlay is free to grow and eat the text rect the moment
            // the field stops editing and puts it on screen. Width only - the field pins the
            // overlay's top and bottom itself, so a height constraint here would fight it.
            reloadContainer.widthAnchor.constraint(equalToConstant: 44)
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

    @objc private func dismissAddressEditing() {
        addressField.resignFirstResponder()
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

    /// - Note: the change handler `observe(_:options:changeHandler:)` takes is `@Sendable`, so the
    ///   body cannot touch this controller's state without saying which actor it is on. It is the
    ///   main one: `estimatedProgress`, `canGoBack`, `canGoForward` and `isLoading` are main-thread
    ///   properties of `WKWebView`, WebKit mutates them there, and KVO delivers synchronously on the
    ///   thread that mutated. `assumeIsolated` records that fact; hopping with `Task { @MainActor }`
    ///   instead would put the progress bar and the back/forward buttons a runloop turn behind the
    ///   change they describe, and could reorder two notifications that arrived in the same turn.
    ///
    ///   The observed object arrives as the closure's first argument, which is why there is no
    ///   `weak webView` capture: the argument is the view that actually changed.
    private func attachWebViewObservations(to webView: WKWebView) {
        webViewObservations = [
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] observed, _ in
                MainActor.assumeIsolated {
                    guard let self, observed === self.displayedWebView else { return }
                    self.updateProgress(for: observed)
                }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] observed, _ in
                MainActor.assumeIsolated {
                    guard let self, observed === self.displayedWebView else { return }
                    self.updateControls()
                }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] observed, _ in
                MainActor.assumeIsolated {
                    guard let self, observed === self.displayedWebView else { return }
                    self.updateControls()
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] observed, _ in
                MainActor.assumeIsolated {
                    guard let self, observed === self.displayedWebView else { return }
                    self.updateProgress(for: observed)
                    self.updateControls()
                }
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
        // No `accessibilityValue` is set here on purpose. UITextField already reports its own
        // live text to accessibility; assigning a snapshot overrode that with whatever the
        // address was at the moment a tab loaded, so VoiceOver — and XCUITest's `value` —
        // read a blank field for the entire time the user was typing into it.
        // The icon beside the address is a security indicator and nothing else. A favicon is bytes
        // the site chose, so letting one occupy this slot let a page on http:// draw its own
        // padlock — and, because that branch came first, paint over the private-browsing indicator
        // as well. Favicons still identify tabs in the switcher, where they claim nothing about
        // transport security or about which profile a tab belongs to.
        if tab.isPrivate {
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
        var tools: [UIMenuElement] = [history, downloads]
        if extensionCoordinator != nil {
            tools.append(
                UIAction(title: "Extensions", image: UIImage(systemName: "puzzlepiece.extension")) { [weak self] _ in
                    self?.showExtensions()
                }
            )
        }
        tools.append(settings)

        var children: [UIMenuElement] = [
            reload,
            share,
            openExternal,
            UIMenu(options: .displayInline, children: [newTab, privateTab, close]),
            UIMenu(options: .displayInline, children: tools)
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

    private func showExtensions() {
        presentExtensions(importing: nil)
    }

    /// A package another app opened in KiwiX. Goes through the same screen and the same consent
    /// sheet as one picked from Files — arriving by share sheet grants nothing extra.
    func presentExtensionInstall(fileURL: URL) {
        presentExtensions(importing: fileURL)
    }

    private func presentExtensions(importing fileURL: URL?) {
        guard let extensionCoordinator else { return }
        let extensions = ExtensionsViewController(coordinator: extensionCoordinator)
        if let fileURL {
            extensions.importOnAppearance(fileURL: fileURL)
        }
        let navigation = UINavigationController(rootViewController: extensions)
        navigation.modalPresentationStyle = .formSheet

        guard presentedViewController != nil else {
            present(navigation, animated: true)
            return
        }
        // An incoming file arrives whatever is on screen, including the tab switcher or another
        // sheet. Whatever it is loses; presenting on top of it would silently do nothing.
        dismiss(animated: false) { [weak self] in
            self?.present(navigation, animated: true)
        }
    }

    #if DEBUG
    private func showDebugInfo() {
        let controller = DebugInfoViewController { [weak self] in
            guard let self else { return [:] }
            let information = [
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

    /// Drops everything keyed to a tab that no longer exists.
    ///
    /// The two close paths that go through this controller clean up after themselves, but they are
    /// not the only ones: `WebExtensionTabAdapter.close`, the last-private-tab reset and the
    /// replacement tab `TabManager.closeTab` opens all remove a tab without telling anyone which id
    /// went. `faviconGenerations` in particular is never removed anywhere else, so it grows for the
    /// life of the process and a favicon fetch for a closed tab keeps running against a dead web view.
    private func discardStateForClosedTabs(liveTabIDs: Set<UUID>) {
        // Snapshot the keys: the loop body mutates the dictionary it would otherwise be iterating.
        for tabID in Array(faviconGenerations.keys) where !liveTabIDs.contains(tabID) {
            faviconGenerations.removeValue(forKey: tabID)
            faviconTasks.removeValue(forKey: tabID)?.cancel()
            externalNavigationRateLimiter.remove(tabID: tabID)
            webDialogRateLimiter.remove(tabID: tabID)
            popupCreationRateLimiter.remove(tabID: tabID)
        }
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

extension BrowserViewController: UIGestureRecognizerDelegate {
    /// The tap-to-dismiss recogniser, and only while the address bar is being edited.
    ///
    /// Returning false is what keeps this invisible the rest of the time: a recogniser that never
    /// begins never swallows a touch, so page interaction is exactly what it was before.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.name == Self.dismissKeyboardTapName else { return true }
        return addressField.isFirstResponder
    }
}

extension BrowserViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        editingTabID = tabManager.selectedTabID
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
        editingTabID = nil
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
        // Addressed to the tab that was in front when typing started. A stale id makes
        // `navigate(to:in:)` a no-op, which is the right outcome for a tab that has since been
        // closed — better than quietly loading it somewhere the user was not looking.
        tabManager.navigate(to: resolution.url, in: editingTabID ?? tabManager.selectedTabID)
        textField.resignFirstResponder()
        return true
    }
}

extension BrowserViewController: TabManagerDelegate {
    func tabManagerDidChangeTabs(_ manager: TabManager) {
        discardStateForClosedTabs(liveTabIDs: Set(manager.tabs.map(\.id)))
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
        handleNavigationFailure(error, webView: webView, wasProvisional: true)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error, webView: webView, wasProvisional: false)
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
        // `targetFrame == nil` means the navigation is opening a frame it does not have yet, which
        // becomes a top-level document by the time anything is drawn.
        let isTopLevelNavigation = navigationAction.targetFrame?.isMainFrame ?? true
        if InternalNavigationPolicy.blocksTopLevelNavigation(
            scheme: scheme,
            isTopLevel: isTopLevelNavigation,
            isDownload: navigationAction.shouldPerformDownload
        ) {
            AppLog.browser.warning("Refused a top-level \(scheme, privacy: .public): navigation")
            decisionHandler(.cancel)
            return
        }

        guard !InternalNavigationPolicy.isInternallySupported(scheme: scheme) else {
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
            // An alert is not a promise that one of its actions runs; see WebKitDecisionOnce.
            let decide = WebKitDecisionOnce<WKNavigationActionPolicy>(
                fallback: .cancel,
                handler: decisionHandler
            )
            let alert = UIAlertController(title: "Download File?", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in decide(.cancel) })
            alert.addAction(UIAlertAction(title: "Download", style: .default) { _ in decide(.download) })
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
        // A download for the main frame is the page the user is looking at handing them a file. One
        // for a subframe is an embedded document they may not know exists — a hidden iframe pointed
        // at any non-renderable resource writes a file into Documents/Downloads with no click, no
        // prompt and nothing on screen, because the branch below is silent whenever the size and
        // privacy checks have nothing to say. It is not blocked outright: subframe downloads are a
        // real pattern. It is made visible, which is the part that was missing.
        let confirmation = downloadCoordinator.confirmationMessage(
            expectedBytes: expectedBytes,
            isPrivate: tab?.isPrivate == true
        )
        let subframeNotice = navigationResponse.isForMainFrame
            ? nil
            : "This file was requested by content embedded in the page rather than by the page itself."
        let combined = [subframeNotice, confirmation].compactMap { $0 }.joined(separator: "\n\n")
        guard !combined.isEmpty else {
            decisionHandler(.download)
            return
        }
        let message = combined
        guard tab?.id == tabManager.selectedTabID,
              webView === displayedWebView,
              UIApplication.shared.applicationState == .active,
              presentedViewController == nil else {
            decisionHandler(.cancel)
            return
        }
        let decide = WebKitDecisionOnce<WKNavigationResponsePolicy>(
            fallback: .cancel,
            handler: decisionHandler
        )
        let alert = UIAlertController(title: "Download File?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in decide(.cancel) })
        alert.addAction(UIAlertAction(title: "Download", style: .default) { _ in decide(.download) })
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

    /// - Parameter wasProvisional: true when nothing from this navigation ever committed, so the
    ///   document still on screen belongs to the *previous* URL.
    ///
    /// The rollback runs before the cancellation check, and that ordering is the point. `WKWebView.url`
    /// is the active URL, which during a provisional load is the target rather than what is rendered,
    /// and `didStartProvisionalNavigation` writes it straight into the tab. If that load is then
    /// cancelled — `window.stop()` from a script fifty milliseconds after setting `location.href`, or
    /// the user pressing Stop — WebKit reports NSURLErrorCancelled, nothing commits, and the previous
    /// page stays live under an address bar naming somewhere it never went. With the HTTPS padlock,
    /// because the target's scheme is what the icon was chosen from. Treating cancellation as
    /// "nothing to report" is right for the error view and wrong for the address.
    private func handleNavigationFailure(_ error: Error, webView: WKWebView, wasProvisional: Bool) {
        guard let tab = tabManager.tab(containing: webView) else { return }
        if wasProvisional {
            tabManager.revertToCommittedURL(
                tabID: tab.id,
                committedURL: webView.backForwardList.currentItem?.url
            )
        }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
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
        // `alert()` has a single outcome — the page resumes either way — so the value carried here
        // is ignored and only the call-exactly-once guarantee matters: without it a dialog dismissed
        // from outside leaves the page suspended and WebKit trapping. See WebKitDecisionOnce.
        let decide = WebKitDecisionOnce<Bool>(fallback: false) { _ in completionHandler() }
        let alert = UIAlertController(title: content.title, message: content.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in decide(true) })
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
        let decide = WebKitDecisionOnce<Bool>(fallback: false, handler: completionHandler)
        let alert = UIAlertController(title: content.title, message: content.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in decide(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in decide(true) })
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
        let decide = WebKitDecisionOnce<String?>(fallback: nil, handler: completionHandler)
        let alert = UIAlertController(title: content.title, message: content.message, preferredStyle: .alert)
        alert.addTextField { $0.text = content.defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in decide(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            decide(alert?.textFields?.first?.text.map {
                SafeInput.utf8Prefix($0, maximumByteCount: WebDialogPolicy.maximumDefaultTextByteCount)
            })
        })
        present(alert, animated: true)
    }
}
