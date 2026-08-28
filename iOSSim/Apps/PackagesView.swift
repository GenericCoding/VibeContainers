import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

/// Settings → ★ Applications. A small store front over AltStore-format
/// sources: five tabs, per-app pages built from whatever the repo publishes,
/// and a local installed record that also takes plain `.ipa` files.
///
/// iOSSim is not connected to AltStore in any way — it only reads the same
/// public JSON shape. `IndependenceNotice` says so at the bottom of every tab.
struct PackagesView: View {
    var onBack: () -> Void

    @State private var store = PackageStore.shared
    @State private var tab = 0
    @State private var stack: [Screen] = []
    @State private var query = ""
    @State private var showAddSource = false
    @State private var didLoad = false

    @Environment(\.deviceSafeArea) private var safeArea

    private enum Screen: Equatable {
        case source(UUID)
        case app(String)
        case guest(String)
    }

    private static let tabs = [
        TabItem(title: "Home", symbol: "house.fill"),
        TabItem(title: "Browse", symbol: "square.grid.2x2.fill"),
        TabItem(title: "Search", symbol: "magnifyingglass"),
        TabItem(title: "Sources", symbol: "tray.full.fill"),
        TabItem(title: "Installed", symbol: "arrow.down.circle.fill")
    ]

    var body: some View {
        ZStack(alignment: .top) {
            SysColor.groupedBackground.ignoresSafeArea()

            content
                .padding(.top, safeArea.top + 60)

            navBar

            AppTabBar(items: Self.tabs, selection: tabBinding)
                .frame(maxHeight: .infinity, alignment: .bottom)

            if showAddSource {
                AddSourceDialog(
                    store: store,
                    onClose: { withAnimation(.easeOut(duration: 0.18)) { showAddSource = false } }
                )
                .zIndex(3)
            }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await store.refreshAll()

        }
    }

    /// Switching tabs always returns to that tab's root.
    private var tabBinding: Binding<Int> {
        Binding(get: { tab }, set: { newValue in
            withAnimation(.easeOut(duration: 0.15)) {
                stack.removeAll()
                tab = newValue
            }
        })
    }

    // MARK: - Chrome

    private var navBar: some View {
        InlineNavBar(title: title, backTitle: backTitle, onBack: back) {
            if stack.isEmpty && tab == 3 {
                Button {
                    Haptics.tap(.light)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { showAddSource = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SysColor.blue)
                }
            }
        }
    }

    private var title: String {
        switch stack.last {
        case .source(let id): store.sources.first { $0.id == id }?.displayName ?? "Source"
        case .app(let id): store.entry(id: id)?.app.name ?? "App"
        case .guest(let bundle): store.installed[bundle]?.name ?? "LiveContainer"
        case nil: tab == 0 ? "★ Applications" : Self.tabs[tab].title
        }
    }

    private var backTitle: String {
        switch stack.count {
        case 0: "Settings"
        case 1: Self.tabs[tab].title
        default: "Back"
        }
    }

    private func back() {
        if stack.isEmpty {
            onBack()
        } else {
            withAnimation(.appClose) { _ = stack.popLast() }
        }
    }

    private func push(_ screen: Screen) {
        withAnimation(.appLaunch) { stack.append(screen) }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        let bottomInset = safeArea.bottom + 78

        switch stack.last {
        case .guest(let bundle):
            GuestContainerView(bundleIdentifier: bundle, onClose: back)
        case .app(let id):
            if let entry = store.entry(id: id) {
                AppDetailPage(entry: entry, store: store, bottomInset: bottomInset) {
                    push(.guest($0))
                }
            }
        case .source(let id):
            if let source = store.sources.first(where: { $0.id == id }) {
                SourceDetailPage(source: source, store: store, bottomInset: bottomInset) { entry in
                    push(.app(entry.id))
                }
            }
        case nil:
            switch tab {
            case 1:
                BrowseTab(store: store, bottomInset: bottomInset) { push(.app($0.id)) }
            case 2:
                SearchTab(store: store, query: $query, bottomInset: bottomInset) { push(.app($0.id)) }
            case 3:
                SourcesTab(
                    store: store,
                    bottomInset: bottomInset,
                    openSource: { push(.source($0.id)) },
                    addSource: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { showAddSource = true }
                    }
                )
            case 4:
                InstalledTab(store: store, bottomInset: bottomInset) {
                    push(.guest($0.bundleIdentifier))
                }
            default:
                HomeTab(store: store, bottomInset: bottomInset,
                        openApp: { push(.app($0.id)) },
                        seeAll: { withAnimation(.easeOut(duration: 0.15)) { tab = 1 } })
            }
        }
    }
}

// MARK: - Home

private struct HomeTab: View {
    let store: PackageStore
    let bottomInset: CGFloat
    var openApp: (PackageStore.Entry) -> Void
    var seeAll: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if store.allApps.isEmpty {
                    EmptyNotice(symbol: "shippingbox",
                                title: "No sources loaded",
                                detail: "Add a source to start browsing packages.")
                        .padding(.top, 40)
                } else {
                    updatesStrip
                    featuredStrip
                    recentList

                    Text("\(store.allApps.count) apps across \(store.sources.count) sources")
                        .font(.system(size: 13))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .frame(maxWidth: .infinity)
                }

                IndependenceNotice()
            }
            .padding(.bottom, bottomInset)
        }
    }

    @ViewBuilder private var updatesStrip: some View {
        if !store.updates.isEmpty {
            SectionHeader(title: "Updates Available")
            VStack(spacing: 0) {
                ForEach(Array(store.updates.enumerated()), id: \.element.id) { index, pending in
                    AppRow(
                        title: pending.app.name,
                        subtitle: "\(pending.installed.version) → \(pending.app.latestVersion)",
                        iconURL: pending.app.iconURL,
                        tint: pending.app.tintColor,
                        last: index == store.updates.count - 1,
                        action: store.action(
                            for: pending.app,
                            sourceName: pending.sourceName
                        )
                    )
                }
            }
            .cardBackground()
        }
    }

    @ViewBuilder private var featuredStrip: some View {
        if !store.featured.isEmpty {
            SectionHeader(title: "Featured")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(store.featured) { entry in
                        FeatureCard(entry: entry, store: store) { openApp(entry) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var recentList: some View {
        let recent = Array(store.recentlyUpdated.prefix(6))
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recently Updated", action: ("See All", seeAll))
            VStack(spacing: 0) {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                    AppRow(
                        title: entry.app.name,
                        subtitle: subtitle(entry),
                        iconURL: entry.app.iconURL,
                        tint: entry.app.tintColor,
                        last: index == recent.count - 1,
                        action: store.action(for: entry),
                        onOpen: { openApp(entry) }
                    )
                }
            }
            .cardBackground()
        }
    }

    private func subtitle(_ entry: PackageStore.Entry) -> String {
        var parts = [entry.app.developer, entry.app.latestVersion]
        if let date = PackageFormat.date(entry.app.latestDate) { parts.append(date) }
        return parts.joined(separator: " · ")
    }
}

private struct FeatureCard: View {
    let entry: PackageStore.Entry
    let store: PackageStore
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        PackageIcon(url: entry.app.iconURL, tint: entry.app.tintColor, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.app.name)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(SysColor.label)
                                .lineLimit(1)
                            Text(entry.app.developer)
                                .font(.system(size: 13))
                                .foregroundStyle(SysColor.secondaryLabel)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }

                    Text(entry.app.blurb)
                        .font(.system(size: 14))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Keep the install control a sibling of the detail button. Nested
            // SwiftUI buttons can dispatch both actions from one GET tap.
            ActionPill(action: store.action(for: entry), onOpen: open)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(SysColor.secondaryGrouped)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Browse

private struct BrowseTab: View {
    let store: PackageStore
    let bottomInset: CGFloat
    var openApp: (PackageStore.Entry) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.allApps.isEmpty {
                    EmptyNotice(symbol: "square.grid.2x2",
                                title: "Nothing to browse",
                                detail: "Add a source first.")
                        .padding(.top, 40)
                } else {
                    ForEach(store.categories) { group in
                        ListSection(header: "\(group.name) · \(group.entries.count)") {
                            ForEach(group.entries) { entry in
                                AppRow(
                                    title: entry.app.name,
                                    subtitle: "\(entry.app.developer) · \(entry.sourceName)",
                                    iconURL: entry.app.iconURL,
                                    tint: entry.app.tintColor,
                                    last: entry.id == group.entries.last?.id,
                                    action: store.action(for: entry),
                                    onOpen: { openApp(entry) }
                                )
                            }
                        }
                    }
                }

                IndependenceNotice()
            }
            .padding(.bottom, bottomInset)
        }
    }
}

// MARK: - Search

private struct SearchTab: View {
    let store: PackageStore
    @Binding var query: String
    let bottomInset: CGFloat
    var openApp: (PackageStore.Entry) -> Void

    @State private var results: [PackageStore.Entry] = []
    @State private var searching = false

    private struct Request: Hashable {
        let query: String
        let catalogGeneration: Int
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                SearchField(text: $query, placeholder: "Apps, developers, sources")
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)

                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ListSection(header: "Categories") {
                        ForEach(store.categories) { group in
                            ListRow(showsSeparator: group.id != store.categories.last?.id,
                                    separatorInset: 16,
                                    action: { query = group.name }) {
                                Text(group.name)
                                    .font(.system(size: 17))
                                    .foregroundStyle(SysColor.label)
                            } trailing: {
                                Text("\(group.entries.count)")
                                    .font(.system(size: 15))
                                    .foregroundStyle(SysColor.secondaryLabel)
                            }
                        }
                    }
                } else if searching {
                    ProgressView()
                        .padding(.top, 32)
                } else if results.isEmpty {
                    EmptyNotice(symbol: "magnifyingglass",
                                title: "No results",
                                detail: "Nothing in your sources matches “\(query)”.")
                        .padding(.top, 30)
                } else {
                    ListSection(header: "\(results.count) results") {
                        ForEach(results) { entry in
                            AppRow(
                                title: entry.app.name,
                                subtitle: "\(entry.app.developer) · \(entry.sourceName)",
                                iconURL: entry.app.iconURL,
                                tint: entry.app.tintColor,
                                last: entry.id == results.last?.id,
                                action: store.action(for: entry),
                                onOpen: { openApp(entry) }
                            )
                        }
                    }
                }
            }
            .padding(.bottom, bottomInset)
        }
        .task(id: Request(query: query, catalogGeneration: store.catalogGeneration)) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                results = []
                searching = false
                return
            }

            searching = true
            do {
                // Avoid starting a full catalogue scan for every intermediate
                // keystroke when someone types quickly.
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            let matches = await store.search(trimmed)
            guard !Task.isCancelled else { return }
            results = matches
            searching = false
        }
    }
}

// MARK: - Sources

private struct SourcesTab: View {
    let store: PackageStore
    let bottomInset: CGFloat
    var openSource: (PackageStore.Source) -> Void
    var addSource: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ListSection(footer: "AltStore sources are JSON. A GitHub page link is rewritten to its raw file automatically.") {
                    ForEach(Array(store.sources.enumerated()), id: \.element.id) { index, source in
                        SourceRow(
                            source: source,
                            state: state(for: source),
                            last: index == store.sources.count - 1,
                            open: { openSource(source) },
                            remove: { withAnimation(.snappy) { store.removeSource(source) } }
                        )
                    }
                }

                ListSection {
                    ListRow(showsSeparator: false, separatorInset: 16, action: addSource) {
                        Label("Add Source", systemImage: "plus.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.blue)
                            .padding(.vertical, 2)
                    }
                }

                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("Refresh All Sources", systemImage: "arrow.clockwise")
                        .font(.system(size: 17))
                        .foregroundStyle(SysColor.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(SysColor.secondaryGrouped)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)

                IndependenceNotice()
            }
            .padding(.bottom, bottomInset)
        }
    }

    private func state(for source: PackageStore.Source) -> SourceRow.State {
        if store.loading.contains(source.id) { return .loading }
        if let error = store.failures[source.id] { return .failed(error) }
        if let catalog = store.catalogs[source.id] { return .loaded(catalog.apps.count) }
        return .idle
    }
}

// MARK: - Installed

private struct InstalledTab: View {
    let store: PackageStore
    let bottomInset: CGFloat
    var openGuest: (PackageStore.InstalledApp) -> Void

    @State private var installer = GuestInstaller.shared
    @State private var picking = false
    @State private var askingForURL = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                sideloadSection
                if !store.updates.isEmpty {
                    ListSection(header: "Updates Available") {
                        ForEach(store.updates) { pending in
                            AppRow(
                                title: pending.app.name,
                                subtitle: "\(pending.installed.version) → \(pending.app.latestVersion)",
                                iconURL: pending.app.iconURL,
                                tint: pending.app.tintColor,
                                last: pending.id == store.updates.last?.id,
                                action: store.action(
                                    for: pending.app,
                                    sourceName: pending.sourceName
                                )
                            )
                        }
                    }
                }

                if store.installed.isEmpty {
                    EmptyNotice(symbol: "arrow.down.circle",
                                title: "Nothing installed",
                                detail: "Add an .ipa above, or open an app in Browse and tap GET.")
                        .padding(.top, 30)
                } else {
                    ListSection(footer: "\(store.installed.count) installed. Tap an app to manage its IPA or the bin to remove it.") {
                        ForEach(store.installedList) { item in
                            AppRow(
                                title: item.name,
                                subtitle: "\(item.version) · \(item.sourceName)",
                                iconURL: item.iconURL,
                                tint: nil,
                                last: item.id == store.installedList.last?.id,
                                action: .remove { store.remove(item.bundleIdentifier) },
                                onOpen: { openGuest(item) }
                            )
                        }
                    }
                }

                IndependenceNotice()
            }
            .padding(.bottom, bottomInset)
        }
        .fileImporter(
            isPresented: $picking,
            allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data, .zip]
        ) { result in
            switch result {
            case .success(let url):
                Task { await installer.installIPA(at: url) }
            case .failure(let error):
                Task { @MainActor in installer.clearSideload() }
                print("[iOSSim] IPA import cancelled: \(error.localizedDescription)")
            }
        }
        .overlay {
            if askingForURL {
                InstallFromURLDialog(
                    onInstall: { url in
                        askingForURL = false
                        Task { await installer.installIPA(from: url) }
                    },
                    onClose: { withAnimation(.easeOut(duration: 0.18)) { askingForURL = false } }
                )
            }
        }
    }

    /// The two ways an IPA gets in without a source behind it.
    @ViewBuilder private var sideloadSection: some View {
        ListSection(
            header: "Install an App",
            footer: "An .ipa is unpacked into its own LiveContainer container, patched, and added below. Nothing is submitted anywhere — the file never leaves this device."
        ) {
            ListRow(separatorInset: 16, action: {
                guard !installer.sideload.isWorking else { return }
                Haptics.tap(.light)
                installer.clearSideload()
                picking = true
            }) {
                Label("Choose .ipa File…", systemImage: "folder")
                    .font(.system(size: 17))
                    .foregroundStyle(SysColor.blue)
                    .padding(.vertical, 2)
            }

            ListRow(showsSeparator: sideloadStatus != nil, separatorInset: 16, action: {
                guard !installer.sideload.isWorking else { return }
                Haptics.tap(.light)
                installer.clearSideload()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { askingForURL = true }
            }) {
                Label("Install from URL…", systemImage: "link")
                    .font(.system(size: 17))
                    .foregroundStyle(SysColor.blue)
                    .padding(.vertical, 2)
            }

            if let status = sideloadStatus {
                ListRow(showsSeparator: false, separatorInset: 16) {
                    HStack(spacing: 10) {
                        if installer.sideload.isWorking {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: status.symbol)
                                .foregroundStyle(status.tint)
                        }
                        Text(status.text)
                            .font(.system(size: 14))
                            .foregroundStyle(status.tint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var sideloadStatus: (text: String, symbol: String, tint: Color)? {
        switch installer.sideload {
        case .idle:
            nil
        case .downloading(let progress):
            ("Downloading \(Int(progress * 100))%", "arrow.down", SysColor.secondaryLabel)
        case .unpacking:
            ("Unpacking the archive…", "shippingbox", SysColor.secondaryLabel)
        case .preparing:
            ("Preparing the container…", "gearshape", SysColor.secondaryLabel)
        case .installed(let name):
            ("\(name) installed", "checkmark.circle.fill", SysColor.green)
        case .failed(let message):
            (message, "exclamationmark.triangle.fill", SysColor.orange)
        }
    }
}

/// Asks for a link to an `.ipa`, in the same shape as the Add Source dialog.
private struct InstallFromURLDialog: View {
    var onInstall: (URL) -> Void
    var onClose: () -> Void

    @State private var text = ""
    @State private var error: String?
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Palette.ink.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("Install from URL")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SysColor.label)
                    Text("A direct link to an .ipa file.")
                        .font(.system(size: 13))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .multilineTextAlignment(.center)

                    TextField("https://example.com/App.ipa", text: $text)
                        .font(.system(size: 15))
                        .foregroundStyle(SysColor.label)
                        .tint(SysColor.blue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(SysColor.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(.top, 6)

                    if let error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(SysColor.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 16)

                Rectangle().fill(SysColor.separator).frame(height: 0.5)

                HStack(spacing: 0) {
                    Button(action: onClose) {
                        Text("Cancel")
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.blue)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)

                    Rectangle().fill(SysColor.separator).frame(width: 0.5, height: 44)

                    Button(action: submit) {
                        Text("Install")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(text.isEmpty ? SysColor.secondaryLabel : SysColor.blue)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty)
                }
            }
            .frame(width: 290)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.paper.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Palette.ink.opacity(0.5), radius: 30, y: 12)
            .scaleEffect(shown ? 1 : 1.12)
            .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { shown = true }
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), url.host() != nil else {
            error = "That is not a URL."
            return
        }
        Haptics.tap(.medium)
        onInstall(url)
    }
}

/// Says plainly, wherever you are in this screen, who is behind it.
struct IndependenceNotice: View {
    var body: some View {
        Text("VibeContainers is an independent app and is not affiliated with, endorsed by, or connected to AltStore or its developers. It only reads the same public source format.")
            .font(.system(size: 12))
            .foregroundStyle(SysColor.secondaryLabel.opacity(0.85))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Source detail

private struct SourceDetailPage: View {
    let source: PackageStore.Source
    let store: PackageStore
    let bottomInset: CGFloat
    var openApp: (PackageStore.Entry) -> Void

    var body: some View {
        let entries = store.entries(for: source.id)

        ScrollView {
            VStack(spacing: 0) {
                if store.loading.contains(source.id) {
                    ProgressView().padding(.top, 40)
                } else if let error = store.failures[source.id] {
                    VStack(spacing: 12) {
                        EmptyNotice(symbol: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                        Button("Try Again") { Task { await store.refresh(source) } }
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.blue)
                    }
                    .padding(.top, 30)
                } else if entries.isEmpty {
                    EmptyNotice(symbol: "shippingbox", title: "No apps", detail: "This source lists nothing.")
                        .padding(.top, 40)
                } else {
                    ListSection(header: "\(entries.count) apps", footer: source.url) {
                        ForEach(entries) { entry in
                            let app = entry.app
                            AppRow(
                                title: app.name,
                                subtitle: subtitle(app),
                                iconURL: app.iconURL,
                                tint: app.tintColor,
                                last: entry.id == entries.last?.id,
                                action: store.action(for: entry),
                                onOpen: { openApp(entry) }
                            )
                        }
                    }
                }
            }
            .padding(.bottom, bottomInset)
        }
    }

    private func subtitle(_ app: AltApp) -> String {
        var parts = [app.developer, app.latestVersion]
        if let size = PackageFormat.size(app.latestSize) { parts.append(size) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - App page

private struct AppDetailPage: View {
    let entry: PackageStore.Entry
    let store: PackageStore
    let bottomInset: CGFloat
    var openGuest: (String) -> Void

    private var app: AltApp { entry.app }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if !app.shots.isEmpty { screenshots }

                if let description = app.localizedDescription, !description.isEmpty {
                    Block(title: "Description") {
                        Text(description)
                            .font(.system(size: 15))
                            .foregroundStyle(SysColor.label.opacity(0.92))
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let notes = app.releaseNotes, !notes.isEmpty {
                    Block(title: "What's New", caption: whatsNewCaption) {
                        Text(notes)
                            .font(.system(size: 15))
                            .foregroundStyle(SysColor.label.opacity(0.92))
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !app.privacyNotes.isEmpty { privacy }

                information
            }
            .padding(.bottom, bottomInset)
        }
    }

    private var whatsNewCaption: String {
        [app.latestVersion, PackageFormat.date(app.latestDate)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            PackageIcon(url: app.iconURL, tint: app.tintColor, size: 88)

            VStack(alignment: .leading, spacing: 5) {
                Text(app.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                    .lineLimit(2)
                Text(app.developer)
                    .font(.system(size: 14))
                    .foregroundStyle(SysColor.secondaryLabel)
                if let subtitle = app.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    ActionPill(action: store.action(for: entry),
                               onOpen: { openGuest(app.bundleIdentifier) })
                    if app.beta == true {
                        Text("BETA")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(SysColor.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(SysColor.orange.opacity(0.18)))
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private var screenshots: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(app.shots.prefix(10).enumerated()), id: \.offset) { _, shot in
                    AsyncImage(url: URL(string: shot)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure:
                            RoundedRectangle(cornerRadius: 12).fill(SysColor.tertiary).frame(width: 160)
                        default:
                            ZStack {
                                RoundedRectangle(cornerRadius: 12).fill(SysColor.tertiary).frame(width: 160)
                                ProgressView()
                            }
                        }
                    }
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Palette.paper.opacity(0.12), lineWidth: 0.5)
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var privacy: some View {
        Block(title: "Privacy") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(app.privacyNotes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(SysColor.label)
                        if let usage = note.usageDescription {
                            Text(usage)
                                .font(.system(size: 13))
                                .foregroundStyle(SysColor.secondaryLabel)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var information: some View {
        Block(title: "Information") {
            VStack(spacing: 0) {
                InfoLine("Source", entry.sourceName)
                InfoLine("Bundle ID", app.bundleIdentifier)
                InfoLine("Version", app.latestVersion)
                if let size = PackageFormat.size(app.latestSize) { InfoLine("Size", size) }
                if let min = app.latest?.minOSVersion { InfoLine("Requires", "iOS \(min)") }
                if let category = app.categoryLabel { InfoLine("Category", category) }
                if let date = PackageFormat.date(app.latestDate) { InfoLine("Released", date, last: true) }
            }
        }
    }
}

private struct Block<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                Spacer()
                if let caption {
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(SysColor.secondaryLabel)
                }
            }
            content
        }
        .padding(14)
        .background(SysColor.secondaryGrouped)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }
}

private struct InfoLine: View {
    let label: String
    let value: String
    var last = false

    init(_ label: String, _ value: String, last: Bool = false) {
        self.label = label
        self.value = value
        self.last = last
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(SysColor.secondaryLabel)
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(size: 14))
                    .foregroundStyle(SysColor.label)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            .padding(.vertical, 8)

            if !last {
                Rectangle().fill(SysColor.separator).frame(height: 0.5)
            }
        }
    }
}

// MARK: - Add source popup

private struct AddSourceDialog: View {
    let store: PackageStore
    var onClose: () -> Void

    @State private var url = ""
    @State private var error: String?
    @State private var working = false
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Palette.ink.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture { if !working { onClose() } }

            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("Add Source")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SysColor.label)
                    Text("Enter an AltStore source URL. GitHub page links are converted for you.")
                        .font(.system(size: 13))
                        .foregroundStyle(SysColor.secondaryLabel)
                        .multilineTextAlignment(.center)

                    TextField("https://apps.altstore.io", text: $url)
                        .font(.system(size: 15))
                        .foregroundStyle(SysColor.label)
                        .tint(SysColor.blue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit(submit)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(SysColor.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(.top, 6)

                    if let error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(SysColor.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 16)

                Rectangle().fill(SysColor.separator).frame(height: 0.5)

                HStack(spacing: 0) {
                    Button(action: onClose) {
                        Text("Cancel")
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.blue)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(working)

                    Rectangle().fill(SysColor.separator).frame(width: 0.5, height: 44)

                    Button(action: submit) {
                        HStack(spacing: 6) {
                            if working { ProgressView().scaleEffect(0.7) }
                            Text(working ? "Checking…" : "Add")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(url.isEmpty ? SysColor.secondaryLabel : SysColor.blue)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(url.isEmpty || working)
                }
            }
            .frame(width: 280)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.paper.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Palette.ink.opacity(0.5), radius: 30, y: 12)
            .scaleEffect(shown ? 1 : 1.14)
            .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { shown = true }
        }
    }

    private func submit() {
        guard !url.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            let result = await store.addSource(url: url)
            working = false
            switch result {
            case .success:
                Haptics.tap(.medium)
                onClose()
            case .failure(let failure):
                error = failure.message
            }
        }
    }
}

// MARK: - Shared pieces

private struct SectionHeader: View {
    let title: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(SysColor.label)
            Spacer()
            if let action {
                Button(action.title, action: action.run)
                    .font(.system(size: 15))
                    .foregroundStyle(SysColor.blue)
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct EmptyNotice: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(SysColor.secondaryLabel)
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SysColor.label)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(SysColor.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

private extension View {
    func cardBackground() -> some View {
        background(SysColor.secondaryGrouped)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
    }
}

// MARK: - Rows

struct ActionPill: View {
    let action: AppRow.Action
    var onOpen: (() -> Void)?

    var body: some View {
        switch action {
        case .get(let run): pill("GET", filled: true, run: run)
        case .update(let run): pill("UPDATE", filled: true, run: run)
        case .retry(let run): pill("RETRY", filled: true, run: run)
        case .installing(let label, let progress): installProgress(label, progress: progress)
        case .open: pill("OPEN", filled: false, run: onOpen ?? {})
        case .remove(let run):
            Button {
                Haptics.tap(.rigid)
                run()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16))
                    .foregroundStyle(SysColor.red)
                    .frame(width: 40, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func pill(_ label: String, filled: Bool, run: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap(.medium)
            run()
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(filled ? Palette.ink : SysColor.blue)
                .frame(minWidth: 62)
                .padding(.vertical, 6)
                .background(Capsule().fill(filled ? SysColor.blue : SysColor.fill))
        }
        .buttonStyle(.plain)
    }

    private func installProgress(_ label: String, progress: Double?) -> some View {
        HStack(spacing: 6) {
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(Palette.ink)
                    .frame(width: 28)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Palette.ink)
            }
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(SysColor.blue.opacity(0.78)))
        .accessibilityLabel(label)
    }
}

struct AppRow: View {
    let title: String
    let subtitle: String
    let iconURL: String?
    let tint: String?
    var last = false
    let action: Action
    var onOpen: (() -> Void)?

    enum Action {
        case get(() -> Void)
        case update(() -> Void)
        case retry(() -> Void)
        case installing(String, progress: Double?)
        case open
        case remove(() -> Void)
    }

    var body: some View {
        ListRow(showsSeparator: !last, separatorInset: 68) {
            Button { onOpen?() } label: {
                HStack(spacing: 12) {
                    PackageIcon(url: iconURL, tint: tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 17))
                            .foregroundStyle(SysColor.label)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(SysColor.secondaryLabel)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)
        } trailing: {
            ActionPill(action: action, onOpen: onOpen)
        }
    }
}

struct SourceRow: View {
    let source: PackageStore.Source
    let state: State
    var last = false
    let open: () -> Void
    let remove: () -> Void

    enum State {
        case idle, loading
        case loaded(Int)
        case failed(String)
    }

    var body: some View {
        ListRow(showsSeparator: !last, separatorInset: 16, action: open) {
            VStack(alignment: .leading, spacing: 3) {
                Text(source.displayName)
                    .font(.system(size: 17))
                    .foregroundStyle(SysColor.label)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(isFailed ? SysColor.red : SysColor.secondaryLabel)
                    .lineLimit(1)
            }
            .padding(.vertical, 5)
        } trailing: {
            HStack(spacing: 10) {
                if case .loading = state { ProgressView().scaleEffect(0.8) }
                Button {
                    Haptics.tap(.rigid)
                    remove()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(SysColor.red)
                        .frame(width: 34, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Chevron()
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var detail: String {
        switch state {
        case .idle: source.host
        case .loading: "Refreshing…"
        case .loaded(let count): "\(source.host) · \(count) apps"
        case .failed(let error): error
        }
    }
}

/// Remote icon with a drawn fallback, so a missing or slow icon still reads as
/// a package rather than a hole in the list.
struct PackageIcon: View {
    let url: String?
    var tint: String?
    var size: CGFloat = 44

    @State private var remoteImage: UIImage?

    var body: some View {
        Group {
            if let local = localImage {
                // A sideloaded app's icon was lifted out of its own bundle and
                // is sitting on disk; going through AsyncImage for that only
                // buys a placeholder flash on every row that scrolls past.
                Image(uiImage: local).resizable().scaledToFill()
            } else if let remoteImage {
                Image(uiImage: remoteImage).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .strokeBorder(Palette.paper.opacity(0.12), lineWidth: 0.5)
        )
        .task(id: remoteRequest) {
            remoteImage = nil
            guard let request = remoteRequest else { return }
            let cached = await PackageIconPipeline.shared.image(
                at: request.url,
                maximumPixelSize: request.maximumPixelSize,
                scale: request.scale
            )
            guard !Task.isCancelled else { return }
            remoteImage = cached?.image
        }
    }

    private struct RemoteRequest: Hashable {
        let url: URL
        let maximumPixelSize: Int
        let scale: CGFloat
    }

    private var remoteRequest: RemoteRequest? {
        guard let url,
              !url.hasPrefix(GuestInstaller.localIconScheme),
              let parsed = URL(string: url),
              !parsed.isFileURL,
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { return nil }
        let scale = UIScreen.main.scale
        return RemoteRequest(
            url: parsed,
            maximumPixelSize: max(1, Int((size * scale).rounded(.up))),
            scale: scale
        )
    }

    /// Icons extracted from a sideloaded bundle, resolved at display time.
    ///
    /// Also heals a record written before these were stored by name: an old
    /// absolute path that no longer exists still names the file, and the file
    /// is where it always was.
    private var localImage: UIImage? {
        guard let url else { return nil }

        if url.hasPrefix(GuestInstaller.localIconScheme) {
            let name = String(url.dropFirst(GuestInstaller.localIconScheme.count))
            return UIImage(contentsOfFile: GuestInstaller.iconFolder.appendingPathComponent(name).path)
        }

        guard let parsed = URL(string: url), parsed.isFileURL else { return nil }
        if let image = UIImage(contentsOfFile: parsed.path) { return image }
        let moved = GuestInstaller.iconFolder.appendingPathComponent(parsed.lastPathComponent)
        return UIImage(contentsOfFile: moved.path)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [fallbackTint.opacity(0.9), fallbackTint.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: "shippingbox.fill")
                .font(.system(size: size * 0.38))
                .foregroundStyle(Palette.paper.opacity(0.85))
        }
    }

    private var fallbackTint: Color {
        guard let tint, !tint.isEmpty else { return Palette.stone }
        return Color(hex: tint)
    }
}

private struct PackageCachedImage: @unchecked Sendable {
    let image: UIImage
    let cost: Int
}

/// Downloads each icon once per display size and decodes a thumbnail instead
/// of keeping the repository's original (often 512–1024 px) bitmap alive.
/// NSCache automatically evicts thumbnails under memory pressure.
private actor PackageIconPipeline {
    static let shared = PackageIconPipeline()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<PackageCachedImage?, Never>] = [:]
    private var failedUntil: [String: Date] = [:]

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 24 * 1_024 * 1_024
    }

    func image(at url: URL, maximumPixelSize: Int, scale: CGFloat) async -> PackageCachedImage? {
        let key = "\(url.absoluteString)|\(maximumPixelSize)"
        if let image = cache.object(forKey: key as NSString) {
            return PackageCachedImage(image: image, cost: 0)
        }
        if let retryDate = failedUntil[key], retryDate > Date() { return nil }
        failedUntil[key] = nil

        let task: Task<PackageCachedImage?, Never>
        if let existing = inFlight[key] {
            task = existing
        } else {
            task = Task.detached(priority: .utility) {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) { return nil }
                    guard !Task.isCancelled else { return nil }
                    return Self.downsample(data, maximumPixelSize: maximumPixelSize, scale: scale)
                } catch {
                    return nil
                }
            }
            inFlight[key] = task
        }

        let result = await task.value
        inFlight[key] = nil
        if let result {
            cache.setObject(result.image, forKey: key as NSString, cost: result.cost)
        } else {
            // Broken or non-image repository URLs used to be decoded again
            // every time a row reappeared, producing an ImageIO warning and
            // needless network work on large sources. Retry later so a
            // transient server failure can still heal without a relaunch.
            // Keep the negative cache bounded too. A malformed repository can
            // publish a unique broken icon URL for every package; retaining
            // all of those keys would otherwise grow forever as the user
            // scrolls, even though the decoded-image cache itself is bounded.
            if failedUntil.count >= 512,
               failedUntil[key] == nil,
               let evicted = failedUntil.keys.first {
                failedUntil[evicted] = nil
            }
            failedUntil[key] = Date().addingTimeInterval(5 * 60)
        }
        return result
    }

    private nonisolated static func downsample(
        _ data: Data,
        maximumPixelSize: Int,
        scale: CGFloat
    ) -> PackageCachedImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0,
              height.doubleValue > 0 else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else { return nil }

        return PackageCachedImage(
            image: UIImage(cgImage: thumbnail, scale: scale, orientation: .up),
            cost: thumbnail.bytesPerRow * thumbnail.height
        )
    }
}

// MARK: - Store convenience

extension PackageStore {
    func action(for entry: Entry) -> AppRow.Action {
        action(for: entry.app, sourceName: entry.sourceName)
    }

    func action(for app: AltApp, sourceName: String) -> AppRow.Action {
        let bundleIdentifier = app.bundleIdentifier
        let phase = GuestInstaller.shared.phase(for: bundleIdentifier)

        if pendingInstallBundles.contains(bundleIdentifier) {
            switch phase {
            case .downloading(let progress):
                return .installing("\(Int((progress * 100).rounded()))%", progress: progress)
            case .unpacking:
                return .installing("UNPACKING", progress: nil)
            case .preparing:
                return .installing("PREPARING", progress: nil)
            default:
                return .installing("STARTING", progress: nil)
            }
        }

        switch phase {
        case .downloading(let progress):
            return .installing("\(Int((progress * 100).rounded()))%", progress: progress)
        case .unpacking:
            return .installing("UNPACKING", progress: nil)
        case .preparing:
            return .installing("PREPARING", progress: nil)
        case .failed:
            return .retry { self.install(app, from: sourceName) }
        case .idle, .ready:
            break
        }

        if hasUpdate(app) { return .update { self.install(app, from: sourceName) } }
        if isInstalled(app) { return .open }
        return .get { self.install(app, from: sourceName) }
    }
}
