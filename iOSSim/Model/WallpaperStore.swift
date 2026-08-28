import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Pocket Poster/Nugget's archive type. The identifier is intentionally
    /// imported rather than exported: iOSSim consumes Tendies packages but
    /// does not claim to author the PosterBoard format.
    static let tendies = UTType(importedAs: "com.leemin.tendies", conformingTo: .archive)
}

enum WallpaperKind: String, Codable {
    case image
    case gif
    case video
    case tendies

    var title: String {
        switch self {
        case .image: "Image"
        case .gif: "Animated GIF"
        case .video: "Video"
        case .tendies: "Tendies Live Wallpaper"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo.fill"
        case .gif: "sparkles.rectangle.stack.fill"
        case .video: "play.rectangle.fill"
        case .tendies: "livephoto"
        }
    }
}

enum WallpaperRenderer: String, Codable {
    case image
    case gif
    case video
    case tendiesLayers
}

struct ImportedWallpaper: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let kind: WallpaperKind
    let renderer: WallpaperRenderer
    let directoryName: String
    let resourceRelativePath: String
}

@MainActor
@Observable
final class WallpaperStore {
    static let shared = WallpaperStore()

    static let supportedContentTypes: [UTType] = [
        .image,
        .movie,
        .tendies
    ]

    private(set) var items: [ImportedWallpaper] = []
    private(set) var selectedID: UUID?

    var selected: ImportedWallpaper? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    private struct SavedLibrary: Codable {
        let items: [ImportedWallpaper]
        let selectedID: UUID?
    }

    private static let defaultsKey = "wallpapers.library.v1"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode(SavedLibrary.self, from: data) else {
            return
        }

        let root = try? Self.libraryRoot()
        items = saved.items.filter { item in
            guard let root else { return false }
            return FileManager.default.fileExists(
                atPath: root.appendingPathComponent(item.directoryName, isDirectory: true).path
            )
        }
        if let selectedID = saved.selectedID, items.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        }
    }

    func selectBuiltIn() {
        selectedID = nil
        save()
    }

    func select(_ item: ImportedWallpaper) {
        guard items.contains(item) else { return }
        selectedID = item.id
        save()
    }

    func fileURL(for item: ImportedWallpaper) -> URL? {
        guard items.contains(item), let root = try? Self.libraryRoot() else { return nil }
        let directory = root.appendingPathComponent(item.directoryName, isDirectory: true)
        let candidate = directory.appendingPathComponent(item.resourceRelativePath).standardizedFileURL
        let prefix = directory.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(prefix) else { return nil }
        return candidate
    }

    @discardableResult
    func importWallpaper(from sourceURL: URL) async throws -> ImportedWallpaper {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let item = try await Task.detached(priority: .userInitiated) {
            try Self.stageWallpaper(from: sourceURL)
        }.value

        items.removeAll { $0.id == item.id }
        items.append(item)
        selectedID = item.id
        save()
        return item
    }

    func remove(_ item: ImportedWallpaper) throws {
        guard items.contains(item), item.directoryName == item.id.uuidString else { return }
        let root = try Self.libraryRoot().standardizedFileURL
        let directory = root.appendingPathComponent(item.directoryName, isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent().path == root.path else { return }

        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        items.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = nil }
        save()
    }

    private func save() {
        let saved = SavedLibrary(items: items, selectedID: selectedID)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    nonisolated private static func libraryRoot() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw WallpaperImportError.storageUnavailable
        }
        let root = support.appendingPathComponent("Wallpapers", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    nonisolated private static func stageWallpaper(from sourceURL: URL) throws -> ImportedWallpaper {
        let ext = sourceURL.pathExtension.lowercased()
        guard let kind = kind(forExtension: ext) else {
            throw WallpaperImportError.unsupportedType
        }

        let id = UUID()
        let root = try libraryRoot()
        let staging = root.appendingPathComponent(".\(id.uuidString).importing", isDirectory: true)
        let final = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            let sourceName = sourceURL.deletingPathExtension().lastPathComponent
            let displayName = sourceName.isEmpty ? "Wallpaper" : sourceName
            let item: ImportedWallpaper

            if kind == .tendies {
                item = try stageTendies(
                    sourceURL,
                    id: id,
                    fallbackName: displayName,
                    staging: staging
                )
            } else {
                let filename = "Wallpaper.\(ext)"
                try manager.copyItem(at: sourceURL, to: staging.appendingPathComponent(filename))
                item = ImportedWallpaper(
                    id: id,
                    name: displayName,
                    kind: kind,
                    renderer: renderer(for: kind),
                    directoryName: id.uuidString,
                    resourceRelativePath: filename
                )
            }

            try manager.moveItem(at: staging, to: final)
            return item
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    nonisolated private static func stageTendies(
        _ sourceURL: URL,
        id: UUID,
        fallbackName: String,
        staging: URL
    ) throws -> ImportedWallpaper {
        let manager = FileManager.default
        let archive = staging.appendingPathComponent("Original.tendies")
        let payload = staging.appendingPathComponent("Payload", isDirectory: true)
        try manager.copyItem(at: sourceURL, to: archive)
        try ZipArchive.extract(
            archive,
            to: payload,
            maximumUncompressedBytes: 512 * 1_024 * 1_024,
            maximumEntries: 20_000
        )

        let requiredRoots = ["container", "descriptor", "descriptors"]
        guard requiredRoots.contains(where: {
            manager.fileExists(atPath: payload.appendingPathComponent($0, isDirectory: true).path)
        }) else {
            throw WallpaperImportError.invalidTendies
        }

        let files = descendantFiles(in: payload)
        let packageName = tendiesName(in: files) ?? fallbackName

        if let video = largestFile(in: files, extensions: ["mov", "mp4", "m4v"]) {
            return ImportedWallpaper(
                id: id,
                name: packageName,
                kind: .tendies,
                renderer: .video,
                directoryName: id.uuidString,
                resourceRelativePath: relativePath(of: video, under: staging)
            )
        }
        if let gif = largestFile(in: files, extensions: ["gif"]) {
            return ImportedWallpaper(
                id: id,
                name: packageName,
                kind: .tendies,
                renderer: .gif,
                directoryName: id.uuidString,
                resourceRelativePath: relativePath(of: gif, under: staging)
            )
        }
        if files.contains(where: { $0.lastPathComponent == "main.caml" }) {
            // A Tendies archive may restore several PosterBoard descriptors
            // (for example, one per seasonal variant). Render one descriptor
            // deterministically instead of stacking every descriptor's layers.
            let descriptorRoot = files
                .filter { $0.lastPathComponent == "Wallpaper.plist" }
                .sorted { $0.path < $1.path }
                .first?
                .deletingLastPathComponent()
            return ImportedWallpaper(
                id: id,
                name: packageName,
                kind: .tendies,
                renderer: .tendiesLayers,
                directoryName: id.uuidString,
                resourceRelativePath: relativePath(of: descriptorRoot ?? payload, under: staging)
            )
        }
        if let image = largestFile(
            in: files,
            extensions: ["png", "jpg", "jpeg", "heic", "heif", "webp"]
        ) {
            return ImportedWallpaper(
                id: id,
                name: packageName,
                kind: .tendies,
                renderer: .image,
                directoryName: id.uuidString,
                resourceRelativePath: relativePath(of: image, under: staging)
            )
        }

        throw WallpaperImportError.noRenderableContent
    }

    nonisolated private static func kind(forExtension ext: String) -> WallpaperKind? {
        switch ext {
        case "tendies": .tendies
        case "gif": .gif
        case "mov", "mp4", "m4v": .video
        case "png", "jpg", "jpeg", "heic", "heif", "webp": .image
        default: nil
        }
    }

    nonisolated private static func renderer(for kind: WallpaperKind) -> WallpaperRenderer {
        switch kind {
        case .image: .image
        case .gif: .gif
        case .video: .video
        case .tendies: .tendiesLayers
        }
    }

    nonisolated private static func descendantFiles(in root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        return files
    }

    nonisolated private static func largestFile(in files: [URL], extensions: Set<String>) -> URL? {
        files
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .max { lhs, rhs in fileSize(lhs) < fileSize(rhs) }
    }

    nonisolated private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    nonisolated private static func tendiesName(in files: [URL]) -> String? {
        for plist in files where plist.lastPathComponent == "Wallpaper.plist" {
            guard let data = try? Data(contentsOf: plist),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = object as? [String: Any],
                  let name = dictionary["name"] as? String,
                  !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    nonisolated private static func relativePath(of url: URL, under root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(prefix.count))
    }
}

enum WallpaperImportError: LocalizedError {
    case unsupportedType
    case invalidTendies
    case noRenderableContent
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            "Choose an image, animated GIF, MOV/MP4 video, or .tendies wallpaper."
        case .invalidTendies:
            "This archive is not a valid Tendies container or descriptor package."
        case .noRenderableContent:
            "The Tendies package does not contain a supported animation or image."
        case .storageUnavailable:
            "The wallpaper library is not available."
        }
    }
}
