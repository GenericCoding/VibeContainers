import Foundation
import Observation

/// The feeds the home screen reads, and the articles pulled from them.
///
/// Articles are cached to `UserDefaults` so the page has something to show the
/// instant it is swiped to, rather than a spinner on every launch; the refresh
/// then happens behind whatever is already on screen.
@MainActor
@Observable
final class FeedStore {
    static let shared = FeedStore()

    static let defaultFeed = "https://varik.dev/feed.xml"

    struct Source: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var url: String
        /// Filled in from the feed itself on the first successful fetch.
        var title: String

        var host: String { URL(string: url)?.host() ?? url }
    }

    struct Article: Identifiable, Codable, Hashable {
        var id: String
        var title: String
        var summary: String
        var link: String
        var sourceTitle: String
        var date: Date?

        var dateText: String {
            guard let date else { return "" }
            let elapsed = Date().timeIntervalSince(date)
            if elapsed < 60 * 60 * 24 * 7 {
                return date.formatted(.relative(presentation: .named))
            }

            // Feeds routinely stamp a post as midnight UTC, which is a *date*
            // rather than an instant. Rendering that locally in a timezone
            // behind GMT dates every article a day early, so it is read back in
            // the timezone it was written in.
            return Self.isMidnightUTC(date)
                ? Self.utcDayFormatter.string(from: date)
                : Self.dayFormatter.string(from: date)
        }

        private static func isMidnightUTC(_ date: Date) -> Bool {
            guard let utc = TimeZone(secondsFromGMT: 0) else { return false }
            let parts = Calendar(identifier: .gregorian).dateComponents(in: utc, from: date)
            return parts.hour == 0 && parts.minute == 0 && parts.second == 0
        }

        private static let dayFormatter = makeDayFormatter(timeZone: .current)
        private static let utcDayFormatter = makeDayFormatter(timeZone: TimeZone(secondsFromGMT: 0) ?? .current)

        private static func makeDayFormatter(timeZone: TimeZone) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
            return formatter
        }
    }

    enum AddResult {
        case added(Source)
        case failed(String)
    }

    private(set) var sources: [Source]
    private(set) var articles: [Article]
    private(set) var refreshing = false
    private(set) var failures: [UUID: String] = [:]
    private(set) var lastRefreshed: Date?

    private let sourcesKey = "feeds.sources"
    private let articlesKey = "feeds.articles"
    private let refreshedKey = "feeds.lastRefreshed"

    private init() {
        let defaults = UserDefaults.standard
        sources = Self.decode([Source].self, from: defaults.data(forKey: sourcesKey))
            ?? [Source(url: Self.defaultFeed, title: "Varik's Blog")]
        articles = Self.decode([Article].self, from: defaults.data(forKey: articlesKey)) ?? []
        lastRefreshed = defaults.object(forKey: refreshedKey) as? Date
    }

    // MARK: - Sources

    func add(url raw: String) async -> AddResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard let url = URL(string: normalized), url.host() != nil else {
            return .failed("That is not a URL.")
        }
        guard !sources.contains(where: { $0.url == normalized }) else {
            return .failed("That feed is already in the list.")
        }

        do {
            let feed = try await fetch(url)
            var source = Source(url: normalized, title: feed.title.isEmpty ? url.host() ?? normalized : feed.title)
            if source.title.isEmpty { source.title = normalized }
            sources.append(source)
            merge(feed, from: source)
            persist()
            return .added(source)
        } catch {
            return .failed(Self.describe(error))
        }
    }

    func remove(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        // The articles it contributed go with it.
        articles.removeAll { $0.sourceTitle == source.title }
        failures[source.id] = nil
        persist()
    }

    // MARK: - Refreshing

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        for source in sources {
            do {
                guard let url = URL(string: source.url) else { throw FeedError.badURL }
                let feed = try await fetch(url)
                if let index = sources.firstIndex(where: { $0.id == source.id }),
                   !feed.title.isEmpty, sources[index].title != feed.title {
                    // A feed that renamed itself takes its articles with it.
                    let old = sources[index].title
                    sources[index].title = feed.title
                    for position in articles.indices where articles[position].sourceTitle == old {
                        articles[position].sourceTitle = feed.title
                    }
                }
                merge(feed, from: sources.first { $0.id == source.id } ?? source)
                failures[source.id] = nil
            } catch {
                failures[source.id] = Self.describe(error)
            }
        }

        lastRefreshed = Date()
        persist()
    }

    /// Refreshes if the last one is stale, so swiping to the page does not
    /// re-fetch every feed each time.
    func refreshIfStale(after interval: TimeInterval = 900) async {
        guard let lastRefreshed else { return await refresh() }
        guard Date().timeIntervalSince(lastRefreshed) > interval else { return }
        await refresh()
    }

    private enum FeedError: LocalizedError {
        case badURL, notAFeed, status(Int)

        var errorDescription: String? {
            switch self {
            case .badURL: "That is not a URL."
            case .notAFeed: "No RSS or Atom feed there."
            case .status(let code): "The server answered \(code)."
            }
        }
    }

    private func fetch(_ url: URL) async throws -> ParsedFeed {
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 20)
        request.setValue("VibeContainers/1.0 (feed reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8",
                         forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.status(http.statusCode)
        }
        guard let feed = FeedParser.parse(data) else { throw FeedError.notAFeed }
        return feed
    }

    /// Folds a fetch into the article list, newest first, without duplicating
    /// anything already there.
    private func merge(_ feed: ParsedFeed, from source: Source) {
        let name = feed.title.isEmpty ? source.title : feed.title
        var known = Set(articles.map(\.id))

        for item in feed.items {
            let id = item.identifier.isEmpty ? "\(name)|\(item.title)" : item.identifier
            guard !known.contains(id) else { continue }
            known.insert(id)
            articles.append(Article(id: id,
                                    title: item.title,
                                    summary: item.summary,
                                    link: item.link,
                                    sourceTitle: name,
                                    date: item.date))
        }

        articles.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if articles.count > 120 { articles.removeLast(articles.count - 120) }
    }

    // MARK: - Persistence

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(sources), forKey: sourcesKey)
        defaults.set(try? JSONEncoder().encode(articles), forKey: articlesKey)
        defaults.set(lastRefreshed, forKey: refreshedKey)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func describe(_ error: Error) -> String {
        if let feedError = error as? FeedError { return feedError.localizedDescription }
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "No internet connection."
        case NSURLErrorTimedOut: return "The feed timed out."
        case NSURLErrorCannotFindHost: return "That host does not resolve."
        default: return ns.localizedDescription
        }
    }
}
