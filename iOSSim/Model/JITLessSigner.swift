import Foundation

@_silgen_name("IOSSimJITLessSigningConfigured")
private func IOSSimJITLessSigningConfigured() -> Bool

@_silgen_name("IOSSimConfigureJITLessSigning")
private func IOSSimConfigureJITLessSigning(
    _ certificate: UnsafeRawPointer,
    _ length: Int,
    _ password: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("IOSSimRemoveJITLessSigning")
private func IOSSimRemoveJITLessSigning()

@_silgen_name("IOSSimSignGuestForJITLess")
private func IOSSimSignGuestForJITLess(
    _ appBundlePath: UnsafePointer<CChar>,
    _ tweaksPath: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("IOSSimPrepareWidgetExtensionForHosting")
private func IOSSimPrepareWidgetExtensionForHosting(
    _ appBundlePath: UnsafePointer<CChar>,
    _ extensionBundlePath: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("IOSSimPreflightWidgetExtensionForHosting")
private func IOSSimPreflightWidgetExtensionForHosting(
    _ appBundlePath: UnsafePointer<CChar>,
    _ extensionBundlePath: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("IOSSimPrepareWidgetRuntimeModule")
private func IOSSimPrepareWidgetRuntimeModule(
    _ appBundlePath: UnsafePointer<CChar>,
    _ extensionBundlePath: UnsafePointer<CChar>,
    _ preparedExecutablePath: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("IOSSimLoadAndCaptureWidgetRuntimeModule")
private func IOSSimLoadAndCaptureWidgetRuntimeModule(
    _ preparedExecutablePath: UnsafePointer<CChar>,
    _ requestIdentifier: UnsafePointer<CChar>,
    _ extensionBundleIdentifier: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

/// Swift-facing owner of LiveContainer's ZSign-based JIT-less configuration.
enum JITLessSigner {
    /// ZSign exposes callback-based work that synchronously waits for its own
    /// dispatch worker. Keep that wait on one dedicated GCD queue: callers
    /// suspend on a continuation instead of blocking Swift's cooperative pool.
    private static let operationQueue = DispatchQueue(
        label: "com.vibecontainers.jitless-signer",
        qos: .userInitiated
    )

    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    struct WidgetSigningRequired: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    struct PreparedWidgetRuntimeModule: Equatable, Sendable {
        let executablePath: String

        var bundleURL: URL {
            URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        }
    }

    private struct RuntimeModulePreparationResult: Sendable {
        let executablePath: String?
        let errorMessage: String?
    }

    static var isConfigured: Bool { IOSSimJITLessSigningConfigured() }

    /// Matching signatures are a physical-device library-validation path.
    /// Simulator guests use LiveContainer's platform-routing path instead.
    static var isAvailableForLaunch: Bool {
        !HostPlatform.isSimulator && isConfigured
    }

    static var teamIdentifier: String? {
        UserDefaults.standard.string(forKey: "IOSSimCertificateTeamID")
    }

    private static var bundledCertificateURL: URL? {
        Bundle.main.url(forResource: "VibeContainersSigner", withExtension: "p12")
    }

    static var hasBundledCertificate: Bool {
        bundledCertificateURL != nil
    }

    static func bundledCertificate() throws -> Data {
        guard let url = bundledCertificateURL else {
            throw Failure(message: "This build does not contain a bundled PKCS#12 identity.")
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw Failure(message: "The bundled identity could not be read: \(error.localizedDescription)")
        }
    }

    static func configure(certificate: Data, password: String) async throws {
        let message = await performOperation {
            certificate.withUnsafeBytes { bytes -> String? in
                guard let base = bytes.baseAddress else { return "The selected certificate is empty." }
                return password.withCString { passwordBytes in
                    guard let error = IOSSimConfigureJITLessSigning(
                        base, certificate.count, passwordBytes
                    ) else { return nil }
                    defer { free(error) }
                    return String(cString: error)
                }
            }
        }
        if let message { throw Failure(message: message) }
    }

    static func remove() {
        IOSSimRemoveJITLessSigning()
    }

    /// ZSign replaces each Mach-O file to invalidate the kernel's signature
    /// cache, so this work must remain off the main actor.
    static func sign(appBundle: URL) async throws {
        let tweaks = await TweakStore.shared.folder
        let appPath = appBundle.path
        let tweaksPath = tweaks.path
        let message = await performOperation {
            appPath.withCString { appBytes -> String? in
                tweaksPath.withCString { tweakBytes in
                    guard let error = IOSSimSignGuestForJITLess(appBytes, tweakBytes) else {
                        return nil
                    }
                    defer { free(error) }
                    return String(cString: error)
                }
            }
        }
        if let message { throw Failure(message: message) }
    }

    /// Validates the immutable source widget and re-registers a matching,
    /// provisioned runner when one has already been staged.
    static func preflightWidgetForHosting(appBundle: URL, extensionBundle: URL) async throws {
        try await runWidgetOperation(
            appBundle: appBundle,
            extensionBundle: extensionBundle,
            shouldSign: false
        )
    }

    /// Atomically stages an isolated copy under the reserved runner identity,
    /// signs nested code before its provisioned main executable, and registers
    /// the exact runner URL with PlugInKit. The installed guest stays untouched.
    static func prepareWidgetForHosting(appBundle: URL, extensionBundle: URL) async throws {
        try await runWidgetOperation(
            appBundle: appBundle,
            extensionBundle: extensionBundle,
            shouldSign: true
        )
    }

    /// Prepares an isolated, host-signed MH_DYLIB copy of the guest widget.
    /// Conversion and signing stay on the dedicated signer queue; the source
    /// .appex is never modified.
    static func prepareWidgetRuntimeModule(
        appBundle: URL,
        extensionBundle: URL
    ) async throws -> PreparedWidgetRuntimeModule {
        let appPath = appBundle.resolvingSymlinksInPath().path
        let extensionPath = extensionBundle.resolvingSymlinksInPath().path
        let result: RuntimeModulePreparationResult = await performOperation {
            appPath.withCString { appBytes in
                extensionPath.withCString { extensionBytes in
                    var preparedPath: UnsafeMutablePointer<CChar>?
                    let error = IOSSimPrepareWidgetRuntimeModule(
                        appBytes, extensionBytes, &preparedPath
                    )
                    defer {
                        if let error { free(error) }
                        if let preparedPath { free(preparedPath) }
                    }
                    if let error {
                        return RuntimeModulePreparationResult(
                            executablePath: nil,
                            errorMessage: String(cString: error)
                        )
                    }
                    guard let preparedPath else {
                        return RuntimeModulePreparationResult(
                            executablePath: nil,
                            errorMessage: "The widget module signer returned no executable path."
                        )
                    }
                    return RuntimeModulePreparationResult(
                        executablePath: String(cString: preparedPath),
                        errorMessage: nil
                    )
                }
            }
        }
        if let message = result.errorMessage { throw Failure(message: message) }
        guard let executablePath = result.executablePath, !executablePath.isEmpty else {
            throw Failure(message: "The widget module signer returned an empty executable path.")
        }
        return PreparedWidgetRuntimeModule(executablePath: executablePath)
    }

    /// Loads the already-signed module and synchronously captures its concrete
    /// WidgetBundle on the main actor. The Objective-C loader retains the dyld
    /// handle for the process lifetime because captured Swift metadata and
    /// providers cannot be safely unloaded.
    @MainActor
    static func captureWidgetRuntimeModule(
        _ module: PreparedWidgetRuntimeModule,
        requestIdentifier: String,
        extensionBundleIdentifier: String
    ) throws {
        let message = module.executablePath.withCString { executableBytes in
            requestIdentifier.withCString { requestBytes in
                extensionBundleIdentifier.withCString { extensionBytes -> String? in
                    guard let error = IOSSimLoadAndCaptureWidgetRuntimeModule(
                        executableBytes, requestBytes, extensionBytes
                    ) else { return nil }
                    defer { free(error) }
                    return String(cString: error)
                }
            }
        }
        if let message { throw Failure(message: message) }
    }

    private static func runWidgetOperation(
        appBundle: URL,
        extensionBundle: URL,
        shouldSign: Bool
    ) async throws {
        let appPath = appBundle.resolvingSymlinksInPath().path
        let extensionPath = extensionBundle.resolvingSymlinksInPath().path
        let message = await performOperation {
            appPath.withCString { appBytes -> String? in
                extensionPath.withCString { extensionBytes in
                    let error = shouldSign
                        ? IOSSimPrepareWidgetExtensionForHosting(appBytes, extensionBytes)
                        : IOSSimPreflightWidgetExtensionForHosting(appBytes, extensionBytes)
                    guard let error else { return nil }
                    defer { free(error) }
                    return String(cString: error)
                }
            }
        }
        if let message {
            let prefix = "SIGNING_REQUIRED:"
            if message.hasPrefix(prefix) {
                throw WidgetSigningRequired(message: String(message.dropFirst(prefix.count)))
            }
            throw Failure(message: message)
        }
    }

    private static func performOperation<Result: Sendable>(
        _ operation: @escaping @Sendable () -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            operationQueue.async {
                continuation.resume(returning: operation())
            }
        }
    }
}
