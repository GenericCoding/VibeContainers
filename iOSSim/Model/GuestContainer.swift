import Foundation
import Darwin

/// A data container for an installed guest app, modelled on LiveContainer's.
///
/// LiveContainer gives every guest app its own directory tree and redirects the
/// guest's `NSHomeDirectory()` into it, so several copies of an app can hold
/// separate data. The directories here are real — created, measured and wiped
/// on disk — which is the part of that design that ports.
///
/// The installer uses LiveContainer's original executable conversion on both
/// hosts. The guest remains `PLATFORM_IOS`; Simulator builds patch dyld's
/// platform routing, while physical builds use either matching ZSign code
/// signatures or the native JIT/library-validation path before redirecting
/// HOME and handing off to guest main.
@MainActor
@Observable
final class GuestContainerStore {
    static let shared = GuestContainerStore()

    struct Container: Codable, Identifiable, Hashable {
        let bundleIdentifier: String
        var uuid: UUID
        var created: Date
        var id: String { bundleIdentifier }
    }

    private(set) var containers: [String: Container] = [:]
    private let key = "guest.containers"

    private init() {
        containers = Self.load() ?? [:]
    }

    // MARK: - Lifecycle

    var root: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Containers", isDirectory: true)
    }

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var liveContainerApplicationsRoot: URL {
        documents.appendingPathComponent("Applications", isDirectory: true)
    }

    private var liveContainerDataRoot: URL {
        documents.appendingPathComponent("Data/Application", isDirectory: true)
    }

    func url(for container: Container) -> URL {
        root.appendingPathComponent(container.uuid.uuidString, isDirectory: true)
    }

    func applicationURL(for container: Container) -> URL {
        liveContainerApplicationsRoot
            .appendingPathComponent(container.bundleIdentifier)
            .appendingPathExtension("app")
    }

    /// Publishes the extracted bundle at LiveContainer's canonical
    /// Documents/Applications location without duplicating its bytes.
    func publish(_ appBundle: URL, for container: Container) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: liveContainerApplicationsRoot,
                                    withIntermediateDirectories: true)
        let published = applicationURL(for: container)

        // Write the metadata before changing the public application link. The
        // link rename below is the commit point: if any preparation fails, an
        // update keeps resolving to the old, known-good bundle.
        let appInfoURL = url(for: container).appendingPathComponent("LCAppInfo.plist")
        let appInfo: [String: Any] = [
            "bundlePath": published.path,
            "LCDataUUID": container.uuid.uuidString,
            "LCOrignalBundleIdentifier": container.bundleIdentifier
        ]
        let appInfoData = try PropertyListSerialization.data(
            fromPropertyList: appInfo,
            format: .binary,
            options: 0
        )
        try appInfoData.write(to: appInfoURL, options: .atomic)

        // Simulator reinstalls can move the host's Data/Application UUID while
        // preserving Documents. An absolute link would then point at the old,
        // nonexistent container. Both locations are below Documents, so keep
        // the link relative and relocation-safe.
        let destination = "../Containers/\(container.uuid.uuidString)/Payload/\(appBundle.lastPathComponent)"
        let pendingLink = liveContainerApplicationsRoot
            .appendingPathComponent(".publish-\(UUID().uuidString)")
        try manager.createSymbolicLink(atPath: pendingLink.path,
                                       withDestinationPath: destination)
        defer { try? manager.removeItem(at: pendingLink) }

        // `rename(2)` replaces an existing symlink in one filesystem operation,
        // so readers see either the previous target or the fully prepared one.
        let renameResult = pendingLink.path.withCString { source in
            published.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard renameResult == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not publish the prepared app link: \(String(cString: strerror(code)))"
                ]
            )
        }
    }

    @discardableResult
    func provision(for bundleIdentifier: String) -> Container {
        if let existing = containers[bundleIdentifier] {
            createTree(for: existing)
            return existing
        }

        let container = Container(bundleIdentifier: bundleIdentifier, uuid: UUID(), created: Date())
        createTree(for: container)
        containers[bundleIdentifier] = container
        persist()
        return container
    }

    func container(for bundleIdentifier: String) -> Container? {
        containers[bundleIdentifier]
    }

    func destroy(_ bundleIdentifier: String) {
        guard let container = detachForDestruction(bundleIdentifier) else { return }
        destroyDetached(container)
    }

    /// Removes a container from the live registry without touching its files.
    /// Widget uninstall uses this as the logical commit point, then destroys
    /// the detached tree only after SwiftUI has dismantled every renderer.
    func detachForDestruction(_ bundleIdentifier: String) -> Container? {
        guard let container = containers.removeValue(forKey: bundleIdentifier) else {
            return nil
        }
        persist()
        return container
    }

    /// Destroys a previously detached container. The public application path
    /// is removed only when its symlink still names this exact UUID, so a fast
    /// reinstall can never have its newly-published app deleted by an older
    /// deferred teardown.
    func destroyDetached(_ container: Container) {
        let manager = FileManager.default
        let published = applicationURL(for: container)
        if let destination = try? manager.destinationOfSymbolicLink(atPath: published.path),
           destination.split(separator: "/").contains(Substring(container.uuid.uuidString)) {
            try? manager.removeItem(at: published)
        }
        try? FileManager.default.removeItem(
            at: liveContainerDataRoot.appendingPathComponent(container.uuid.uuidString)
        )
        try? FileManager.default.removeItem(at: url(for: container))
    }

    /// Wipes the contents and lays the tree down again, keeping the identity.
    func reset(_ bundleIdentifier: String) {
        guard let container = containers[bundleIdentifier] else { return }
        try? FileManager.default.removeItem(at: applicationURL(for: container))
        try? FileManager.default.removeItem(at: url(for: container))
        createTree(for: container)
    }

    private func createTree(for container: Container) {
        let base = url(for: container)
        let manager = FileManager.default
        for leaf in ["Documents", "Library/Caches", "Library/Preferences", "tmp"] {
            try? manager.createDirectory(
                at: base.appendingPathComponent(leaf, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        // The upstream bootstrap resolves containers from
        // Documents/Data/Application/<UUID>. Keep iOSSim's existing storage
        // layout and expose it there with a symlink.
        try? manager.createDirectory(at: liveContainerDataRoot,
                                     withIntermediateDirectories: true)
        let liveData = liveContainerDataRoot.appendingPathComponent(container.uuid.uuidString)
        try? manager.removeItem(at: liveData)
        try? manager.createSymbolicLink(
            atPath: liveData.path,
            withDestinationPath: "../../Containers/\(container.uuid.uuidString)"
        )
        // A marker file, so the container has something real in it to measure.
        let marker = base.appendingPathComponent("Library/Preferences/container.plist")
        let info: [String: Any] = [
            "CFBundleIdentifier": container.bundleIdentifier,
            "ContainerUUID": container.uuid.uuidString,
            "Created": ISO8601DateFormatter().string(from: container.created)
        ]
        try? NSDictionary(dictionary: info).write(to: marker)
    }

    // MARK: - Measurement

    struct Usage {
        var files: Int
        var bytes: Int64

        var sizeText: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }
    }

    func usage(of container: Container) -> Usage {
        let base = url(for: container)
        guard let walker = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return Usage(files: 0, bytes: 0) }

        var usage = Usage(files: 0, bytes: 0)
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            usage.files += 1
            usage.bytes += Int64(values?.fileSize ?? 0)
        }
        return usage
    }

    /// Whether a downloaded payload is present in the container.
    func hasPayload(_ container: Container) -> Bool {
        let payload = url(for: container).appendingPathComponent("Payload", isDirectory: true)
        return FileManager.default.fileExists(atPath: payload.path)
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(containers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func load() -> [String: Container]? {
        guard let data = UserDefaults.standard.data(forKey: "guest.containers") else { return nil }
        return try? JSONDecoder().decode([String: Container].self, from: data)
    }
}

/// The host's Mach-O platform, read at runtime so the launch screen can state
/// the actual mismatch rather than assert one.
enum HostPlatform {
    /// `LC_BUILD_VERSION` platform constants.
    static let simulator = 7
    static let device = 2

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    static var name: String { isSimulator ? "iOS Simulator (platform 7)" : "iOS device (platform 2)" }
    static var guestName: String { "iOS device (platform 2)" }
}
