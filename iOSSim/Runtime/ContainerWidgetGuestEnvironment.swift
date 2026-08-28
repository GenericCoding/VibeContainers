import Foundation

@_silgen_name("IOSSimWidgetGuestExtensionBundle")
private func IOSSimWidgetGuestExtensionBundle() -> UnsafeMutableRawPointer?

@_silgen_name("IOSSimCopyWidgetGuestAppGroupPath")
private func IOSSimCopyWidgetGuestAppGroupPath(
    _ groupIdentifier: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

/// Main-actor access to the exact extension resource/storage context installed
/// after the image-filtered widget loader completes `dlopen`. The renderer can
/// use these values when a public API accepts an explicit bundle or app-group
/// URL; guest calls to
/// `Bundle.main`, `UserDefaults`, and the file-manager app-group API are also
/// redirected automatically inside guest Mach-O images.
@MainActor
enum ContainerWidgetGuestEnvironment {
    static var extensionBundle: Bundle? {
        guard let pointer = IOSSimWidgetGuestExtensionBundle() else { return nil }
        return Unmanaged<Bundle>.fromOpaque(pointer).takeUnretainedValue()
    }

    static func appGroupURL(for identifier: String) -> URL? {
        identifier.withCString { bytes in
            guard let path = IOSSimCopyWidgetGuestAppGroupPath(bytes) else {
                return nil
            }
            defer { free(path) }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
    }
}
