import Foundation
import Network
import UIKit

@_silgen_name("IOSSimCopyContainerApplicationIcon")
private func IOSSimCopyContainerApplicationIcon(
    _ bundlePath: UnsafePointer<CChar>
) -> UnsafeMutableRawPointer?

/// Creates a real iOS Home Screen web clip whose URL deep-links directly into
/// a VibeContainers guest. iOS requires the user to approve every Home Screen
/// profile, so the app serves the generated `.mobileconfig` to Safari and lets
/// the system own the confirmation/install step.
@MainActor
final class HomeScreenShortcutInstaller {
    static let shared = HomeScreenShortcutInstaller()

    private var downloads: [UUID: DownloadServer] = [:]
    private var backgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]

    private init() {}

    func beginInstall(
        bundleIdentifier: String,
        displayName: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(.failure(ShortcutError.serverUnavailable))
                return
            }
            do {
                let profile = try await makeProfile(
                    bundleIdentifier: bundleIdentifier,
                    displayName: displayName
                )
                try beginServing(
                    profile,
                    displayName: displayName,
                    completion: completion
                )
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func beginServing(
        _ profile: Data,
        displayName: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        let token = UUID()
        let fileName = safeFileName(displayName) + ".mobileconfig"
        let server = try DownloadServer(data: profile, fileName: fileName)
        downloads[token] = server

        backgroundTasks[token] = UIApplication.shared.beginBackgroundTask(
            withName: "Install VibeContainers Home Screen Shortcut"
        ) { [weak self] in
            Task { @MainActor in self?.finish(token) }
        }

        server.onReady = { [weak self] port in
            Task { @MainActor in
                guard self?.downloads[token] != nil,
                      let url = URL(string: "http://127.0.0.1:\(port)/\(fileName)") else {
                    completion(.failure(ShortcutError.serverUnavailable))
                    self?.finish(token)
                    return
                }
                UIApplication.shared.open(url, options: [:]) { opened in
                    Task { @MainActor in
                        if opened {
                            completion(.success(()))
                        } else {
                            completion(.failure(ShortcutError.couldNotOpenSafari))
                            self?.finish(token)
                        }
                    }
                }
            }
        }
        server.onFinished = { [weak self] in
            Task { @MainActor in self?.finish(token) }
        }
        server.start()

        // A profile download takes one request. Do not leave a listener or
        // background assertion alive if Safari never reaches it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            self?.finish(token)
        }
    }

    private func finish(_ token: UUID) {
        downloads.removeValue(forKey: token)?.stop()
        if let task = backgroundTasks.removeValue(forKey: token), task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func makeProfile(bundleIdentifier: String, displayName: String) async throws -> Data {
        guard !bundleIdentifier.isEmpty else { throw ShortcutError.missingBundleIdentifier }

        let profileUUID = UUID().uuidString
        let clipUUID = UUID().uuidString
        let icon = try await iconPNG(for: bundleIdentifier)
        let iconRevision = Self.iconRevision(for: icon)
        let escapedBundle = bundleIdentifier.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? bundleIdentifier
        let identifierSuffix = bundleIdentifier
            .lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" }
        let payloadIdentifier = "com.vibecontainers.webclip.\(String(identifierSuffix))"

        let webClip: [String: Any] = [
            "FullScreen": false,
            "IsRemovable": true,
            "Icon": icon,
            "Label": String(displayName.prefix(32)),
            "PayloadDescription": "Opens \(displayName) in VibeContainers.",
            "PayloadDisplayName": displayName,
            // SpringBoard caches web-clip artwork by payload/URL identity. A
            // revision derived from the exact PNG bytes prevents an old
            // VibeContainers-icon shortcut from surviving a profile update.
            "PayloadIdentifier": payloadIdentifier + ".clip." + iconRevision,
            "PayloadType": "com.apple.webClip.managed",
            "PayloadUUID": clipUUID,
            "PayloadVersion": 1,
            "Precomposed": true,
            "URL": "iossim://guest/\(escapedBundle)?icon=\(iconRevision)"
        ]

        let profile: [String: Any] = [
            "PayloadContent": [webClip],
            "PayloadDescription": "Adds a direct Home Screen shortcut for \(displayName).",
            "PayloadDisplayName": "Add \(displayName) to Home Screen",
            "PayloadIdentifier": payloadIdentifier,
            "PayloadOrganization": "VibeContainers",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": profileUUID,
            "PayloadVersion": 1
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: profile,
            format: .xml,
            options: 0
        )
        // Validate the serialized artifact, not just the UIImage before it is
        // inserted. This guarantees the `Icon` field Safari receives remains
        // a decodable 180x180 PNG belonging to this guest/generic container.
        guard let decodedProfile = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              let payloads = decodedProfile["PayloadContent"] as? [[String: Any]],
              let encodedIcon = payloads.first?["Icon"] as? Data,
              let decodedIcon = UIImage(data: encodedIcon),
              decodedIcon.size == CGSize(width: 180, height: 180) else {
            throw ShortcutError.couldNotEncodeIcon
        }
        return data
    }

    /// Stable FNV-1a digest used only as a cache revision. It is deliberately
    /// based on the final normalized PNG, so the identity changes exactly when
    /// the bytes embedded into the profile change.
    private nonisolated static func iconRevision(for data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    /// Resolve the selected guest's own primary icon. Installed bundle artwork
    /// wins because it remains available offline and exactly matches the app
    /// being launched; the package record is a fallback for asset-catalog-only
    /// apps whose IPA does not expose a standalone PNG.
    private func iconPNG(for bundleIdentifier: String) async throws -> Data {
        let image: UIImage
        if let bundledIcon = containerBundleIcon(for: bundleIdentifier) {
            image = bundledIcon
        } else if let renderedIcon = renderedContainerIcon(for: bundleIdentifier) {
            image = renderedIcon
        } else if let localIcon = localPackageIcon(for: bundleIdentifier) {
            image = localIcon
        } else if let remoteIcon = await remotePackageIcon(for: bundleIdentifier) {
            image = remoteIcon
        } else {
            image = genericContainerIcon()
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 180), format: format)
        guard let data = renderer.image(actions: { _ in
            let target = Self.aspectFillRect(
                imageSize: image.size,
                bounds: CGRect(x: 0, y: 0, width: 180, height: 180)
            )
            image.draw(in: target)
        }).pngData(),
              let decoded = UIImage(data: data),
              decoded.size == CGSize(width: 180, height: 180) else {
            throw ShortcutError.couldNotEncodeIcon
        }
        return data
    }

    private func containerBundleIcon(for bundleIdentifier: String) -> UIImage? {
        guard let app = containerApplicationURL(for: bundleIdentifier) else { return nil }
        let info = NSDictionary(
            contentsOf: app.appendingPathComponent("Info.plist")
        ) as? [String: Any]

        var stems: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info?[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
            else { continue }
            if let files = primary["CFBundleIconFiles"] as? [String] {
                stems.append(contentsOf: files)
            }
            if let name = primary["CFBundleIconName"] as? String {
                stems.append(name)
            }
        }
        if let file = info?["CFBundleIconFile"] as? String { stems.append(file) }
        let normalizedStems = Set(stems.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        })

        let files = (try? FileManager.default.contentsOfDirectory(
            at: app,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = files.compactMap { url -> (UIImage, Int, Int)? in
            guard url.pathExtension.lowercased() == "png",
                  let image = UIImage(contentsOfFile: url.path) else { return nil }
            let base = url.deletingPathExtension().lastPathComponent
            let declared = normalizedStems.contains { base.hasPrefix($0) }
            let conventional = base.localizedCaseInsensitiveContains("appicon")
                || base.localizedCaseInsensitiveContains("icon")
            guard declared || (normalizedStems.isEmpty && conventional) else { return nil }
            let pixels = Int(image.size.width * image.scale)
                * Int(image.size.height * image.scale)
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (image, pixels, bytes)
        }
        return candidates.max {
            $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1
        }?.0
    }

    /// Asset-catalog-only apps do not necessarily ship a loose AppIcon PNG.
    /// Ask LiveContainer's existing IconServices renderer for the installed
    /// guest bundle rendition before considering repository artwork.
    private func renderedContainerIcon(for bundleIdentifier: String) -> UIImage? {
        guard let app = containerApplicationURL(for: bundleIdentifier) else { return nil }
        let pointer = app.path.withCString(IOSSimCopyContainerApplicationIcon)
        guard let pointer else { return nil }
        return Unmanaged<UIImage>.fromOpaque(pointer).takeRetainedValue()
    }

    /// Resolve the public application symlink, then prove it remains beneath
    /// this container's private Payload directory. This prevents a stale or
    /// corrupted link from ever supplying the host app's artwork.
    private func containerApplicationURL(for bundleIdentifier: String) -> URL? {
        guard let container = GuestContainerStore.shared.container(for: bundleIdentifier)
        else { return nil }
        let payload = GuestContainerStore.shared.url(for: container)
            .appendingPathComponent("Payload", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let app = GuestContainerStore.shared.applicationURL(for: container)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let payloadPrefix = payload.path.hasSuffix("/") ? payload.path : payload.path + "/"
        guard app.path.hasPrefix(payloadPrefix),
              app.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              FileManager.default.fileExists(atPath: app.path) else {
            NSLog("[ShortcutIcon] Rejected application path outside %@ for %@: %@",
                  payload.path, bundleIdentifier, app.path)
            return nil
        }
        return app
    }

    private func localPackageIcon(for bundleIdentifier: String) -> UIImage? {
        guard let value = PackageStore.shared.installed[bundleIdentifier]?.iconURL
        else { return nil }
        if value.hasPrefix(GuestInstaller.localIconScheme) {
            let name = String(value.dropFirst(GuestInstaller.localIconScheme.count))
            return UIImage(contentsOfFile: GuestInstaller.iconFolder
                .appendingPathComponent(name).path)
        }
        guard let url = URL(string: value), url.isFileURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private func remotePackageIcon(for bundleIdentifier: String) async -> UIImage? {
        guard let value = PackageStore.shared.installed[bundleIdentifier]?.iconURL,
              let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard data.count <= 20 * 1_024 * 1_024,
                  (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) != false
            else { return nil }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    private static func aspectFillRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func genericContainerIcon() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: 180, height: 180),
            format: format
        ).image { context in
            UIColor(red: 0.16, green: 0.20, blue: 0.28, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 180, height: 180))
            let symbol = UIImage(systemName: "shippingbox.fill")?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 48, y: 48, width: 84, height: 84))
        }
    }

    private func safeFileName(_ name: String) -> String {
        let value = name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let collapsed = String(value).replacingOccurrences(of: "--", with: "-")
        return collapsed.isEmpty ? "VibeContainer" : collapsed
    }

    enum ShortcutError: LocalizedError {
        case missingBundleIdentifier
        case serverUnavailable
        case couldNotOpenSafari
        case couldNotEncodeIcon

        var errorDescription: String? {
            switch self {
            case .missingBundleIdentifier: "That container has no bundle identifier."
            case .serverUnavailable: "The shortcut download server could not start."
            case .couldNotOpenSafari: "VibeContainers could not open Safari to install the shortcut."
            case .couldNotEncodeIcon: "The container's Home Screen icon could not be encoded."
            }
        }
    }
}

private final class DownloadServer: @unchecked Sendable {
    var onReady: ((UInt16) -> Void)?
    var onFinished: (() -> Void)?

    private let data: Data
    private let fileName: String
    private let queue = DispatchQueue(label: "com.vibecontainers.webclip", qos: .userInitiated)
    private let listener: NWListener
    private var served = false
    private var finished = false
    private var activeConnection: NWConnection?

    init(data: Data, fileName: String) throws {
        self.data = data
        self.fileName = fileName
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else { return }
                DispatchQueue.main.async { self.onReady?(port) }
            case .failed:
                self.finishServing(notify: true)
            case .cancelled:
                if !self.finished { self.finishServing(notify: true) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            finishServing(notify: false)
        }
    }

    private func serve(_ connection: NWConnection) {
        guard !served else { connection.cancel(); return }
        served = true
        activeConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !self.finished else { return }
            switch state {
            case .ready:
                self.receiveRequest(on: connection)
            case .failed, .cancelled:
                self.finishServing(notify: true)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self, weak connection] request, _, _, error in
            guard let self, let connection, !self.finished else { return }
            guard error == nil, request?.isEmpty == false else {
                self.finishServing(notify: true)
                return
            }
            var response = Data("HTTP/1.1 200 OK\r\n".utf8)
            response.append(Data("Content-Type: application/x-apple-aspen-config\r\n".utf8))
            response.append(Data("Content-Disposition: attachment; filename=\"\(fileName)\"\r\n".utf8))
            response.append(Data("Content-Length: \(data.count)\r\n".utf8))
            response.append(Data("Cache-Control: no-store\r\nConnection: close\r\n\r\n".utf8))
            response.append(data)
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                self?.finishServing(notify: true)
            })
        }
    }

    private func finishServing(notify: Bool) {
        guard !finished else { return }
        finished = true
        let connection = activeConnection
        activeConnection = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        if notify {
            DispatchQueue.main.async { [weak self] in self?.onFinished?() }
        }
    }
}
