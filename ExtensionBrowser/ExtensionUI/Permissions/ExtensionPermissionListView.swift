import SwiftUI

struct ExtensionPermissionListView: View {
    let permissions: [String]

    var body: some View {
        if permissions.isEmpty {
            Label("No additional permissions", systemImage: "checkmark.shield")
                .foregroundStyle(.secondary)
        } else {
            ForEach(permissions, id: \.self) { permission in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: permission.contains("://") || permission == "<all_urls>" ? "globe" : "hand.raised")
                        .foregroundStyle(.blue)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission)
                            .font(.subheadline.weight(.semibold))
                        Text(ExtensionPermissionManager.displayText(for: permission))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
