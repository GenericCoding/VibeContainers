import Foundation

/// An AltStore source document.
///
/// Sources come in two shapes in the wild: the original one carries the
/// version fields on the app itself, the current one nests them in a
/// `versions` array (newest first). Real repos often carry *both* for
/// backwards compatibility, so the model decodes either and prefers the array.
struct AltSource: Decodable, Sendable {
    let name: String
    let identifier: String?
    let subtitle: String?
    let iconURL: String?
    let website: String?
    let tintColor: String?
    let apps: [AltApp]
    let news: [AltNews]
    /// Bundle identifiers the source wants promoted.
    let featuredApps: [String]

    enum CodingKeys: String, CodingKey {
        case name, identifier, subtitle, iconURL, website, tintColor, apps, news, featuredApps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled Source"
        identifier = try? container.decode(String.self, forKey: .identifier)
        subtitle = try? container.decode(String.self, forKey: .subtitle)
        iconURL = try? container.decode(String.self, forKey: .iconURL)
        website = try? container.decode(String.self, forKey: .website)
        tintColor = try? container.decode(String.self, forKey: .tintColor)
        // Decoded element by element: a single malformed app in a real repo
        // would otherwise take the entire catalogue down with it.
        apps = (try? container.decode(LossyArray<AltApp>.self, forKey: .apps))?.elements ?? []
        news = (try? container.decode(LossyArray<AltNews>.self, forKey: .news))?.elements ?? []
        featuredApps = (try? container.decode([String].self, forKey: .featuredApps)) ?? []
    }

    var featured: [AltApp] {
        let identifiers = Set(featuredApps)
        let promoted = apps.filter { identifiers.contains($0.bundleIdentifier) }
        return promoted.isEmpty ? Array(apps.prefix(2)) : promoted
    }
}

struct AltApp: Decodable, Sendable {
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let localizedDescription: String?
    let iconURL: String?
    let tintColor: String?
    let category: String?
    let beta: Bool?

    private let screenshotURLs: [String]?
    private let screenshots: AltScreenshotSet?
    private let appPermissions: AltPermissions?

    // Legacy, top-level.
    private let version: String?
    private let versionDate: String?
    private let size: Int?
    private let downloadURL: String?
    private let minOSVersion: String?

    // Current, newest first. Nothing in the app needs historical releases, so
    // decode only the first element instead of retaining every version from a
    // repository. Large sources often carry dozens per app.
    private let versions: FirstElement<AltVersion>?

    var latest: AltVersion? {
        if let current = versions?.value { return current }
        guard let downloadURL else { return nil }
        return AltVersion(
            version: version ?? "—",
            date: versionDate,
            localizedDescription: nil,
            downloadURL: downloadURL,
            size: size,
            minOSVersion: minOSVersion
        )
    }
    var latestVersion: String { latest?.version ?? version ?? "—" }
    var latestDate: String? { latest?.date ?? versionDate }
    var latestSize: Int? { latest?.size ?? size }
    var releaseNotes: String? { latest?.localizedDescription }

    var developer: String { developerName ?? "Unknown developer" }
    var blurb: String { subtitle ?? localizedDescription ?? developer }

    var shots: [String] {
        if let urls = screenshots?.urls, !urls.isEmpty { return urls }
        return screenshotURLs ?? []
    }

    var privacyNotes: [AltPermissions.Privacy] { appPermissions?.privacy ?? [] }
    var entitlements: [String] { (appPermissions?.entitlements ?? []).map(\.name) }

    var categoryLabel: String? { category?.capitalized }
}

/// `screenshots` takes three shapes in the wild: a plain array of URLs, an
/// array mixing URLs and sized objects, or a dictionary keyed by device
/// ("iphone" / "ipad"). AltStore's own source uses all three across six apps.
struct AltScreenshotSet: Decodable, Sendable {
    let urls: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Detail pages display at most ten shots. Some large sources include
        // dozens per app, so retaining every URL multiplies catalogue memory
        // for data the UI can never show.
        if let list = try? container.decode(CappedLossyArray<AltScreenshot>.self) {
            urls = list.elements.map(\.url)
        } else if let byDevice = try? container.decode([String: CappedLossyArray<AltScreenshot>].self) {
            let preferred = byDevice["iphone"]?.elements
                ?? byDevice.values.first?.elements
                ?? []
            urls = preferred.map(\.url)
        } else {
            urls = []
        }
    }
}

struct AltScreenshot: Decodable, Sendable {
    let url: String

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            url = raw
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .imageURL)
    }

    private enum CodingKeys: String, CodingKey { case imageURL }
}

struct AltPermissions: Decodable, Sendable {
    struct Entitlement: Decodable, Sendable {
        let name: String

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                name = value
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
        }

        private enum CodingKeys: String, CodingKey { case name }
    }

    struct Privacy: Decodable, Identifiable, Sendable {
        let name: String
        let usageDescription: String?
        var id: String { name }
    }

    let entitlements: [Entitlement]?
    let privacy: [Privacy]?

    init(from decoder: Decoder) throws {
        // Permission metadata has changed shape across AltStore source
        // generations. It is optional display data and must never make an
        // otherwise installable app disappear from a lossy catalogue decode.
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            entitlements = []
            privacy = []
            return
        }

        entitlements = (try? container.decode(
            LossyArray<Entitlement>.self,
            forKey: .entitlements
        ))?.elements ?? []

        if let list = try? container.decode(LossyArray<Privacy>.self, forKey: .privacy) {
            privacy = list.elements
        } else if let values = try? container.decode([String: String].self, forKey: .privacy) {
            privacy = values
                .map { Privacy(name: $0.key, usageDescription: $0.value) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } else {
            privacy = []
        }
    }

    private enum CodingKeys: String, CodingKey { case entitlements, privacy }
}

struct AltNews: Decodable, Identifiable, Sendable {
    let title: String
    let identifier: String?
    let caption: String?
    let tintColor: String?
    let imageURL: String?
    let date: String?
    let url: String?
    let appID: String?

    var id: String { identifier ?? title }
}

struct AltVersion: Decodable, Sendable {
    let version: String
    let date: String?
    let localizedDescription: String?
    let downloadURL: String?
    let size: Int?
    let minOSVersion: String?
}

/// Decodes what it can and steps over what it cannot.
/// Decodes only the first member of an array. An unkeyed nested container does
/// not need to be consumed before its parent can continue decoding.
private struct FirstElement<Element: Decodable & Sendable>: Decodable, Sendable {
    let value: Element?

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        value = container.isAtEnd ? nil : try? container.decode(Element.self)
    }
}

/// Consumes an entire JSON array while retaining only the first few valid
/// members. Consuming the tail keeps decoding correct without letting unused
/// screenshot metadata dominate memory for very large catalogues.
private struct CappedLossyArray<Element: Decodable & Sendable>: Decodable, Sendable {
    let elements: [Element]

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var kept: [Element] = []
        kept.reserveCapacity(min(container.count ?? 10, 10))

        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                if kept.count < 10 { kept.append(element) }
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        elements = kept
    }
}

struct LossyArray<Element: Decodable & Sendable>: Decodable, Sendable {
    var elements: [Element] = []

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if let count = container.count { elements.reserveCapacity(count) }
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // A failed decode leaves the cursor put; Skip always succeeds,
                // so it consumes the bad element and the loop can progress.
                _ = try? container.decode(Skip.self)
            }
        }
    }
}

// MARK: - Version comparison

enum SemVer {
    /// Compares dotted version strings component by component, ignoring any
    /// non-numeric decoration ("1.6.3b" reads as 1.6.3).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ value: String) -> [Int] {
        value.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }
}

// MARK: - URL normalisation

enum SourceURL {
    /// Accepts what people actually paste: a bare host, or a GitHub *page*
    /// URL, which serves HTML rather than the JSON the repo needs.
    static func normalise(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard var url = URL(string: text) else { return nil }

        // github.com/<user>/<repo>/blob/<ref>/<path> → raw.githubusercontent.com
        if url.host?.contains("github.com") == true {
            let parts = url.path.split(separator: "/").map(String.init)
            if let blob = parts.firstIndex(of: "blob"), parts.count > blob + 1 {
                var rebuilt = parts
                rebuilt.remove(at: blob)
                if let raw = URL(string: "https://raw.githubusercontent.com/" + rebuilt.joined(separator: "/")) {
                    url = raw
                }
            }
        }
        return url
    }
}
