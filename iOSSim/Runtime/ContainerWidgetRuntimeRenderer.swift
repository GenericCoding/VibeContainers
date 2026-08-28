import Foundation
import Observation
import SwiftUI
import WidgetKit

/// Type-erases a captured concrete WidgetBundle behind a class reference. The
/// class is process-lifetime storage, so the host never releases the final copy
/// through a guest opaque existential's destroy witness.
@MainActor
protocol ContainerWidgetCapturedBundle: AnyObject {
    func render(
        requestedKind: String,
        familyRawValue: Int64,
        displaySize: CGSize,
        requestIdentifier: String,
        extensionBundleIdentifier: String,
        executablePath: String
    ) async throws -> ContainerWidgetCompatibleSession
}

@MainActor
private final class ContainerWidgetCapturedBundleBox<B: WidgetBundle>:
    ContainerWidgetCapturedBundle
{
    private let bundle: B

    init(bundle: B) {
        self.bundle = bundle
    }

    func render(
        requestedKind: String,
        familyRawValue: Int64,
        displaySize: CGSize,
        requestIdentifier: String,
        extensionBundleIdentifier: String,
        executablePath: String
    ) async throws -> ContainerWidgetCompatibleSession {
        try await ContainerWidgetCompatibleRenderer.render(
            bundle: bundle,
            requestedKind: requestedKind,
            familyRawValue: familyRawValue,
            displaySize: displaySize,
            requestIdentifier: requestIdentifier,
            extensionBundleIdentifier: extensionBundleIdentifier,
            executablePath: executablePath
        )
    }
}

/// Structured output from the experimental in-process WidgetBundle ABI bridge.
///
/// This is an inventory, not a substitute widget. The bridge instantiates the
/// guest's real WidgetBundle and walks its real Widget/WidgetConfiguration
/// values. A future renderer can consume this structure without ever invoking
/// NSExtensionMain or drawing a guessed visual replacement.
struct ContainerWidgetRuntimeReport: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case armed
        case ready
        case failed
    }

    enum NodeRole: String, Codable, Sendable {
        case bundle
        case widget
        case configuration
    }

    enum NodeOrigin: String, Codable, Sendable {
        case guest
        case swiftUI
        case widgetKit
        case standardLibrary
        case unknown
    }

    struct Node: Identifiable, Codable, Equatable, Sendable {
        let id: Int
        let role: NodeRole
        let origin: NodeOrigin
        let qualifiedTypeName: String
        let path: String
        let depth: Int
        let reflectedChildCount: Int
    }

    struct Failure: Codable, Equatable, Sendable {
        enum Stage: String, Codable, Sendable {
            case gate
            case capture
            case abiValidation
            case bundleInstantiation
            case inventory
            case configurationResolution
            case timelineSnapshot
            case viewGeneration
            case loader
            case recovery
        }

        let stage: Stage
        let code: String
        let message: String
        let recoverable: Bool
    }

    let schemaVersion: Int
    let requestIdentifier: String
    let extensionBundleIdentifier: String
    let executablePath: String
    let outcome: Outcome
    let guestModuleName: String?
    let bundleTypeName: String?
    let nodes: [Node]
    let failure: Failure?
    let updatedAt: Date

    var summary: String {
        switch outcome {
        case .armed:
            "Inspecting real widget types…"
        case .ready:
            "Mapped \(nodes.count) runtime types"
        case .failed:
            failure?.message ?? "Widget runtime inventory failed"
        }
    }
}

@MainActor
@Observable
final class ContainerWidgetRuntimeRenderer {
    static let shared = ContainerWidgetRuntimeRenderer()

    private struct CapturedModuleKey: Hashable {
        let executablePath: String
        let extensionBundleIdentifier: String
    }

    private struct CapturedModule {
        let bundle: any ContainerWidgetCapturedBundle
        let report: ContainerWidgetRuntimeReport
    }

    private(set) var isEnabled: Bool
    private(set) var reports: [String: ContainerWidgetRuntimeReport] = [:]
    private var capturedBundles: [String: any ContainerWidgetCapturedBundle] = [:]
    /// The hidden WidgetBundle entry thunk is a module bootstrap, not a view
    /// factory. Capture it once per canonical extension image, then give every
    /// Springboard placement its own request/session backed by that retained
    /// bundle box.
    private var capturedModules: [CapturedModuleKey: CapturedModule] = [:]
    private var moduleKeysByRequestIdentifier: [String: CapturedModuleKey] = [:]
    /// Guest-owned existential values cannot be destroyed safely after their
    /// module has been loaded. Uninstall moves request-scoped references here
    /// before clearing their reusable lookup keys, intentionally retaining the
    /// old values while allowing a later reinstall to create fresh sessions.
    private var retiredCapturedBundles: [any ContainerWidgetCapturedBundle] = []
    private var retiredModuleKeys: Set<CapturedModuleKey> = []
    private var retiredRequestIdentifiers: Set<String> = []
    // A failed ABI experiment can leave an opaque guest destroy witness unsafe
    // to call. Keep captured values and their dylib alive for the process, but
    // quarantine failed requests so rendering cannot fetch them accidentally.
    private var quarantinedCapturedRequestIdentifiers: Set<String> = []
    private var crashFusedRequestIdentifiers: Set<String> = []

    private static let enabledKey = "container.widgets.runtimeRenderer.enabled"
    private static let crashFuseKey = "container.widgets.runtimeRenderer.activeCapture"

    private init() {
        let defaults = UserDefaults.standard
        let explicitlyEnabled = defaults.object(forKey: Self.enabledKey) as? Bool
        isEnabled = ContainerWidgetCompatibleRenderer.isSupported
            && (explicitlyEnabled ?? true)
        recoverInterruptedCapture(defaults: defaults)
        // The Objective-C capture interposer consults the same preference
        // synchronously. Persist the ABI-gated default so an absent legacy
        // value cannot make Swift and the loader disagree about enablement.
        defaults.set(isEnabled, forKey: Self.enabledKey)
    }

    func report(for requestIdentifier: String) -> ContainerWidgetRuntimeReport? {
        reports[requestIdentifier]
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled && ContainerWidgetCompatibleRenderer.isSupported
        UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
    }

    func shouldAttemptCompatibleRender(for requestIdentifier: String) -> Bool {
        isEnabled
            && !crashFusedRequestIdentifiers.contains(requestIdentifier)
            && !quarantinedCapturedRequestIdentifiers.contains(requestIdentifier)
            && !retiredRequestIdentifiers.contains(requestIdentifier)
    }

    /// A user-initiated retry clears only this widget's crash fuse. Other
    /// widgets remain available and a bad guest cannot globally strand the
    /// renderer in a disabled state.
    func retryCompatibleRender(for requestIdentifier: String) {
        guard !retiredRequestIdentifiers.contains(requestIdentifier) else { return }
        crashFusedRequestIdentifiers.remove(requestIdentifier)
        quarantinedCapturedRequestIdentifiers.remove(requestIdentifier)
        reports.removeValue(forKey: requestIdentifier)
        if ContainerWidgetCompatibleRenderer.isSupported {
            isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
    }

    /// The real instantiated guest bundle, retained for the private
    /// WidgetBundleHost descriptor resolver. The loader must keep the dyld
    /// image containing this value's metadata and implementations alive while
    /// the returned existential is in use.
    func capturedBundle(
        for requestIdentifier: String
    ) -> (any ContainerWidgetCapturedBundle)? {
        guard !quarantinedCapturedRequestIdentifiers.contains(requestIdentifier) else {
            return nil
        }
        return capturedBundles[requestIdentifier]
    }

    /// Fan a process-lifetime module capture out to another placement. The
    /// caller still invokes `render` with its own request ID and geometry, so
    /// timelines, crash fuses and resize sessions remain independent.
    @discardableResult
    func reuseCapturedBundleIfAvailable(
        requestIdentifier: String,
        extensionBundleIdentifier: String,
        executablePath: String
    ) -> Bool {
        guard !quarantinedCapturedRequestIdentifiers.contains(requestIdentifier)
        else { return false }
        let key = moduleKey(
            executablePath: executablePath,
            extensionBundleIdentifier: extensionBundleIdentifier
        )
        guard !retiredModuleKeys.contains(key),
              let captured = capturedModules[key] else { return false }
        capturedBundles[requestIdentifier] = captured.bundle
        moduleKeysByRequestIdentifier[requestIdentifier] = key
        reports[requestIdentifier] = copyReport(
            captured.report,
            requestIdentifier: requestIdentifier
        )
        NSLog(
            "[WidgetRuntime] Reused %@ capture for indexed request %@.",
            extensionBundleIdentifier,
            requestIdentifier
        )
        return true
    }

    /// Opens the stored existential at a MainActor-scoped call site without
    /// leaking it into background work. Returning nil means no compatible
    /// WidgetBundle.main capture has completed for this descriptor.
    func withCapturedBundle<Result>(
        for requestIdentifier: String,
        _ operation: (any ContainerWidgetCapturedBundle) throws -> Result
    ) rethrows -> Result? {
        guard !quarantinedCapturedRequestIdentifiers.contains(requestIdentifier),
              let bundle = capturedBundles[requestIdentifier] else { return nil }
        return try operation(bundle)
    }

    func releaseCapturedBundle(for requestIdentifier: String) {
        // Never invoke an untrusted guest existential's opaque destroy witness
        // while its image is deliberately retained. Make it unreachable only.
        if capturedBundles[requestIdentifier] != nil {
            quarantinedCapturedRequestIdentifiers.insert(requestIdentifier)
        }
    }

    /// Quarantines every request belonging to descriptors that are about to be
    /// uninstalled. Captured guest values are moved to process-lifetime
    /// storage rather than released through an opaque destroy witness, while
    /// their lookup keys are retired so a reinstall cannot reuse the old app's
    /// module or timeline provider.
    func retireWidgets(descriptorIDs: Set<String>) {
        guard !descriptorIDs.isEmpty else { return }

        let requestIdentifiers = Set(reports.keys)
            .union(capturedBundles.keys)
            .union(moduleKeysByRequestIdentifier.keys)
            .union(quarantinedCapturedRequestIdentifiers)
            .filter { requestIdentifier($0, belongsTo: descriptorIDs) }

        for requestIdentifier in requestIdentifiers {
            if let captured = capturedBundles[requestIdentifier] {
                retiredCapturedBundles.append(captured)
                capturedBundles.removeValue(forKey: requestIdentifier)
            }
            if let key = moduleKeysByRequestIdentifier.removeValue(
                forKey: requestIdentifier
            ) {
                retiredModuleKeys.insert(key)
            }
            reports.removeValue(forKey: requestIdentifier)
            quarantinedCapturedRequestIdentifiers.insert(requestIdentifier)
            retiredRequestIdentifiers.insert(requestIdentifier)
        }

        let defaults = UserDefaults.standard
        var markers = Self.crashMarkers(defaults: defaults)
        for requestIdentifier in requestIdentifiers {
            markers.removeValue(forKey: requestIdentifier)
        }
        if markers.isEmpty {
            defaults.removeObject(forKey: Self.crashFuseKey)
        } else {
            defaults.set(markers, forKey: Self.crashFuseKey)
        }
        defaults.synchronize()
    }

    /// Descriptor IDs are stable across reinstalls, while their physical
    /// container paths are not. Revive only request identities retired by an
    /// uninstall; old module keys remain permanently unavailable.
    func reviveWidgets(descriptorIDs: Set<String>) {
        guard !descriptorIDs.isEmpty else { return }
        let revived = retiredRequestIdentifiers.filter {
            requestIdentifier($0, belongsTo: descriptorIDs)
        }
        for requestIdentifier in revived {
            retiredRequestIdentifiers.remove(requestIdentifier)
            quarantinedCapturedRequestIdentifiers.remove(requestIdentifier)
        }
    }

    /// Persists one request-scoped guard without overwriting other widget
    /// renders that may be suspended in an asynchronous snapshot callback.
    func beginCrashProtectedOperation(
        requestIdentifier: String,
        extensionBundleIdentifier: String,
        executablePath: String,
        stage: String
    ) {
        let defaults = UserDefaults.standard
        var markers = Self.crashMarkers(defaults: defaults)
        markers[requestIdentifier] = [
            "requestIdentifier": requestIdentifier,
            "extensionBundleIdentifier": extensionBundleIdentifier,
            "executablePath": executablePath,
            "stage": stage
        ]
        defaults.set(markers, forKey: Self.crashFuseKey)
        // The guarded ABI call can terminate the process before the next
        // run-loop turn, so flush this small recovery record immediately.
        defaults.synchronize()
    }

    func endCrashProtectedOperation(requestIdentifier: String) {
        let defaults = UserDefaults.standard
        var markers = Self.crashMarkers(defaults: defaults)
        markers.removeValue(forKey: requestIdentifier)
        if markers.isEmpty {
            defaults.removeObject(forKey: Self.crashFuseKey)
        } else {
            defaults.set(markers, forKey: Self.crashFuseKey)
        }
        defaults.synchronize()
    }

    func arm(
        requestIdentifier: String,
        extensionBundleIdentifier: String,
        executablePath: String
    ) {
        guard !retiredRequestIdentifiers.contains(requestIdentifier) else { return }
        reports[requestIdentifier] = ContainerWidgetRuntimeReport(
            schemaVersion: 1,
            requestIdentifier: requestIdentifier,
            extensionBundleIdentifier: extensionBundleIdentifier,
            executablePath: executablePath,
            outcome: .armed,
            guestModuleName: nil,
            bundleTypeName: nil,
            nodes: [],
            failure: nil,
            updatedAt: .now
        )
    }

    func capture(
        requestIdentifier: String,
        extensionBundleIdentifier: String,
        executablePath: String,
        metadataAddress: UInt,
        witnessAddress: UInt
    ) {
        let key = moduleKey(
            executablePath: executablePath,
            extensionBundleIdentifier: extensionBundleIdentifier
        )
        guard !retiredRequestIdentifiers.contains(requestIdentifier),
              !retiredModuleKeys.contains(key) else { return }
        // SwiftUI can ask multiple surfaces for the same descriptor in one
        // frame. Replacing the first value would destroy guest-owned opaque
        // storage; reuse the process-lifetime capture instead.
        if capturedBundles[requestIdentifier] != nil {
            NSLog(
                "[WidgetRuntime] Reusing retained WidgetBundle capture for %@.",
                extensionBundleIdentifier
            )
            return
        }
        if let captured = capturedModules[key] {
            capturedBundles[requestIdentifier] = captured.bundle
            moduleKeysByRequestIdentifier[requestIdentifier] = key
            reports[requestIdentifier] = copyReport(
                captured.report,
                requestIdentifier: requestIdentifier
            )
            NSLog(
                "[WidgetRuntime] Fanned %@ capture out to indexed request %@.",
                extensionBundleIdentifier,
                requestIdentifier
            )
            return
        }
        beginCrashProtectedOperation(
            requestIdentifier: requestIdentifier,
            extensionBundleIdentifier: extensionBundleIdentifier,
            executablePath: executablePath,
            stage: "capture"
        )
        defer {
            endCrashProtectedOperation(requestIdentifier: requestIdentifier)
        }

        do {
            let capture = try WidgetRuntimeInventoryBuilder.build(
                metadataAddress: metadataAddress,
                witnessAddress: witnessAddress
            )
            capturedBundles[requestIdentifier] = capture.bundle
            let report = ContainerWidgetRuntimeReport(
                schemaVersion: 1,
                requestIdentifier: requestIdentifier,
                extensionBundleIdentifier: extensionBundleIdentifier,
                executablePath: executablePath,
                outcome: .ready,
                guestModuleName: capture.inventory.guestModuleName,
                bundleTypeName: capture.inventory.bundleTypeName,
                nodes: capture.inventory.nodes,
                failure: nil,
                updatedAt: .now
            )
            reports[requestIdentifier] = report
            capturedModules[key] = CapturedModule(
                bundle: capture.bundle,
                report: report
            )
            moduleKeysByRequestIdentifier[requestIdentifier] = key
            NSLog(
                "[WidgetRuntime] Captured %@ as %@ with %ld runtime node(s).",
                extensionBundleIdentifier,
                capture.inventory.bundleTypeName,
                capture.inventory.nodes.count
            )
        } catch let failure as WidgetRuntimeInventoryBuilder.Failure {
            fail(
                requestIdentifier: requestIdentifier,
                extensionBundleIdentifier: extensionBundleIdentifier,
                executablePath: executablePath,
                stage: failure.stage,
                code: failure.code,
                message: failure.message,
                recoverable: failure.recoverable
            )
        } catch {
            fail(
                requestIdentifier: requestIdentifier,
                extensionBundleIdentifier: extensionBundleIdentifier,
                executablePath: executablePath,
                stage: .inventory,
                code: "unexpected_inventory_error",
                message: error.localizedDescription,
                recoverable: true
            )
        }
    }

    func fail(
        requestIdentifier: String,
        extensionBundleIdentifier: String,
        executablePath: String,
        stage: ContainerWidgetRuntimeReport.Failure.Stage,
        code: String,
        message: String,
        recoverable: Bool
    ) {
        guard !retiredRequestIdentifiers.contains(requestIdentifier) else { return }
        if capturedBundles[requestIdentifier] != nil {
            quarantinedCapturedRequestIdentifiers.insert(requestIdentifier)
        }
        reports[requestIdentifier] = ContainerWidgetRuntimeReport(
            schemaVersion: 1,
            requestIdentifier: requestIdentifier,
            extensionBundleIdentifier: extensionBundleIdentifier,
            executablePath: executablePath,
            outcome: .failed,
            guestModuleName: nil,
            bundleTypeName: nil,
            nodes: [],
            failure: .init(
                stage: stage,
                code: code,
                message: message,
                recoverable: recoverable
            ),
            updatedAt: .now
        )
        NSLog(
            "[WidgetRuntime] %@ failed at %@/%@: %@",
            extensionBundleIdentifier,
            stage.rawValue,
            code,
            message
        )
    }

    private func recoverInterruptedCapture(defaults: UserDefaults) {
        let markers = Self.crashMarkers(defaults: defaults)
        guard !markers.isEmpty else { return }
        defaults.removeObject(forKey: Self.crashFuseKey)
        defaults.synchronize()
        for (requestIdentifier, marker) in markers.sorted(by: { $0.key < $1.key }) {
            let extensionIdentifier = marker["extensionBundleIdentifier"] ?? "unknown"
            let executablePath = marker["executablePath"] ?? "unknown"
            crashFusedRequestIdentifiers.insert(requestIdentifier)
            fail(
                requestIdentifier: requestIdentifier,
                extensionBundleIdentifier: extensionIdentifier,
                executablePath: executablePath,
                stage: .recovery,
                code: "previous_process_interrupted",
                message: "The previous compatible render ended before its crash fuse cleared. This widget will use the system-host fallback until you retry it.",
                recoverable: true
            )
        }
    }

    private static func crashMarkers(
        defaults: UserDefaults
    ) -> [String: [String: String]] {
        guard let stored = defaults.dictionary(forKey: crashFuseKey) else {
            return [:]
        }

        // Migrate the original single-marker representation written by builds
        // before request-scoped concurrent rendering was supported.
        if let requestIdentifier = stored["requestIdentifier"] as? String {
            var legacy: [String: String] = [
                "requestIdentifier": requestIdentifier
            ]
            for key in ["extensionBundleIdentifier", "executablePath", "stage"] {
                if let value = stored[key] as? String { legacy[key] = value }
            }
            return [requestIdentifier: legacy]
        }

        var markers: [String: [String: String]] = [:]
        for (requestIdentifier, value) in stored {
            guard let marker = value as? [String: String],
                  marker["requestIdentifier"] == requestIdentifier else {
                continue
            }
            markers[requestIdentifier] = marker
        }
        return markers
    }

    private func moduleKey(
        executablePath: String,
        extensionBundleIdentifier: String
    ) -> CapturedModuleKey {
        CapturedModuleKey(
            executablePath: URL(fileURLWithPath: executablePath)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path,
            extensionBundleIdentifier: extensionBundleIdentifier
        )
    }

    private func requestIdentifier(
        _ requestIdentifier: String,
        belongsTo descriptorIDs: Set<String>
    ) -> Bool {
        descriptorIDs.contains { descriptorID in
            requestIdentifier == descriptorID
                || requestIdentifier.hasSuffix(".\(descriptorID)")
        }
    }

    private func copyReport(
        _ report: ContainerWidgetRuntimeReport,
        requestIdentifier: String
    ) -> ContainerWidgetRuntimeReport {
        ContainerWidgetRuntimeReport(
            schemaVersion: report.schemaVersion,
            requestIdentifier: requestIdentifier,
            extensionBundleIdentifier: report.extensionBundleIdentifier,
            executablePath: report.executablePath,
            outcome: report.outcome,
            guestModuleName: report.guestModuleName,
            bundleTypeName: report.bundleTypeName,
            nodes: report.nodes,
            failure: report.failure,
            updatedAt: .now
        )
    }
}

@MainActor
private enum WidgetRuntimeInventoryBuilder {
    struct Capture {
        let bundle: any ContainerWidgetCapturedBundle
        let inventory: Inventory
    }

    struct Inventory {
        let guestModuleName: String?
        let bundleTypeName: String
        let nodes: [ContainerWidgetRuntimeReport.Node]
    }

    struct Failure: Error {
        let stage: ContainerWidgetRuntimeReport.Failure.Stage
        let code: String
        let message: String
        let recoverable: Bool
    }

    private struct RuntimeConformingType {
        let metadata: UnsafeRawPointer
        let witness: UnsafeRawPointer
    }

    static func build(metadataAddress: UInt, witnessAddress: UInt) throws -> Capture {
        guard metadataAddress != 0, witnessAddress != 0,
              metadataAddress.isMultiple(
                of: UInt(MemoryLayout<UnsafeRawPointer>.alignment)
              ),
              witnessAddress.isMultiple(
                of: UInt(MemoryLayout<UnsafeRawPointer>.alignment)
              ),
              let metadata = UnsafeRawPointer(bitPattern: metadataAddress),
              let witness = UnsafeRawPointer(bitPattern: witnessAddress) else {
            throw Failure(
                stage: .abiValidation,
                code: "invalid_conformance_words",
                message: "The captured WidgetBundle conformance words are invalid.",
                recoverable: false
            )
        }

        let representation = RuntimeConformingType(metadata: metadata, witness: witness)
        let bundleType = unsafeBitCast(
            representation,
            to: (any WidgetBundle.Type).self
        )
        let bundleTypeName = String(reflecting: bundleType)
        guard !bundleTypeName.isEmpty else {
            throw Failure(
                stage: .abiValidation,
                code: "unnamed_bundle_type",
                message: "Swift accepted the conformance words but could not name the WidgetBundle type.",
                recoverable: false
            )
        }

        let guestModuleName = moduleName(from: bundleTypeName)
        var traversal = Traversal(guestModuleName: guestModuleName)
        let bundle = bundleType.init()
        traversal.visitBundle(bundle, path: "bundle", depth: 0)
        guard traversal.nodes.contains(where: { $0.role == .widget }),
              traversal.nodes.contains(where: { $0.role == .configuration }) else {
            throw Failure(
                stage: .inventory,
                code: "incomplete_widget_graph",
                message: "The real WidgetBundle was instantiated, but its Widget and WidgetConfiguration graph could not be opened.",
                recoverable: true
            )
        }
        return Capture(
            bundle: retainConcreteBundle(bundle),
            inventory: Inventory(
                guestModuleName: guestModuleName,
                bundleTypeName: bundleTypeName,
                nodes: traversal.nodes
            )
        )
    }

    private static func retainConcreteBundle<B: WidgetBundle>(
        _ bundle: B
    ) -> any ContainerWidgetCapturedBundle {
        ContainerWidgetCapturedBundleBox(bundle: bundle)
    }

    private static func moduleName(from qualifiedName: String) -> String? {
        guard let first = qualifiedName.split(separator: ".").first,
              !first.isEmpty else { return nil }
        return String(first)
    }

    @MainActor
    private struct Traversal {
        private static let maximumDepth = 18
        private static let maximumNodes = 256
        private static let maximumReflectedValues = 1_024

        let guestModuleName: String?
        var nodes: [ContainerWidgetRuntimeReport.Node] = []
        private var expandedProtocolTypes: Set<String> = []
        private var reflectedValueCount = 0
        private var seenObjects: Set<ObjectIdentifier> = []

        init(guestModuleName: String?) {
            self.guestModuleName = guestModuleName
        }

        mutating func visitBundle<B: WidgetBundle>(
            _ bundle: B,
            path: String,
            depth: Int
        ) {
            guard register(bundle, role: .bundle, path: path, depth: depth) else { return }
            let body = bundle.body
            visitWidget(body, path: "\(path).body", depth: depth + 1)
            reflectChildren(of: bundle, path: path, depth: depth + 1)
        }

        mutating func visitWidget<W: Widget>(
            _ widget: W,
            path: String,
            depth: Int
        ) {
            guard register(widget, role: .widget, path: path, depth: depth) else { return }
            reflectChildren(of: widget, path: path, depth: depth + 1)

            guard ObjectIdentifier(W.Body.self) != ObjectIdentifier(Never.self) else { return }
            let configuration = widget.body
            visitConfiguration(
                configuration,
                path: "\(path).body",
                depth: depth + 1
            )
        }

        mutating func visitConfiguration<C: WidgetConfiguration>(
            _ configuration: C,
            path: String,
            depth: Int
        ) {
            guard register(
                configuration,
                role: .configuration,
                path: path,
                depth: depth
            ) else { return }
            // Primitive WidgetConfiguration implementations commonly declare
            // Body == Never. Mirror their stored real provider/content graph;
            // never evaluate the unavailable body getter.
            reflectChildren(of: configuration, path: path, depth: depth + 1)
        }

        private mutating func register<T>(
            _ value: T,
            role: ContainerWidgetRuntimeReport.NodeRole,
            path: String,
            depth: Int
        ) -> Bool {
            guard depth <= Self.maximumDepth, nodes.count < Self.maximumNodes else {
                return false
            }
            let typeName = String(reflecting: T.self)
            let mirror = Mirror(reflecting: value)
            nodes.append(
                .init(
                    id: nodes.count,
                    role: role,
                    origin: origin(of: typeName),
                    qualifiedTypeName: typeName,
                    path: path,
                    depth: depth,
                    reflectedChildCount: mirror.children.count
                )
            )
            return expandedProtocolTypes.insert("\(role.rawValue):\(typeName)").inserted
        }

        private func origin(
            of typeName: String
        ) -> ContainerWidgetRuntimeReport.NodeOrigin {
            if let guestModuleName,
               typeName == guestModuleName || typeName.hasPrefix("\(guestModuleName).") {
                return .guest
            }
            if typeName.hasPrefix("SwiftUI.") { return .swiftUI }
            if typeName.hasPrefix("WidgetKit.") { return .widgetKit }
            if typeName.hasPrefix("Swift.") { return .standardLibrary }
            return .unknown
        }

        private mutating func reflectChildren<T>(
            of value: T,
            path: String,
            depth: Int
        ) {
            guard depth <= Self.maximumDepth,
                  reflectedValueCount < Self.maximumReflectedValues else { return }

            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .class,
               let object = value as AnyObject? {
                let identifier = ObjectIdentifier(object)
                guard seenObjects.insert(identifier).inserted else { return }
            }

            for (index, child) in mirror.children.enumerated() {
                guard reflectedValueCount < Self.maximumReflectedValues else { return }
                reflectedValueCount += 1
                let component = child.label?.isEmpty == false
                    ? child.label!
                    : "[\(index)]"
                inspect(
                    child.value,
                    path: "\(path).\(component)",
                    depth: depth
                )
            }
        }

        private mutating func inspect(_ value: Any, path: String, depth: Int) {
            guard depth <= Self.maximumDepth else { return }
            if let bundle = value as? any WidgetBundle {
                visitBundle(bundle, path: path, depth: depth)
            } else if let widget = value as? any Widget {
                visitWidget(widget, path: path, depth: depth)
            } else if let configuration = value as? any WidgetConfiguration {
                visitConfiguration(configuration, path: path, depth: depth)
            } else {
                reflectChildren(of: value, path: path, depth: depth + 1)
            }
        }
    }
}

@_cdecl("IOSSimWidgetRuntimeDidArm")
func IOSSimWidgetRuntimeDidArm(
    _ requestIdentifier: UnsafePointer<CChar>,
    _ extensionBundleIdentifier: UnsafePointer<CChar>,
    _ executablePath: UnsafePointer<CChar>
) {
    let request = String(cString: requestIdentifier)
    let extensionIdentifier = String(cString: extensionBundleIdentifier)
    let path = String(cString: executablePath)
    guard Thread.isMainThread else {
        Task { @MainActor in
            ContainerWidgetRuntimeRenderer.shared.fail(
                requestIdentifier: request,
                extensionBundleIdentifier: extensionIdentifier,
                executablePath: path,
                stage: .capture,
                code: "arm_not_main_actor",
                message: "The runtime capture was armed outside the main actor.",
                recoverable: true
            )
        }
        return
    }
    MainActor.assumeIsolated {
        ContainerWidgetRuntimeRenderer.shared.arm(
            requestIdentifier: request,
            extensionBundleIdentifier: extensionIdentifier,
            executablePath: path
        )
    }
}

@_cdecl("IOSSimWidgetRuntimeDidCapture")
func IOSSimWidgetRuntimeDidCapture(
    _ requestIdentifier: UnsafePointer<CChar>,
    _ extensionBundleIdentifier: UnsafePointer<CChar>,
    _ executablePath: UnsafePointer<CChar>,
    _ metadataAddress: UInt,
    _ witnessAddress: UInt
) {
    let request = String(cString: requestIdentifier)
    let extensionIdentifier = String(cString: extensionBundleIdentifier)
    let path = String(cString: executablePath)
    guard Thread.isMainThread else {
        Task { @MainActor in
            ContainerWidgetRuntimeRenderer.shared.fail(
                requestIdentifier: request,
                extensionBundleIdentifier: extensionIdentifier,
                executablePath: path,
                stage: .capture,
                code: "capture_not_main_actor",
                message: "WidgetBundle metadata was captured outside the main actor and was not evaluated.",
                recoverable: true
            )
        }
        return
    }
    MainActor.assumeIsolated {
        ContainerWidgetRuntimeRenderer.shared.capture(
            requestIdentifier: request,
            extensionBundleIdentifier: extensionIdentifier,
            executablePath: path,
            metadataAddress: metadataAddress,
            witnessAddress: witnessAddress
        )
    }
}

@_cdecl("IOSSimWidgetRuntimeDidFail")
func IOSSimWidgetRuntimeDidFail(
    _ requestIdentifier: UnsafePointer<CChar>,
    _ extensionBundleIdentifier: UnsafePointer<CChar>,
    _ executablePath: UnsafePointer<CChar>,
    _ stage: UnsafePointer<CChar>,
    _ code: UnsafePointer<CChar>,
    _ message: UnsafePointer<CChar>,
    _ recoverable: Bool
) {
    let request = String(cString: requestIdentifier)
    let extensionIdentifier = String(cString: extensionBundleIdentifier)
    let path = String(cString: executablePath)
    let stageName = String(cString: stage)
    let failureCode = String(cString: code)
    let failureMessage = String(cString: message)
    let parsedStage = ContainerWidgetRuntimeReport.Failure.Stage(rawValue: stageName) ?? .loader

    if Thread.isMainThread {
        MainActor.assumeIsolated {
            ContainerWidgetRuntimeRenderer.shared.fail(
                requestIdentifier: request,
                extensionBundleIdentifier: extensionIdentifier,
                executablePath: path,
                stage: parsedStage,
                code: failureCode,
                message: failureMessage,
                recoverable: recoverable
            )
        }
    } else {
        Task { @MainActor in
            ContainerWidgetRuntimeRenderer.shared.fail(
                requestIdentifier: request,
                extensionBundleIdentifier: extensionIdentifier,
                executablePath: path,
                stage: parsedStage,
                code: failureCode,
                message: failureMessage,
                recoverable: recoverable
            )
        }
    }
}
