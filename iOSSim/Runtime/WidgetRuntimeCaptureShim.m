#import "WidgetRuntimeCaptureShim.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <os/lock.h>
#import <pthread.h>
#import <string.h>

#import "../../LiveContainer-3.8.0/litehook/src/litehook.h"

static NSString *const IOSSimWidgetRuntimeEnabledKey =
    @"container.widgets.runtimeRenderer.enabled";

extern void IOSSimWidgetRuntimeDidArm(const char *requestIdentifier,
                                      const char *extensionBundleIdentifier,
                                      const char *executablePath);
extern void IOSSimWidgetRuntimeDidCapture(const char *requestIdentifier,
                                          const char *extensionBundleIdentifier,
                                          const char *executablePath,
                                          uintptr_t bundleMetadata,
                                          uintptr_t widgetBundleWitness);
extern void IOSSimWidgetRuntimeDidFail(const char *requestIdentifier,
                                       const char *extensionBundleIdentifier,
                                       const char *executablePath,
                                       const char *stage,
                                       const char *code,
                                       const char *message,
                                       bool recoverable);

@interface IOSSimWidgetRuntimeCaptureContext : NSObject
@property(nonatomic, copy) NSString *requestIdentifier;
@property(nonatomic, copy) NSString *extensionBundleIdentifier;
@property(nonatomic, copy) NSString *executablePath;
@end

@implementation IOSSimWidgetRuntimeCaptureContext
@end

static os_unfair_lock IOSSimWidgetRuntimeContextLock = OS_UNFAIR_LOCK_INIT;
static IOSSimWidgetRuntimeCaptureContext *IOSSimWidgetRuntimeContext;

static char *IOSSimWidgetRuntimeError(NSString *message) {
    return strdup(message.UTF8String ?: "Widget runtime renderer failed.");
}

static BOOL IOSSimReadablePointer(const void *pointer) {
    if (!pointer || ((uintptr_t)pointer & (sizeof(void *) - 1)) != 0) return NO;

    vm_address_t address = (vm_address_t)pointer;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(
        mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object
    );
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || !(info.protection & VM_PROT_READ)) return NO;

    vm_address_t value = (vm_address_t)pointer;
    return value >= address && value + sizeof(void *) >= value
        && value + sizeof(void *) <= address + size;
}

static IOSSimWidgetRuntimeCaptureContext *IOSSimTakeCaptureContext(void) {
    os_unfair_lock_lock(&IOSSimWidgetRuntimeContextLock);
    IOSSimWidgetRuntimeCaptureContext *context = IOSSimWidgetRuntimeContext;
    IOSSimWidgetRuntimeContext = nil;
    os_unfair_lock_unlock(&IOSSimWidgetRuntimeContextLock);
    return context;
}

static IOSSimWidgetRuntimeCaptureContext *IOSSimTakeCaptureContextMatching(
    NSString *requestIdentifier
) {
    os_unfair_lock_lock(&IOSSimWidgetRuntimeContextLock);
    IOSSimWidgetRuntimeCaptureContext *context = IOSSimWidgetRuntimeContext;
    if (context && [context.requestIdentifier isEqualToString:requestIdentifier]) {
        IOSSimWidgetRuntimeContext = nil;
    } else {
        context = nil;
    }
    os_unfair_lock_unlock(&IOSSimWidgetRuntimeContextLock);
    return context;
}

bool IOSSimWidgetRuntimeRendererEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:IOSSimWidgetRuntimeEnabledKey];
}

void IOSSimCaptureWidgetBundleMain(const void *bundleMetadata,
                                   const void *widgetBundleWitness) {
    IOSSimWidgetRuntimeCaptureContext *context = IOSSimTakeCaptureContext();
    if (!context) return;

    if (pthread_main_np() != 1) {
        IOSSimWidgetRuntimeDidFail(
            context.requestIdentifier.UTF8String,
            context.extensionBundleIdentifier.UTF8String,
            context.executablePath.UTF8String,
            "capture", "not_main_actor",
            "The guest called WidgetBundle.main off the main thread; unsafe metadata evaluation was refused.",
            true
        );
        return;
    }

    if (!IOSSimReadablePointer(bundleMetadata)
        || !IOSSimReadablePointer(widgetBundleWitness)) {
        IOSSimWidgetRuntimeDidFail(
            context.requestIdentifier.UTF8String,
            context.extensionBundleIdentifier.UTF8String,
            context.executablePath.UTF8String,
            "abiValidation", "unreadable_conformance",
            "WidgetBundle.main supplied an unreadable metadata or witness-table pointer.",
            false
        );
        return;
    }

    Dl_info metadataImage = {0};
    if (dladdr(bundleMetadata, &metadataImage) == 0 || !metadataImage.dli_fbase) {
        IOSSimWidgetRuntimeDidFail(
            context.requestIdentifier.UTF8String,
            context.extensionBundleIdentifier.UTF8String,
            context.executablePath.UTF8String,
            "abiValidation", "metadata_image_unknown",
            "The captured WidgetBundle metadata does not belong to a loaded dyld image.",
            false
        );
        return;
    }

    IOSSimWidgetRuntimeDidCapture(
        context.requestIdentifier.UTF8String,
        context.extensionBundleIdentifier.UTF8String,
        context.executablePath.UTF8String,
        (uintptr_t)bundleMetadata,
        (uintptr_t)widgetBundleWitness
    );
}

void *IOSSimWidgetBundleMainReplacementAddress(void) {
    return (void *)&IOSSimCaptureWidgetBundleMain;
}

char *IOSSimArmWidgetRuntimeCapture(const struct mach_header_64 *imageHeader,
                                    const char *requestIdentifier,
                                    const char *extensionBundleIdentifier,
                                    const char *executablePath) {
    if (!IOSSimWidgetRuntimeRendererEnabled()) {
        return IOSSimWidgetRuntimeError(
            @"The experimental WidgetBundle ABI renderer is disabled."
        );
    }
    if (!imageHeader || !requestIdentifier || !extensionBundleIdentifier
        || !executablePath) {
        return IOSSimWidgetRuntimeError(@"Widget runtime capture metadata is incomplete.");
    }
    if (pthread_main_np() != 1) {
        return IOSSimWidgetRuntimeError(
            @"Widget runtime capture must be armed on the main thread."
        );
    }
    if (imageHeader->magic != MH_MAGIC_64
        || (imageHeader->filetype != MH_DYLIB && imageHeader->filetype != MH_BUNDLE)) {
        return IOSSimWidgetRuntimeError(
            @"The widget image must already be converted into a loaded arm64 dylib or bundle."
        );
    }

    NSString *request = [NSString stringWithUTF8String:requestIdentifier];
    NSString *extension = [NSString stringWithUTF8String:extensionBundleIdentifier];
    NSString *path = [NSString stringWithUTF8String:executablePath];
    if (!request.length || !extension.length || !path.length) {
        return IOSSimWidgetRuntimeError(@"Widget runtime capture metadata is not valid UTF-8.");
    }

    // Crash recovery is request-scoped and completed by the MainActor Swift
    // renderer before this loader can be reached. Do not interpret another
    // widget's currently active async render marker as a prior process crash.

    os_unfair_lock_lock(&IOSSimWidgetRuntimeContextLock);
    BOOL busy = IOSSimWidgetRuntimeContext != nil;
    os_unfair_lock_unlock(&IOSSimWidgetRuntimeContextLock);
    if (busy) {
        return IOSSimWidgetRuntimeError(
            @"Another WidgetBundle ABI capture is already active."
        );
    }

    static const char *symbols[] = {
        "$s7SwiftUI12WidgetBundleP0C3KitE4mainyyFZ",
        "$s9WidgetKit0A6BundlePAAE4mainyyFZ"
    };
    void *resolved[sizeof(symbols) / sizeof(symbols[0])] = {0};
    NSUInteger resolvedCount = 0;
    for (NSUInteger index = 0; index < sizeof(symbols) / sizeof(symbols[0]); index++) {
        void *candidate = dlsym(RTLD_DEFAULT, symbols[index]);
        if (!candidate) continue;
        BOOL duplicate = NO;
        for (NSUInteger prior = 0; prior < resolvedCount; prior++) {
            if (resolved[prior] == candidate) duplicate = YES;
        }
        if (!duplicate) resolved[resolvedCount++] = candidate;
    }
    if (resolvedCount == 0) {
        return IOSSimWidgetRuntimeError(
            @"This iOS build does not export a compatible WidgetBundle.main ABI symbol."
        );
    }

    for (NSUInteger index = 0; index < resolvedCount; index++) {
        litehook_rebind_symbol(
            (const mach_header_u *)imageHeader,
            resolved[index],
            (void *)&IOSSimCaptureWidgetBundleMain,
            NULL
        );
    }

    IOSSimWidgetRuntimeCaptureContext *context = [IOSSimWidgetRuntimeCaptureContext new];
    context.requestIdentifier = request;
    context.extensionBundleIdentifier = extension;
    context.executablePath = path;
    os_unfair_lock_lock(&IOSSimWidgetRuntimeContextLock);
    if (IOSSimWidgetRuntimeContext) {
        os_unfair_lock_unlock(&IOSSimWidgetRuntimeContextLock);
        return IOSSimWidgetRuntimeError(
            @"Another WidgetBundle ABI capture started while the image was being prepared."
        );
    }
    IOSSimWidgetRuntimeContext = context;
    os_unfair_lock_unlock(&IOSSimWidgetRuntimeContextLock);

    IOSSimWidgetRuntimeDidArm(request.UTF8String, extension.UTF8String, path.UTF8String);
    return NULL;
}

void IOSSimFinishWidgetRuntimeCapture(const char *requestIdentifier,
                                      const char *loaderError) {
    if (!requestIdentifier) return;
    NSString *request = [NSString stringWithUTF8String:requestIdentifier];
    if (!request.length) return;
    IOSSimWidgetRuntimeCaptureContext *context =
        IOSSimTakeCaptureContextMatching(request);
    if (!context) return;

    NSString *message = loaderError
        ? [NSString stringWithUTF8String:loaderError]
        : @"The guest entry point returned without calling the compatible WidgetBundle.main ABI.";
    IOSSimWidgetRuntimeDidFail(
        context.requestIdentifier.UTF8String,
        context.extensionBundleIdentifier.UTF8String,
        context.executablePath.UTF8String,
        "capture", loaderError ? "loader_failed" : "entrypoint_not_captured",
        message.UTF8String ?: "Widget runtime loader failed.",
        true
    );
}
