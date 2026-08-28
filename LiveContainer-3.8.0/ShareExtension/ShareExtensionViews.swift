import SwiftUI
import UIKit

struct ShareExtensionRootView: View {
    @ObservedObject var viewModel: ShareExtensionViewModel
    let extensionContext: NSExtensionContext?

    private let columns = [
        GridItem(.adaptive(minimum: 58, maximum: 70), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let suggested = viewModel.suggestedApps()
                    suggestedSection(apps: suggested, showsInstallAction: viewModel.shouldShowInstallAction())

                    let regular = viewModel.regularApps()
                    let hiddenApps = viewModel.hiddenRegularApps()
                    let showHiddenUnlockButton = viewModel.shouldShowHiddenUnlockButton()

                    if regular.isEmpty && !showHiddenUnlockButton && !(viewModel.hiddenUnlocked && !hiddenApps.isEmpty) {
                        VStack(spacing: 8) {
                            Image(systemName: "app")
                                .font(.system(size: 28))
                            Text("lc.appList.manageInPrimaryTip".loc)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        appGridSection(title: "lc.tabView.apps".loc, apps: regular, includesHiddenUnlockButton: showHiddenUnlockButton)
                    }

                    if viewModel.hiddenUnlocked && !hiddenApps.isEmpty {
                        appGridSection(title: "lc.appList.hiddenApps".loc, apps: hiddenApps)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        viewModel.cancelRequest()
                    }
                }
            }
            .alert("lc.common.error".loc, isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("lc.common.ok".loc) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .navigationTitle(Text("LiveContainer"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func suggestedSection(apps: [ShareApp], showsInstallAction: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("lc.common.suggested".loc)
                .font(.headline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                if showsInstallAction {
                    ShareInstallGridEntry(viewModel: viewModel, extensionContext: extensionContext)
                }
                if apps.isEmpty && !showsInstallAction {
                    ShareSuggestedPlaceholderLabel()
                } else {
                    ForEach(apps) { app in
                        ShareAppGridEntry(app: app, viewModel: viewModel, extensionContext: extensionContext)
                    }
                }
            }
        }
    }

    private func appGridSection(title: String, apps: [ShareApp], includesHiddenUnlockButton: Bool = false) -> some View {
        let regularApps = apps.filter { !$0.isBuiltInSideStore }
        let sideStoreApps = apps.filter { $0.isBuiltInSideStore }
        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(regularApps) { app in
                    ShareAppGridEntry(app: app, viewModel: viewModel, extensionContext: extensionContext)
                }
                ForEach(sideStoreApps) { app in
                    ShareAppGridEntry(app: app, viewModel: viewModel, extensionContext: extensionContext)
                }
                if includesHiddenUnlockButton {
                    ShareHiddenUnlockGridEntry(viewModel: viewModel)
                }
            }
        }
    }
}

private struct ShareSuggestedPlaceholderLabel: View {
    var body: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 52 * 0.2667, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 52, height: 52)
            Text(" ")
                .font(.caption)
                .frame(width: 64, height: 32, alignment: .top)
        }
        .frame(width: 64)
        .accessibilityHidden(true)
    }
}

private struct ShareHiddenUnlockGridEntry: View {
    @ObservedObject var viewModel: ShareExtensionViewModel

    var body: some View {
        Button {
            Task { await viewModel.unlockHiddenApps() }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 52 * 0.2667, style: .continuous))
                Text(" ")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(width: 64, height: 32, alignment: .top)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
    }
}

private struct ShareAppGridEntry: View {
    let app: ShareApp
    @ObservedObject var viewModel: ShareExtensionViewModel
    let extensionContext: NSExtensionContext?

    var body: some View {
        if app.containers.count > 1 {
            NavigationLink {
                ShareContainerSelectionView(app: app, viewModel: viewModel, extensionContext: extensionContext)
            } label: {
                ShareAppGridLabel(app: app)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                Task { await viewModel.launch(app: app, context: extensionContext) }
            } label: {
                ShareAppGridLabel(app: app)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ShareAppGridLabel: View {
    let app: ShareApp

    var body: some View {
        VStack(spacing: 7) {
            ShareAppIconView(iconURL: app.iconURL)
                .frame(width: 52, height: 52)
            Text(app.displayName)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(.primary)
                .frame(width: 64, height: 32, alignment: .top)
        }
        .frame(width: 64)
    }
}

private struct ShareInstallGridEntry: View {
    @ObservedObject var viewModel: ShareExtensionViewModel
    let extensionContext: NSExtensionContext?

    var body: some View {
        Button {
            Task { await viewModel.installSharedFileInLiveContainer(context: extensionContext) }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.primary)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 52 * 0.2667, style: .continuous))
                Text("lc.common.install".loc)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .frame(width: 64, height: 32, alignment: .top)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
    }
}

private struct ShareAppIconView: View {
    let iconURL: URL?

    var body: some View {
        GeometryReader { geometry in
            if let iconURL, let image = UIImage(contentsOfFile: iconURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: geometry.size.width * 0.2667, style: .continuous))
            } else {
                Image(systemName: "app")
                    .font(.system(size: geometry.size.width * 0.56))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: geometry.size.width * 0.2667, style: .continuous))
            }
        }
    }
}

private struct ShareContainerSelectionView: View {
    let app: ShareApp
    @ObservedObject var viewModel: ShareExtensionViewModel
    let extensionContext: NSExtensionContext?

    var body: some View {
        List {
            ForEach(app.containers) { container in
                Button {
                    Task { await viewModel.launch(app: app, container: container, context: extensionContext) }
                } label: {
                    HStack(spacing: 12) {
                        ShareAppIconView(iconURL: app.iconURL)
                            .frame(width: 36, height: 36)
                        Text(container.name)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(app.displayName)
    }
}
