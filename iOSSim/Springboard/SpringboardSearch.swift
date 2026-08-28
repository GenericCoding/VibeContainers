import SwiftUI

/// Spotlight: swipe down on an icon page and search what is on the device.
///
/// It looks past the home screen on purpose. Installed built-ins that were
/// removed from a page and guests sitting inside a folder are still findable;
/// mock app implementations that are not part of this product configuration
/// do not leak back into the launcher through search.
struct SpringboardSearch: View {
    var onLaunch: (HomeItem) -> Void
    var onOpenFolder: (UUID) -> Void
    var onDismiss: () -> Void

    @State private var query = ""
    @State private var packages = PackageStore.shared
    @State private var layout = HomeLayoutStore.shared
    @State private var containers = GuestContainerStore.shared
    @FocusState private var focused: Bool

    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 14) {
                field

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !applications.isEmpty {
                            section("Applications") {
                                ForEach(applications, id: \.item) { result in
                                    row(result)
                                }
                            }
                        }

                        if !guests.isEmpty {
                            section("Containers") {
                                ForEach(guests, id: \.item) { result in
                                    row(result)
                                }
                            }
                        }

                        if !folders.isEmpty {
                            section("Folders") {
                                ForEach(folders, id: \.item) { result in
                                    row(result)
                                }
                            }
                        }

                        if isEmpty {
                            Text(query.isEmpty
                                 ? "Search apps, containers and folders."
                                 : "Nothing matches “\(query)”.")
                                .font(.system(size: 14))
                                .foregroundStyle(SysColor.secondaryLabel)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }
                    .padding(.bottom, 40)
                }
                // A drag inside the results dismisses the keyboard rather than
                // fighting it for the swipe.
                .scrollDismissesKeyboard(.immediately)
            }
            .padding(.horizontal, 16)
            .padding(.top, safeArea.top + 8)
        }
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SysColor.secondaryLabel)
                TextField("Search", text: $query)
                    .font(.system(size: 17))
                    .foregroundStyle(SysColor.label)
                    .tint(SysColor.blue)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit(launchFirst)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(SysColor.secondaryLabel)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(SysColor.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            Button("Cancel", action: dismiss)
                .font(.system(size: 17))
                .foregroundStyle(SysColor.blue)
        }
    }

    // MARK: - Results

    /// What a hit is, and what opening it does.
    private struct Result {
        let item: HomeItem
        let title: String
        let detail: String
    }

    private var applications: [Result] {
        HomeLayout.builtins
            .filter { matches($0.title) }
            .map { Result(item: .builtin($0), title: $0.title, detail: "Built-in app") }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var guests: [Result] {
        packages.installedList
            .filter { matches($0.name) || matches($0.bundleIdentifier) || matches($0.sourceName) }
            .map { app in
                let ready = containers.container(for: app.bundleIdentifier)
                    .map(containers.hasPayload) ?? false
                return Result(
                    item: .guest(app.bundleIdentifier),
                    title: app.name,
                    detail: ready ? app.bundleIdentifier : "\(app.bundleIdentifier) · no payload"
                )
            }
    }

    private var folders: [Result] {
        layout.folders.values
            .filter { folder in
                matches(folder.name) || folder.items.contains { item in
                    matches(item.builtinApp?.title ?? "")
                        || matches(packages.installed[item.guestBundle ?? ""]?.name ?? "")
                }
            }
            .map { folder in
                Result(item: .folder(folder.id),
                       title: folder.name,
                       detail: "\(folder.items.count) app\(folder.items.count == 1 ? "" : "s")")
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var isEmpty: Bool { applications.isEmpty && guests.isEmpty && folders.isEmpty }

    private func matches(_ text: String) -> Bool {
        guard !query.isEmpty else { return false }
        return text.localizedCaseInsensitiveContains(query)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SysColor.secondaryLabel)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .background(SysColor.secondaryGrouped.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func row(_ result: Result) -> some View {
        Button {
            open(result.item)
        } label: {
            HStack(spacing: 12) {
                icon(for: result.item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.label)
                        .lineLimit(1)
                    Text(result.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Chevron()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func icon(for item: HomeItem) -> some View {
        if let app = item.builtinApp {
            IconArtwork(app: app, size: 40)
        } else if let id = item.folderID, let folder = layout.folder(id) {
            FolderIcon(folder: folder, size: 40)
        } else if let bundle = item.guestBundle {
            PackageIcon(url: packages.installed[bundle]?.iconURL, tint: nil, size: 40)
        }
    }

    // MARK: - Actions

    private func launchFirst() {
        guard let first = applications.first ?? guests.first ?? folders.first else { return }
        open(first.item)
    }

    private func open(_ item: HomeItem) {
        Haptics.tap(.light)
        focused = false
        if let id = item.folderID {
            onDismiss()
            onOpenFolder(id)
        } else {
            onDismiss()
            onLaunch(item)
        }
    }

    private func dismiss() {
        focused = false
        onDismiss()
    }
}
