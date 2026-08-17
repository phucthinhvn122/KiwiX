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
                            Text("Choose a ZIP containing one Manifest V3 extension and its manifest.json file.")
                        },
                        actions: {
                            Button { showsImporter = true } label: {
                                Label("Import Extension from Files", systemImage: "folder.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    )
                } else {
                    List {
                        Section {
                            Button { showsImporter = true } label: {
                                Label("Import Extension from Files", systemImage: "folder.badge.plus")
                            }
                            .disabled(viewModel.isWorking)
                        } footer: {
                            Text("Select a .zip package containing manifest.json.")
                        }

                        Section("Installed") {
                            ForEach(viewModel.extensions) { item in
                                extensionRow(item)
                                    .contentShape(Rectangle())
                                    .onTapGesture { detailExtension = item }
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
            guard let archive = urls.first(where: { $0.pathExtension.lowercased() == "zip" }) else {
                viewModel.errorMessage = "Drop a .zip extension package."
                return false
            }
            viewModel.prepareImport(from: archive)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .task { viewModel.refresh() }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { viewModel.prepareImport(from: url) }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
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
            NavigationStack { ExtensionDetailsView(extensionItem: item) }
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
                let values = try? iconURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= 2 * 1_024 * 1_024 else { return nil }
                guard let data = try? Data(contentsOf: iconURL, options: [.mappedIfSafe]),
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
                    if let description = preview.manifest.description { Text(description) }
                }
                Section("Requested Access") {
                    ExtensionPermissionListView(permissions: preview.requestedPermissions)
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
                ToolbarItem(placement: .confirmationAction) { Button("Install", action: install).disabled(isWorking) }
            }
        }
    }
}

private struct ExtensionDetailsView: View {
    let extensionItem: InstalledExtension
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Extension") {
                LabeledContent("Name", value: extensionItem.metadata.name)
                LabeledContent("Version", value: extensionItem.metadata.version)
                LabeledContent("ID", value: extensionItem.id.rawValue)
                    .textSelection(.enabled)
                if let description = extensionItem.metadata.extensionDescription { Text(description) }
            }
            Section("Permissions") {
                ExtensionPermissionListView(
                    permissions: Array(Set(
                        extensionItem.metadata.requestedPermissions
                            + extensionItem.metadata.hostPermissions
                            + extensionItem.manifest.contentScripts.flatMap(\.matches)
                    )).sorted()
                )
            }
        }
        .navigationTitle("Extension Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
