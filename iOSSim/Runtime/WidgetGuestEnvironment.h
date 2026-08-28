#import <Foundation/Foundation.h>
#import <mach-o/loader.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs the resource and storage compatibility layer for a prepared
/// in-process widget module. Registrations are retained for the process
/// lifetime and repeated calls for the same executable/identifier are
/// idempotent.
///
/// The implementation derives and validates the immutable source app and its
/// writable LiveContainer data root from metadata already sealed into the
/// staged module. It then rebinds Objective-C message sends only in already
/// loaded images whose paths are inside registered guest apps. Host and system
/// images are never modified. Call this immediately after `dlopen` and before `_main`
/// or any bundle/provider evaluation. Image initializers run as part of
/// `dlopen`, before import slots can be safely rebound, and are deliberately
/// outside this compatibility contract.
///
/// A non-null error is allocated with `strdup`; the caller owns it and must
/// release it with `free`.
FOUNDATION_EXPORT char *_Nullable IOSSimPrepareWidgetGuestEnvironment(
    const char *preparedExecutablePath,
    const char *extensionBundleIdentifier
);

/// Returns whether `imageHeader` belongs unambiguously to a registered guest
/// context. This is a validation aid before the loader calls guest entry points.
FOUNDATION_EXPORT bool IOSSimWidgetGuestEnvironmentOwnsImage(
    const struct mach_header_64 *imageHeader
);

/// Returns the staged extension bundle selected from the calling guest image,
/// or from the sole registered environment for a host caller. Returns null
/// when a host caller has multiple possible environments. The pointer is
/// unretained and remains valid for the process lifetime. Swift callers can
/// bridge it with `Unmanaged<Bundle>.fromOpaque(...).takeUnretainedValue()`.
FOUNDATION_EXPORT void *_Nullable IOSSimWidgetGuestExtensionBundle(void);

/// Returns a copied filesystem path for the caller-selected guest's redirected
/// app-group container, creating the directory when necessary. Returns null
/// for an ambiguous host caller. The caller owns the returned C string and
/// must release it with `free`.
FOUNDATION_EXPORT char *_Nullable IOSSimCopyWidgetGuestAppGroupPath(
    const char *groupIdentifier
);

NS_ASSUME_NONNULL_END
