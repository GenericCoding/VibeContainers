import Foundation
import SwiftUI

/// Sources, their fetched catalogues, and the local record of what is
/// "installed".
///
/// GET persists the selected catalogue record, provisions a LiveContainer
/// slot, and downloads the exact IPA URL from that JSON entry. The Installed
/// screen exposes preparation status and launches the extracted app through
/// LiveContainer. Records are diffed against each source for updates/removals.
@MainActor
@Observable
final class PackageStore {
    static let shared = PackageStore()

    struct Source: Codable, Identifiable, Hashable, Sendable {
        var id: UUID = UUID()
        var url: String
        /// Falls back to the URL host until the catalogue has been fetched.
        var name: String?

        var host: String {
            URL(string: url)?.host ?? url
        }
        var displayName: String { name ?? host }
    }

    struct InstalledApp: Codable, Identifiable, Hashable, Sendable {
        let bundleIdentifier: String
        var name: String
        var developer: String
        var version: String
        var sourceName: String
        var iconURL: String?
        var installedAt: Date

        var id: String { bundleIdentifier }
    }

    struct PendingUpdate: Identifiable, Sendable {
        let installed: InstalledApp
        let app: AltApp
        let sourceName: String
        var id: String { installed.bundleIdentifier }
    }

    private(set) var sources: [Source] = []
    private(set) var installed: [String: InstalledApp] = [:]

    private(set) var catalogs: [UUID: AltSource] = [:]
    var loading: Set<UUID> = []
    var failures: [UUID: String] = [:]

    private var catalogIndex = CatalogIndex()
    private(set) var installedList: [InstalledApp] = []
    private(set) var updates: [PendingUpdate] = []
    private(set) var pendingInstallBundles: Set<String> = []
    private(set) var catalogGeneration = 0
    private var updateBundleIdentifiers: Set<String> = []
    private var indexRevision = 0
    @ObservationIgnored private var refreshAllInProgress = false

    private let sourcesKey = "packages.sources"
    private let installedKey = "packages.installed"

    private init() {
        sources = Self.load([Source].self, from: sourcesKey) ?? Self.seed
        installed = Self.load([String: InstalledApp].self, from: installedKey) ?? [:]
        rebuildInstalledIndex()
    }

    private static let seed: [Source] = [
        .init(url: "https://apps.altstore.io/", name: "AltStore"),
        .init(url: "https://raw.githubusercontent.com/noah978/AltStore-Docs/master/apps.json",
              name: nil)
    ]

    // MARK: - Aggregates across every source

    /// One app, remembered together with the source it came from.
    struct Entry: Identifiable, Sendable {
        let app: AltApp
        let sourceID: UUID
        let sourceName: String
        let id: String

        init(app: AltApp, sourceID: UUID, sourceName: String) {
            self.app = app
            self.sourceID = sourceID
            self.sourceName = sourceName
            id = "\(sourceID.uuidString)|\(app.bundleIdentifier)"
        }
    }

    struct CategoryGroup: Identifiable, Sendable {
        let name: String
        let entries: [Entry]
        var id: String { name }
    }

    private struct SearchRecord: Sendable {
        let entry: Entry
        let text: String
    }

    private struct CatalogIndex: Sendable {
        var allApps: [Entry] = []
        var alphabeticalApps: [Entry] = []
        var featured: [Entry] = []
        var recentlyUpdated: [Entry] = []
        var allNews: [(item: AltNews, sourceName: String)] = []
        var categories: [CategoryGroup] = []
        var entriesByID: [String: Entry] = [:]
        var entriesByBundle: [String: Entry] = [:]
        var entriesBySource: [UUID: [Entry]] = [:]
        var alphabeticalEntriesBySource: [UUID: [Entry]] = [:]
        var searchRecords: [SearchRecord] = []
    }

    var allApps: [Entry] { catalogIndex.allApps }
    var alphabeticalApps: [Entry] { catalogIndex.alphabeticalApps }
    var featured: [Entry] { catalogIndex.featured }
    var recentlyUpdated: [Entry] { catalogIndex.recentlyUpdated }
    var allNews: [(item: AltNews, sourceName: String)] { catalogIndex.allNews }
    var categories: [CategoryGroup] { catalogIndex.categories }

    func entries(for sourceID: UUID) -> [Entry] {
        catalogIndex.entriesBySource[sourceID] ?? []
    }

    func alphabeticalEntries(for sourceID: UUID) -> [Entry] {
        catalogIndex.alphabeticalEntriesBySource[sourceID] ?? []
    }

    func search(_ query: String) async -> [Entry] {
        let text = Self.searchText(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return [] }

        // Searching large repositories is deliberately detached from the main
        // actor. The task is cancelled as the user keeps typing, so obsolete
        // scans never compete with the query currently on screen.
        let records = catalogIndex.searchRecords
        let worker: Task<[Entry], Never> = Task.detached(priority: .userInitiated) {
            var matches: [Entry] = []
            matches.reserveCapacity(min(records.count, 128))
            for (index, record) in records.enumerated() {
                if index.isMultiple(of: 256), Task.isCancelled { return [Entry]() }
                if record.text.contains(text) { matches.append(record.entry) }
            }
            return matches
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func entry(id: String) -> Entry? { catalogIndex.entriesByID[id] }
    func entry(bundleIdentifier: String) -> Entry? { catalogIndex.entriesByBundle[bundleIdentifier] }

    // MARK: - Catalogue

    func apps(for source: Source) -> [AltApp] { catalogs[source.id]?.apps ?? [] }

    func isInstalled(_ app: AltApp) -> Bool {
        installed[app.bundleIdentifier] != nil && hasReadyPayload(app.bundleIdentifier)
    }

    func hasUpdate(_ app: AltApp) -> Bool {
        isInstalled(app) && updateBundleIdentifiers.contains(app.bundleIdentifier)
    }

    /// Builds every expensive catalogue projection once, when source data
    /// changes, instead of once per SwiftUI body evaluation.
    private func rebuildCatalogIndex() async {
        indexRevision &+= 1
        let revision = indexRevision
        let sourceSnapshot = sources
        let catalogSnapshot = catalogs

        let index = await Task.detached(priority: .userInitiated) {
            Self.makeCatalogIndex(sources: sourceSnapshot, catalogs: catalogSnapshot)
        }.value

        // Source refreshes may overlap. Never let an older, slower build
        // replace a newer snapshot that has already reached the UI.
        guard revision == indexRevision else { return }
        catalogIndex = index
        catalogGeneration &+= 1
        rebuildInstalledIndex()
    }

    private func scheduleCatalogIndexRebuild() {
        indexRevision &+= 1
        let revision = indexRevision
        let sourceSnapshot = sources
        let catalogSnapshot = catalogs

        Task { @MainActor in
            let index = await Task.detached(priority: .userInitiated) {
                Self.makeCatalogIndex(sources: sourceSnapshot, catalogs: catalogSnapshot)
            }.value
            guard revision == indexRevision else { return }
            catalogIndex = index
            catalogGeneration &+= 1
            rebuildInstalledIndex()
        }
    }

    private nonisolated static func makeCatalogIndex(
        sources: [Source],
        catalogs: [UUID: AltSource]
    ) -> CatalogIndex {
        let capacity = sources.reduce(into: 0) { total, source in
            total += catalogs[source.id]?.apps.count ?? 0
        }

        var apps: [Entry] = []
        var featured: [Entry] = []
        var news: [(item: AltNews, sourceName: String)] = []
        var byCategory: [String: [Entry]] = [:]
        var byID: [String: Entry] = [:]
        var byBundle: [String: Entry] = [:]
        var bySource: [UUID: [Entry]] = [:]
        var alphabeticalBySource: [UUID: [Entry]] = [:]
        var searchRecords: [SearchRecord] = []

        apps.reserveCapacity(capacity)
        byID.reserveCapacity(capacity)
        byBundle.reserveCapacity(capacity)
        searchRecords.reserveCapacity(capacity)

        for source in sources {
            guard let catalog = catalogs[source.id] else { continue }
            let promotedIDs = Set(catalog.featuredApps)
            var sourceEntries: [Entry] = []
            var sourceFeatured: [Entry] = []
            sourceEntries.reserveCapacity(catalog.apps.count)

            for app in catalog.apps {
                let entry = Entry(app: app, sourceID: source.id, sourceName: catalog.name)
                apps.append(entry)
                sourceEntries.append(entry)
                byID[entry.id] = entry
                if byBundle[app.bundleIdentifier] == nil {
                    byBundle[app.bundleIdentifier] = entry
                }

                let category = app.categoryLabel ?? "Other"
                byCategory[category, default: []].append(entry)
                if promotedIDs.contains(app.bundleIdentifier) { sourceFeatured.append(entry) }

                let searchable = [
                    app.name,
                    app.developer,
                    app.subtitle ?? "",
                    category,
                    catalog.name
                ].joined(separator: "\u{1F}")
                searchRecords.append(SearchRecord(entry: entry, text: Self.searchText(searchable)))
            }

            if sourceFeatured.isEmpty {
                featured.append(contentsOf: sourceEntries.prefix(2))
            } else {
                featured.append(contentsOf: sourceFeatured)
            }
            bySource[source.id] = sourceEntries
            alphabeticalBySource[source.id] = sourceEntries.sorted(by: Self.entryNameOrder)
            news.append(contentsOf: catalog.news.map { (item: $0, sourceName: catalog.name) })
        }

        let categories = byCategory
            .map { CategoryGroup(name: $0.key, entries: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return CatalogIndex(
            allApps: apps,
            alphabeticalApps: apps.sorted(by: Self.entryNameOrder),
            featured: featured,
            recentlyUpdated: apps.sorted { ($0.app.latestDate ?? "") > ($1.app.latestDate ?? "") },
            allNews: news.sorted { ($0.item.date ?? "") > ($1.item.date ?? "") },
            categories: categories,
            entriesByID: byID,
            entriesByBundle: byBundle,
            entriesBySource: bySource,
            alphabeticalEntriesBySource: alphabeticalBySource,
            searchRecords: searchRecords
        )
    }

    private func rebuildInstalledIndex() {
        installedList = installed.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        updates = installedList.compactMap { record in
            guard hasReadyPayload(record.bundleIdentifier),
                  let entry = catalogIndex.entriesByBundle[record.bundleIdentifier],
                  SemVer.isNewer(entry.app.latestVersion, than: record.version) else { return nil }
            return PendingUpdate(installed: record, app: entry.app, sourceName: entry.sourceName)
        }
        updateBundleIdentifiers = Set(updates.map(\.installed.bundleIdentifier))
    }

    private nonisolated static func entryNameOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let order = lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name)
        return order == .orderedSame
            ? lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedAscending
            : order == .orderedAscending
    }

    private nonisolated static func searchText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: .current)
    }

    // MARK: - Fetching

    func refreshAll() async {
        guard !refreshAllInProgress else { return }
        refreshAllInProgress = true
        defer { refreshAllInProgress = false }

        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await self.refresh(source, rebuildIndex: false) }
            }
        }
        await rebuildCatalogIndex()
    }

    func refresh(_ source: Source) async {
        await refresh(source, rebuildIndex: true)
    }

    private func refresh(_ source: Source, rebuildIndex: Bool) async {
        guard let url = SourceURL.normalise(source.url) else {
            failures[source.id] = "That doesn't look like a URL."
            return
        }
        // OPTIONS, the Sources screen, and controller activation can all ask
        // for a refresh at nearly the same time. A large source must never be
        // downloaded and decoded more than once concurrently: besides wasted
        // work, the first request to finish would clear `loading` while a
        // duplicate was still mutating the same catalogue.
        guard !loading.contains(source.id) else { return }
        loading.insert(source.id)
        failures[source.id] = nil
        defer { loading.remove(source.id) }

        do {
            let catalog = try await Self.fetch(url)
            // The request may have outlived a source the user removed. Do not
            // retain a now-unreachable (and potentially enormous) catalogue.
            guard sources.contains(where: { $0.id == source.id }) else { return }
            catalogs[source.id] = catalog
            // Adopt the catalogue's own name once we have it.
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].name = catalog.name
                persistSources()
            }
            if rebuildIndex { await rebuildCatalogIndex() }
        } catch {
            failures[source.id] = message(for: error)
        }
    }

    private nonisolated static func fetch(_ url: URL) async throws -> AltSource {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StoreError.badStatus(http.statusCode)
        }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(AltSource.self, from: data)
            }.value
        } catch {
            throw StoreError.notASource
        }
    }

    // MARK: - Sources

    @discardableResult
    func addSource(url raw: String) async -> Result<Source, StoreError> {
        guard let url = SourceURL.normalise(raw) else { return .failure(.badURL) }
        let normalised = url.absoluteString

        if sources.contains(where: { SourceURL.normalise($0.url)?.absoluteString == normalised }) {
            return .failure(.duplicate)
        }

        do {
            let catalog = try await Self.fetch(url)
            let source = Source(url: normalised, name: catalog.name)
            sources.append(source)
            catalogs[source.id] = catalog
            persistSources()
            await rebuildCatalogIndex()
            return .success(source)
        } catch let error as StoreError {
            return .failure(error)
        } catch {
            return .failure(.offline(message(for: error)))
        }
    }

    func removeSource(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        catalogs[source.id] = nil
        failures[source.id] = nil
        loading.remove(source.id)
        persistSources()
        scheduleCatalogIndexRebuild()
    }

    // MARK: - Installed cache

    func install(_ app: AltApp, from sourceName: String) {
        let bundleIdentifier = app.bundleIdentifier
        guard !pendingInstallBundles.contains(bundleIdentifier),
              !GuestInstaller.shared.isBusy(bundleIdentifier) else { return }
        pendingInstallBundles.insert(bundleIdentifier)

        let completedRecord = InstalledApp(
            bundleIdentifier: bundleIdentifier,
            name: app.name,
            developer: app.developer,
            version: app.latestVersion,
            sourceName: sourceName,
            iconURL: app.iconURL,
            installedAt: Date()
        )
        let container = GuestContainerStore.shared.provision(for: bundleIdentifier)

        // Start the real transfer immediately. GuestInstaller reads
        // app.latest.downloadURL from this decoded source entry and performs
        // download, extraction, patching and optional JIT-less signing in a
        // private same-volume transaction. An update never resets the existing
        // container: its Payload is exchanged only after validation, while
        // Documents, Library, tmp and the container UUID remain untouched.
        // Do not publish the catalogue record until that entire pipeline has
        // reached `.ready` and the app's executable is visible at the canonical
        // LiveContainer path. Otherwise GET briefly becomes OPEN/UPDATE while
        // the IPA is still downloading or a failed partial Payload remains.
        Task {
            defer { pendingInstallBundles.remove(bundleIdentifier) }
            let succeeded = await GuestInstaller.shared.install(app, into: container)
            guard succeeded,
                  GuestInstaller.shared.phase(for: bundleIdentifier) == .ready,
                  hasReadyPayload(bundleIdentifier) else { return }
            installed[bundleIdentifier] = completedRecord
            persistInstalled()
            rebuildInstalledIndex()
        }
    }

    /// A persisted catalogue record alone is not an installed app. Require the
    /// published bundle and the exact CFBundleExecutable so state survives a
    /// relaunch without accepting half-extracted Payload directories.
    func hasReadyPayload(_ bundleIdentifier: String) -> Bool {
        guard let container = GuestContainerStore.shared.container(for: bundleIdentifier) else {
            return false
        }
        let app = GuestContainerStore.shared.applicationURL(for: container)
            .resolvingSymlinksInPath()
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: app.path, isDirectory: &directory),
              directory.boolValue,
              let executable = GuestInstaller.executable(in: app) else { return false }
        return FileManager.default.fileExists(atPath: executable.path)
    }

    /// Records an app that arrived as a bare `.ipa` rather than from a source.
    ///
    /// It goes in the same installed list as anything else, so the home screen,
    /// the tweak injector and the container screen all treat it identically —
    /// the only difference is where the bytes came from.
    func recordSideload(bundleIdentifier: String,
                        name: String,
                        version: String,
                        sourceName: String,
                        iconURL: String?) {
        installed[bundleIdentifier] = InstalledApp(
            bundleIdentifier: bundleIdentifier,
            name: name,
            developer: bundleIdentifier,
            version: version,
            sourceName: sourceName,
            iconURL: iconURL,
            installedAt: Date()
        )
        persistInstalled()
        rebuildInstalledIndex()
    }

    /// Bumps the recorded version — the same bookkeeping a real update does
    /// once the download has landed.
    func update(_ update: PendingUpdate) {
        install(update.app, from: update.sourceName)
    }

    func remove(_ bundleIdentifier: String) {
        // A widget renderer can hold a private host, an async preparation task,
        // and guest Swift values whose metadata lives inside the payload. Tear
        // down every dependent layer while the bundle still exists; deleting
        // the files first leaves those renderers dereferencing vanished code.
        var widgetDescriptorIDs = ContainerWidgetStore.shared.removeWidgets(
            ownedBy: bundleIdentifier
        )
        widgetDescriptorIDs.formUnion(HomeLayoutStore.shared.removeWidgets(
            ownedBy: bundleIdentifier,
            columns: Appearance.shared.columns
        ))
        ContainerWidgetRuntimeRenderer.shared.retireWidgets(
            descriptorIDs: widgetDescriptorIDs
        )

        installed[bundleIdentifier] = nil
        persistInstalled()
        rebuildInstalledIndex()

        guard let container = GuestContainerStore.shared.detachForDestruction(
            bundleIdentifier
        ) else { return }

        // Give SwiftUI one frame to cancel placement-scoped `.task`s and call
        // representable dismantlers after the observable collections above
        // have changed. All work remains MainActor-isolated.
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))
            GuestContainerStore.shared.destroyDetached(container)
        }
    }

    // MARK: - Persistence

    private func persistSources() { Self.save(sources, to: sourcesKey) }
    private func persistInstalled() { Self.save(installed, to: installedKey) }

    private static func save<T: Encodable>(_ value: T, to key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, from key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Errors

    enum StoreError: Error {
        case badURL
        case duplicate
        case badStatus(Int)
        case notASource
        case offline(String)

        var message: String {
            switch self {
            case .badURL: "That doesn't look like a URL."
            case .duplicate: "That source has already been added."
            case .badStatus(let code): "The server replied \(code)."
            case .notASource: "That URL didn't return an AltStore source."
            case .offline(let detail): detail
            }
        }
    }

    private func message(for error: Error) -> String {
        if let store = error as? StoreError { return store.message }
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "No internet connection."
        case NSURLErrorTimedOut: return "The server took too long to reply."
        case NSURLErrorCannotFindHost: return "Couldn't find that host."
        default: return ns.localizedDescription
        }
    }
}

// MARK: - Formatting

@MainActor
enum PackageFormat {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useKB, .useGB]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let plainDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let outputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    static func size(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return byteFormatter.string(fromByteCount: Int64(bytes))
    }

    static func date(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parsed = isoFormatter.date(from: raw)
            ?? plainDateFormatter.date(from: String(raw.prefix(10)))
        guard let parsed else { return nil }
        return outputDateFormatter.string(from: parsed)
    }
}
