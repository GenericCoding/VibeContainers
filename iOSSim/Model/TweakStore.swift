import Foundation
import Observation
import Darwin

@_silgen_name("IOSSimInjectDylib")
private func IOSSimInjectDylib(_ executable: UnsafePointer<CChar>,
                               _ loadPath: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("IOSSimRemoveDylib")
private func IOSSimRemoveDylib(_ executable: UnsafePointer<CChar>,
                               _ loadPath: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("IOSSimCopyInjectedDylibs")
private func IOSSimCopyInjectedDylibs(_ executable: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

/// The tweak library, and the dyld wiring that puts one into a guest app.
///
/// Tweaks live in LiveContainer's global tweak folder, `Documents/Tweaks`.
/// That location is not arbitrary: a guest published at
/// `Documents/Applications/<bundle>.app` resolves the load path
/// `@loader_path/../../Tweaks/<name>` to exactly that folder, which is the
/// convention upstream's own `TweakLoader.dylib` command uses.
///
/// A tweak is enabled by writing an `LC_LOAD_DYLIB` command into the guest's
/// executable, so dyld loads it before the app's own code runs — the same
/// mechanism LiveContainer uses, minus the TweakLoader indirection.
///
/// Two things follow from the binary being the real state. First, every change
/// goes through `sync(_:)`, which reconciles a whole app's load commands against
/// what the library says should be there; that makes the operations idempotent
/// and repairs an app whose executable was replaced by a re-download. Second,
/// the switches are read back out of the Mach-O rather than trusted from
/// `UserDefaults`.
@MainActor
@Observable
final class TweakStore {
    static let shared = TweakStore()

    /// Why a tweak is (or is not) loaded into a particular app.
    enum Reason: Equatable {
        /// Enabled for this app alone.
        case app
        /// Enabled everywhere.
        case global
        /// Global, but this app is on the tweak's blacklist.
        case blocked
        case off
    }

    struct Tweak: Identifiable, Hashable {
        /// The file name in the tweak folder, e.g. `MyTweak.dylib`.
        let name: String
        let url: URL
        /// The Mach-O to inspect — a framework's binary lives inside it.
        let binaryURL: URL
        let bytes: Int64
        let arch: String?
        let platform: String?
        let isDylib: Bool

        var id: String { name }
        var isFramework: Bool { url.pathExtension == "framework" }
        var isSample: Bool { name == TweakStore.sampleName }

        /// dyld can only be pointed at a Mach-O, so a framework is named
        /// through to its binary rather than by its bundle directory.
        var loadPath: String {
            let leaf = isFramework ? "\(name)/\(binaryURL.lastPathComponent)" : name
            return TweakStore.loadPathPrefix + leaf
        }

        /// Whether dyld stands a chance of loading it into an arm64 guest.
        var isLoadable: Bool { isDylib && arch == "arm64" }

        var detail: String {
            var parts: [String] = []
            if let arch { parts.append(arch) }
            if let platform { parts.append(platform) }
            if !isDylib { parts.append("not a dylib") }
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            return parts.joined(separator: " · ")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var library: [Tweak] = []
    /// bundle identifier → load path → enabled. Mirrors the executables.
    private(set) var injections: [String: [String: Bool]] = [:]

    /// Tweak names that apply to every app unless blacklisted.
    private(set) var globals: Set<String> = []
    /// bundle identifier → tweak names enabled for that app alone.
    private(set) var perApp: [String: Set<String>] = [:]
    /// bundle identifier → global tweak names this app opts out of.
    private(set) var blacklist: [String: Set<String>] = [:]

    static let sampleName = "HelloDyld.dylib"
    static let loadPathPrefix = "@loader_path/../../Tweaks/"

    private let globalsKey = "tweaks.globals"
    private let perAppKey = "tweaks.perApp"
    private let blacklistKey = "tweaks.blacklist"
    private let seededKey = "tweaks.sampleSeeded"
    private let sampleRevisionKey = "tweaks.sampleRevision"
    private let sampleUserManagedKey = "tweaks.sampleUserManaged"

    /// Increment only when the bundled sample changes. Existing copies that
    /// still belong to VibeContainers are refreshed once on the next launch;
    /// a sample explicitly replaced by the user is never overwritten.
    private static let sampleRevision = 3

    private init() {
        let defaults = UserDefaults.standard
        globals = Set(defaults.stringArray(forKey: globalsKey) ?? [])
        perApp = Self.loadMap(defaults.dictionary(forKey: perAppKey))
        blacklist = Self.loadMap(defaults.dictionary(forKey: blacklistKey))
        seedSampleTweak()
        refresh()
    }

    // MARK: - Library

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// LiveContainer's global tweak folder.
    var folder: URL { documents.appendingPathComponent("Tweaks", isDirectory: true) }

    func refresh() {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let contents = (try? manager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        )) ?? []

        library = contents
            .compactMap(Self.describe)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func describe(_ url: URL) -> Tweak? {
        let name = url.lastPathComponent
        // LiveContainer's bootstrap links its own TweakLoader into this folder.
        // iOSSim names each tweak in the executable instead of going through
        // it, and ships no TweakLoader for the link to point at, so it is not a
        // library entry — `sync(_:)` parks any command still naming it.
        guard name != "TweakLoader.dylib" else { return nil }
        let binaryURL: URL
        switch url.pathExtension {
        case "dylib":
            binaryURL = url
        case "framework":
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            let executable = info?["CFBundleExecutable"] as? String
                ?? url.deletingPathExtension().lastPathComponent
            binaryURL = url.appendingPathComponent(executable)
        default:
            return nil
        }

        // A dangling symlink is worse than nothing here: naming one in a load
        // command stops the app launching at all.
        guard FileManager.default.fileExists(atPath: binaryURL.path) else { return nil }

        let values = try? binaryURL.resourceValues(forKeys: [.fileSizeKey])
        let info = MachO.inspect(binaryURL)
        return Tweak(
            name: name,
            url: url,
            binaryURL: binaryURL,
            bytes: Int64(values?.fileSize ?? 0),
            arch: info?.arch,
            platform: info?.platform?.label,
            isDylib: info?.isLoadableDylib ?? false
        )
    }

    /// Copies the bundled sample tweak into the library the first time the app
    /// runs, and atomically refreshes app-owned copies when the sample changes.
    /// Deleting it is remembered, so it does not come back by itself.
    private func seedSampleTweak() {
        let defaults = UserDefaults.standard
        guard let source = Bundle.main.privateFrameworksURL?
            .appendingPathComponent(Self.sampleName),
              FileManager.default.fileExists(atPath: source.path) else { return }

        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(Self.sampleName)

        if !defaults.bool(forKey: seededKey) {
            if !manager.fileExists(atPath: destination.path) {
                try? manager.copyItem(at: source, to: destination)
            } else {
                // A file placed here before the first launch belongs to the
                // user even if it happens to use the sample's reserved name.
                defaults.set(true, forKey: sampleUserManagedKey)
            }
            defaults.set(Self.sampleRevision, forKey: sampleRevisionKey)
            defaults.set(true, forKey: seededKey)
            return
        }

        // Respect deletion and explicit replacement. Older releases did not
        // record a revision, so revision zero identifies their bundled copy.
        guard manager.fileExists(atPath: destination.path),
              !defaults.bool(forKey: sampleUserManagedKey),
              defaults.integer(forKey: sampleRevisionKey) < Self.sampleRevision
        else { return }

        let replacement = folder.appendingPathComponent(
            ".\(Self.sampleName).\(UUID().uuidString).replacement"
        )
        do {
            try manager.copyItem(at: source, to: replacement)
            _ = try manager.replaceItemAt(destination, withItemAt: replacement)
            defaults.set(Self.sampleRevision, forKey: sampleRevisionKey)
        } catch {
            try? manager.removeItem(at: replacement)
        }
    }

    /// Moves dylibs dropped straight into the app's Documents folder — the one
    /// the Files app shows — into the tweak folder.
    ///
    /// This is the way in when the document picker is not: AirDrop a dylib to
    /// iOSSim, or copy it into the folder in Files, and it is adopted on the
    /// next visit to Tweaks.
    @discardableResult
    func adoptLooseFiles() -> [String] {
        let manager = FileManager.default
        let loose = (try? manager.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        var adopted: [String] = []

        for url in loose where ["dylib", "framework"].contains(url.pathExtension) {
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? manager.removeItem(at: destination)
            do {
                try manager.moveItem(at: url, to: destination)
                adopted.append(url.lastPathComponent)
                if url.lastPathComponent == Self.sampleName {
                    UserDefaults.standard.set(true, forKey: sampleUserManagedKey)
                }
            } catch {
                continue
            }
        }

        if !adopted.isEmpty { refresh() }
        return adopted
    }

    /// Copies a picked file into the tweak folder. Replacing a tweak in place
    /// keeps its load path, so apps already loading it pick up the new build.
    @discardableResult
    func importTweak(from source: URL) throws -> Tweak {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard ["dylib", "framework"].contains(source.pathExtension) else {
            throw Failure(message: "\(source.lastPathComponent): pick a .dylib or a .framework — dyld cannot load anything else as a tweak.")
        }

        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        try? manager.removeItem(at: destination)
        do {
            try manager.copyItem(at: source, to: destination)
        } catch {
            throw Failure(message: "Could not copy \(source.lastPathComponent) in: \(error.localizedDescription)")
        }

        guard let tweak = Self.describe(destination) else {
            try? manager.removeItem(at: destination)
            throw Failure(message: "\(source.lastPathComponent) could not be read as a Mach-O.")
        }
        if tweak.name == Self.sampleName {
            UserDefaults.standard.set(true, forKey: sampleUserManagedKey)
        }
        refresh()
        // Anything already loading this name now loads the new bytes.
        syncAll()
        return tweak
    }

    /// Deleting a tweak has to switch it off everywhere first: dyld refuses to
    /// start an image whose `LC_LOAD_DYLIB` names a file that is not there.
    func delete(_ tweak: Tweak) {
        globals.remove(tweak.name)
        for bundle in perApp.keys { perApp[bundle]?.remove(tweak.name) }
        for bundle in blacklist.keys { blacklist[bundle]?.remove(tweak.name) }
        persist()

        for container in GuestContainerStore.shared.containers.values {
            if let executable = executable(for: container) {
                refreshInjections(for: container.bundleIdentifier)
                if injectedPaths(for: container.bundleIdentifier)[tweak.loadPath] == true {
                    do {
                        try prepareExecutableForMutation(executable)
                        _ = call(IOSSimRemoveDylib, executable, tweak.loadPath)
                        refreshInjections(for: container.bundleIdentifier)
                    } catch {
                        // Deletion was historically best-effort. Keep the
                        // executable intact and continue removing the library
                        // entry if its fresh-inode replacement cannot commit.
                    }
                }
            }
            try? FileManager.default.removeItem(
                at: tweaksFolder(for: container).appendingPathComponent(tweak.name)
            )
        }
        try? FileManager.default.removeItem(at: tweak.url)
        refresh()
    }

    // MARK: - Scope

    func isGlobal(_ tweak: Tweak) -> Bool { globals.contains(tweak.name) }

    /// Promotes a tweak to every app, or demotes it back to the apps that had
    /// asked for it individually.
    func setGlobal(_ isOn: Bool, tweak: Tweak) throws {
        if isOn { globals.insert(tweak.name) } else { globals.remove(tweak.name) }
        persist()
        try resyncAll()
    }

    func isBlocked(_ tweak: Tweak, in bundleIdentifier: String) -> Bool {
        blacklist[bundleIdentifier]?.contains(tweak.name) == true
    }

    /// The per-app opt-out from a global tweak.
    func setBlocked(_ isOn: Bool, tweak: Tweak, in bundleIdentifier: String) throws {
        var blocked = blacklist[bundleIdentifier] ?? []
        if isOn { blocked.insert(tweak.name) } else { blocked.remove(tweak.name) }
        blacklist[bundleIdentifier] = blocked.isEmpty ? nil : blocked
        persist()
        try sync(bundleIdentifier)
    }

    /// Turns a tweak on for one app. A global tweak is instead un-blacklisted,
    /// so the switch in front of the user always means "load this here".
    func setEnabled(_ isOn: Bool, tweak: Tweak, in bundleIdentifier: String) throws {
        if isGlobal(tweak) {
            try setBlocked(!isOn, tweak: tweak, in: bundleIdentifier)
            return
        }
        var enabled = perApp[bundleIdentifier] ?? []
        if isOn { enabled.insert(tweak.name) } else { enabled.remove(tweak.name) }
        perApp[bundleIdentifier] = enabled.isEmpty ? nil : enabled
        persist()
        try sync(bundleIdentifier)
    }

    func reason(for tweak: Tweak, in bundleIdentifier: String) -> Reason {
        if isGlobal(tweak) {
            return isBlocked(tweak, in: bundleIdentifier) ? .blocked : .global
        }
        return perApp[bundleIdentifier]?.contains(tweak.name) == true ? .app : .off
    }

    func isEnabled(_ tweak: Tweak, in bundleIdentifier: String) -> Bool {
        let reason = reason(for: tweak, in: bundleIdentifier)
        return reason == .app || reason == .global
    }

    /// Every tweak that should be loaded into this app.
    func effectiveTweaks(for bundleIdentifier: String) -> [Tweak] {
        library.filter { isEnabled($0, in: bundleIdentifier) && $0.isLoadable }
    }

    func enabledCount(for bundleIdentifier: String) -> Int {
        effectiveTweaks(for: bundleIdentifier).count
    }

    // MARK: - Injection

    /// Brings one app's load commands in line with the library.
    ///
    /// Everything the library knows about is either injected or parked, and any
    /// leftover command pointing into the tweak folder is parked too, so an app
    /// can never be left naming a dylib that is not there.
    func sync(_ bundleIdentifier: String) throws {
        guard let container = GuestContainerStore.shared.container(for: bundleIdentifier),
              let executable = executable(for: container) else {
            // Nothing unpacked yet: the state is remembered and applied when a
            // payload arrives.
            return
        }

        var wanted: Set<String> = []
        var problems: [String] = []

        for tweak in library {
            let shouldLoad = isEnabled(tweak, in: bundleIdentifier) && tweak.isLoadable
            if shouldLoad {
                do {
                    try stage(tweak, in: container)
                    wanted.insert(tweak.loadPath)
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
        }

        // Read before opening the executable writable. Rewriting a page in a
        // Mach-O vnode that iOS has already validated can terminate the host
        // with SIGKILL (CODESIGNING: Invalid Page), even though the bundle will
        // be signed again immediately afterwards. It also wastes work when the
        // desired commands are already present.
        refreshInjections(for: bundleIdentifier)
        let current = injectedPaths(for: bundleIdentifier)
        let pathsToEnable = wanted.filter { current[$0] != true }
        let pathsToDisable = current.compactMap { path, enabled in
            enabled && !wanted.contains(path) ? path : nil
        }

        if !pathsToEnable.isEmpty || !pathsToDisable.isEmpty {
            try prepareExecutableForMutation(executable)
        }

        for path in pathsToEnable {
            if let error = call(IOSSimInjectDylib, executable, path) {
                let name = library.first { $0.loadPath == path }?.name ?? path
                problems.append("\(name): \(error)")
            }
        }

        // Commands left by a tweak that has since left the library are parked
        // too, so dyld never follows a dangling load path.
        for path in pathsToDisable {
            if let error = call(IOSSimRemoveDylib, executable, path) {
                problems.append(error)
            }
        }

        refreshInjections(for: bundleIdentifier)
        if !problems.isEmpty { throw Failure(message: problems.joined(separator: "\n")) }
    }

    func syncAll() { try? resyncAll() }

    /// Re-applies the whole library to every installed app. A re-downloaded app
    /// arrives with a fresh executable and no load commands in it, so this is
    /// the repair path as well as the fan-out for a scope change.
    func resyncAll() throws {
        var problems: [String] = []
        for bundle in GuestContainerStore.shared.containers.keys {
            do { try sync(bundle) } catch { problems.append(error.localizedDescription) }
        }
        if !problems.isEmpty { throw Failure(message: problems.joined(separator: "\n")) }
    }

    /// Parks a command by its raw load path. This is the way back for a tweak
    /// whose file has gone missing: the app is unlaunchable until the command
    /// naming it is switched off, and there is no library entry left to toggle.
    func disable(loadPath: String, in bundleIdentifier: String) throws {
        guard let container = GuestContainerStore.shared.container(for: bundleIdentifier),
              let executable = executable(for: container) else {
            throw Failure(message: "This app has no unpacked payload.")
        }
        refreshInjections(for: bundleIdentifier)
        guard injectedPaths(for: bundleIdentifier)[loadPath] == true else { return }

        try prepareExecutableForMutation(executable)
        if let error = call(IOSSimRemoveDylib, executable, loadPath) {
            throw Failure(message: error)
        }
        refreshInjections(for: bundleIdentifier)
    }

    /// Load commands pointing into the tweak folder, enabled or parked.
    func injectedPaths(for bundleIdentifier: String) -> [String: Bool] {
        (injections[bundleIdentifier] ?? [:]).filter { $0.key.hasPrefix(Self.loadPathPrefix) }
    }

    /// Reads the executable's dylib commands back into `injections`.
    func refreshInjections(for bundleIdentifier: String) {
        guard let container = GuestContainerStore.shared.container(for: bundleIdentifier),
              let executable = executable(for: container),
              let raw = executable.path.withCString({ IOSSimCopyInjectedDylibs($0) }) else {
            injections[bundleIdentifier] = [:]
            return
        }
        defer { free(raw) }

        var found: [String: Bool] = [:]
        for line in String(cString: raw).split(separator: "\n") {
            guard let marker = line.first else { continue }
            found[String(line.dropFirst())] = marker == "+"
        }
        injections[bundleIdentifier] = found
    }

    /// Whether the app has a payload to inject into at all.
    func isReady(_ bundleIdentifier: String) -> Bool {
        guard let container = GuestContainerStore.shared.container(for: bundleIdentifier) else { return false }
        return executable(for: container) != nil
    }

    // MARK: - Filesystem

    private func tweaksFolder(for container: GuestContainerStore.Container) -> URL {
        GuestContainerStore.shared.url(for: container)
            .appendingPathComponent("Tweaks", isDirectory: true)
    }

    /// Mirrors the tweak into the container's own `Tweaks` folder.
    ///
    /// `@loader_path` is the directory the loading image was found in, and the
    /// guest is reachable by two of them: the published
    /// `Documents/Applications/<bundle>.app` link, and the real
    /// `Documents/Containers/<uuid>/Payload/<App>.app` it points at. Which one
    /// dyld resolves against depends on whether it canonicalises the path it
    /// was handed, so both `../../Tweaks` folders are made to exist. The mirror
    /// is a relative symlink into the global folder, matching how the rest of
    /// the container survives the host being reinstalled under a new UUID.
    private func stage(_ tweak: Tweak, in container: GuestContainerStore.Container) throws {
        let manager = FileManager.default
        let destination = tweaksFolder(for: container)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)

        let link = destination.appendingPathComponent(tweak.name)
        try? manager.removeItem(at: link)
        do {
            try manager.createSymbolicLink(atPath: link.path,
                                           withDestinationPath: "../../../Tweaks/\(tweak.name)")
        } catch {
            throw Failure(message: "Could not stage \(tweak.name) into the container: \(error.localizedDescription)")
        }
    }

    private func executable(for container: GuestContainerStore.Container) -> URL? {
        let payload = GuestContainerStore.shared.url(for: container)
            .appendingPathComponent("Payload", isDirectory: true)
        guard let appDir = GuestInstaller.dotApp(in: payload),
              let executable = GuestInstaller.executable(in: appDir),
              FileManager.default.fileExists(atPath: executable.path) else { return nil }
        return executable
    }

    /// Replaces a previously validated executable with an identical fresh
    /// vnode before changing any Mach-O load-command bytes.
    ///
    /// The staged copy lives outside the app bundle so concurrent signing or
    /// widget discovery cannot mistake it for another bundle executable. A
    /// same-volume rename is the commit point: readers observe either complete
    /// inode, and FileManager's copy preserves the executable's mode and other
    /// filesystem metadata.
    private func prepareExecutableForMutation(_ executable: URL) throws {
        let manager = FileManager.default
        let staged = manager.temporaryDirectory
            .appendingPathComponent("VibeContainers-MachO-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staged) }

        do {
            try manager.copyItem(at: executable, to: staged)
        } catch {
            throw Failure(
                message: "Could not prepare \(executable.lastPathComponent) for modification: \(error.localizedDescription)"
            )
        }

        let renameResult = staged.path.withCString { source in
            executable.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else {
            let code = errno
            throw Failure(
                message: "Could not replace \(executable.lastPathComponent) safely: \(String(cString: strerror(code)))"
            )
        }
    }

    private func call(
        _ function: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?,
        _ executable: URL,
        _ loadPath: String
    ) -> String? {
        let result = executable.path.withCString { executablePath in
            loadPath.withCString { function(executablePath, $0) }
        }
        guard let result else { return nil }
        defer { free(result) }
        return String(cString: result)
    }

    // MARK: - Persistence

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(Array(globals), forKey: globalsKey)
        defaults.set(perApp.mapValues(Array.init), forKey: perAppKey)
        defaults.set(blacklist.mapValues(Array.init), forKey: blacklistKey)
    }

    private static func loadMap(_ raw: [String: Any]?) -> [String: Set<String>] {
        guard let raw else { return [:] }
        return raw.compactMapValues { value in
            guard let names = value as? [String] else { return nil }
            return Set(names)
        }
    }
}
