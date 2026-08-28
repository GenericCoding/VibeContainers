import Foundation

enum AssociatedDomainResolver {
    static func bundleIDs(for host: String) async -> [String] {
        var hosts = [host]
        if host.hasPrefix("www.") {
            hosts.append(String(host.dropFirst(4)))
        }

        for host in hosts {
            let bundleIDs = await fetchBundleIDs(for: host)
            if !bundleIDs.isEmpty {
                return bundleIDs
            }
        }
        return []
    }

    private static func fetchBundleIDs(for host: String) async -> [String] {
        let urls = [
            URL(string: "https://\(host)/apple-app-site-association"),
            URL(string: "https://\(host)/.well-known/apple-app-site-association")
        ].compactMap { $0 }

        return await withTaskGroup(of: [String].self) { group in
            for url in urls {
                group.addTask {
                    await fetchBundleIDs(from: url)
                }
            }

            var result: [String] = []
            for await ids in group {
                for id in ids where !result.contains(id) {
                    result.append(id)
                }
            }
            return result
        }
    }

    private static func fetchBundleIDs(from url: URL) async -> [String] {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let association = try JSONDecoder().decode(SiteAssociation.self, from: data)
            return association.applinks?.details.flatMap { $0.bundleIDs } ?? []
        } catch {
            return []
        }
    }
}

private struct SiteAssociation: Decodable {
    let applinks: AppLinks?
}

private struct AppLinks: Decodable {
    let details: [SiteAssociationDetailItem]

    enum CodingKeys: String, CodingKey {
        case details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let array = try? container.decode([SiteAssociationDetailItem].self, forKey: .details) {
            details = array
            return
        }
        if let dictionary = try? container.decode([String: SiteAssociationDetailItem].self, forKey: .details) {
            details = dictionary.map { appID, item in
                var item = item
                if item.appID == nil {
                    item.appID = appID
                }
                return item
            }
            return
        }
        details = []
    }
}

private struct SiteAssociationDetailItem: Decodable {
    var appID: String?
    let appIDs: [String]?

    var bundleIDs: [String] {
        var result: [String] = []
        if let appID {
            result.append(Self.bundleID(from: appID))
        }
        if let appIDs {
            result.append(contentsOf: appIDs.map(Self.bundleID(from:)))
        }
        return result.filter { !$0.isEmpty }
    }

    private static func bundleID(from appID: String) -> String {
        guard let dot = appID.firstIndex(of: ".") else {
            return ""
        }
        return String(appID[appID.index(after: dot)...])
    }
}
