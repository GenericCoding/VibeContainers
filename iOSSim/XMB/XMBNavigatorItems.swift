import Darwin
import SwiftUI
import UIKit

@_silgen_name("IOSSimProbeJIT")
private func IOSSimProbeJITFromXMB() -> Int32

/// The non-executing JIT capability check, behind a name the dashboard can call.
enum XMBJITProbe {
    /// 0 when the host runtime/provider state is available; otherwise its
    /// explanatory `errno`.
    static func run() -> Int32 { IOSSimProbeJITFromXMB() }
}

/// Every column's rows.
///
/// This is where the dashboard meets the rest of the app: the same
/// `PackageStore`, `WebServer`, `TweakStore` and `GuestInstaller` the iOS
/// side drives, read and written through rows instead of taps. Nothing is
/// duplicated — an install started here is the same install the springboard
/// grows an icon for.
extension XMBNavigator {

    // MARK: - Dispatch

    /// The two catalogue columns can contain many thousands of entries. Keep
    /// their count and lookup paths separate from `items(for:)` so opening or
    /// moving through one never maps the entire catalogue into `XMBItem`s.
    func itemCount(for id: XMBColumnID) -> Int {
        switch id {
        case .allPackages:
            return max(1, PackageStore.shared.alphabeticalApps.count)
        case .source(let uuid):
            return max(1, PackageStore.shared.alphabeticalEntries(for: uuid).count)
        default:
            return items(for: id).count
        }
    }

    func item(
        at index: Int,
        in id: XMBColumnID,
        includePackageInfo: Bool = false
    ) -> XMBItem? {
        guard index >= 0 else { return nil }

        switch id {
        case .allPackages:
            let entries = PackageStore.shared.alphabeticalApps
            if entries.isEmpty { return index == 0 ? emptyPackageRow() : nil }
            guard entries.indices.contains(index) else { return nil }
            return packageRow(entries[index], includeInfo: includePackageInfo)

        case .source(let uuid):
            let entries = PackageStore.shared.alphabeticalEntries(for: uuid)
            if entries.isEmpty { return index == 0 ? emptySourceRow() : nil }
            guard entries.indices.contains(index) else { return nil }
            return packageRow(entries[index], includeInfo: includePackageInfo)

        default:
            let rows = items(for: id)
            guard rows.indices.contains(index) else { return nil }
            return rows[index]
        }
    }

    private func items(for id: XMBColumnID) -> [XMBItem] {
        switch id {
        case .category(let category): categoryItems(category)
        // Large catalogues are deliberately available only through the
        // indexed accessors above. Returning an eager array here would bring
        // back the multi-thousand-row launch stall.
        case .allPackages, .source: []
        case .installed: installedItems()
        case .updates: updateItems()
        case .sources: sourceListItems()
        case .tweaks: tweakItems()
        case .httpServer: httpServerItems()
        case .jit: jitItems()
        case .theme: themeItems()
        case .sound: soundItems()
        case .controllers: controllerItems()
        case .about: aboutItems()
        case .connection: connectionItems()
        case .package(let entryID): packageItems(entryID)
        case .guest(let bundle): guestItems(bundle)
        case .article(let articleID): articleItems(articleID)
        }
    }

    /// The article itself is in the page header; the row is what you can do
    /// with it from a dashboard that has no browser and no keyboard.
    private func articleItems(_ articleID: String) -> [XMBItem] {
        guard let article = FeedStore.shared.articles.first(where: { $0.id == articleID }) else {
            return []
        }
        return [
            XMBItem(
                id: "article.copy",
                title: "Copy Link",
                subtitle: article.link,
                icon: .symbol("link", Palette.denim),
                activate: { [weak self] in
                    UIPasteboard.general.string = article.link
                    self?.say("Link copied")
                }
            ),
            XMBItem(
                id: "article.source",
                title: article.sourceTitle,
                subtitle: article.dateText,
                icon: .symbol("newspaper.fill", Palette.stone),
                dimmed: true
            )
        ]
    }

    // MARK: - Categories

    private func categoryItems(_ category: XMBCategory) -> [XMBItem] {
        switch category {
        case .users: userItems()
        case .settings: settingsItems()
        case .photo: photoItems()
        case .music: musicItems()
        case .video: []                     // "There are no titles."
        case .game: gameItems()
        case .network: networkItems()
        }
    }

    private func userItems() -> [XMBItem] {
        [
            XMBItem(
                id: "user.device",
                title: "Device",
                subtitle: DeviceIdentity.phoneModelName,
                icon: .symbol("person.crop.circle.fill", Palette.wheat),
                info: XMBInfo(
                    title: "Device",
                    subtitle: "Signed in on this device",
                    icon: .symbol("person.crop.circle.fill", Palette.wheat),
                    lines: [
                        .init(label: "Model", value: DeviceIdentity.phoneModelName),
                        .init(label: "Applications", value: "\(PackageStore.shared.installed.count)")
                    ],
                    accent: Palette.wheat
                ),
                activate: { [weak self] in self?.push(.about) }
            ),
            XMBItem(
                id: "user.exit",
                title: "Return to iOS Home Screen",
                subtitle: "Leave the dashboard and use the touchscreen",
                icon: .symbol("iphone", Palette.paperDim),
                activate: { [weak self] in self?.requestExit() }
            )
        ]
    }

    private func settingsItems() -> [XMBItem] {
        let server = WebServer.shared
        return [
            XMBItem(
                id: "settings.http",
                title: "HTTP Server",
                subtitle: server.status.isRunning
                    ? (server.addresses.first ?? "Running")
                    : "Serve a folder over the local network",
                icon: .symbol("network", Palette.sage),
                badge: statusBadge(server.status),
                badgeTint: server.status.isRunning ? Palette.sage : Palette.paperDim,
                activate: { [weak self] in self?.push(.httpServer) }
            ),
            XMBItem(
                id: "settings.tweaks",
                title: "Tweaks",
                subtitle: "Dylibs dyld loads into containerised apps",
                icon: .symbol("puzzlepiece.extension.fill", Palette.mauve),
                badge: TweakStore.shared.library.isEmpty ? nil : "\(TweakStore.shared.library.count)",
                activate: { [weak self] in self?.push(.tweaks) }
            ),
            XMBItem(
                id: "settings.jit",
                title: "JIT & Containers",
                subtitle: "Whether this process may run guest code",
                icon: .symbol("bolt.fill", Palette.wheat),
                activate: { [weak self] in self?.push(.jit) }
            ),
            XMBItem(
                id: "settings.theme",
                title: "Theme & Wave",
                subtitle: "Accent, dust, scanlines, motion",
                icon: .symbol("paintpalette.fill", Palette.rose),
                activate: { [weak self] in self?.push(.theme) }
            ),
            XMBItem(
                id: "settings.sound",
                title: "Sound Settings",
                subtitle: "Dashboard effects and ambience",
                icon: .symbol("speaker.wave.2.fill", Palette.seafoam),
                activate: { [weak self] in self?.push(.sound) }
            ),
            XMBItem(
                id: "settings.controller",
                title: "Controller",
                subtitle: controllerSubtitle,
                icon: .symbol("gamecontroller.fill", Palette.ice),
                badge: ControllerHub.shared.pads.isEmpty ? nil : "\(ControllerHub.shared.pads.count)",
                activate: { [weak self] in self?.push(.controllers) }
            ),
            XMBItem(
                id: "settings.sources",
                title: "Package Sources",
                subtitle: "\(PackageStore.shared.sources.count) repositories",
                icon: .symbol("tray.full.fill", Palette.denim),
                activate: { [weak self] in self?.push(.sources) }
            ),
            XMBItem(
                id: "settings.about",
                title: "System Information",
                subtitle: "iOS Sim · Lofi Edition",
                icon: .symbol("info.circle.fill", Palette.stone),
                activate: { [weak self] in self?.push(.about) }
            )
        ]
    }

    private var controllerSubtitle: String {
        let pads = ControllerHub.shared.pads
        guard let first = pads.first else { return "No controller connected" }
        return pads.count > 1
            ? "\(first.kind.shortTitle) and \(pads.count - 1) more"
            : first.kind.title
    }

    private func gameItems() -> [XMBItem] {
        let store = PackageStore.shared
        let updates = store.updates.count

        return [
            XMBItem(
                id: "game.install",
                title: "Install Packages",
                subtitle: packageCountSubtitle,
                icon: .symbol("arrow.down.circle.fill", Palette.ice),
                badge: store.allApps.isEmpty ? nil : "\(store.allApps.count)",
                info: XMBInfo(
                    title: "Install Packages",
                    subtitle: "Every application in every repository",
                    icon: .symbol("arrow.down.circle.fill", Palette.ice),
                    lines: [
                        .init(label: "Repositories", value: "\(store.sources.count)"),
                        .init(label: "Packages", value: "\(store.allApps.count)"),
                        .init(label: "Installed", value: "\(store.installed.count)")
                    ],
                    body: "Downloads the exact IPA the repository publishes, unpacks Payload/<App>.app into a LiveContainer slot and patches the executable so dyld can load it.",
                    accent: Palette.ice
                ),
                activate: { [weak self] in self?.push(.allPackages) }
            ),
            XMBItem(
                id: "game.installed",
                title: "Installed Applications",
                subtitle: store.installed.isEmpty
                    ? "No applications installed"
                    : "\(store.installed.count) in containers",
                icon: .symbol("square.stack.3d.up.fill", Palette.sage),
                badge: store.installed.isEmpty ? nil : "\(store.installed.count)",
                activate: { [weak self] in self?.push(.installed) }
            ),
            XMBItem(
                id: "game.updates",
                title: "Updates",
                subtitle: updates == 0 ? "Everything is up to date" : "\(updates) waiting",
                icon: .symbol("arrow.triangle.2.circlepath", Palette.amber),
                badge: updates == 0 ? nil : "\(updates)",
                badgeTint: Palette.amber,
                activate: { [weak self] in self?.push(.updates) }
            ),
            XMBItem(
                id: "game.sources",
                title: "Package Sources",
                subtitle: "\(store.sources.count) repositories",
                icon: .symbol("tray.full.fill", Palette.denim),
                activate: { [weak self] in self?.push(.sources) }
            ),
            XMBItem(
                id: "game.refresh",
                title: "Refresh All Repositories",
                subtitle: store.loading.isEmpty ? "Re-read every source" : "Refreshing…",
                icon: .symbol("arrow.clockwise", Palette.stone),
                activate: { [weak self] in self?.refreshAll() }
            )
        ]
    }

    private var packageCountSubtitle: String {
        let store = PackageStore.shared
        if !store.loading.isEmpty { return "Loading repositories…" }
        if store.allApps.isEmpty { return "No repositories loaded — press OPTIONS to refresh" }
        return "\(store.allApps.count) packages in \(store.sources.count) repositories"
    }

    private func networkItems() -> [XMBItem] {
        let feed = FeedStore.shared
        return [
            XMBItem(
                id: "network.connection",
                title: "Connection Information",
                subtitle: WebServer.localIPv4Addresses().first ?? "Not connected",
                icon: .symbol("wifi", Palette.denim),
                activate: { [weak self] in self?.push(.connection) }
            )
        ] + feed.articles.prefix(20).map { article in
            XMBItem(
                id: "network.article.\(article.id)",
                title: article.title,
                subtitle: "\(article.sourceTitle) · \(article.dateText)",
                icon: .symbol("newspaper.fill", Palette.denim),
                info: XMBInfo(
                    title: article.title,
                    subtitle: article.sourceTitle,
                    icon: .symbol("newspaper.fill", Palette.denim),
                    lines: [.init(label: "Published", value: article.dateText)],
                    body: article.summary,
                    footnote: article.link,
                    accent: Palette.denim
                ),
                activate: { [weak self] in self?.push(.article(article.id)) }
            )
        }
    }

    private func photoItems() -> [XMBItem] {
        (0..<PhotosData.count).map { index in
            let caption = PhotosData.caption(index)
            return XMBItem(
                id: "photo.\(index)",
                title: caption,
                subtitle: "IMG_\(String(format: "%04d", 1024 + index))",
                icon: .swatch(PhotosData.palette(index)),
                info: XMBInfo(
                    title: caption,
                    subtitle: "IMG_\(String(format: "%04d", 1024 + index))",
                    icon: .swatch(PhotosData.palette(index)),
                    lines: [
                        .init(label: "Dimensions", value: "4032 × 3024"),
                        .init(label: "Album", value: "Camera Roll")
                    ],
                    accent: Palette.mauve
                )
            )
        }
    }

    private func musicItems() -> [XMBItem] {
        MusicData.queue.map { song in
            XMBItem(
                id: "music.\(song.id)",
                title: song.title,
                subtitle: "\(song.artist) · \(song.album)",
                icon: .swatch(song.colors),
                badge: Self.duration(song.duration),
                badgeTint: Palette.sage,
                info: XMBInfo(
                    title: song.title,
                    subtitle: song.artist,
                    icon: .swatch(song.colors),
                    lines: [
                        .init(label: "Album", value: song.album),
                        .init(label: "Length", value: Self.duration(song.duration))
                    ],
                    accent: Palette.sage
                ),
                activate: { [weak self] in self?.play(song) }
            )
        }
    }

    private static func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Packages

    private func emptyPackageRow() -> XMBItem {
        let store = PackageStore.shared
        return XMBItem(
            id: "packages.empty",
            title: store.loading.isEmpty ? "No packages found" : "Loading repositories…",
            subtitle: store.loading.isEmpty
                ? "Press OPTIONS to refresh every repository"
                : "\(store.loading.count) still fetching",
            icon: .symbol("shippingbox", Palette.stone),
            activate: { [weak self] in self?.refreshAll() }
        )
    }

    private func emptySourceRow() -> XMBItem {
        XMBItem(id: "source.empty", title: "There are no titles.",
                icon: .symbol("tray", Palette.stone), dimmed: true)
    }

    /// A cheap dictionary/set lookup used only for rows in the visible XMB
    /// window. It does not create a task or watcher per repository package.
    private func installPresentation(for bundleIdentifier: String)
        -> (label: String?, progress: Double?, isWorking: Bool, failed: Bool) {
        let store = PackageStore.shared
        let installer = GuestInstaller.shared
        let pending = store.pendingInstallBundles.contains(bundleIdentifier)
        let phase = installer.phase(for: bundleIdentifier)

        switch phase {
        case .downloading(let value):
            let progress = min(max(value, 0), 1)
            return ("\(Int((progress * 100).rounded()))%", progress, true, false)
        case .unpacking:
            return ("UNPACKING", nil, true, false)
        case .preparing:
            return ("PREPARING", nil, true, false)
        case .failed:
            return pending
                ? ("FINALIZING", nil, true, false)
                : ("RETRY", nil, false, true)
        case .ready:
            return pending
                ? ("FINALIZING", 1, true, false)
                : (nil, nil, false, false)
        case .idle:
            return (pending || installer.isBusy(bundleIdentifier))
                ? ("STARTING", nil, true, false)
                : (nil, nil, false, false)
        }
    }

    /// One repository entry, wherever it is being listed.
    private func packageRow(
        _ entry: PackageStore.Entry,
        includeInfo: Bool = true
    ) -> XMBItem {
        let store = PackageStore.shared
        let app = entry.app
        let install = installPresentation(for: app.bundleIdentifier)

        var badge: String?
        var tint = Palette.ice

        if install.isWorking || install.failed {
            badge = install.label
            tint = Palette.amber
        } else {
            if store.hasUpdate(app) {
                badge = "UPDATE"
                tint = Palette.amber
            } else if store.isInstalled(app) {
                badge = "INSTALLED"
                tint = Palette.sage
            } else {
                badge = app.latestVersion
                tint = Palette.paperDim
            }
        }

        return XMBItem(
            id: "package.\(entry.id)",
            title: app.name,
            subtitle: "\(app.developer) · \(entry.sourceName)",
            icon: .package(url: app.iconURL, tint: app.tintColor),
            badge: badge,
            badgeTint: tint,
            // The catalogue column draws only a small window, but even that
            // window should not format a full details panel for every row on
            // every download-progress tick. Only `focused` asks for it.
            info: includeInfo ? info(for: entry) : nil,
            activate: { [weak self] in self?.push(.package(entry.id)) },
            secondary: install.isWorking ? nil : { [weak self] in self?.install(entry) },
            secondaryTitle: install.isWorking ? nil : (install.failed
                ? "Retry"
                : (store.isInstalled(app)
                    ? (store.hasUpdate(app) ? "Update" : "Reinstall")
                    : "Install")),
            progress: install.progress
        )
    }

    /// The PS3 information panel for a package — what the hover overlay shows.
    func info(for entry: PackageStore.Entry) -> XMBInfo {
        let app = entry.app
        let store = PackageStore.shared
        var lines: [XMBInfoLine] = [
            .init(label: "Version", value: app.latestVersion),
            .init(label: "Repository", value: entry.sourceName),
            .init(label: "Developer", value: app.developer)
        ]
        if let size = PackageFormat.size(app.latestSize) {
            lines.append(.init(label: "Size", value: size))
        }
        if let date = PackageFormat.date(app.latestDate) {
            lines.append(.init(label: "Released", value: date))
        }
        if let category = app.categoryLabel {
            lines.append(.init(label: "Category", value: category))
        }
        if let record = store.installed[app.bundleIdentifier] {
            lines.append(.init(label: "Installed", value: record.version))
        }
        if app.beta == true {
            lines.append(.init(label: "Channel", value: "Beta"))
        }

        return XMBInfo(
            title: app.name,
            subtitle: app.subtitle ?? app.developer,
            icon: .package(url: app.iconURL, tint: app.tintColor),
            lines: lines,
            body: app.localizedDescription ?? app.subtitle,
            footnote: app.bundleIdentifier,
            accent: store.isInstalled(app) ? Palette.sage : Palette.ice
        )
    }

    private func installedItems() -> [XMBItem] {
        let store = PackageStore.shared
        let records = store.installedList
        guard !records.isEmpty else {
            return [XMBItem(id: "installed.empty", title: "There are no titles.",
                            subtitle: "Install something from Game → Install Packages",
                            icon: .symbol("square.stack.3d.up", Palette.stone), dimmed: true)]
        }

        return records.map { record in
            let container = GuestContainerStore.shared.container(for: record.bundleIdentifier)
            let hasPayload = container.map { GuestContainerStore.shared.hasPayload($0) } ?? false
            return XMBItem(
                id: "installed.\(record.bundleIdentifier)",
                title: record.name,
                subtitle: "\(record.developer) · \(record.sourceName)",
                icon: .package(url: record.iconURL, tint: nil),
                badge: hasPayload ? record.version : "NO PAYLOAD",
                badgeTint: hasPayload ? Palette.sage : Palette.clay,
                info: XMBInfo(
                    title: record.name,
                    subtitle: record.developer,
                    icon: .package(url: record.iconURL, tint: nil),
                    lines: [
                        .init(label: "Version", value: record.version),
                        .init(label: "Repository", value: record.sourceName),
                        .init(label: "Bundle", value: record.bundleIdentifier),
                        .init(label: "Payload", value: hasPayload ? "Installed" : "Not downloaded")
                    ],
                    body: hasPayload
                        ? "Launching hands this process to LiveContainer, which loads the guest's own executable and calls its entry point."
                        : "The container has no payload yet. Open it and download the IPA before launching.",
                    footnote: container.map { "Container \($0.uuid.uuidString.prefix(8))…" },
                    accent: hasPayload ? Palette.sage : Palette.clay
                ),
                activate: { [weak self] in self?.push(.guest(record.bundleIdentifier)) },
                secondary: { [weak self] in self?.launch(record.bundleIdentifier) },
                secondaryTitle: "Launch"
            )
        }
    }

    private func updateItems() -> [XMBItem] {
        let store = PackageStore.shared
        let pending = store.updates
        guard !pending.isEmpty else {
            return [XMBItem(id: "updates.empty", title: "Everything is up to date.",
                            icon: .symbol("checkmark.seal.fill", Palette.sage), dimmed: true)]
        }

        return pending.map { update in
            let install = installPresentation(for: update.installed.bundleIdentifier)
            return XMBItem(
                id: "update.\(update.id)",
                title: update.installed.name,
                subtitle: "\(update.installed.version) → \(update.app.latestVersion)",
                icon: .package(url: update.installed.iconURL, tint: update.app.tintColor),
                badge: install.label ?? "UPDATE",
                badgeTint: Palette.amber,
                info: XMBInfo(
                    title: update.installed.name,
                    subtitle: "Update available",
                    icon: .package(url: update.installed.iconURL, tint: nil),
                    lines: [
                        .init(label: "Installed", value: update.installed.version),
                        .init(label: "Available", value: update.app.latestVersion),
                        .init(label: "Repository", value: update.sourceName)
                    ],
                    body: update.app.releaseNotes,
                    accent: Palette.amber
                ),
                activate: install.isWorking ? nil : { [weak self] in self?.applyUpdate(update) },
                secondary: install.isWorking ? nil : { [weak self] in self?.applyUpdate(update) },
                secondaryTitle: install.isWorking ? nil : (install.failed ? "Retry" : "Update"),
                progress: install.progress
            )
        }
    }

    private func sourceListItems() -> [XMBItem] {
        let store = PackageStore.shared
        return store.sources.map { source in
            let catalog = store.catalogs[source.id]
            let loading = store.loading.contains(source.id)
            let failure = store.failures[source.id]

            return XMBItem(
                id: "source.\(source.id)",
                title: source.displayName,
                subtitle: failure ?? (loading ? "Refreshing…" : source.host),
                icon: .package(url: catalog?.iconURL, tint: catalog?.tintColor),
                badge: catalog.map { "\($0.apps.count)" },
                badgeTint: failure == nil ? Palette.ice : Palette.clay,
                info: XMBInfo(
                    title: source.displayName,
                    subtitle: catalog?.subtitle ?? source.host,
                    icon: .package(url: catalog?.iconURL, tint: catalog?.tintColor),
                    lines: [
                        .init(label: "Host", value: source.host),
                        .init(label: "Packages", value: "\(catalog?.apps.count ?? 0)"),
                        .init(label: "News", value: "\(catalog?.news.count ?? 0)")
                    ],
                    body: failure,
                    footnote: source.url,
                    accent: failure == nil ? Palette.denim : Palette.clay
                ),
                activate: { [weak self] in self?.push(.source(source.id)) },
                secondary: { Task { await store.refresh(source) } },
                secondaryTitle: "Refresh"
            )
        }
    }

    /// The information page a package row opens with ✕.
    private func packageItems(_ entryID: String) -> [XMBItem] {
        guard let entry = PackageStore.shared.entry(id: entryID) else { return [] }
        let store = PackageStore.shared
        let app = entry.app
        let installed = store.isInstalled(app)
        let phase = GuestInstaller.shared.phase(for: app.bundleIdentifier)

        var rows: [XMBItem] = []

        switch phase {
        case .downloading(let value):
            rows.append(XMBItem(id: "pkg.progress", title: "Downloading",
                                subtitle: "\(Int(value * 100))% of \(PackageFormat.size(app.latestSize) ?? "the IPA")",
                                icon: .symbol("arrow.down.circle", Palette.amber),
                                progress: value, dimmed: true))
        case .unpacking, .preparing:
            rows.append(XMBItem(id: "pkg.progress", title: "Preparing container",
                                subtitle: "Unpacking Payload and patching the executable",
                                icon: .symbol("shippingbox", Palette.amber), dimmed: true))
        case .failed(let message):
            rows.append(XMBItem(id: "pkg.failed", title: "Install failed", subtitle: message,
                                icon: .symbol("exclamationmark.triangle.fill", Palette.clay),
                                dimmed: true))
        default:
            break
        }

        rows.append(XMBItem(
            id: "pkg.install",
            title: store.hasUpdate(app) ? "Update" : (installed ? "Reinstall" : "Install"),
            subtitle: PackageFormat.size(app.latestSize).map { "Download \($0)" } ?? "Download the IPA",
            icon: .symbol("arrow.down.circle.fill", Palette.ice),
            activate: { [weak self] in self?.install(entry) }
        ))

        if installed {
            rows.append(XMBItem(
                id: "pkg.launch",
                title: "Launch in Container",
                subtitle: "Hand this process to LiveContainer",
                icon: .symbol("play.fill", Palette.sage),
                activate: { [weak self] in self?.launch(app.bundleIdentifier) }
            ))
            rows.append(XMBItem(
                id: "pkg.manage",
                title: "Container",
                subtitle: "Tweaks, storage, reset",
                icon: .symbol("externaldrive.fill", Palette.stone),
                activate: { [weak self] in self?.push(.guest(app.bundleIdentifier)) }
            ))
        }

        rows.append(XMBItem(
            id: "pkg.source",
            title: entry.sourceName,
            subtitle: "Show everything in this repository",
            icon: .symbol("tray.full.fill", Palette.denim),
            activate: { [weak self] in self?.push(.source(entry.sourceID)) }
        ))

        return rows
    }

    /// The container page for something already installed.
    private func guestItems(_ bundle: String) -> [XMBItem] {
        let store = PackageStore.shared
        let containers = GuestContainerStore.shared
        guard let record = store.installed[bundle],
              let container = containers.container(for: bundle) else { return [] }

        let hasPayload = containers.hasPayload(container)
        let usage = containers.usage(of: container)
        let tweaks = TweakStore.shared

        var rows: [XMBItem] = [
            XMBItem(
                id: "guest.launch",
                title: hasPayload ? "Launch in Container" : "Download & Install",
                subtitle: hasPayload
                    ? "LiveContainer loads the guest and calls its entry point"
                    : "Fetch the IPA this app came from",
                icon: .symbol(hasPayload ? "play.fill" : "arrow.down.circle.fill", Palette.ice),
                activate: { [weak self] in
                    hasPayload ? self?.launch(bundle) : self?.reinstall(bundle)
                }
            )
        ]

        for tweak in tweaks.library where tweak.isLoadable {
            let enabled = tweaks.isEnabled(tweak, in: bundle)
            rows.append(XMBItem(
                id: "guest.tweak.\(tweak.id)",
                title: tweak.name,
                subtitle: enabled ? "Loaded into this app" : "Not loaded",
                icon: .symbol("puzzlepiece.extension.fill", enabled ? Palette.sage : Palette.stone),
                badge: enabled ? "ON" : "OFF",
                badgeTint: enabled ? Palette.sage : Palette.paperDim,
                activate: { [weak self] in self?.setTweak(!enabled, tweak: tweak, in: bundle) }
            ))
        }

        rows.append(contentsOf: [
            XMBItem(id: "guest.version", title: "Version", subtitle: record.version,
                    icon: .symbol("number", Palette.stone), dimmed: true),
            XMBItem(id: "guest.bundle", title: "Bundle Identifier", subtitle: bundle,
                    icon: .symbol("shippingbox.fill", Palette.stone), dimmed: true),
            XMBItem(id: "guest.disk", title: "On Disk",
                    subtitle: "\(usage.files) files · \(usage.sizeText)",
                    icon: .symbol("externaldrive.fill", Palette.stone), dimmed: true),
            XMBItem(
                id: "guest.reset",
                title: "Reset Container",
                subtitle: "Delete the guest's data and payload",
                icon: .symbol("arrow.counterclockwise", Palette.amber),
                activate: { [weak self] in
                    containers.reset(bundle)
                    self?.say("Container reset")
                }
            ),
            XMBItem(
                id: "guest.uninstall",
                title: "Uninstall",
                subtitle: "Remove the application and its container",
                icon: .symbol("trash.fill", Palette.clay),
                activate: { [weak self] in
                    store.remove(bundle)
                    self?.say("\(record.name) uninstalled")
                    self?.popAfterRemoval()
                }
            )
        ])

        return rows
    }

    // MARK: - Settings pages

    private func httpServerItems() -> [XMBItem] {
        let server = WebServer.shared
        let running = server.status.isRunning

        var rows: [XMBItem] = [
            XMBItem(
                id: "http.power",
                title: running ? "Stop Server" : "Start Server",
                subtitle: statusDetail(server.status),
                icon: .symbol(running ? "stop.circle.fill" : "play.circle.fill",
                              running ? Palette.clay : Palette.sage),
                badge: statusBadge(server.status),
                badgeTint: running ? Palette.sage : Palette.paperDim,
                activate: {
                    running ? server.stop() : server.start()
                    XMBSound.shared.play(running ? .back : .complete)
                }
            ),
            XMBItem(
                id: "http.port",
                title: "Port",
                subtitle: "← → to change, ✕ to apply",
                icon: .symbol("number.square.fill", Palette.denim),
                badge: "\(server.port)",
                activate: {
                    if running { server.restart() }
                    XMBSound.shared.play(.complete)
                },
                adjust: { delta in
                    let next = Int(server.port) + delta
                    server.port = UInt16(min(65_535, max(1_024, next)))
                }
            ),
            XMBItem(
                id: "http.root",
                title: "www Path",
                // The full path is a sandbox URL nobody can read at a glance;
                // the last two components are the part that identifies it.
                subtitle: server.root.pathComponents.suffix(2).joined(separator: "/"),
                icon: .symbol("folder.fill", Palette.wheat),
                badge: server.root.lastPathComponent,
                adjust: { [weak self] delta in self?.cycleServerRoot(by: delta) }
            )
        ]

        for address in server.addresses.prefix(3) {
            rows.append(XMBItem(
                id: "http.address.\(address)",
                title: address,
                subtitle: "✕ to copy this address",
                icon: .symbol("link", Palette.ice),
                activate: { [weak self] in
                    UIPasteboard.general.string = address
                    self?.say("Address copied")
                }
            ))
        }

        rows.append(XMBItem(
            id: "http.stats",
            title: "Requests Served",
            subtitle: "\(server.requestCount) requests · \(PackageFormat.size(server.bytesServed) ?? "0 bytes")",
            icon: .symbol("chart.bar.fill", Palette.stone),
            activate: { [weak self] in
                server.clearLog()
                self?.say("Log cleared")
            }
        ))

        for entry in server.log.prefix(6) {
            rows.append(XMBItem(
                id: "http.log.\(entry.id)",
                title: "\(entry.method) \(entry.path)",
                subtitle: "\(entry.status) · \(PackageFormat.size(entry.bytes) ?? "0 bytes")",
                icon: .symbol("arrow.left.arrow.right", entry.status < 400 ? Palette.sage : Palette.clay),
                dimmed: true
            ))
        }

        return rows
    }

    private func statusBadge(_ status: WebServer.Status) -> String {
        switch status {
        case .stopped: "OFF"
        case .starting: "…"
        case .running(let port): "ON :\(port)"
        case .paused: "PAUSED"
        case .failed: "ERROR"
        }
    }

    private func statusDetail(_ status: WebServer.Status) -> String {
        switch status {
        case .stopped: "The listener is down."
        case .starting: "Binding the socket…"
        case .running(let port): "Serving \(WebServer.shared.root.lastPathComponent) on port \(port)."
        case .paused: "iOS suspended the app; it resumes on return."
        case .failed(let message): message
        }
    }

    private func cycleServerRoot(by delta: Int) {
        let server = WebServer.shared
        var options = [WebServer.defaultRoot] + server.documentFolders
        // The default root is usually also a Documents folder.
        options = options.reduce(into: [URL]()) { unique, url in
            if !unique.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                unique.append(url)
            }
        }
        guard options.count > 1 else { return }
        let current = options.firstIndex { $0.standardizedFileURL == server.root.standardizedFileURL } ?? 0
        let next = (current + delta + options.count) % options.count
        server.setRoot(options[next], external: false)
    }

    private func jitItems() -> [XMBItem] {
        let result = jitProbe
        let ok = result == 0
        let signed = JITLessSigner.isAvailableForLaunch
        let canLaunch = ok || signed
        return [
            XMBItem(
                id: "jit.run",
                title: "Refresh JIT Status",
                subtitle: ok
                    ? (HostPlatform.isSimulator
                        ? "Simulator host runtime is available."
                        : "JIT provider state is active; no code probe was executed.")
                    : "No active JIT provider: \(String(cString: strerror(result)))",
                icon: .symbol(ok ? "checkmark.seal.fill" : "xmark.seal.fill",
                              ok ? Palette.sage : Palette.clay),
                badge: ok ? "AVAILABLE" : "BLOCKED",
                badgeTint: ok ? Palette.sage : Palette.clay,
                activate: { [weak self] in
                    self?.runJITProbe()
                    let passed = self?.jitProbe == 0
                    XMBSound.shared.play(passed ? .complete : .error)
                    self?.say(passed ? "JIT available" : "JIT unavailable")
                }
            ),
            XMBItem(id: "jit.host", title: "Host",
                    subtitle: HostPlatform.isSimulator ? "Simulator" : "Physical device",
                    icon: .symbol("cpu.fill", Palette.stone), dimmed: true),
            XMBItem(id: "jit.arch", title: "Architecture", subtitle: "arm64",
                    icon: .symbol("memorychip.fill", Palette.stone), dimmed: true),
            XMBItem(id: "jit.signing", title: "JIT-less Signing",
                    subtitle: signed
                        ? "Configured for team \(JITLessSigner.teamIdentifier ?? "unknown")"
                        : "Import a certificate in touchscreen Settings",
                    icon: .symbol(signed ? "checkmark.shield.fill" : "shield.slash.fill",
                                  signed ? Palette.sage : Palette.stone), dimmed: true),
            XMBItem(id: "jit.launch", title: "Container Launch",
                    subtitle: canLaunch
                        ? (signed ? "Enabled without JIT" : "Enabled with JIT")
                        : "Import a certificate or enable JIT",
                    icon: .symbol("play.rectangle.fill", canLaunch ? Palette.sage : Palette.stone),
                    dimmed: true),
            XMBItem(id: "jit.containers", title: "Containers Provisioned",
                    subtitle: "\(PackageStore.shared.installed.count)",
                    icon: .symbol("externaldrive.fill", Palette.stone), dimmed: true)
        ]
    }

    private func themeItems() -> [XMBItem] {
        let appearance = Appearance.shared
        return [
            XMBItem(
                id: "theme.accent",
                title: "Accent",
                subtitle: "Tints the dashboard, the wave and the pad's light bar",
                icon: .symbol("circle.fill", appearance.accent),
                badge: AccentChoice.all[appearance.accentIndex].name,
                badgeTint: appearance.accent,
                adjust: { delta in
                    let count = AccentChoice.all.count
                    appearance.accentIndex = (appearance.accentIndex + delta + count) % count
                    ControllerHub.shared.paintAll(appearance.accent)
                }
            ),
            toggle(id: "theme.motes", title: "Dust Motes",
                   subtitle: "Specks drifting through the light",
                   symbol: "sparkles", isOn: appearance.showMotes) {
                appearance.showMotes.toggle()
            },
            XMBItem(
                id: "theme.density",
                title: "Mote Density",
                subtitle: "\(appearance.moteCount) motes",
                icon: .symbol("slider.horizontal.3", Palette.ice),
                badge: "\(Int(appearance.moteDensity * 100))%",
                adjust: { delta in
                    appearance.moteDensity = min(1, max(0, appearance.moteDensity + Double(delta) * 0.05))
                },
                progress: appearance.moteDensity
            ),
            toggle(id: "theme.scanlines", title: "Scanlines",
                   subtitle: "A CRT's line structure over the wave",
                   symbol: "line.3.horizontal", isOn: appearance.scanlines) {
                appearance.scanlines.toggle()
            },
            toggle(id: "theme.motion", title: "Reduce Motion",
                   subtitle: "Freezes the wave and shortens animations",
                   symbol: "figure.walk.motion", isOn: appearance.reduceMotion) {
                appearance.reduceMotion.toggle()
            }
        ]
    }

    private func soundItems() -> [XMBItem] {
        let sound = XMBSound.shared
        return [
            toggle(id: "sound.effects", title: "Dashboard Effects",
                   subtitle: "Cursor, confirm, cancel", symbol: "waveform",
                   isOn: sound.effectsEnabled) { sound.effectsEnabled.toggle() },
            toggle(id: "sound.ambience", title: "Wave Ambience",
                   subtitle: "The bed under the dashboard", symbol: "water.waves",
                   isOn: sound.ambienceEnabled) { sound.ambienceEnabled.toggle() },
            XMBItem(
                id: "sound.volume",
                title: "Volume",
                subtitle: "← → to change",
                icon: .symbol("speaker.wave.3.fill", Palette.seafoam),
                badge: "\(Int(sound.volume * 100))%",
                adjust: { delta in
                    sound.volume = min(1, max(0, sound.volume + Float(delta) * 0.05))
                },
                progress: Double(sound.volume)
            ),
            XMBItem(
                id: "sound.test",
                title: "Play the Boot Sound",
                subtitle: "The swell the dashboard opens with",
                icon: .symbol("play.circle.fill", Palette.seafoam),
                activate: { sound.play(.boot) }
            )
        ]
    }

    private func controllerItems() -> [XMBItem] {
        let hub = ControllerHub.shared
        guard !hub.pads.isEmpty else {
            return [XMBItem(id: "pad.none", title: "No controller connected",
                            subtitle: "Pair a DualSense or DualShock 4 in iOS Settings → Bluetooth",
                            icon: .symbol("gamecontroller", Palette.stone), dimmed: true)]
        }

        var rows: [XMBItem] = []
        for pad in hub.pads {
            rows.append(XMBItem(
                id: "pad.\(pad.id)",
                title: pad.kind.title,
                subtitle: pad.vendorName,
                icon: .symbol(pad.kind.symbol, pad.kind.isPlayStation ? Palette.ice : Palette.stone),
                badge: pad.batteryText,
                badgeTint: (pad.battery ?? 1) < 0.2 ? Palette.clay : Palette.sage,
                info: XMBInfo(
                    title: pad.kind.title,
                    subtitle: pad.vendorName,
                    icon: .symbol(pad.kind.symbol, Palette.ice),
                    lines: [
                        .init(label: "Battery", value: pad.batteryText),
                        .init(label: "Light bar", value: pad.hasLightBar ? "Supported" : "None"),
                        .init(label: "Haptics", value: pad.hasHaptics ? "Supported" : "None"),
                        .init(label: "Adaptive triggers", value: pad.hasAdaptiveTriggers ? "Supported" : "None")
                    ],
                    accent: Palette.ice
                ),
                activate: {
                    hub.rumble(intensity: 0.8, sharpness: 0.4, duration: 0.25)
                },
                dimmed: true
            ))
        }

        rows.append(XMBItem(
            id: "pad.light",
            title: "Light Bar Colour",
            subtitle: "Follows the accent; ← → to change it here",
            icon: .symbol("lightbulb.fill", Appearance.shared.accent),
            badge: AccentChoice.all[Appearance.shared.accentIndex].name,
            badgeTint: Appearance.shared.accent,
            adjust: { delta in
                let count = AccentChoice.all.count
                Appearance.shared.accentIndex = (Appearance.shared.accentIndex + delta + count) % count
                hub.paintAll(Appearance.shared.accent)
            }
        ))

        rows.append(XMBItem(
            id: "pad.rumble",
            title: "Test Rumble",
            subtitle: "A short pulse through every connected pad",
            icon: .symbol("waveform.path", Palette.mauve),
            activate: { hub.rumble(intensity: 1, sharpness: 0.3, duration: 0.4) }
        ))

        rows.append(XMBItem(
            id: "pad.exit",
            title: "Return to iOS Home Screen",
            subtitle: "Also the PS button, from the top of the dashboard",
            icon: .symbol("iphone", Palette.paperDim),
            activate: { [weak self] in self?.requestExit() }
        ))

        return rows
    }

    private func aboutItems() -> [XMBItem] {
        let store = PackageStore.shared
        return [
            XMBItem(id: "about.model", title: "Model", subtitle: DeviceIdentity.phoneModelName,
                    icon: .symbol("cpu.fill", Palette.stone), dimmed: true),
            XMBItem(id: "about.version", title: "System Software", subtitle: "VibeContainers 1.0 (41) · iOS Edition",
                    icon: .symbol("gear", Palette.stone), dimmed: true),
            XMBItem(id: "about.host", title: "Host", subtitle: HostPlatform.name,
                    icon: .symbol("desktopcomputer", Palette.stone), dimmed: true),
            XMBItem(id: "about.packages", title: "Applications",
                    subtitle: "\(store.installed.count) installed from \(store.sources.count) repositories",
                    icon: .symbol("shippingbox.fill", Palette.stone), dimmed: true),
            XMBItem(id: "about.tweaks", title: "Tweaks",
                    subtitle: "\(TweakStore.shared.library.count) in the library",
                    icon: .symbol("puzzlepiece.extension.fill", Palette.stone), dimmed: true),
            XMBItem(id: "about.renderer", title: "Renderer", subtitle: "SwiftUI Canvas",
                    icon: .symbol("paintbrush.fill", Palette.stone), dimmed: true),
            XMBItem(id: "about.acknowledgements", title: "Acknowledgements",
                    subtitle: "Thanks Duy Trans for livecontainers",
                    icon: .symbol("heart.fill", Palette.stone), dimmed: true),
            XMBItem(
                id: "about.exit",
                title: "Return to iOS Home Screen",
                subtitle: "Leave the dashboard",
                icon: .symbol("arrow.uturn.left", Palette.paperDim),
                activate: { [weak self] in self?.requestExit() }
            )
        ]
    }

    private func connectionItems() -> [XMBItem] {
        let addresses = WebServer.localIPv4Addresses()
        var rows: [XMBItem] = [
            XMBItem(id: "net.status", title: "Status",
                    subtitle: addresses.isEmpty ? "Not connected" : "Connected",
                    icon: .symbol("wifi", addresses.isEmpty ? Palette.clay : Palette.sage),
                    badge: addresses.isEmpty ? "OFFLINE" : "ONLINE",
                    badgeTint: addresses.isEmpty ? Palette.clay : Palette.sage,
                    dimmed: true)
        ]

        for address in addresses {
            rows.append(XMBItem(
                id: "net.addr.\(address)",
                title: address,
                subtitle: "✕ to copy",
                icon: .symbol("network", Palette.denim),
                activate: { [weak self] in
                    UIPasteboard.general.string = address
                    self?.say("Address copied")
                }
            ))
        }

        rows.append(XMBItem(
            id: "net.server",
            title: "HTTP Server",
            subtitle: statusDetail(WebServer.shared.status),
            icon: .symbol("server.rack", Palette.sage),
            badge: statusBadge(WebServer.shared.status),
            activate: { [weak self] in self?.push(.httpServer) }
        ))

        return rows
    }

    private func tweakItems() -> [XMBItem] {
        let tweaks = TweakStore.shared
        guard !tweaks.library.isEmpty else {
            return [XMBItem(id: "tweak.empty", title: "There are no titles.",
                            subtitle: "Drop a .dylib into Documents/Tweaks",
                            icon: .symbol("puzzlepiece.extension", Palette.stone), dimmed: true)]
        }

        return tweaks.library.map { tweak in
            let global = tweaks.isGlobal(tweak)
            return XMBItem(
                id: "tweak.\(tweak.id)",
                title: tweak.name,
                subtitle: tweak.detail,
                icon: .symbol("puzzlepiece.extension.fill",
                              tweak.isLoadable ? (global ? Palette.sage : Palette.mauve) : Palette.clay),
                badge: tweak.isLoadable ? (global ? "GLOBAL" : "OFF") : "UNLOADABLE",
                badgeTint: global ? Palette.sage : Palette.paperDim,
                info: XMBInfo(
                    title: tweak.name,
                    subtitle: tweak.detail,
                    icon: .symbol("puzzlepiece.extension.fill", Palette.mauve),
                    lines: [
                        .init(label: "Loadable", value: tweak.isLoadable ? "Yes" : "No"),
                        .init(label: "Scope", value: global ? "Every container" : "Per application")
                    ],
                    body: "A global tweak writes an LC_LOAD_DYLIB command into every installed app's executable; dyld loads it at the next launch.",
                    accent: Palette.mauve
                ),
                activate: { [weak self] in
                    guard tweak.isLoadable else { XMBSound.shared.play(.error); return }
                    self?.setGlobalTweak(!global, tweak: tweak)
                }
            )
        }
    }

    /// A row whose ✕ flips a Boolean.
    private func toggle(id: String,
                        title: String,
                        subtitle: String,
                        symbol: String,
                        isOn: Bool,
                        action: @escaping () -> Void) -> XMBItem {
        XMBItem(
            id: id,
            title: title,
            subtitle: subtitle,
            icon: .symbol(symbol, isOn ? Palette.sage : Palette.stone),
            badge: isOn ? "ON" : "OFF",
            badgeTint: isOn ? Palette.sage : Palette.paperDim,
            activate: action,
            adjust: { _ in action() }
        )
    }
}

// MARK: - Actions

extension XMBNavigator {
    func install(_ entry: PackageStore.Entry) {
        let store = PackageStore.shared
        let bundle = entry.app.bundleIdentifier
        guard !store.pendingInstallBundles.contains(bundle),
              !GuestInstaller.shared.isBusy(bundle) else {
            say("\(entry.app.name) is already installing")
            return
        }
        guard entry.app.latest?.downloadURL != nil else {
            XMBSound.shared.play(.error)
            say("\(entry.app.name) has no download in \(entry.sourceName)")
            return
        }
        store.install(entry.app, from: entry.sourceName)
        say("Installing \(entry.app.name)…")
        watchInstall(of: entry.app.bundleIdentifier, named: entry.app.name)
    }

    func applyUpdate(_ update: PackageStore.PendingUpdate) {
        let store = PackageStore.shared
        let bundle = update.installed.bundleIdentifier
        guard !store.pendingInstallBundles.contains(bundle),
              !GuestInstaller.shared.isBusy(bundle) else {
            say("\(update.installed.name) is already updating")
            return
        }
        store.update(update)
        say("Updating \(update.installed.name)…")
        watchInstall(of: update.installed.bundleIdentifier, named: update.installed.name)
    }

    private func reinstall(_ bundle: String) {
        guard let entry = PackageStore.shared.entry(bundleIdentifier: bundle) else {
            XMBSound.shared.play(.error)
            say("No repository currently carries this app")
            return
        }
        install(entry)
    }

    /// Says so when the install lands, so a long download still ends with the
    /// same confirmation a short one gets.
    private func watchInstall(of bundle: String, named name: String) {
        Task { [weak self] in
            let installer = GuestInstaller.shared
            for _ in 0..<600 {
                try? await Task.sleep(for: .milliseconds(500))
                switch installer.phase(for: bundle) {
                case .ready:
                    XMBSound.shared.play(.complete)
                    self?.say("\(name) installed")
                    return
                case .failed(let message):
                    XMBSound.shared.play(.error)
                    self?.say(message)
                    return
                default:
                    continue
                }
            }
        }
    }

    func launch(_ bundle: String) {
        guard let container = GuestContainerStore.shared.container(for: bundle) else {
            XMBSound.shared.play(.error)
            say("No container for \(bundle)")
            return
        }
        say(JITLessSigner.isAvailableForLaunch ? "Signing guest…" : "Preparing guest…")
        Task { [weak self] in
            let outcome = await GuestInstaller.shared.launch(container)
            if outcome.ok {
                XMBSound.shared.play(.complete)
            } else {
                XMBSound.shared.play(.error)
                self?.say(outcome.headline)
            }
        }
    }

    private func setTweak(_ isOn: Bool, tweak: TweakStore.Tweak, in bundle: String) {
        do {
            try TweakStore.shared.setEnabled(isOn, tweak: tweak, in: bundle)
        } catch {
            XMBSound.shared.play(.error)
            say(error.localizedDescription)
        }
    }

    private func setGlobalTweak(_ isOn: Bool, tweak: TweakStore.Tweak) {
        do {
            try TweakStore.shared.setGlobal(isOn, tweak: tweak)
            say(isOn ? "\(tweak.name) loads into every container" : "\(tweak.name) disabled")
        } catch {
            XMBSound.shared.play(.error)
            say(error.localizedDescription)
        }
    }

    private func play(_ song: Song) {
        nowPlaying = song
        say("Now playing · \(song.title)")
    }

    private func refreshAll() {
        say("Refreshing every repository…")
        Task {
            await PackageStore.shared.refreshAll()
            XMBSound.shared.play(.complete)
        }
    }

    /// The row that was open no longer exists; step back to the list it was in.
    private func popAfterRemoval() {
        handle(.circle)
    }
}
