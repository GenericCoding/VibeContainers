#import <Foundation/Foundation.h>
#import <mach-o/loader.h>

NS_ASSUME_NONNULL_BEGIN

/// Experimental in-process WidgetBundle ABI capture.
///
/// The caller must keep `imageHeader` loaded until the image's exported `main`
/// has returned. `requestIdentifier` should be the corresponding
/// `ContainerWidgetStore.Descriptor.id` so the SwiftUI surface can display the
/// structured inventory result.
///
/// This API never calls NSExtensionMain and never fabricates widget content.
/// It only redirects WidgetBundle.main for one already-loaded image so the
/// concrete bundle metadata and witness table can be inspected by Swift.
/// A non-null error is allocated with `strdup`; the caller owns it and must
/// release it with `free` after copying or presenting the message.
FOUNDATION_EXPORT char *_Nullable IOSSimArmWidgetRuntimeCapture(
    const struct mach_header_64 *imageHeader,
    const char *requestIdentifier,
    const char *extensionBundleIdentifier,
    const char *executablePath
);

/// Completes an armed capture after the guest entry point returns. If the
/// replacement was not reached, the active request becomes a structured
/// failure instead of remaining stuck in an indeterminate state.
FOUNDATION_EXPORT void IOSSimFinishWidgetRuntimeCapture(
    const char *requestIdentifier,
    const char *_Nullable loaderError
);

/// C-compatible replacement for WidgetBundle.main(metadata:witness:).
/// This is exported separately for loaders that already own their rebinding
/// implementation.
FOUNDATION_EXPORT void IOSSimCaptureWidgetBundleMain(
    const void *bundleMetadata,
    const void *widgetBundleWitness
);

FOUNDATION_EXPORT void *IOSSimWidgetBundleMainReplacementAddress(void);
FOUNDATION_EXPORT bool IOSSimWidgetRuntimeRendererEnabled(void);

NS_ASSUME_NONNULL_END
