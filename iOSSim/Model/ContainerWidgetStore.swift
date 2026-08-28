import Foundation
import Observation

@_silgen_name("IOSSimInvalidateContainerWidgetHostsForContainer")
private func IOSSimInvalidateContainerWidgetHostsForContainer(
    _ bundleIdentifier: UnsafePointer<CChar>
)

/// Discovers WidgetKit extensions embedded in apps installed as containers.
///
/// The private Chrono host needs both the extension identity and the WidgetKit
/// configuration's `kind`. Apple does not put the latter in Info.plist, so the
/// store extracts plausible kind literals from the extension's Mach-O and lets
/// the user override the selection when an extension contains several widgets.
@MainActor
@Observable
final class ContainerWidgetStore {
    static let shared = ContainerWidgetStore()

    struct Descriptor: Identifiable, Hashable {
        let ownerBundleIdentifier: String
        let extensionBundleIdentifier: String
        let appName: String
        let extensionName: String
        let iconURL: String?
        let extensionPoint: String
        let extensionBundlePath: String
        let containerBundlePath: String
        let candidateKinds: [String]

        var id: String { "\(ownerBundleIdentifier)::\(extensionBundleIdentifier)" }

        var kindLabel: String {
            extensionPoint == "com.apple.widgetkit-extension" ? "WidgetKit extension" : "Today extension"
        }
    }

    private(set) var discovered: [Descriptor] = []
    private(set) var enabledIDs: Set<String>

    private let enabledKey = "container.widgets.enabled"
    private let kindKey = "container.widgets.kinds"
    private var kindOverrides: [String: String]
    private let widgetExtensionPoints: Set<String> = [
        "com.apple.widgetkit-extension"
    ]
    private let provisionedRunnerBundleIdentifier = "com.genericcoding.vibecontainers.WidgetRunner"

    private init() {
        enabledIDs = Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? [])
        kindOverrides = UserDefaults.standard.dictionary(forKey: kindKey) as? [String: String] ?? [:]
    }

    var enabled: [Descriptor] {
        discovered.filter { enabledIDs.contains($0.id) }
    }

    func isEnabled(_ widget: Descriptor) -> Bool {
        enabledIDs.contains(widget.id)
    }

    func setEnabled(_ enabled: Bool, for widget: Descriptor) {
        if enabled {
            enabledIDs.insert(widget.id)
        } else {
            enabledIDs.remove(widget.id)
        }
        persist()
    }

    func selectedKind(for widget: Descriptor) -> String {
        let override = kindOverrides[widget.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return widget.candidateKinds.first ?? widget.extensionName
    }

    func setKind(_ kind: String, for widget: Descriptor) {
        let value = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == widget.candidateKinds.first {
            kindOverrides.removeValue(forKey: widget.id)
        } else {
            kindOverrides[widget.id] = value
        }
        persist()
    }

    /// Stops private hosts and removes every descriptor preference owned by an
    /// app before its bundle is detached. The stable descriptor-ID snapshot is
    /// also used to retire compatible renderer sessions that intentionally
    /// retain guest Swift values for process lifetime.
    @discardableResult
    func removeWidgets(ownedBy bundleIdentifier: String) -> Set<String> {
        bundleIdentifier.withCString {
            IOSSimInvalidateContainerWidgetHostsForContainer($0)
        }

        let prefix = "\(bundleIdentifier)::"
        var descriptorIDs = Set(
            discovered.lazy
                .filter { $0.ownerBundleIdentifier == bundleIdentifier }
                .map(\.id)
        )
        descriptorIDs.formUnion(enabledIDs.filter { $0.hasPrefix(prefix) })
        descriptorIDs.formUnion(kindOverrides.keys.filter { $0.hasPrefix(prefix) })

        discovered.removeAll { $0.ownerBundleIdentifier == bundleIdentifier }
        enabledIDs.subtract(descriptorIDs)
        for id in descriptorIDs {
            kindOverrides.removeValue(forKey: id)
        }
        persist()
        return descriptorIDs
    }

    /// Rescans installed payloads. This is intentionally synchronous: only
    /// the shallow PlugIns/Extensions directories and their small plists are
    /// read, so refreshes do not enumerate the contents of an IPA.
    func refresh() {
        let packages = PackageStore.shared.installedList
        let packageIDs = Set(packages.map(\.bundleIdentifier))
        var results: [Descriptor] = []

        for app in packages {
            guard let container = GuestContainerStore.shared.container(for: app.bundleIdentifier) else {
                continue
            }

            let appBundle = GuestContainerStore.shared.applicationURL(for: container)
                .resolvingSymlinksInPath()
            for directoryName in ["PlugIns", "Extensions"] {
                let directory = appBundle.appendingPathComponent(directoryName, isDirectory: true)
                guard let extensions = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for extensionBundle in extensions where extensionBundle.pathExtension == "appex" {
                    guard let descriptor = descriptor(for: extensionBundle, owner: app) else { continue }
                    if !results.contains(where: { $0.id == descriptor.id }) {
                        results.append(descriptor)
                    }
                }
            }
        }

        discovered = results.sorted {
            let appOrder = $0.appName.localizedCaseInsensitiveCompare($1.appName)
            return appOrder == .orderedSame
                ? $0.extensionName.localizedCaseInsensitiveCompare($1.extensionName) == .orderedAscending
                : appOrder == .orderedAscending
        }
        ContainerWidgetRuntimeRenderer.shared.reviveWidgets(
            descriptorIDs: Set(discovered.map(\.id))
        )

        // Forget choices only for apps that have actually been uninstalled.
        // A payload can be temporarily absent during an update and should not
        // make the user's widget selection disappear.
        let retained = enabledIDs.filter { id in
            guard let separator = id.range(of: "::") else { return false }
            return packageIDs.contains(String(id[..<separator.lowerBound]))
        }
        if retained != enabledIDs {
            enabledIDs = retained
            persist()
        }
    }

    private func descriptor(
        for extensionBundle: URL,
        owner: PackageStore.InstalledApp
    ) -> Descriptor? {
        let infoURL = extensionBundle.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              let extensionInfo = info["NSExtension"] as? [String: Any],
              let point = extensionInfo["NSExtensionPointIdentifier"] as? String,
              widgetExtensionPoints.contains(point) else { return nil }

        let extensionID = (info["CFBundleIdentifier"] as? String)
            ?? "\(owner.bundleIdentifier).\(extensionBundle.deletingPathExtension().lastPathComponent)"
        guard extensionID != provisionedRunnerBundleIdentifier,
              extensionBundle.lastPathComponent != "IOSSimWidgetRunner.appex" else {
            return nil
        }
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? extensionBundle.deletingPathExtension().lastPathComponent
        let executableName = (info["CFBundleExecutable"] as? String)
            ?? extensionBundle.deletingPathExtension().lastPathComponent
        let executableURL = extensionBundle.appendingPathComponent(executableName)
        let explicitKinds = explicitKinds(in: info, extensionInfo: extensionInfo)
        let candidates = Self.widgetKinds(
            executableURL: executableURL,
            explicit: explicitKinds,
            extensionName: name,
            executableName: executableName,
            bundleIdentifier: extensionID
        )

        return Descriptor(
            ownerBundleIdentifier: owner.bundleIdentifier,
            extensionBundleIdentifier: extensionID,
            appName: owner.name,
            extensionName: name,
            iconURL: owner.iconURL,
            extensionPoint: point,
            extensionBundlePath: extensionBundle.path,
            containerBundlePath: extensionBundle
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path,
            candidateKinds: candidates
        )
    }

    private func explicitKinds(
        in info: [String: Any],
        extensionInfo: [String: Any]
    ) -> [String] {
        let attributes = extensionInfo["NSExtensionAttributes"] as? [String: Any] ?? [:]
        let values: [Any?] = [
            info["WidgetKind"], info["WidgetKinds"],
            info["WidgetKitConfigurationKind"], info["WidgetKitConfigurationKinds"],
            attributes["WidgetKind"], attributes["WidgetKinds"]
        ]
        return values.flatMap { value -> [String] in
            if let string = value as? String { return [string] }
            return value as? [String] ?? []
        }
    }

    private static func widgetKinds(
        executableURL: URL,
        explicit: [String],
        extensionName: String,
        executableName: String,
        bundleIdentifier: String
    ) -> [String] {
        var scored: [String: Int] = [:]

        func offer(_ raw: String, score: Int) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 3, value.count <= 120,
                  value.unicodeScalars.allSatisfy({ scalar in
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar.value == 0x2E
                          || scalar.value == 0x2D
                          || scalar.value == 0x5F
                  }) else { return }
            scored[value] = max(scored[value] ?? Int.min, score)
        }

        explicit.forEach { offer($0, score: 1_000) }

        if let data = try? Data(contentsOf: executableURL, options: [.mappedIfSafe]) {
            for literal in machoCStringLiterals(in: data) {
                let lower = literal.lowercased()
                var score = 0
                if lower.contains("widget") { score += 120 }
                if lower.hasPrefix(bundleIdentifier.lowercased()) { score += 90 }
                if literal == extensionName || literal == executableName { score += 60 }
                if lower.contains("extension") { score += 10 }
                if score >= 60, !genericWidgetStrings.contains(lower) {
                    offer(literal, score: score)
                }
            }
        }

        // A large share of WidgetKit targets use their configuration type or
        // target name as `kind`. These are useful editable fallbacks when the
        // compiler coalesced or obfuscated the literal.
        offer(extensionName, score: 35)
        offer(executableName, score: 30)

        return scored.sorted {
            $0.value == $1.value
                ? $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
                : $0.value > $1.value
        }
        .prefix(12)
        .map(\.key)
    }

    private static let genericWidgetStrings: Set<String> = [
        "widget", "widgets", "widgetkit", "widgetbundle", "widgetcenter",
        "widgetfamily", "widgetconfiguration", "widgetextension"
    ]

    /// Returns C string literals from every `__cstring` section in a thin or
    /// universal 64-bit Mach-O. Reading the section instead of grepping the
    /// whole binary avoids mistaking selectors and symbol names for kinds.
    private static func machoCStringLiterals(in data: Data) -> [String] {
        func u32(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let value = data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { partial, pair in
                partial | (UInt32(pair.element) << UInt32(pair.offset * 8))
            }
            return bigEndian ? value.byteSwapped : value
        }
        func u64(_ offset: Int) -> UInt64? {
            guard let low = u32(offset), let high = u32(offset + 4) else { return nil }
            return UInt64(low) | (UInt64(high) << 32)
        }
        func fixedString(_ offset: Int, count: Int) -> String {
            guard offset >= 0, offset + count <= data.count else { return "" }
            let bytes = data[offset..<(offset + count)].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        func strings(offset: Int, size: Int) -> [String] {
            guard offset >= 0, size >= 0, offset + size <= data.count else { return [] }
            var result: [String] = []
            var start = offset
            for index in offset...(offset + size) {
                if index == offset + size || data[index] == 0 {
                    if index > start {
                        let bytes = data[start..<index]
                        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
                            result.append(String(decoding: bytes, as: UTF8.self))
                        }
                    }
                    start = index + 1
                }
            }
            return result
        }

        var sliceOffset = 0
        guard let magic = u32(0) else { return [] }
        if magic == 0xbebafeca || magic == 0xcafebabe {
            let bigEndian = magic == 0xbebafeca
            guard let count = u32(4, bigEndian: bigEndian) else { return [] }
            for index in 0..<min(Int(count), 32) {
                let arch = 8 + index * 20
                guard let cpu = u32(arch, bigEndian: bigEndian),
                      let offset = u32(arch + 8, bigEndian: bigEndian) else { break }
                if cpu == 0x0100_000c { // CPU_TYPE_ARM64
                    sliceOffset = Int(offset)
                    break
                }
            }
        }

        guard u32(sliceOffset) == 0xfeedfacf,
              let commandCount = u32(sliceOffset + 16) else { return [] }
        var cursor = sliceOffset + 32
        var result: [String] = []
        for _ in 0..<min(Int(commandCount), 4_096) {
            guard let command = u32(cursor), let commandSize = u32(cursor + 4),
                  commandSize >= 8, cursor + Int(commandSize) <= data.count else { break }
            if command == 0x19, let sectionCount = u32(cursor + 64) {
                for sectionIndex in 0..<min(Int(sectionCount), 1_024) {
                    let section = cursor + 72 + sectionIndex * 80
                    guard section + 80 <= cursor + Int(commandSize) else { break }
                    if fixedString(section, count: 16) == "__cstring",
                       let sectionSize = u64(section + 40),
                       let fileOffset = u32(section + 48),
                       sectionSize <= UInt64(Int.max) {
                        result.append(contentsOf: strings(
                            offset: sliceOffset + Int(fileOffset),
                            size: Int(sectionSize)
                        ))
                    }
                }
            }
            cursor += Int(commandSize)
        }
        return result
    }

    private func persist() {
        UserDefaults.standard.set(enabledIDs.sorted(), forKey: enabledKey)
        UserDefaults.standard.set(kindOverrides, forKey: kindKey)
    }
}
