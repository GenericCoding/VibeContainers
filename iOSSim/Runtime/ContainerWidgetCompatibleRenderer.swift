import Foundation
import SwiftUI
import WidgetKit

@_silgen_name("VibeWidgetBundleHostCreate")
@MainActor
private func VibeWidgetBundleHostCreate<B: WidgetBundle>(
    _ bundle: B
) -> UnsafeMutableRawPointer?

@_silgen_name("VibeWidgetBundleHostReadPreference")
@MainActor
private func VibeWidgetBundleHostReadPreference<K: PreferenceKey>(
    _ host: UnsafeMutableRawPointer,
    _ key: K.Type
) -> K.Value

@_silgen_name("VibeInvokeOneArgViewClosure")
private func VibeInvokeOneArgViewClosure(
    _ function: UnsafeRawPointer,
    _ context: UnsafeRawPointer?,
    _ argument: UnsafeRawPointer,
    _ result: UnsafeMutableRawPointer
)

@_silgen_name("VibeViewWitness")
private func VibeViewWitness(_ metadata: UnsafeRawPointer) -> UnsafeRawPointer?

@_silgen_name("VibeMakeAnyView")
private func VibeMakeAnyView(
    _ value: UnsafeMutableRawPointer,
    _ metadata: UnsafeRawPointer,
    _ witness: UnsafeRawPointer
) -> AnyView

@_silgen_name("VibeWidgetRuntimeInstructionPointerIsUnsigned")
private func VibeWidgetRuntimeInstructionPointerIsUnsigned(
    _ pointer: UnsafeRawPointer
) -> Bool

@_silgen_name("VibeWidgetRuntimeStripInstructionPointer")
private func VibeWidgetRuntimeStripInstructionPointer(
    _ pointer: UnsafeRawPointer
) -> UnsafeRawPointer?

@_silgen_name("VibeWidgetRuntimeReadableMemory")
private func VibeWidgetRuntimeReadableMemory(
    _ pointer: UnsafeRawPointer,
    _ length: Int
) -> Bool

@_silgen_name("VibeWidgetRuntimeExecutableAddress")
private func VibeWidgetRuntimeExecutableAddress(
    _ pointer: UnsafeRawPointer
) -> Bool

@_silgen_name("VibeWidgetRuntimeSymbolAvailable")
private func VibeWidgetRuntimeSymbolAvailable(
    _ symbol: UnsafePointer<CChar>
) -> Bool

private let widgetKitEntryProvidingTypeName = "WidgetKit.EntryProviding"

private struct EntryProviderFactoryInvoker {
    let invoke: (Any) -> AnyObject?
}

private func makeEntryProviderFactoryInvoker<Result>(
    _ resultType: Result.Type
) -> EntryProviderFactoryInvoker? {
    let expectedSize = 5 * MemoryLayout<UInt>.stride
    guard String(reflecting: resultType) == widgetKitEntryProvidingTypeName,
          MemoryLayout<Result>.size == expectedSize,
          MemoryLayout<Result>.stride == expectedSize,
          MemoryLayout<Result>.alignment == MemoryLayout<UInt>.alignment else {
        return nil
    }

    return EntryProviderFactoryInvoker { factory in
        guard let typedFactory = factory as? () -> Result else {
            return nil
        }
        return typedFactory() as AnyObject
    }
}

/// Owns every guest/runtime object needed by a generated widget view. In
/// particular, the bundle host and entry-provider class must outlive AnyView;
/// their metadata and closure contexts point into the intentionally retained
/// widget dylib.
@MainActor
final class ContainerWidgetCompatibleSession: Identifiable {
    let id = UUID()
    let kind: String
    let family: WidgetFamily
    let content: AnyView
    let usedSnapshot: Bool

    private let bundleHost: AnyObject
    private let entryProvider: AnyObject

    init(
        kind: String,
        family: WidgetFamily,
        content: AnyView,
        usedSnapshot: Bool,
        bundleHost: AnyObject,
        entryProvider: AnyObject
    ) {
        self.kind = kind
        self.family = family
        self.content = content
        self.usedSnapshot = usedSnapshot
        self.bundleHost = bundleHost
        self.entryProvider = entryProvider
    }
}

@MainActor
enum ContainerWidgetCompatibleRenderer {
    struct Failure: LocalizedError {
        let stage: ContainerWidgetRuntimeReport.Failure.Stage
        let code: String
        let message: String
        let recoverable: Bool

        var errorDescription: String? { message }
    }

    private struct TimelineConfiguration {
        let kind: String
        let makeEntryProvider: Any
    }

    private struct GeneratedContent {
        let view: AnyView
        let usedSnapshot: Bool
    }

    private static let descriptorPreferenceKeyName = "9WidgetKit0A13DescriptorKeyV"
    private static let entryProviderFactoryTypeName =
        "() -> WidgetKit.EntryProviding"
    private static let entryProviderExistentialTypeName =
        widgetKitEntryProvidingTypeName
    private static let entryProviderExistentialMangledName =
        "9WidgetKit14EntryProviding_p"
    private static let swiftFunctionMetadataKind: UInt = 0x302
    private static let swiftExistentialMetadataKind: UInt = 0x303
    // FunctionTypeFlags for an ordinary escaping, synchronous, non-throwing
    // Swift closure with no parameters on the renderer's gated Swift ABI.
    private static let noArgumentClosureFlags: UInt = 0x0400_0000
    // One witness table, value-capable (not class-constrained), no superclass
    // or special protocol. The concrete TimelineEntryProvider is still a
    // class, but it is carried inside a five-word opaque existential.
    private static let entryProviderExistentialFlags: UInt32 = 0x8000_0001
    private static let expectedContextLayout = (
        size: 363,
        stride: 368,
        alignment: 8,
        variantsOffset: 0,
        familyOffset: 32,
        previewOffset: 56,
        displaySizeOffset: 64
    )
    private static let requiredSymbols = [
        "$s7SwiftUI16WidgetBundleHostCN",
        "$s7SwiftUI16WidgetBundleHostC6bundleACx_tcAA0cD0RzlufC",
        "$s7SwiftUI16WidgetBundleHostC14readPreferencey5ValueQzxmAA0G3KeyRzlF",
        "$s7SwiftUI4ViewMp",
        "$s7SwiftUI7AnyViewVyACxcAA0D0RzlufC"
    ]

    static var isSupported: Bool { supportFailure == nil }

    static var unsupportedReason: String? { supportFailure?.message }

    private static var supportFailure: Failure? {
#if targetEnvironment(simulator) || !arch(arm64)
        return failure(
            .gate,
            "unsupported_platform",
            "The compatible widget renderer requires a physical arm64 iPhone."
        )
#else
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard majorVersion == 26 || majorVersion == 27 else {
            return failure(
                .gate,
                "unsupported_os_abi",
                "This iOS version is outside the renderer's verified SwiftUI ABI range."
            )
        }
        guard MemoryLayout<Any>.size == 32,
              MemoryLayout<UnsafeRawPointer>.size == 8,
              MemoryLayout<WidgetFamily>.size == 1,
              MemoryLayout<WidgetFamily>.stride == 1,
              MemoryLayout<TimelineProviderContext>.size == expectedContextLayout.size,
              MemoryLayout<TimelineProviderContext>.stride == expectedContextLayout.stride,
              MemoryLayout<TimelineProviderContext>.alignment == expectedContextLayout.alignment,
              MemoryLayout<TimelineProviderContext>.offset(of: \.environmentVariants)
                == expectedContextLayout.variantsOffset,
              MemoryLayout<TimelineProviderContext>.offset(of: \.family)
                == expectedContextLayout.familyOffset,
              MemoryLayout<TimelineProviderContext>.offset(of: \.isPreview)
                == expectedContextLayout.previewOffset,
              MemoryLayout<TimelineProviderContext>.offset(of: \.displaySize)
                == expectedContextLayout.displaySizeOffset else {
            return failure(
                .gate,
                "timeline_context_layout_changed",
                "WidgetKit's timeline context layout does not match the verified renderer ABI."
            )
        }
        guard EnvironmentValues().widgetFamily == .systemMedium else {
            return failure(
                .gate,
                "widget_family_environment_changed",
                "SwiftUI's empty widget-family environment no longer matches the verified renderer ABI."
            )
        }
        guard _typeByName(descriptorPreferenceKeyName) is any PreferenceKey.Type else {
            return failure(
                .gate,
                "descriptor_preference_missing",
                "WidgetKit's descriptor preference type is unavailable."
            )
        }
        for symbol in requiredSymbols {
            let available = symbol.withCString(VibeWidgetRuntimeSymbolAvailable)
            guard available else {
                return failure(
                    .gate,
                    "swiftui_symbol_missing",
                    "SwiftUI's compatible widget-host ABI is unavailable on this system."
                )
            }
        }
        return nil
#endif
    }

    static func render<B: WidgetBundle>(
        bundle: B,
        requestedKind: String,
        familyRawValue: Int64,
        displaySize: CGSize,
        requestIdentifier: String,
        extensionBundleIdentifier: String,
        executablePath: String
    ) async throws -> ContainerWidgetCompatibleSession {
        if let supportFailure { throw supportFailure }
        guard let family = WidgetFamily(rawValue: Int(familyRawValue)),
              family == .systemSmall
                || family == .systemMedium
                || family == .systemLarge else {
            throw failure(
                .gate,
                "unsupported_widget_family",
                "The compatible renderer supports standard small, medium, and large widgets on iPhone."
            )
        }
        guard displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0,
              displaySize.width <= 4_096, displaySize.height <= 4_096 else {
            throw failure(
                .gate,
                "invalid_display_size",
                "The widget surface reported an invalid display size."
            )
        }

        let runtimeRenderer = ContainerWidgetRuntimeRenderer.shared
        runtimeRenderer.beginCrashProtectedOperation(
            requestIdentifier: requestIdentifier,
            extensionBundleIdentifier: extensionBundleIdentifier,
            executablePath: executablePath,
            stage: "compatibleRender"
        )
        defer {
            runtimeRenderer.endCrashProtectedOperation(
                requestIdentifier: requestIdentifier
            )
        }

        return try await renderGuarded(
            bundle: bundle,
            requestedKind: requestedKind,
            family: family,
            displaySize: displaySize
        )
    }

    private static func renderGuarded<B: WidgetBundle>(
        bundle: B,
        requestedKind: String,
        family: WidgetFamily,
        displaySize: CGSize
    ) async throws -> ContainerWidgetCompatibleSession {
        guard let hostPointer = VibeWidgetBundleHostCreate(bundle) else {
            throw failure(
                .bundleInstantiation,
                "bundle_host_init_failed",
                "SwiftUI did not create a WidgetBundleHost for the captured bundle."
            )
        }
        let bundleHost = Unmanaged<AnyObject>
            .fromOpaque(hostPointer)
            .takeRetainedValue()
        let retainedHostPointer = Unmanaged.passUnretained(bundleHost).toOpaque()

        guard let preferenceKey = _typeByName(descriptorPreferenceKeyName)
            as? any PreferenceKey.Type else {
            throw failure(
                .configurationResolution,
                "descriptor_preference_missing",
                "WidgetKit's descriptor preference type disappeared after the ABI gate."
            )
        }
        let preference = readPreference(preferenceKey, host: retainedHostPointer)
        let configurations = try timelineConfigurations(from: preference)
        let configuration = try selectConfiguration(
            configurations,
            requestedKind: requestedKind
        )
        let entryProvider = try invokeEntryProviderFactory(
            configuration.makeEntryProvider
        )
        let generated = try await generateContent(
            entryProvider: entryProvider,
            family: family,
            displaySize: displaySize
        )
        return ContainerWidgetCompatibleSession(
            kind: configuration.kind,
            family: family,
            content: generated.view,
            usedSnapshot: generated.usedSnapshot,
            bundleHost: bundleHost,
            entryProvider: entryProvider
        )
    }

    private static func readPreference<K: PreferenceKey>(
        _ key: K.Type,
        host: UnsafeMutableRawPointer
    ) -> Any {
        VibeWidgetBundleHostReadPreference(host, key)
    }

    private static func timelineConfigurations(
        from preference: Any
    ) throws -> [TimelineConfiguration] {
        let preferenceMirror = Mirror(reflecting: preference)
        guard preferenceMirror.displayStyle == .collection else {
            throw failure(
                .configurationResolution,
                "descriptor_value_not_collection",
                "WidgetKit returned an unexpected descriptor preference value."
            )
        }

        var configurations: [TimelineConfiguration] = []
        var unsupportedSources: [String] = []
        for child in preferenceMirror.children {
            let descriptor = child.value
            guard String(reflecting: type(of: descriptor)) == "WidgetKit.WidgetDescriptor",
                  let source = reflectedChild(named: "source", in: descriptor) else {
                throw failure(
                    .configurationResolution,
                    "invalid_widget_descriptor",
                    "WidgetKit returned a descriptor with an unknown runtime layout."
                )
            }

            let sourceMirror = Mirror(reflecting: source)
            guard sourceMirror.displayStyle == .enum,
                  let sourceCase = sourceMirror.children.first,
                  sourceMirror.children.count == 1 else {
                throw failure(
                    .configurationResolution,
                    "invalid_view_source",
                    "The widget descriptor's view source has an unknown runtime layout."
                )
            }
            guard sourceCase.label == "timeline",
                  String(reflecting: type(of: sourceCase.value))
                    == "WidgetKit.TimelineViewSource" else {
                unsupportedSources.append(sourceCase.label ?? "unknown")
                continue
            }

            let timeline = sourceCase.value
            guard let kind = reflectedChild(named: "kind", in: timeline) as? String,
                  !kind.isEmpty,
                  let intentType = reflectedChild(named: "intentType", in: timeline),
                  isNilOptional(intentType),
                  let factory = reflectedChild(named: "makeEntryProvider", in: timeline) else {
                unsupportedSources.append("intent-or-malformed-timeline")
                continue
            }
            configurations.append(
                TimelineConfiguration(kind: kind, makeEntryProvider: factory)
            )
        }

        guard !configurations.isEmpty else {
            let sourceDescription = unsupportedSources.isEmpty
                ? "no configurations"
                : unsupportedSources.sorted().joined(separator: ", ")
            throw failure(
                .configurationResolution,
                "unsupported_configuration_source",
                "This widget uses \(sourceDescription). The first compatible renderer supports StaticConfiguration with TimelineProvider only."
            )
        }
        return configurations
    }

    private static func selectConfiguration(
        _ configurations: [TimelineConfiguration],
        requestedKind: String
    ) throws -> TimelineConfiguration {
        if let exact = configurations.first(where: { $0.kind == requestedKind }) {
            return exact
        }
        if configurations.count == 1, let only = configurations.first {
            return only
        }
        throw failure(
            .configurationResolution,
            "widget_kind_not_found",
            "The requested widget kind was not found in the real WidgetBundle descriptors."
        )
    }

    private static func invokeEntryProviderFactory(
        _ factory: Any
    ) throws -> AnyObject {
        let dynamicType = type(of: factory)
        let dynamicTypeName = String(reflecting: dynamicType)
        let functionMetadata = unsafeBitCast(
            dynamicType,
            to: UnsafeRawPointer.self
        )
        guard dynamicTypeName == entryProviderFactoryTypeName,
              VibeWidgetRuntimeReadableMemory(
                functionMetadata,
                3 * MemoryLayout<UInt>.stride
              ) else {
            NSLog(
                "[WidgetRuntime] Entry-provider closure ABI mismatch type=%@ metadata=0x%llx.",
                dynamicTypeName,
                UInt(bitPattern: functionMetadata)
            )
            throw failure(
                .configurationResolution,
                "invalid_entry_provider_factory",
                "The StaticConfiguration entry-provider factory has an unsupported closure ABI."
            )
        }

        let functionMetadataWords = functionMetadata.bindMemory(
            to: UInt.self,
            capacity: 3
        )
        guard let resultType = _typeByName(
            entryProviderExistentialMangledName
        ) else {
            throw failure(
                .configurationResolution,
                "entry_provider_factory_type_mismatch",
                "WidgetKit's EntryProviding existential type could not be resolved."
            )
        }
        let expectedResultMetadata = unsafeBitCast(
            resultType,
            to: UnsafeRawPointer.self
        )
        guard functionMetadataWords[0] == swiftFunctionMetadataKind,
              functionMetadataWords[1] == noArgumentClosureFlags,
              let resultMetadata = UnsafeRawPointer(
                bitPattern: functionMetadataWords[2]
              ),
              resultMetadata == expectedResultMetadata,
              VibeWidgetRuntimeReadableMemory(
                resultMetadata,
                3 * MemoryLayout<UInt>.stride
              ),
              String(reflecting: unsafeBitCast(
                resultMetadata,
                to: Any.Type.self
              )) == entryProviderExistentialTypeName else {
            throw failure(
                .configurationResolution,
                "entry_provider_factory_type_mismatch",
                "The StaticConfiguration factory does not have WidgetKit's verified EntryProviding result ABI."
            )
        }

        let existentialMetadataWords = resultMetadata.bindMemory(
            to: UInt.self,
            capacity: 3
        )
        let flagsAndProtocolCount = existentialMetadataWords[1]
        let existentialFlags = UInt32(truncatingIfNeeded: flagsAndProtocolCount)
        let protocolCount = UInt32(
            truncatingIfNeeded: flagsAndProtocolCount >> 32
        )
        let protocolDescriptorWord = existentialMetadataWords[2]
        guard existentialMetadataWords[0] == swiftExistentialMetadataKind,
              existentialFlags == entryProviderExistentialFlags,
              protocolCount == 1,
              protocolDescriptorWord & 1 == 0,
              let protocolDescriptor = UnsafeRawPointer(
                bitPattern: protocolDescriptorWord
              ),
              VibeWidgetRuntimeReadableMemory(
                protocolDescriptor,
                MemoryLayout<UInt32>.stride
              ),
              protocolDescriptor.load(as: UInt32.self) & 0x1f == 3 else {
            throw failure(
                .configurationResolution,
                "entry_provider_existential_layout_changed",
                "WidgetKit's EntryProviding existential no longer has the verified opaque layout."
            )
        }

        // Dynamically open WidgetKit's private existential metatype so Swift
        // performs the checked closure projection, indirect result allocation,
        // value-witness destruction, and object bridging itself.
        guard let invoker = _openExistential(
            resultType,
            do: makeEntryProviderFactoryInvoker
        ) else {
            throw failure(
                .configurationResolution,
                "entry_provider_existential_layout_changed",
                "WidgetKit's EntryProviding existential no longer has the verified opaque layout."
            )
        }
        guard let object = invoker.invoke(factory) else {
            throw failure(
                .configurationResolution,
                "invalid_entry_provider_factory",
                "The StaticConfiguration entry-provider factory could not be invoked with WidgetKit's verified result type."
            )
        }

        let concreteType = type(of: object) as Any.Type
        guard concreteType is AnyClass,
              String(reflecting: concreteType)
                .hasPrefix("WidgetKit.TimelineEntryProvider<") else {
            throw failure(
                .configurationResolution,
                "unsupported_entry_provider",
                "The configuration did not produce WidgetKit's TimelineEntryProvider class."
            )
        }
        return object
    }

    private static func generateContent(
        entryProvider: AnyObject,
        family: WidgetFamily,
        displaySize: CGSize
    ) async throws -> GeneratedContent {
        let mirror = Mirror(reflecting: entryProvider)
        guard let provider = mirror.children.first(where: {
            $0.label == "provider"
        })?.value as? any TimelineProvider,
        let generator = mirror.children.first(where: {
            $0.label == "generator"
        })?.value else {
            throw failure(
                .configurationResolution,
                "timeline_provider_layout_changed",
                "WidgetKit's TimelineEntryProvider no longer exposes its provider and view generator."
            )
        }
        let context = try makeTimelineContext(
            family: family,
            displaySize: displaySize
        )
        return try await generateContent(
            provider: provider,
            generator: generator,
            context: context
        )
    }

    private static func generateContent<P: TimelineProvider>(
        provider: P,
        generator: Any,
        context: TimelineProviderContext
    ) async throws -> GeneratedContent {
        // Build the real placeholder first. It proves the selected provider and
        // generator pair without relying on a guest callback or app-group data.
        let placeholder = provider.placeholder(in: context)
        let placeholderView = try generateView(
            generator: generator,
            entry: placeholder
        )

        do {
            let snapshot = try await snapshot(
                provider: provider,
                context: context,
                timeout: .seconds(2)
            )
            return GeneratedContent(
                view: try generateView(generator: generator, entry: snapshot),
                usedSnapshot: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A real provider-generated placeholder is still valid widget
            // content. Slow or data-dependent snapshot failures do not replace
            // it with a fabricated card.
            return GeneratedContent(view: placeholderView, usedSnapshot: false)
        }
    }

    private static func snapshot<P: TimelineProvider>(
        provider: P,
        context: TimelineProviderContext,
        timeout: Duration
    ) async throws -> P.Entry {
        let gate = SnapshotGate<P.Entry>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, timeout: timeout)
                provider.getSnapshot(in: context) { entry in
                    gate.succeed(entry)
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    private static func generateView<Entry>(
        generator: Any,
        entry: Entry
    ) throws -> AnyView {
        var generator = generator
        let closureWords = withUnsafeBytes(of: &generator) {
            Array($0.bindMemory(to: UInt.self))
        }
        guard closureWords.count == 4,
              let encodedFunction = UnsafeRawPointer(bitPattern: closureWords[0]),
              let function = VibeWidgetRuntimeStripInstructionPointer(encodedFunction),
              let functionMetadata = UnsafeRawPointer(bitPattern: closureWords[3]),
              isCallable(function),
              VibeWidgetRuntimeReadableMemory(
                functionMetadata,
                4 * MemoryLayout<UInt>.stride
              ) else {
            throw failure(
                .viewGeneration,
                "invalid_view_generator",
                "The widget view generator has an unsupported closure ABI."
            )
        }
        let closureContext = UnsafeRawPointer(bitPattern: closureWords[1])
        let metadataWords = functionMetadata.bindMemory(to: UInt.self, capacity: 4)
        let entryMetadataWord = unsafeBitCast(Entry.self, to: UInt.self)
        guard metadataWords[0] == 0x302,
              metadataWords[1] & 0x00ff_ffff == 1,
              metadataWords[3] == entryMetadataWord,
              let resultMetadata = UnsafeRawPointer(bitPattern: metadataWords[2]),
              VibeWidgetRuntimeReadableMemory(
                resultMetadata.advanced(by: -MemoryLayout<UInt>.stride),
                2 * MemoryLayout<UInt>.stride
              ),
              let witness = VibeViewWitness(resultMetadata),
              VibeWidgetRuntimeReadableMemory(witness, MemoryLayout<UInt>.stride) else {
            throw failure(
                .viewGeneration,
                "view_generator_type_mismatch",
                "The widget generator's entry or SwiftUI.View metadata did not match its provider."
            )
        }

        let valueWitnessAddress = resultMetadata
            .advanced(by: -MemoryLayout<UInt>.stride)
            .load(as: UnsafeRawPointer.self)
        guard VibeWidgetRuntimeReadableMemory(
            valueWitnessAddress,
            11 * MemoryLayout<UInt>.stride
        ) else {
            throw failure(
                .viewGeneration,
                "unreadable_view_value_witness",
                "The generated view's value-witness table is unreadable."
            )
        }
        let valueWitness = valueWitnessAddress.bindMemory(to: UInt.self, capacity: 11)
        let size = max(valueWitness[8], 1)
        let stride = max(valueWitness[9], size)
        let alignmentMask = valueWitness[10] & 0xff
        let alignment = alignmentMask + 1
        guard size <= stride, stride <= 16 * 1_024 * 1_024,
              alignment <= 4_096,
              alignment.nonzeroBitCount == 1 else {
            throw failure(
                .viewGeneration,
                "invalid_view_value_layout",
                "The generated SwiftUI.View reported an invalid value layout."
            )
        }

        let result = UnsafeMutableRawPointer.allocate(
            byteCount: Int(stride),
            alignment: Int(alignment)
        )
        result.initializeMemory(as: UInt8.self, repeating: 0, count: Int(stride))
        defer { result.deallocate() }
        withUnsafePointer(to: entry) { entryPointer in
            VibeInvokeOneArgViewClosure(
                function,
                closureContext,
                UnsafeRawPointer(entryPointer),
                result
            )
        }
        return VibeMakeAnyView(result, resultMetadata, witness)
    }

    private static func makeTimelineContext(
        family: WidgetFamily,
        displaySize: CGSize
    ) throws -> TimelineProviderContext {
        guard let familyOffset = MemoryLayout<TimelineProviderContext>
            .offset(of: \.family),
        let previewOffset = MemoryLayout<TimelineProviderContext>
            .offset(of: \.isPreview),
        let displaySizeOffset = MemoryLayout<TimelineProviderContext>
            .offset(of: \.displaySize) else {
            throw failure(
                .gate,
                "timeline_context_offsets_missing",
                "WidgetKit did not publish timeline context field offsets."
            )
        }

        let byteCount = MemoryLayout<TimelineProviderContext>.stride
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<TimelineProviderContext>.alignment
        )
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        defer { storage.deallocate() }

        // The all-zero EnvironmentVariants representation is WidgetKit's empty
        // variant set for this verified ABI. Populate only public context fields
        // using runtime key-path offsets instead of assuming Swift padding.
        storage.storeBytes(
            of: family,
            toByteOffset: familyOffset,
            as: WidgetFamily.self
        )
        storage.storeBytes(
            of: true,
            toByteOffset: previewOffset,
            as: Bool.self
        )
        storage.storeBytes(
            of: displaySize,
            toByteOffset: displaySizeOffset,
            as: CGSize.self
        )
        return storage.load(as: TimelineProviderContext.self)
    }

    private static func reflectedChild(named label: String, in value: Any) -> Any? {
        Mirror(reflecting: value).children.first(where: {
            $0.label == label
        })?.value
    }

    private static func isNilOptional(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }

    private static func isCallable(_ pointer: UnsafeRawPointer) -> Bool {
        VibeWidgetRuntimeInstructionPointerIsUnsigned(pointer)
            && VibeWidgetRuntimeExecutableAddress(pointer)
    }

    private static func failure(
        _ stage: ContainerWidgetRuntimeReport.Failure.Stage,
        _ code: String,
        _ message: String,
        recoverable: Bool = true
    ) -> Failure {
        Failure(
            stage: stage,
            code: code,
            message: message,
            recoverable: recoverable
        )
    }
}

/// Exactly-once bridge for TimelineProvider's callback API. The lock protects
/// both continuation ownership and timeout/cancellation races, which makes the
/// narrow @unchecked Sendable promise valid even though Entry itself does not
/// require Sendable in WidgetKit's public protocol.
private final class SnapshotGate<Entry>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Entry, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var cancelledBeforeInstall = false

    func install(
        _ continuation: CheckedContinuation<Entry, Error>,
        timeout: Duration
    ) {
        lock.lock()
        if cancelledBeforeInstall {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                self?.fail(
                    ContainerWidgetCompatibleRenderer.Failure(
                        stage: .timelineSnapshot,
                        code: "snapshot_timeout",
                        message: "The widget provider did not return a snapshot in time.",
                        recoverable: true
                    )
                )
            } catch {
                // Cancellation is the normal completion path for this timer.
            }
        }
        timeoutTask = task
        lock.unlock()
    }

    func succeed(_ entry: Entry) {
        finish(.success(entry))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    func cancel() {
        lock.lock()
        if continuation == nil {
            cancelledBeforeInstall = true
            lock.unlock()
            return
        }
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Entry, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        continuation.resume(with: result)
    }
}
