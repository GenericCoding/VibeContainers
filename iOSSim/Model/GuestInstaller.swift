import Foundation
import SwiftUI
import Darwin

@_silgen_name("IOSSimPatchGuestExecutable")
private func IOSSimPatchGuestExecutable(_ path: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("IOSSimRelaunchForGuest")
private func IOSSimRelaunchForGuest() -> Int32

@_silgen_name("IOSSimLaunchMultitaskGuest")
private func IOSSimLaunchMultitaskGuest(
    _ displayName: UnsafePointer<CChar>,
    _ relativeBundleName: UnsafePointer<CChar>,
    _ dataUUID: UnsafePointer<CChar>
) -> Int32

@_silgen_name("IOSSimMultitaskRuntimeAvailable")
private func IOSSimMultitaskRuntimeAvailable() -> Bool

@_silgen_name("IOSSimProbeJIT")
private func IOSSimProbeJIT() -> Int32

private enum IPADownloadError: Error {
    case status(Int)
}

/// Lets URLSession stream the response to disk in native-sized chunks while
/// preserving the progress UI. The temporary file must be moved from inside
/// the delegate callback because URLSession removes it when that callback ends.
private final class IPADownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @MainActor @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completed = false
    private var lastReportedProgress = 0.0
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(destination: URL, progress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func start(_ url: URL) async throws {
        defer { session?.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }

                let session = URLSession(
                    configuration: .default,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        let shouldReport = lock.withLock {
            guard value >= 1 || value >= lastReportedProgress + 0.002 else { return false }
            lastReportedProgress = max(lastReportedProgress, value)
            return true
        }
        guard shouldReport else { return }
        Task { @MainActor [progress] in progress(value) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            finish(.failure(IPADownloadError.status(response.statusCode)))
            return
        }

        do {
            let manager = FileManager.default
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !completed else { return nil }
            completed = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

/// Downloads a guest `.ipa`, unpacks it into the container, and — in the
/// host — converts its executable with LiveContainer's own patcher.
///
/// This is the real work behind `GET` once a payload exists: fetch the bytes,
/// extract `Payload/<App>.app`, then apply the upstream PAGEZERO/MH_DYLIB patch.
/// Simulator builds route the unchanged iOS platform image to simulator
/// libraries; physical builds either use LiveContainer's native device/JIT
/// bootstrap or ZSign every Mach-O with the host identity for JIT-less launch.
@MainActor
@Observable
final class GuestInstaller {
    static let shared = GuestInstaller()
    private init() {}

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case unpacking
        case preparing
        case ready
        case failed(String)
    }

    /// Keyed by bundle identifier so several installs can be in flight.
    private(set) var phases: [String: Phase] = [:]
    private var activeInstalls: Set<String> = []

    /// A sideloaded IPA has no catalogue entry to key progress against — its
    /// bundle identifier is not known until the archive has been opened — so
    /// the one import at a time gets its own state.
    enum SideloadPhase: Equatable {
        case idle
        case downloading(Double)
        case unpacking
        case preparing
        case installed(String)
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .downloading, .unpacking, .preparing: true
            default: false
            }
        }
    }

    private(set) var sideload: SideloadPhase = .idle

    func clearSideload() { sideload = .idle }

    func phase(for bundle: String) -> Phase { phases[bundle] ?? .idle }
    func isBusy(_ bundle: String) -> Bool { activeInstalls.contains(bundle) }

    // MARK: - Install

    @discardableResult
    func install(_ app: AltApp, into container: GuestContainerStore.Container) async -> Bool {
        let bundle = container.bundleIdentifier
        guard activeInstalls.insert(bundle).inserted else { return false }
        defer { activeInstalls.remove(bundle) }

        guard let raw = app.latest?.downloadURL, let url = URL(string: raw) else {
            phases[bundle] = .failed("This version has no download URL.")
            return false
        }

        let base = GuestContainerStore.shared.url(for: container)
        let transactionRoot = base
            .appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let payloadDir = transactionRoot.appendingPathComponent("Payload", isDirectory: true)
        let ipaURL = transactionRoot.appendingPathComponent("app.ipa")
        var preserveTransactionForRecovery = false
        defer {
            if !preserveTransactionForRecovery {
                try? FileManager.default.removeItem(at: transactionRoot)
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: transactionRoot,
                withIntermediateDirectories: true
            )
            phases[bundle] = .downloading(0)
            try await download(url, to: ipaURL) { progress in
                guard case .downloading(let current) = self.phases[bundle],
                      progress >= current else { return }
                self.phases[bundle] = .downloading(progress)
            }

            phases[bundle] = .unpacking
            let modes = try await Task.detached(priority: .userInitiated) {
                try ZipArchive.extract(ipaURL, to: transactionRoot)
            }.value
            try? FileManager.default.removeItem(at: ipaURL)

            restoreExecutableBits(modes, under: transactionRoot)

            phases[bundle] = .preparing
            _ = try await prepareStagedPayload(payloadDir, container: container)
            try commitStagedPayload(payloadDir, for: container)

            phases[bundle] = .ready
            return true
        } catch let error as PayloadCommitFailure {
            // A failed rollback never deletes the only remaining copy of the
            // previous payload. Leave its transaction directory in place for
            // recovery and report its exact location in the failure message.
            preserveTransactionForRecovery = error.preserveStaging
            phases[bundle] = .failed(error.localizedDescription)
            return false
        } catch {
            phases[bundle] = .failed(Self.describe(error))
            return false
        }
    }

    // MARK: - Sideloading

    /// Installs an `.ipa` the user picked in the file browser.
    ///
    /// The picked file lives outside the app, so its security scope has to be
    /// open for the copy — and only for the copy: everything after this works
    /// on iOSSim's own staging directory.
    func installIPA(at picked: URL) async {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        let staging = Self.stagingRoot
            .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        let copy = staging.appendingPathComponent("import.ipa")

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: picked, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            sideload = .failed("Could not read that file: \(error.localizedDescription)")
            return
        }
        await unpackAndInstall(copy, origin: "Local file")
    }

    /// Downloads an `.ipa` from a link and installs it.
    func installIPA(from remote: URL) async {
        let staging = Self.stagingRoot
            .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        let copy = staging.appendingPathComponent("import.ipa")

        sideload = .downloading(0)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try await download(remote, to: copy) { progress in
                guard case .downloading = self.sideload else { return }
                self.sideload = .downloading(progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            sideload = .failed(Self.describe(error))
            return
        }
        await unpackAndInstall(copy, origin: remote.host() ?? "Link")
    }

    /// The shared tail of both routes: open the archive, learn what the app is
    /// from its own `Info.plist`, then hand it the same container treatment a
    /// catalogue install gets.
    private func unpackAndInstall(_ ipa: URL, origin: String) async {
        let staging = ipa.deletingLastPathComponent()
        let payload = staging.appendingPathComponent("Payload", isDirectory: true)
        var preserveTransactionForRecovery = false
        defer {
            if !preserveTransactionForRecovery {
                try? FileManager.default.removeItem(at: staging)
            }
        }

        sideload = .unpacking

        do {
            let modes = try await Task.detached(priority: .userInitiated) {
                try ZipArchive.extract(ipa, to: staging)
            }.value
            restoreExecutableBits(modes, under: staging)
        } catch {
            sideload = .failed(Self.describe(error))
            return
        }

        guard let appDir = Self.dotApp(in: payload),
              let info = NSDictionary(contentsOf: appDir.appendingPathComponent("Info.plist")),
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            try? FileManager.default.removeItem(at: payload)
            sideload = .failed("That archive has no Payload/*.app with an Info.plist — is it really an IPA?")
            return
        }

        guard activeInstalls.insert(bundleIdentifier).inserted else {
            sideload = .failed("That app is already being installed or updated.")
            return
        }
        defer { activeInstalls.remove(bundleIdentifier) }

        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? appDir.deletingPathExtension().lastPathComponent
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String) ?? "1.0"

        sideload = .preparing

        // Patch, validate and (when configured) sign the private transaction
        // before exchanging its Payload with the app's current one.
        let container = GuestContainerStore.shared.provision(for: bundleIdentifier)
        let base = GuestContainerStore.shared.url(for: container)
        let destination = base.appendingPathComponent("Payload", isDirectory: true)
        do {
            _ = try await prepareStagedPayload(payload, container: container)
            try commitStagedPayload(payload, for: container)
        } catch let error as PayloadCommitFailure {
            preserveTransactionForRecovery = error.preserveStaging
            sideload = .failed(error.localizedDescription)
            return
        } catch {
            sideload = .failed(Self.describe(error))
            return
        }

        guard let installedApp = Self.dotApp(in: destination) else {
            sideload = .failed("The app went missing while it was being installed.")
            return
        }

        // Recorded by name, not by path: the host's data-container UUID changes
        // between installs, and an absolute URL saved today points at nothing
        // tomorrow. `PackageIcon` resolves this against Documents/Icons.
        let icon = Self.extractIcon(from: installedApp, bundleIdentifier: bundleIdentifier)
        PackageStore.shared.recordSideload(
            bundleIdentifier: bundleIdentifier,
            name: name,
            version: version,
            sourceName: origin,
            iconURL: icon == nil ? nil : "\(Self.localIconScheme)\(bundleIdentifier).png"
        )

        // Whatever tweaks are meant for this app go into the fresh executable.
        try? TweakStore.shared.sync(bundleIdentifier)

        phases[bundleIdentifier] = .ready
        sideload = .installed(name)
    }

    /// Marks an icon that lives in this app's own Documents/Icons folder.
    static let localIconScheme = "iossim-icon:"

    static var iconFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Icons", isDirectory: true)
    }

    private static var stagingRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Staging", isDirectory: true)
    }

    /// Lifts the app's own icon out of the bundle so the home screen shows it
    /// rather than a placeholder box.
    ///
    /// The names come from `CFBundleIcons`, which lists them without the
    /// `@2x`/`@3x` scale suffix, so the actual files have to be matched by
    /// prefix — and the biggest match wins.
    private static func extractIcon(from appDir: URL, bundleIdentifier: String) -> URL? {
        let manager = FileManager.default
        let info = NSDictionary(contentsOf: appDir.appendingPathComponent("Info.plist"))

        var stems: [String] = []
        if let icons = info?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            stems = files
        }
        if let single = info?["CFBundleIconFile"] as? String { stems.append(single) }
        if stems.isEmpty { stems = ["AppIcon", "Icon"] }

        let contents = (try? manager.contentsOfDirectory(at: appDir,
                                                         includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let candidates = contents.filter { file in
            file.pathExtension.lowercased() == "png"
                && stems.contains { file.lastPathComponent.hasPrefix($0) }
        }
        guard let best = candidates.max(by: { left, right in
            let leftSize = (try? left.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let rightSize = (try? right.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return leftSize < rightSize
        }) else { return nil }

        let folder = iconFolder
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(bundleIdentifier).png")
        try? manager.removeItem(at: destination)
        try? manager.copyItem(at: best, to: destination)
        return manager.fileExists(atPath: destination.path) ? destination : nil
    }

    // MARK: - Download

    private func download(_ url: URL, to destination: URL,
                          progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let downloader = IPADownloadDelegate(destination: destination, progress: progress)
        do {
            try await downloader.start(url)
        } catch IPADownloadError.status(let code) {
            throw Failure.status(code)
        }
        progress(1)
    }

    // MARK: - Post-processing

    /// ZIP records unix permissions in the external attributes; the main
    /// binary and embedded dylibs must stay executable to be loaded.
    private func restoreExecutableBits(_ modes: [String: UInt16], under base: URL) {
        for (path, mode) in modes where (mode & 0o111) != 0 {
            let url = base.appendingPathComponent(path)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int(mode & 0o777))],
                ofItemAtPath: url.path
            )
        }
    }

    /// Finishes every binary mutation while the incoming app is still private.
    /// A configured JIT-less identity signs the staged tree here as well, so a
    /// bad certificate can never replace a currently launchable version.
    private func prepareStagedPayload(
        _ payloadDir: URL,
        container: GuestContainerStore.Container
    ) async throws -> URL {
        let patchError = await Task.detached(priority: .userInitiated) {
            Self.prepareBundle(payloadDir, container: container)
        }.value
        if let patchError { throw Failure.patch(patchError) }

        guard let appBundle = Self.dotApp(in: payloadDir),
              let executable = Self.executable(in: appBundle),
              FileManager.default.fileExists(atPath: executable.path) else {
            throw Failure.patch("The IPA has no complete Payload/*.app bundle.")
        }

        if JITLessSigner.isAvailableForLaunch {
            try await JITLessSigner.sign(appBundle: appBundle)
            guard FileManager.default.fileExists(atPath: executable.path) else {
                throw Failure.patch("The app executable went missing while it was being signed.")
            }
        }
        return appBundle
    }

    /// Replaces only `<container>/Payload`; Documents, Library, tmp, Tweaks,
    /// the data-container UUID and its LiveContainer data link are never moved.
    /// Both directories are on the same volume, so `RENAME_SWAP` makes the
    /// normal update a single atomic filesystem exchange. The old payload then
    /// remains at `stagedPayload` until publishing the new symlink succeeds.
    private func commitStagedPayload(
        _ stagedPayload: URL,
        for container: GuestContainerStore.Container
    ) throws {
        let manager = FileManager.default
        let base = GuestContainerStore.shared.url(for: container)
        let livePayload = base.appendingPathComponent("Payload", isDirectory: true)

        var stagedIsDirectory = ObjCBool(false)
        guard manager.fileExists(atPath: stagedPayload.path, isDirectory: &stagedIsDirectory),
              stagedIsDirectory.boolValue,
              Self.dotApp(in: stagedPayload) != nil else {
            throw Failure.patch("The prepared Payload directory is incomplete.")
        }

        enum Replacement {
            case fresh
            case swapped
            case backedUp(URL)
        }

        let hadLivePayload = manager.fileExists(atPath: livePayload.path)
        let replacement: Replacement

        if hadLivePayload {
            let swapError = Self.swapItems(livePayload, stagedPayload)
            if swapError == 0 {
                replacement = .swapped
            } else if swapError == ENOTSUP || swapError == EINVAL {
                // Older/non-APFS volumes may not support RENAME_SWAP. Retain
                // the old directory beside Payload until the link is published.
                let backup = base.appendingPathComponent(
                    ".Payload-backup-\(UUID().uuidString)",
                    isDirectory: true
                )
                let backupError = Self.moveItem(livePayload, backup)
                guard backupError == 0 else {
                    throw PayloadCommitFailure(
                        message: Self.filesystemMessage(
                            "Could not preserve the current payload",
                            code: backupError
                        ),
                        preserveStaging: false
                    )
                }

                let installError = Self.moveItem(stagedPayload, livePayload)
                guard installError == 0 else {
                    let restoreError = Self.moveItem(backup, livePayload)
                    let suffix = restoreError == 0
                        ? " The previous version was restored."
                        : " The previous version remains safe at \(backup.path)."
                    throw PayloadCommitFailure(
                        message: Self.filesystemMessage(
                            "Could not install the prepared payload",
                            code: installError
                        ) + suffix,
                        preserveStaging: false
                    )
                }
                replacement = .backedUp(backup)
            } else {
                throw PayloadCommitFailure(
                    message: Self.filesystemMessage(
                        "Could not atomically exchange the app payload",
                        code: swapError
                    ),
                    preserveStaging: false
                )
            }
        } else {
            let installError = Self.moveItem(stagedPayload, livePayload)
            guard installError == 0 else {
                throw PayloadCommitFailure(
                    message: Self.filesystemMessage(
                        "Could not install the prepared payload",
                        code: installError
                    ),
                    preserveStaging: false
                )
            }
            replacement = .fresh
        }

        do {
            guard let installedApp = Self.dotApp(in: livePayload),
                  let executable = Self.executable(in: installedApp),
                  manager.fileExists(atPath: executable.path) else {
                throw Failure.patch("The prepared app failed its final executable check.")
            }
            try GuestContainerStore.shared.publish(installedApp, for: container)

            if case .backedUp(let backup) = replacement {
                try? manager.removeItem(at: backup)
            }
        } catch {
            let originalMessage = Self.describe(error)
            var rollbackError: Int32 = 0
            var preserveStaging = false

            switch replacement {
            case .fresh:
                rollbackError = Self.moveItem(livePayload, stagedPayload)

            case .swapped:
                rollbackError = Self.swapItems(livePayload, stagedPayload)
                // If the swap-back fails, stagedPayload is still the only copy
                // of the old version. Its containing transaction must survive.
                preserveStaging = rollbackError != 0

            case .backedUp(let backup):
                let failedPayload = base.appendingPathComponent(
                    ".Payload-failed-\(UUID().uuidString)",
                    isDirectory: true
                )
                let quarantineError = Self.moveItem(livePayload, failedPayload)
                if quarantineError == 0 {
                    rollbackError = Self.moveItem(backup, livePayload)
                    try? manager.removeItem(at: failedPayload)
                } else {
                    rollbackError = quarantineError
                }
            }

            guard rollbackError == 0 else {
                throw PayloadCommitFailure(
                    message: originalMessage + " " + Self.filesystemMessage(
                        "The previous payload could not be restored automatically",
                        code: rollbackError
                    ) + (preserveStaging
                        ? " It remains safe at \(stagedPayload.path)."
                        : " Its same-volume backup was retained."),
                    preserveStaging: preserveStaging
                )
            }

            // Restore the canonical link as part of rollback too. `publish`
            // commits its symlink with rename(2), so a failed new publish will
            // normally have left this link untouched; republishing also repairs
            // a missing/stale link without risking the restored payload.
            if hadLivePayload, let previousApp = Self.dotApp(in: livePayload) {
                do {
                    try GuestContainerStore.shared.publish(previousApp, for: container)
                } catch {
                    throw PayloadCommitFailure(
                        message: originalMessage
                            + " The previous payload was restored, but its application link could not be republished: "
                            + error.localizedDescription,
                        preserveStaging: false
                    )
                }
            }

            throw PayloadCommitFailure(
                message: originalMessage + (hadLivePayload
                    ? " The previous version and its data were restored."
                    : " No existing app data was changed."),
                preserveStaging: false
            )
        }
    }

    /// Returns zero on success or the captured POSIX errno on failure.
    nonisolated private static func moveItem(_ source: URL, _ destination: URL) -> Int32 {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        return result == 0 ? 0 : errno
    }

    /// Returns zero on success or the captured POSIX errno on failure.
    nonisolated private static func swapItems(_ first: URL, _ second: URL) -> Int32 {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renamex_np(firstPath, secondPath, UInt32(RENAME_SWAP))
            }
        }
        return result == 0 ? 0 : errno
    }

    nonisolated private static func filesystemMessage(_ operation: String, code: Int32) -> String {
        "\(operation): \(String(cString: strerror(code)))"
    }

    /// Applies LiveContainer's original executable patch and writes the small
    /// metadata document consumed by its bootstrap.
    nonisolated private static func prepareBundle(
        _ payloadDir: URL,
        container: GuestContainerStore.Container
    ) -> String? {
        guard let appDir = dotApp(in: payloadDir) else {
            return "The IPA has no Payload/*.app bundle."
        }
        guard let executable = executable(in: appDir),
              FileManager.default.fileExists(atPath: executable.path) else {
            return "The app's CFBundleExecutable is missing."
        }

        let errorPointer = executable.path.withCString { IOSSimPatchGuestExecutable($0) }
        if let errorPointer {
            defer { free(errorPointer) }
            return String(cString: errorPointer)
        }

        let metadata: [String: Any] = [
            "LCDataUUID": container.uuid.uuidString,
            "LCContainers": [["folderName": container.uuid.uuidString]],
            "LCPatchRevision": 7,
            "dontInjectTweakLoader": true,
            "dontLoadTweakLoader": true,
            "hideLiveContainer": false,
            "spoofSDKVersion": 0
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: metadata, format: .binary, options: 0
            )
            try data.write(to: appDir.appendingPathComponent("LCAppInfo.plist"), options: .atomic)
        } catch {
            return "Could not write LiveContainer metadata: \(error.localizedDescription)"
        }
        return nil
    }

    nonisolated static func dotApp(in payloadDir: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "app" }
    }

    nonisolated static func executable(in appDir: URL) -> URL? {
        let infoPlist = appDir.appendingPathComponent("Info.plist")
        if let dict = NSDictionary(contentsOf: infoPlist),
           let name = dict["CFBundleExecutable"] as? String {
            return appDir.appendingPathComponent(name)
        }
        // Fall back to the bundle's own name.
        return appDir.appendingPathComponent(appDir.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Launch report

    struct LaunchOutcome {
        let ok: Bool
        let headline: String
        let detail: String
    }

    /// Reports whether the executable is ready for the upstream LiveContainer
    /// runtime. Its platform intentionally remains iOS/device.
    func launchReport(_ container: GuestContainerStore.Container) -> LaunchOutcome {
        let base = GuestContainerStore.shared.url(for: container)
        let payloadDir = base.appendingPathComponent("Payload", isDirectory: true)

        guard let appDir = Self.dotApp(in: payloadDir),
              let binary = Self.executable(in: appDir),
              FileManager.default.fileExists(atPath: binary.path) else {
            return LaunchOutcome(ok: false, headline: "No payload",
                                 detail: "Download the app first — there is no binary to inspect.")
        }
        guard let info = MachO.inspect(binary) else {
            return LaunchOutcome(ok: false, headline: "Not a Mach-O",
                                 detail: "The executable could not be parsed.")
        }

        let platform = info.platform ?? .iOS
        if info.isEncrypted {
            return LaunchOutcome(
                ok: false,
                headline: "Encrypted IPA",
                detail: "This executable is FairPlay-encrypted. Install a decrypted IPA instead."
            )
        }

        if info.isLoadableDylib {
            let routing = HostPlatform.isSimulator
                ? "LiveContainer will patch dyld's platform check and route libSystem/framework loads through the Simulator runtime."
                : (JITLessSigner.isAvailableForLaunch
                    ? "ZSign will sign every Mach-O with VibeContainers' bundle ID before LiveContainer loads it without JIT."
                    : "LiveContainer will use the native iOS dyld/library-validation bypass after the fresh process is launched with JIT.")
            return LaunchOutcome(
                ok: true,
                headline: "Ready to launch",
                detail: """
                \(binary.lastPathComponent) — \(info.arch), \(platform.label). \(routing)
                """
            )
        }

        return LaunchOutcome(
            ok: false,
            headline: "Not prepared",
            detail: """
            \(binary.lastPathComponent) is still MH_EXECUTE. Re-download it to apply LiveContainer's executable patch.
            """
        )
    }

    /// Starts a guest in its own LiveProcess extension and presents that remote
    /// scene over VibeContainers. The host remains alive, so more guests can be
    /// launched, rearranged, minimized and closed without process relaunches.
    /// A legacy direct-process path remains available behind the Settings
    /// switch for compatibility with unusual apps.
    func launch(_ container: GuestContainerStore.Container) async -> LaunchOutcome {
        let preflight = launchReport(container)
        guard preflight.ok else { return preflight }

        let usesMultitasking = MultitaskPreferences.isEnabled
        if usesMultitasking,
           let existing = RunningContainerStore.shared.entry(for: container.uuid.uuidString),
           existing.phase.isActive {
            switch existing.phase {
            case .launching:
                return LaunchOutcome(
                    ok: true,
                    headline: "Already opening",
                    detail: "\(existing.displayName) is still starting in its container process."
                )
            case .running:
                if RunningContainerStore.shared.focus(existing) {
                    return LaunchOutcome(
                        ok: true,
                        headline: "Guest focused",
                        detail: "Switched to the existing \(existing.displayName) process."
                    )
                }
            case .failed, .terminated:
                break
            }
        }

        let base = GuestContainerStore.shared.url(for: container)
        let publishedApp = GuestContainerStore.shared.applicationURL(for: container)
        let payloadDir = base.appendingPathComponent("Payload", isDirectory: true)
        guard let appBundle = Self.dotApp(in: payloadDir) else {
            return LaunchOutcome(ok: false, headline: "No payload",
                                 detail: "The guest app bundle is missing. Re-download the app.")
        }

        // Reconcile load commands first. Any changed command invalidates the old
        // CodeDirectory, so JIT-less signing must be the final binary mutation.
        do {
            try TweakStore.shared.sync(container.bundleIdentifier)
        } catch {
            return LaunchOutcome(ok: false, headline: "Tweak preparation failed",
                                 detail: error.localizedDescription)
        }

        let usesJITLessSigning = JITLessSigner.isAvailableForLaunch
        if usesJITLessSigning {
            do {
                try await JITLessSigner.sign(appBundle: appBundle)
            } catch {
                return LaunchOutcome(
                    ok: false,
                    headline: "Signing failed",
                    detail: "ZSign could not prepare this guest for JIT-less launch: \(error.localizedDescription)"
                )
            }
        } else {
            if usesMultitasking && !HostPlatform.isSimulator {
                return LaunchOutcome(
                    ok: false,
                    headline: "Multitasking needs JIT-less signing",
                    detail: "A LiveProcess guest runs independently from the host and cannot inherit its temporary JIT state. Import VibeContainers' signing certificate in Settings → JIT & Containers, or turn off multitasking mode for this compatibility launch."
                )
            }
            let jitResult = IOSSimProbeJIT()
            guard jitResult == 0 else {
                let reason = String(cString: strerror(jitResult))
                return LaunchOutcome(
                    ok: false,
                    headline: "Launch capability unavailable",
                    detail: "No active JIT provider was detected (\(reason)). Import VibeContainers' signing certificate in Settings → JIT & Containers for JIT-less launch, or enable JIT and try again."
                )
            }
        }

        // Rebuild relocation-safe LiveContainer links before every launch.
        // Xcode may assign the host a new Simulator data-container UUID while
        // preserving its Documents directory between installs.
        try? GuestContainerStore.shared.publish(appBundle, for: container)
        _ = GuestContainerStore.shared.provision(for: container.bundleIdentifier)
        guard FileManager.default.fileExists(atPath: publishedApp.path) else {
            return LaunchOutcome(ok: false, headline: "No payload",
                                 detail: "The LiveContainer application link is missing. Re-download the app.")
        }

        if usesMultitasking {
            guard IOSSimMultitaskRuntimeAvailable() else {
                return LaunchOutcome(
                    ok: false,
                    headline: "Multitasking unavailable",
                    detail: "The LiveProcess extension or LiveContainer multitasking framework is missing from this build."
                )
            }

            let info = NSDictionary(
                contentsOf: appBundle.appendingPathComponent("Info.plist")
            ) as? [String: Any]
            let displayName = (info?["CFBundleDisplayName"] as? String)
                ?? (info?["CFBundleName"] as? String)
                ?? container.bundleIdentifier

            guard RunningContainerStore.shared.beginLaunch(
                bundleIdentifier: container.bundleIdentifier,
                dataUUID: container.uuid.uuidString,
                displayName: displayName
            ) else {
                return LaunchOutcome(
                    ok: true,
                    headline: "Already opening",
                    detail: "This data container already has a pending or running scene."
                )
            }

            do {
                try GuestExitActivityManager.start(bundleIdentifier: container.bundleIdentifier)
            } catch {
                RunningContainerStore.shared.markLaunchFailed(
                    dataUUID: container.uuid.uuidString,
                    message: error.localizedDescription
                )
                return LaunchOutcome(
                    ok: false,
                    headline: "Exit control unavailable",
                    detail: error.localizedDescription
                )
            }

            let result = displayName.withCString { displayNameBytes in
                publishedApp.lastPathComponent.withCString { relativeBundleNameBytes in
                    container.uuid.uuidString.withCString { dataUUIDBytes in
                        IOSSimLaunchMultitaskGuest(
                            displayNameBytes,
                            relativeBundleNameBytes,
                            dataUUIDBytes
                        )
                    }
                }
            }
            guard result == 0 else {
                GuestExitActivityManager.endGuest()
                let message = String(cString: strerror(result))
                RunningContainerStore.shared.markLaunchFailed(
                    dataUUID: container.uuid.uuidString,
                    message: message
                )
                return LaunchOutcome(
                    ok: false,
                    headline: "Multitask launch failed",
                    detail: message
                )
            }

            return LaunchOutcome(
                ok: true,
                headline: "Guest opened",
                detail: "Running in its own app process. Use the floating dock to switch, resize, minimize or close it."
            )
        }

        let ticket: [String: String] = [
            "bundlePath": publishedApp.path,
            "homePath": base.path,
            "bundleIdentifier": container.bundleIdentifier
        ]
        let ticketURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".iossim-livecontainer-launch.plist")
        do {
            let ticketData = try PropertyListSerialization.data(
                fromPropertyList: ticket, format: .binary, options: 0
            )
            try ticketData.write(to: ticketURL, options: .atomic)
        } catch {
            return LaunchOutcome(ok: false, headline: "Relaunch failed",
                                 detail: "Could not create the LiveContainer launch ticket: \(error.localizedDescription)")
        }

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "guest.launch.lastBundle")
        defaults.removeObject(forKey: "guest.launch.lastError")
        defaults.removeObject(forKey: "error")
        defaults.synchronize()

        do {
            try GuestExitActivityManager.start(bundleIdentifier: container.bundleIdentifier)
        } catch {
            try? FileManager.default.removeItem(at: ticketURL)
            return LaunchOutcome(
                ok: false,
                headline: "Exit control unavailable",
                detail: error.localizedDescription
            )
        }

        let result = IOSSimRelaunchForGuest()
        guard result == 0 else {
            try? FileManager.default.removeItem(at: ticketURL)
            GuestExitActivityManager.endGuest()
            let message: String
            if result == EPERM && !HostPlatform.isSimulator {
                message = "No JIT-less identity or supported JIT relaunch provider was available. Import VibeContainers' signing certificate or enable JIT, then try again."
            } else {
                message = String(cString: strerror(result))
            }
            return LaunchOutcome(ok: false, headline: "Relaunch failed", detail: message)
        }

        // The queued self-open terminates this incarnation asynchronously.
        // Returning keeps the SwiftUI action well-defined until that happens.
        let detail = HostPlatform.isSimulator
            ? "Restarting VibeContainers through SpringBoard…"
            : (usesJITLessSigning
                ? "Restarting VibeContainers with the host-signed guest — no JIT handoff is needed."
                : "Handing VibeContainers to the device JIT launcher…")
        return LaunchOutcome(ok: true, headline: "Launching guest", detail: detail)
    }

    func consumeLaunchError(for bundleIdentifier: String) -> LaunchOutcome? {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "guest.launch.lastBundle") == bundleIdentifier else { return nil }
        let detail = defaults.string(forKey: "guest.launch.lastError")
            ?? defaults.string(forKey: "error")
        defaults.removeObject(forKey: "guest.launch.lastBundle")
        guard let detail else { return nil }
        defaults.removeObject(forKey: "guest.launch.lastError")
        defaults.removeObject(forKey: "error")
        return LaunchOutcome(ok: false, headline: "Guest launch failed", detail: detail)
    }

    // MARK: - Errors

    private struct PayloadCommitFailure: LocalizedError {
        let message: String
        let preserveStaging: Bool
        var errorDescription: String? { message }
    }

    private enum Failure: Error {
        case status(Int)
        case patch(String)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case Failure.status(let code): return "Download failed (HTTP \(code))."
        case Failure.patch(let detail): return detail
        case ZipArchive.ZipError.notAZip: return "The downloaded file is not a valid IPA."
        case ZipArchive.ZipError.unsupportedMethod(let m): return "Unsupported ZIP compression (method \(m))."
        default:
            let ns = error as NSError
            if ns.code == NSURLErrorNotConnectedToInternet { return "No internet connection." }
            if ns.code == NSURLErrorTimedOut { return "The download timed out." }
            return ns.localizedDescription
        }
    }
}
