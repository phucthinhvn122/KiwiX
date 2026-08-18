import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct ExtensionManagerView: View {
    @StateObject private var viewModel: ExtensionManagerViewModel
    @State private var showsImporter = false
    @State private var isDropTargeted = false
    @State private var detailExtension: InstalledExtension?
    @State private var pendingRemoval: InstalledExtension?
    @Environment(\.dismiss) private var dismiss

    init(repository: ExtensionRepository, installer: ExtensionInstaller) {
        _viewModel = StateObject(wrappedValue: ExtensionManagerViewModel(
            repository: repository,
            installer: installer
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.extensions.isEmpty && !viewModel.isWorking {
                    ContentUnavailableView(
                        label: {
                            Label("No Extensions", systemImage: "puzzlepiece.extension")
                        },
                        description: {
                            Text("Choose a ZIP or folder containing one Manifest V3 extension and its manifest.json file.")
                        },
                        actions: {
                            Button { showsImporter = true } label: {
                                Label("Import ZIP or Folder", systemImage: "folder.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    )
                } else {
                    List {
                        Section {
                            Button { showsImporter = true } label: {
                                Label("Import ZIP or Folder", systemImage: "folder.badge.plus")
                            }
                            .disabled(viewModel.isWorking)
                        } footer: {
                            Text("Select a ZIP or an unpacked extension folder containing manifest.json.")
                        }

                        Section("Installed") {
                            ForEach(viewModel.extensions) { item in
                                extensionRow(item)
                                    .contentShape(Rectangle())
                                    .onTapGesture { detailExtension = item }
                                    .accessibilityAction(named: "Show Details") {
                                        detailExtension = item
                                    }
                                    .swipeActions {
                                        Button(role: .destructive) { pendingRemoval = item } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Extensions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsImporter = true } label: {
                        Label("Import Extension", systemImage: "plus")
                    }
                    .disabled(viewModel.isWorking)
                }
            }
            .overlay {
                if viewModel.isWorking {
                    ProgressView("Validating Extension…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .tint(Color(uiColor: KiwiTheme.accentDeep))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Color(uiColor: KiwiTheme.accentDeep), style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let package = urls.first(where: isSupportedPackage) else {
                viewModel.errorMessage = "Drop a ZIP or extension folder containing manifest.json."
                return false
            }
            viewModel.prepareImport(from: package)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .task { viewModel.refresh() }
        .sheet(isPresented: $showsImporter) {
            ExtensionPackageDocumentPicker { packageURL in
                showsImporter = false
                guard let packageURL else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    viewModel.prepareImport(from: packageURL)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $viewModel.pendingPreview, onDismiss: {
            if viewModel.pendingPreview != nil { viewModel.cancelImport() }
        }) { preview in
            ExtensionImportConfirmationView(
                preview: preview,
                isWorking: viewModel.isWorking,
                cancel: viewModel.cancelImport,
                install: viewModel.confirmImport
            )
            .interactiveDismissDisabled(true)
        }
        .sheet(item: $detailExtension) { item in
            NavigationStack {
                ExtensionDetailsView(extensionID: item.id, viewModel: viewModel)
            }
        }
        .alert("Extension Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            "Remove this extension and its local data?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Extension", role: .destructive) {
                if let item = pendingRemoval { viewModel.remove(extensionID: item.id) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        }
    }

    private func isSupportedPackage(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "zip" { return true }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    @ViewBuilder
    private func extensionRow(_ item: InstalledExtension) -> some View {
        HStack(spacing: 12) {
            ExtensionIconView(extensionItem: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.metadata.name).font(.headline)
                Text("Version \(item.metadata.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { item.metadata.isEnabled },
                set: { viewModel.setEnabled($0, extensionID: item.id) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 3)
    }
}

private struct ExtensionPackageDocumentPicker: UIViewControllerRepresentable {
    let onSelection: (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.zip, .folder, .data],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelection: (URL?) -> Void
        private var hasCompleted = false

        init(onSelection: @escaping (URL?) -> Void) {
            self.onSelection = onSelection
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            complete(with: urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            complete(with: nil)
        }

        private func complete(with url: URL?) {
            guard !hasCompleted else { return }
            hasCompleted = true
            onSelection(url)
        }
    }
}

private struct ExtensionIconView: View {
    let extensionItem: InstalledExtension
    @State private var imageData: Data?

    private var iconURL: URL? {
        let paths = extensionItem.manifest.icons
        let selected = paths.max { lhs, rhs in
            (Int(lhs.key) ?? 0) < (Int(rhs.key) ?? 0)
        }?.value
        let fallback: String?
        switch extensionItem.manifest.action?.defaultIcon {
        case .some(.path(let path)): fallback = path
        case .some(.sized(let sized)):
            fallback = sized.max { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }?.value
        case .none: fallback = nil
        }
        guard let path = selected ?? fallback else { return nil }
        return try? ExtensionResourcePath.containedURL(for: path, under: extensionItem.filesURL)
    }

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title2)
                    .foregroundStyle(Color(uiColor: KiwiTheme.accentDeep))
                    .padding(7)
                    .background(Color(uiColor: KiwiTheme.accent).opacity(0.14))
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .task(id: iconURL) {
            guard let iconURL else {
                imageData = nil
                return
            }
            imageData = await Task.detached(priority: .utility) {
                guard let data = try? BoundedFileReader.read(
                        from: iconURL,
                        maximumByteCount: 2 * 1_024 * 1_024
                      ),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                        as? [CFString: Any],
                      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                      width > 0, height > 0,
                      width <= 1_024, height <= 1_024,
                      width * height <= 1_048_576 else { return nil }
                return data
            }.value
        }
        .accessibilityHidden(true)
    }
}

private struct ExtensionImportConfirmationView: View {
    let preview: ExtensionPackagePreview
    let isWorking: Bool
    let cancel: () -> Void
    let install: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Extension") {
                    LabeledContent("Name", value: preview.manifest.name)
                    LabeledContent("Version", value: preview.manifest.version)
                    LabeledContent("Extension ID", value: preview.id.rawValue)
                        .textSelection(.enabled)
                    if let description = preview.manifest.description { Text(description) }
                }
                Section("Security & Provenance") {
                    Label("Unverified extension", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.red)
                        .font(.headline)
                    LabeledContent("Publisher", value: "Not verified")
                    LabeledContent("Source", value: preview.sourceDescription)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Package SHA-256").font(.caption).foregroundStyle(.secondary)
                        Text(preview.packageDigest).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text("The package hash identifies these exact files; it does not verify who published them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Requested Browser Permissions") {
                    ExtensionPermissionListView(permissions: preview.manifest.permissions)
                }
                Section("Requested Websites") {
                    let websites = Array(Set(
                        preview.manifest.hostPermissions + preview.manifest.contentScripts.flatMap(\.matches)
                    )).sorted()
                    if websites.isEmpty {
                        Text("No website access requested").foregroundStyle(.secondary)
                    } else {
                        ExtensionPermissionListView(permissions: websites)
                    }
                    if websites.contains("<all_urls>") {
                        Label(
                            "Requests access to read and change data on all websites. This access is off until you enable it in Extension Details.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)
                        .font(.footnote)
                    }
                }
                Section {
                    Text("Only JavaScript, HTML, CSS, and other web resources run. Native binaries and unsafe ZIP paths are rejected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Confirm Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel).disabled(isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install", action: install).disabled(isWorking)
                }
            }
        }
    }
}

private struct ExtensionDetailsView: View {
    private enum WebsiteAccessScope: String, CaseIterable, Identifiable {
        case ask
        case current
        case selected
        case all

        var id: String { rawValue }
        var label: String {
            switch self {
            case .ask: return "Ask"
            case .current: return "Current Website"
            case .selected: return "Selected Websites"
            case .all: return "All Requested Websites"
            }
        }
    }

    let extensionID: ExtensionIdentifier
    @ObservedObject var viewModel: ExtensionManagerViewModel
    @State private var pendingAllWebsitesGrant = false
    @State private var selectedHostname = ""
    @State private var keepsSelectedWebsiteEditorOpen = false
    @Environment(\.dismiss) private var dismiss

    private var extensionItem: InstalledExtension? {
        viewModel.extensions.first(where: { $0.id == extensionID })
    }

    private var requestsAllWebsites: Bool {
        guard let extensionItem else { return false }
        return extensionItem.manifest.hostPermissions.contains("<all_urls>")
            || extensionItem.manifest.contentScripts.flatMap(\.matches).contains("<all_urls>")
    }

    var body: some View {
        Group {
            if let extensionItem {
                List {
                    Section("Extension") {
                        LabeledContent("Name", value: extensionItem.metadata.name)
                        LabeledContent("Version", value: extensionItem.metadata.version)
                        LabeledContent("ID", value: extensionItem.id.rawValue)
                            .textSelection(.enabled)
                        LabeledContent("Publisher", value: "Not verified")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Package SHA-256").font(.caption).foregroundStyle(.secondary)
                            Text(extensionItem.metadata.packageDigest)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        if let description = extensionItem.metadata.extensionDescription { Text(description) }
                    }
                    capabilitySection(extensionItem)
                    websiteAccessSection(extensionItem)
                }
            } else {
                ContentUnavailableView("Extension Not Found", systemImage: "puzzlepiece.extension")
            }
        }
        .navigationTitle("Extension Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .confirmationDialog(
            "Allow access to all websites?",
            isPresented: Binding(
                get: { pendingAllWebsitesGrant },
                set: { pendingAllWebsitesGrant = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button(requestsAllWebsites ? "Allow on All Websites" : "Allow on All Requested Websites", role: .destructive) {
                keepsSelectedWebsiteEditorOpen = false
                viewModel.replaceHostPermissions(grantAllDeclared: true, extensionID: extensionID)
                pendingAllWebsitesGrant = false
            }
            Button("Cancel", role: .cancel) { pendingAllWebsitesGrant = false }
        } message: {
            Text(requestsAllWebsites
                ? "This lets the extension read and change data on every website you visit. You can revoke it here at any time."
                : "This enables every website pattern requested by the extension. You can revoke them here at any time.")
        }
    }

    @ViewBuilder
    private func capabilitySection(_ item: InstalledExtension) -> some View {
        Section("Browser Permissions") {
            if item.manifest.permissions.isEmpty {
                Text("No browser permissions requested").foregroundStyle(.secondary)
            }
            ForEach(item.manifest.permissions, id: \.self) { permission in
                if let capability = ExtensionCapability(rawValue: permission) {
                    Toggle(isOn: Binding(
                        get: { item.metadata.grantedPermissions.contains(permission) },
                        set: {
                            viewModel.setCapability(capability, granted: $0, extensionID: item.id)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permissionLabel(permission))
                            Text(ExtensionPermissionManager.displayText(for: permission))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func websiteAccessSection(_ item: InstalledExtension) -> some View {
        let declaredPatterns = Array(Set(
            item.manifest.hostPermissions + item.manifest.contentScripts.flatMap(\.matches)
        )).sorted()
        let selectedHosts = Array(Set(item.metadata.grantedHostPermissions.compactMap {
            try? WebExtensionMatchPattern($0).exactHostname
        })).sorted()
        Section {
            if declaredPatterns.isEmpty {
                Text("No website access requested").foregroundStyle(.secondary)
            } else {
                Picker("Website Access", selection: Binding(
                    get: { websiteAccessScope(for: item, declaredPatterns: declaredPatterns) },
                    set: { scope in setWebsiteAccessScope(scope, for: item) }
                )) {
                    ForEach(WebsiteAccessScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.inline)

                if websiteAccessScope(for: item, declaredPatterns: declaredPatterns) == .current {
                    LabeledContent("Allowed Website", value: viewModel.currentWebsiteHostname ?? "Unavailable")
                }

                if websiteAccessScope(for: item, declaredPatterns: declaredPatterns) == .selected {
                    ForEach(selectedHosts, id: \.self) { hostname in
                        HStack {
                            Label(hostname, systemImage: "checkmark.shield")
                            Spacer()
                            Button("Remove", role: .destructive) {
                                viewModel.setWebsitePermission(hostname, granted: false, extensionID: item.id)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("example.com", text: $selectedHostname)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.done)
                            .onSubmit { addSelectedWebsite(to: item) }
                        Button("Add") { addSelectedWebsite(to: item) }
                            .disabled(selectedHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Only websites covered by this extension's declared access can be added.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if declaredPatterns.contains("<all_urls>") {
                    Label("All Websites includes every site you visit and requires a separate warning before it is enabled.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Website Access")
        } footer: {
            Text("Ask keeps persistent website access off. Invoking an extension with Current Tab permission grants one-time access until navigation. Revocation applies immediately to future scripts and API calls.")
        }
    }

    private func websiteAccessScope(
        for item: InstalledExtension,
        declaredPatterns: [String]
    ) -> WebsiteAccessScope {
        if keepsSelectedWebsiteEditorOpen { return .selected }
        let grants = Set(item.metadata.grantedHostPermissions)
        guard !grants.isEmpty else { return .ask }
        if grants == Set(declaredPatterns) { return .all }
        let hosts = Set(grants.compactMap { try? WebExtensionMatchPattern($0).exactHostname })
        if hosts.count == 1, hosts.first == viewModel.currentWebsiteHostname { return .current }
        return .selected
    }

    private func setWebsiteAccessScope(_ scope: WebsiteAccessScope, for item: InstalledExtension) {
        switch scope {
        case .ask:
            keepsSelectedWebsiteEditorOpen = false
            viewModel.replaceHostPermissions(grantAllDeclared: false, extensionID: item.id)
        case .current:
            keepsSelectedWebsiteEditorOpen = false
            guard let hostname = viewModel.currentWebsiteHostname else {
                viewModel.errorMessage = "Open a normal HTTP or HTTPS page before allowing the current website."
                return
            }
            viewModel.replaceHostPermissions(withWebsiteHostname: hostname, extensionID: item.id)
        case .selected:
            let declared = Set(
                item.manifest.hostPermissions + item.manifest.contentScripts.flatMap(\.matches)
            )
            let wasAll = Set(item.metadata.grantedHostPermissions) == declared
            keepsSelectedWebsiteEditorOpen = true
            if wasAll {
                viewModel.replaceHostPermissions(grantAllDeclared: false, extensionID: item.id)
            }
        case .all:
            keepsSelectedWebsiteEditorOpen = false
            pendingAllWebsitesGrant = true
        }
    }

    private func addSelectedWebsite(to item: InstalledExtension) {
        let hostname = selectedHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else { return }
        selectedHostname = ""
        viewModel.setWebsitePermission(hostname, granted: true, extensionID: item.id)
    }

    private func permissionLabel(_ permission: String) -> String {
        switch permission {
        case "activeTab": return "Current Tab When Invoked"
        case "storage": return "Extension Storage"
        case "tabs": return "Browser Tabs"
        case "scripting": return "Run Scripts"
        default: return permission
        }
    }
}
