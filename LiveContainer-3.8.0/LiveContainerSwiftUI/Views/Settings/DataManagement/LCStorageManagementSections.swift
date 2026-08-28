import SwiftUI

private enum LCStorageSummaryCategory {
    case appBundle
    case containers
    case appGroup
    case tweaks
    case temporaryFiles
    case other
}

private struct LCStorageSummaryDisplayItem: Identifiable {
    let category: LCStorageSummaryCategory
    let size: Int64

    var id: LCStorageSummaryCategory { category }

    var title: String {
        switch category {
        case .appBundle:
            return "lc.storage.appBundle".loc
        case .containers:
            return "lc.storage.containers".loc
        case .appGroup:
            return "lc.storage.appGroupData".loc
        case .tweaks:
            return "lc.storage.tweaks".loc
        case .temporaryFiles:
            return "lc.storage.temporaryFiles".loc
        case .other:
            return "lc.storage.other".loc
        }
    }

    var color: Color {
        switch category {
        case .appBundle:
            return .blue
        case .containers:
            return .green
        case .appGroup:
            return .purple
        case .tweaks:
            return .pink
        case .temporaryFiles:
            return .orange
        case .other:
            return .gray
        }
    }
}

private struct LCStorageSummaryBarView: View {
    let items: [LCStorageSummaryDisplayItem]

    private var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        if totalSize > 0 {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(items) { item in
                        Rectangle()
                            .fill(item.color)
                            .frame(width: segmentWidth(for: item, totalWidth: geometry.size.width))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
    }

    private func segmentWidth(for item: LCStorageSummaryDisplayItem, totalWidth: CGFloat) -> CGFloat {
        guard totalSize > 0 else { return 0 }

        let spacing: CGFloat = 2
        let totalSpacing = max(0, CGFloat(items.count - 1) * spacing)
        let availableWidth = max(0, totalWidth - totalSpacing)

        return max(0, availableWidth * CGFloat(item.size) / CGFloat(totalSize))
    }
}

struct LCStorageSummarySection: View {
    let breakdown: LCStorageBreakdown?
    let isCalculating: Bool
    let errorInfo: String?

    var body: some View {
        Section("lc.storage.totalStorage".loc) {
            VStack(alignment: .leading, spacing: 12) {
                if isCalculating {
                    HStack {
                        Spacer()
                        ProgressView("lc.storage.calculating".loc)
                            .controlSize(.regular)
                        Spacer()
                    }
                }

                if let breakdown {
                    Text(formatStorageSize(breakdown.totalSize))
                        .font(.title2)
                        .fontWeight(.semibold)
                }

                if let errorInfo {
                    Text(errorInfo)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let breakdown {
                    let displayItems = self.displayItems

                    if !displayItems.isEmpty {
                        LCStorageSummaryBarView(items: displayItems)
                            .padding(.top, 2)
                    }

                    // Keep the larger category set flattened into one settings-style summary so total-first scanning still works.
                    VStack(spacing: 0) {
                        // Hide zero-sized categories to keep the expanded summary readable even with the larger category set.
                        ForEach(displayItems) { item in
                            storageRow(title: item.title, size: item.size, color: item.color)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var displayItems: [LCStorageSummaryDisplayItem] {
        guard let breakdown else {
            return []
        }

        var items: [LCStorageSummaryDisplayItem] = []

        if breakdown.appBundleSize > 0 {
            items.append(
                LCStorageSummaryDisplayItem(
                    category: .appBundle,
                    size: breakdown.appBundleSize
                )
            )
        }

        if breakdown.containersSize > 0 {
            items.append(
                LCStorageSummaryDisplayItem(
                    category: .containers,
                    size: breakdown.containersSize
                )
            )
        }

        if breakdown.temporaryFilesSize > 0 {
            items.append(
                LCStorageSummaryDisplayItem(
                    category: .temporaryFiles,
                    size: breakdown.temporaryFilesSize
                )
            )
        }

        if breakdown.appGroupSize > 0 {
            items.append(
                LCStorageSummaryDisplayItem(
                    category: .appGroup,
                    size: breakdown.appGroupSize
                )
            )
        }

        if breakdown.tweaksSize > 0 {
            items.append(
                LCStorageSummaryDisplayItem(
                    category: .tweaks,
                    size: breakdown.tweaksSize
                )
            )
        }

        // Treat Other as the residual bucket now that more explicit categories are broken out above.
        if breakdown.otherSize > 0 {
            items.append(
                LCStorageSummaryDisplayItem(
                    category: .other,
                    size: breakdown.otherSize
                )
            )
        }

        return items
    }

    @ViewBuilder
    private func storageRow(title: String, size: Int64, color: Color?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color ?? .clear)
                    .frame(width: 8, height: 8)
                    .opacity(color == nil ? 0 : 1)
                    .accessibilityHidden(true)

                Text(title)
            }

            Spacer(minLength: 12)

            Text(formatStorageSize(size))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }
}

struct LCInstalledAppsSection: View {
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    let breakdown: LCStorageBreakdown?

    var body: some View {
        Section("lc.storage.installedApps".loc) {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let breakdown {
            if breakdown.appItems.isEmpty {
                Text("lc.storage.noAppStorageData".loc)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(breakdown.appItems, id: \.id) { appItem in
                    appRow(appItem)
                }
            }
        }
    }

    private func appRow(_ appItem: LCAppStorageItem) -> some View {
        NavigationLink {
            LCAppStorageDetailView(appItem: appItem)
        } label: {
            HStack(spacing: 12) {
                IconImageView(icon: appItem.appModel.appInfo.iconIsDarkIcon(darkModeIcon))
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appItem.appModel.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let lastUsedAt = appItem.appModel.appInfo.lastLaunched {
                        Text("lc.appList.sort.lastLaunched".loc + ": \(formatStorageDate(lastUsedAt))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer()

                Text(formatStorageSize(appItem.totalSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LCAppStorageSummaryHeaderView: View {
    let appItem: LCAppStorageItem

    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 58
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            IconImageView(icon: appItem.appModel.appInfo.iconIsDarkIcon(darkModeIcon))
                .frame(width: iconSize, height: iconSize)

            VStack(alignment: .leading) {
                Text(appItem.appModel.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(appItem.appModel.version)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let bundleIdentifier = appItem.appModel.appInfo.bundleIdentifier() {
                    Text(bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding([.leading], 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

private struct LCAppStorageDetailView: View {
    let appItem: LCAppStorageItem

    var body: some View {
        Form {
            Section {
                LCAppStorageSummaryHeaderView(appItem: appItem)

                if let bundleSize = appItem.bundleSize {
                    HStack(spacing: 12) {
                        Text("lc.storage.appBundle".loc)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 12)

                        Text(formatStorageSize(bundleSize))
                            .strikethrough(appItem.appModel.appInfo is BuiltInSideStoreAppInfo)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 12) {
                    Text("lc.storage.containers".loc)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 12)

                    Text(formatStorageSize(appItem.containersSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

            }

            if !appItem.containerDetails.isEmpty {
                Section("lc.storage.containers".loc) {
                    ForEach(appItem.containerDetails, id: \.id) { container in
                        appContainerRow(container)
                    }
                }
            }
        }
        .navigationTitle(appItem.appModel.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func appContainerRow(_ container: LCAppStorageContainerItem) -> some View {
    HStack(spacing: 12) {
        Text(container.name)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)

        Spacer(minLength: 12)

        Text(formatStorageSize(container.size))
            .strikethrough(container.isExternalContainer)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
    .padding(.vertical, 2)
}

private func formatStorageDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter.string(from: date)
}

private func formatStorageSize(_ size: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
}
