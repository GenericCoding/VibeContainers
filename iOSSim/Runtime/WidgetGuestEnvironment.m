#import "WidgetGuestEnvironment.h"

#import <TargetConditionals.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <ptrauth.h>
#import <unistd.h>

#import "../../LiveContainer-3.8.0/litehook/src/litehook.h"

static NSString *const IOSSimWidgetSourceIdentifierKey =
    @"IOSSimSourceWidgetBundleIdentifier";
static NSString *const IOSSimWidgetSourceRelativePathKey =
    @"IOSSimSourceWidgetRelativePath";
static NSString *const IOSSimWidgetModulePrefix = @".IOSSimWidgetModule-";
static NSString *const IOSSimWidgetModuleStagePrefix = @".IOSSimWidgetModule-stage-";
static NSString *const IOSSimWidgetModuleBackupPrefix = @".IOSSimWidgetModule-backup-";

@interface NSUserDefaults (IOSSimWidgetGuestEnvironmentPrivate)
- (instancetype)_initWithSuiteName:(NSString *)suiteName
                         container:(NSURL *)container;
@end

@interface IOSSimWidgetGuestEnvironmentContext : NSObject
@property(nonatomic, copy) NSString *executablePath;
@property(nonatomic, copy) NSString *moduleRoot;
@property(nonatomic, copy) NSString *appRoot;
@property(nonatomic, copy) NSString *dataRoot;
@property(nonatomic, copy) NSString *extensionIdentifier;
@property(nonatomic, strong) NSBundle *extensionBundle;
@property(nonatomic, strong) NSUserDefaults *standardDefaults;
@property(nonatomic, strong) NSURL *dataRootURL;
@property(nonatomic, strong) NSURL *appGroupRootURL;
@end

@implementation IOSSimWidgetGuestEnvironmentContext
@end

typedef NS_ENUM(NSUInteger, IOSSimWidgetGuestCallerResolution) {
    IOSSimWidgetGuestCallerResolutionOutside,
    IOSSimWidgetGuestCallerResolutionUnique,
    IOSSimWidgetGuestCallerResolutionAmbiguous,
    IOSSimWidgetGuestCallerResolutionUnresolved
};

static os_unfair_lock IOSSimWidgetGuestEnvironmentLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, IOSSimWidgetGuestEnvironmentContext *>
    *IOSSimWidgetGuestEnvironmentsByExecutablePath;
static NSMutableDictionary<NSString *, IOSSimWidgetGuestEnvironmentContext *>
    *IOSSimWidgetGuestEnvironmentsByModuleRoot;
static NSMutableDictionary<NSString *, NSMutableArray<IOSSimWidgetGuestEnvironmentContext *> *>
    *IOSSimWidgetGuestEnvironmentsByAppRoot;
static NSMutableDictionary<NSString *, IOSSimWidgetGuestEnvironmentContext *>
    *IOSSimWidgetGuestEnvironmentsByLoadedImagePath;
static NSMutableSet<NSString *> *IOSSimWidgetGuestAmbiguousLoadedImagePaths;
static NSMutableSet<NSString *> *IOSSimWidgetGuestOutsideLoadedImagePaths;

// Read by the arm64 selector trampoline. They are initialized before the
// filtered image rebind is registered and then remain immutable.
SEL IOSSimWidgetGuestMainBundleSelector;
SEL IOSSimWidgetGuestStandardDefaultsSelector;
SEL IOSSimWidgetGuestSuiteDefaultsSelector;
SEL IOSSimWidgetGuestAppGroupSelector;

extern void IOSSimWidgetGuestObjCMessageSend(void);
extern void IOSSimWidgetGuestMainBundleSelectorSend(void);
extern void IOSSimWidgetGuestStandardDefaultsSelectorSend(void);
extern void IOSSimWidgetGuestSuiteDefaultsSelectorSend(void);
extern void IOSSimWidgetGuestAppGroupSelectorSend(void);

typedef struct {
    void *replacee;
    void *replacement;
} IOSSimWidgetGuestHookBinding;

static IOSSimWidgetGuestHookBinding IOSSimWidgetGuestHookBindings[5];
static NSUInteger IOSSimWidgetGuestHookBindingCount;
static NSString *IOSSimWidgetGuestHookSetupError;

static char *IOSSimWidgetGuestError(NSString *message) {
    return strdup((message ?: @"The widget guest environment failed.").UTF8String);
}

static NSString *IOSSimWidgetGuestCanonicalPath(NSString *path) {
    return path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
}

static BOOL IOSSimWidgetGuestPathIsInside(NSString *path, NSString *root) {
    if (!path.length || !root.length) return NO;
    NSString *standardPath = path.stringByStandardizingPath;
    NSString *standardRoot = root.stringByStandardizingPath;
    return [standardPath isEqualToString:standardRoot]
        || [standardPath hasPrefix:[standardRoot stringByAppendingString:@"/"]];
}

static void IOSSimInitializeWidgetGuestEnvironmentRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        IOSSimWidgetGuestEnvironmentsByExecutablePath = [NSMutableDictionary dictionary];
        IOSSimWidgetGuestEnvironmentsByModuleRoot = [NSMutableDictionary dictionary];
        IOSSimWidgetGuestEnvironmentsByAppRoot = [NSMutableDictionary dictionary];
        IOSSimWidgetGuestEnvironmentsByLoadedImagePath = [NSMutableDictionary dictionary];
        IOSSimWidgetGuestAmbiguousLoadedImagePaths = [NSMutableSet set];
        IOSSimWidgetGuestOutsideLoadedImagePaths = [NSMutableSet set];
    });
}

static NSObject *IOSSimWidgetGuestPreparationLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString *IOSSimWidgetGuestImagePath(const struct mach_header_64 *header) {
    if (!header) return nil;
    Dl_info image = {0};
    if (dladdr(header, &image) == 0 || !image.dli_fname) return nil;
    NSString *path = [NSString stringWithUTF8String:image.dli_fname];
    return IOSSimWidgetGuestCanonicalPath(path);
}

static IOSSimWidgetGuestEnvironmentContext *
IOSSimWidgetGuestEnvironmentForImagePath(
    NSString *imagePath,
    IOSSimWidgetGuestCallerResolution *resolutionOut
) {
    IOSSimInitializeWidgetGuestEnvironmentRegistry();
    NSString *canonicalPath = IOSSimWidgetGuestCanonicalPath(imagePath);
    if (!canonicalPath.length) {
        if (resolutionOut) {
            *resolutionOut = IOSSimWidgetGuestCallerResolutionUnresolved;
        }
        return nil;
    }

    os_unfair_lock_lock(&IOSSimWidgetGuestEnvironmentLock);
    IOSSimWidgetGuestEnvironmentContext *cached =
        IOSSimWidgetGuestEnvironmentsByLoadedImagePath[canonicalPath];
    if (cached) {
        os_unfair_lock_unlock(&IOSSimWidgetGuestEnvironmentLock);
        if (resolutionOut) *resolutionOut = IOSSimWidgetGuestCallerResolutionUnique;
        return cached;
    }
    if ([IOSSimWidgetGuestAmbiguousLoadedImagePaths containsObject:canonicalPath]) {
        os_unfair_lock_unlock(&IOSSimWidgetGuestEnvironmentLock);
        if (resolutionOut) {
            *resolutionOut = IOSSimWidgetGuestCallerResolutionAmbiguous;
        }
        return nil;
    }
    if ([IOSSimWidgetGuestOutsideLoadedImagePaths containsObject:canonicalPath]) {
        os_unfair_lock_unlock(&IOSSimWidgetGuestEnvironmentLock);
        if (resolutionOut) *resolutionOut = IOSSimWidgetGuestCallerResolutionOutside;
        return nil;
    }

    // An isolated module-root match is authoritative. This keeps two widget
    // extensions from the same source app distinguishable even though their
    // broader app roots are identical.
    IOSSimWidgetGuestEnvironmentContext *match = nil;
    BOOL ambiguous = NO;
    for (NSString *moduleRoot in IOSSimWidgetGuestEnvironmentsByModuleRoot) {
        if (!IOSSimWidgetGuestPathIsInside(canonicalPath, moduleRoot)) continue;
        IOSSimWidgetGuestEnvironmentContext *candidate =
            IOSSimWidgetGuestEnvironmentsByModuleRoot[moduleRoot];
        if (match && match != candidate) {
            ambiguous = YES;
            break;
        }
        match = candidate;
    }

    // A source-app image is eligible only when exactly one registered context
    // owns that app. Shared app images cannot safely imply which extension's
    // defaults or groups should be used.
    if (!match && !ambiguous) {
        for (NSString *appRoot in IOSSimWidgetGuestEnvironmentsByAppRoot) {
            if (!IOSSimWidgetGuestPathIsInside(canonicalPath, appRoot)) continue;
            for (IOSSimWidgetGuestEnvironmentContext *candidate in
                    IOSSimWidgetGuestEnvironmentsByAppRoot[appRoot]) {
                if (match && match != candidate) {
                    ambiguous = YES;
                    break;
                }
                match = candidate;
            }
            if (ambiguous) break;
        }
    }

    IOSSimWidgetGuestCallerResolution resolution;
    if (ambiguous) {
        [IOSSimWidgetGuestAmbiguousLoadedImagePaths addObject:canonicalPath];
        resolution = IOSSimWidgetGuestCallerResolutionAmbiguous;
        match = nil;
    } else if (match) {
        IOSSimWidgetGuestEnvironmentsByLoadedImagePath[canonicalPath] = match;
        resolution = IOSSimWidgetGuestCallerResolutionUnique;
    } else {
        [IOSSimWidgetGuestOutsideLoadedImagePaths addObject:canonicalPath];
        resolution = IOSSimWidgetGuestCallerResolutionOutside;
    }
    os_unfair_lock_unlock(&IOSSimWidgetGuestEnvironmentLock);
    if (resolutionOut) *resolutionOut = resolution;
    return match;
}

static IOSSimWidgetGuestEnvironmentContext *
IOSSimWidgetGuestEnvironmentForCaller(
    const void *callerAddress,
    IOSSimWidgetGuestCallerResolution *resolutionOut
) {
    if (!callerAddress) {
        if (resolutionOut) {
            *resolutionOut = IOSSimWidgetGuestCallerResolutionUnresolved;
        }
        return nil;
    }
#if __has_feature(ptrauth_calls)
    callerAddress = ptrauth_strip((void *)callerAddress,
                                  ptrauth_key_return_address);
#endif
    Dl_info caller = {0};
    if (dladdr(callerAddress, &caller) == 0 || !caller.dli_fname) {
        if (resolutionOut) {
            *resolutionOut = IOSSimWidgetGuestCallerResolutionUnresolved;
        }
        return nil;
    }
    NSString *imagePath = [NSString stringWithUTF8String:caller.dli_fname];
    return IOSSimWidgetGuestEnvironmentForImagePath(imagePath, resolutionOut);
}

static IOSSimWidgetGuestEnvironmentContext *
IOSSimSoleWidgetGuestEnvironment(void) {
    IOSSimInitializeWidgetGuestEnvironmentRegistry();
    os_unfair_lock_lock(&IOSSimWidgetGuestEnvironmentLock);
    IOSSimWidgetGuestEnvironmentContext *context = nil;
    if (IOSSimWidgetGuestEnvironmentsByExecutablePath.count == 1) {
        context = IOSSimWidgetGuestEnvironmentsByExecutablePath.objectEnumerator.nextObject;
    }
    os_unfair_lock_unlock(&IOSSimWidgetGuestEnvironmentLock);
    return context;
}

/// `litehook` calls this for loaded and subsequently added images. Every path
/// covered by a registered module/app context is eligible. Ambiguous shared
/// app images are rebound too, but their sensitive calls fail closed later.
static bool IOSSimWidgetGuestImageFilter(const mach_header_u *header) {
    NSString *path = IOSSimWidgetGuestImagePath(
        (const struct mach_header_64 *)header);
    IOSSimWidgetGuestCallerResolution resolution;
    (void)IOSSimWidgetGuestEnvironmentForImagePath(path, &resolution);
    return resolution == IOSSimWidgetGuestCallerResolutionUnique
        || resolution == IOSSimWidgetGuestCallerResolutionAmbiguous;
}

static BOOL IOSSimWidgetGuestObjectIsKindOfClass(id object, Class expectedClass) {
    if (!object || !expectedClass) return NO;
    Class current = object_getClass(object);
    if (class_isMetaClass(current)) return NO;
    while (current) {
        if (current == expectedClass) return YES;
        current = class_getSuperclass(current);
    }
    return NO;
}

static BOOL IOSSimWidgetGuestValidGroupIdentifier(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]
        || identifier.length == 0 || identifier.length > 255
        || [identifier isEqualToString:@"."]
        || [identifier isEqualToString:@".."]) return NO;
    static NSCharacterSet *invalidCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *allowed =
            NSCharacterSet.alphanumericCharacterSet.mutableCopy;
        [allowed addCharactersInString:@"._-"];
        invalidCharacters = allowed.invertedSet;
    });
    if ([identifier rangeOfCharacterFromSet:invalidCharacters].location
        != NSNotFound) return NO;

    // A third-party widget must never receive a fabricated Apple system group.
    return ![identifier hasPrefix:@"com.apple."]
        && ![identifier hasPrefix:@"group.com.apple."]
        && ![identifier hasPrefix:@"systemgroup.com.apple."];
}

static NSURL *IOSSimWidgetGuestAppGroupURL(
    IOSSimWidgetGuestEnvironmentContext *context,
    NSString *identifier,
    BOOL create
) {
    if (!context || !IOSSimWidgetGuestValidGroupIdentifier(identifier)) return nil;
    NSURL *url = [context.appGroupRootURL URLByAppendingPathComponent:identifier
                                                          isDirectory:YES];
    if (!create) return url;

    NSError *directoryError = nil;
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager createDirectoryAtURL:url withIntermediateDirectories:YES
                            attributes:nil error:&directoryError]) {
        NSLog(@"[WidgetGuestEnvironment] Could not create app group %@: %@",
              identifier, directoryError.localizedDescription);
        return nil;
    }
    NSURL *preferences = [[url URLByAppendingPathComponent:@"Library"
                                                isDirectory:YES]
        URLByAppendingPathComponent:@"Preferences" isDirectory:YES];
    if (![manager createDirectoryAtURL:preferences withIntermediateDirectories:YES
                            attributes:nil error:&directoryError]) {
        NSLog(@"[WidgetGuestEnvironment] Could not create preferences for %@: %@",
              identifier, directoryError.localizedDescription);
        return nil;
    }
    return url;
}

static NSUserDefaults *IOSSimWidgetGuestDefaults(NSString *suiteName,
                                                 NSURL *container) {
    NSUserDefaults *allocated = [NSUserDefaults alloc];
    SEL initializer = @selector(_initWithSuiteName:container:);
    if (![allocated respondsToSelector:initializer]) return nil;
    return [allocated _initWithSuiteName:suiteName container:container];
}

static IOSSimWidgetGuestEnvironmentContext *
IOSSimRegisteredWidgetGuestEnvironment(NSString *executablePath) {
    IOSSimInitializeWidgetGuestEnvironmentRegistry();
    os_unfair_lock_lock(&IOSSimWidgetGuestEnvironmentLock);
    IOSSimWidgetGuestEnvironmentContext *context =
        IOSSimWidgetGuestEnvironmentsByExecutablePath[executablePath];
    os_unfair_lock_unlock(&IOSSimWidgetGuestEnvironmentLock);
    return context;
}

static IOSSimWidgetGuestEnvironmentContext *
IOSSimRegisterWidgetGuestEnvironment(
    IOSSimWidgetGuestEnvironmentContext *context,
    NSString **errorMessage
) {
    IOSSimInitializeWidgetGuestEnvironmentRegistry();
    os_unfair_lock_lock(&IOSSimWidgetGuestEnvironmentLock);
    IOSSimWidgetGuestEnvironmentContext *existing =
        IOSSimWidgetGuestEnvironmentsByExecutablePath[context.executablePath];
    if (existing) {
        BOOL identical =
            [existing.extensionIdentifier isEqualToString:context.extensionIdentifier]
            && [existing.moduleRoot isEqualToString:context.moduleRoot]
            && [existing.appRoot isEqualToString:context.appRoot]
            && [existing.dataRoot isEqualToString:context.dataRoot];
        os_unfair_lock_unlock(&IOSSimWidgetGuestEnvironmentLock);
        if (!identical && errorMessage) {
            *errorMessage =
                @"A prepared executable is already registered with different guest metadata.";
        }
        return identical ? existing : nil;
    }

    IOSSimWidgetGuestEnvironmentContext *moduleOwner =
        IOSSimWidgetGuestEnvironmentsByModuleRoot[context.moduleRoot];
    if (moduleOwner && moduleOwner != context) {
        os_unfair_lock_unlock(&IOSSimWidgetGuestEnvironmentLock);
        if (errorMessage) {
            *errorMessage =
                @"A finalized module root is already registered to another guest environment.";
        }
        return nil;
    }

    IOSSimWidgetGuestEnvironmentsByExecutablePath[context.executablePath] = context;
    IOSSimWidgetGuestEnvironmentsByModuleRoot[context.moduleRoot] = context;
    NSMutableArray<IOSSimWidgetGuestEnvironmentContext *> *appContexts =
        IOSSimWidgetGuestEnvironmentsByAppRoot[context.appRoot];
    if (!appContexts) {
        appContexts = [NSMutableArray array];
        IOSSimWidgetGuestEnvironmentsByAppRoot[context.appRoot] = appContexts;
    }
    [appContexts addObject:context];

    // A newly registered extension can turn a source-app image from unique to
    // ambiguous, so every derived image-path decision must be recomputed.
    [IOSSimWidgetGuestEnvironmentsByLoadedImagePath removeAllObjects];
    [IOSSimWidgetGuestAmbiguousLoadedImagePaths removeAllObjects];
    [IOSSimWidgetGuestOutsideLoadedImagePaths removeAllObjects];
    os_unfair_lock_unlock(&IOSSimWidgetGuestEnvironmentLock);
    return context;
}

static void IOSSimInitializeWidgetGuestHookBindings(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        IOSSimWidgetGuestMainBundleSelector = sel_registerName("mainBundle");
        IOSSimWidgetGuestStandardDefaultsSelector =
            sel_registerName("standardUserDefaults");
        IOSSimWidgetGuestSuiteDefaultsSelector =
            sel_registerName("initWithSuiteName:");
        IOSSimWidgetGuestAppGroupSelector =
            sel_registerName("containerURLForSecurityApplicationGroupIdentifier:");

        dlerror();
        void *objcMessageSend = dlsym(RTLD_DEFAULT, "objc_msgSend");
        const char *symbolError = dlerror();
        if (!objcMessageSend || symbolError) {
            IOSSimWidgetGuestHookSetupError = [NSString stringWithFormat:
                @"The Objective-C message dispatcher is unavailable: %s",
                symbolError ?: "symbol missing"];
            return;
        }
        IOSSimWidgetGuestHookBindings[IOSSimWidgetGuestHookBindingCount++] =
            (IOSSimWidgetGuestHookBinding) {
                objcMessageSend, (void *)&IOSSimWidgetGuestObjCMessageSend
            };

        struct {
            const char *name;
            void *replacement;
        } selectorImports[] = {
            { "objc_msgSend$mainBundle",
              (void *)&IOSSimWidgetGuestMainBundleSelectorSend },
            { "objc_msgSend$standardUserDefaults",
              (void *)&IOSSimWidgetGuestStandardDefaultsSelectorSend },
            { "objc_msgSend$initWithSuiteName:",
              (void *)&IOSSimWidgetGuestSuiteDefaultsSelectorSend },
            { "objc_msgSend$containerURLForSecurityApplicationGroupIdentifier:",
              (void *)&IOSSimWidgetGuestAppGroupSelectorSend }
        };
        for (NSUInteger index = 0;
             index < sizeof(selectorImports) / sizeof(selectorImports[0]);
             index++) {
            dlerror();
            void *selectorTarget = dlsym(RTLD_DEFAULT,
                                         selectorImports[index].name);
            if (selectorTarget && dlerror() == NULL) {
                IOSSimWidgetGuestHookBindings[IOSSimWidgetGuestHookBindingCount++] =
                    (IOSSimWidgetGuestHookBinding) {
                        selectorTarget, selectorImports[index].replacement
                    };
            }
        }
    });
}

static void IOSSimInstallWidgetGuestGlobalHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSUInteger index = 0;
             index < IOSSimWidgetGuestHookBindingCount;
             index++) {
            IOSSimWidgetGuestHookBinding binding =
                IOSSimWidgetGuestHookBindings[index];
            litehook_rebind_symbol(
                LITEHOOK_REBIND_GLOBAL,
                binding.replacee,
                binding.replacement,
                &IOSSimWidgetGuestImageFilter
            );
        }
    });
}

static void IOSSimRebindLoadedImagesForWidgetGuestEnvironment(
    IOSSimWidgetGuestEnvironmentContext *context
) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
        const mach_header_u *header =
            (const mach_header_u *)_dyld_get_image_header(imageIndex);
        NSString *path = IOSSimWidgetGuestImagePath(
            (const struct mach_header_64 *)header);
        if (!IOSSimWidgetGuestPathIsInside(path, context.appRoot)) continue;
        for (NSUInteger bindingIndex = 0;
             bindingIndex < IOSSimWidgetGuestHookBindingCount;
             bindingIndex++) {
            IOSSimWidgetGuestHookBinding binding =
                IOSSimWidgetGuestHookBindings[bindingIndex];
            litehook_rebind_symbol(header, binding.replacee,
                                   binding.replacement, NULL);
        }
    }
}

static IOSSimWidgetGuestEnvironmentContext *IOSSimBuildWidgetGuestEnvironment(
    NSString *preparedExecutablePath,
    NSString *expectedExtensionIdentifier,
    NSString **errorMessage
) {
    NSString *executablePath =
        IOSSimWidgetGuestCanonicalPath(preparedExecutablePath);
    NSURL *executableURL = [NSURL fileURLWithPath:executablePath];
    NSURL *moduleURL = executableURL.URLByDeletingLastPathComponent;
    NSString *moduleName = moduleURL.lastPathComponent;
    BOOL generatedModule = [moduleName hasPrefix:IOSSimWidgetModulePrefix]
        && ![moduleName hasPrefix:IOSSimWidgetModuleStagePrefix]
        && ![moduleName hasPrefix:IOSSimWidgetModuleBackupPrefix]
        && [moduleName hasSuffix:@".appex"];
    if (!generatedModule) {
        if (errorMessage) *errorMessage =
            @"The widget environment refused a path outside a finalized module.";
        return nil;
    }

    NSDictionary *moduleInfo = [NSDictionary dictionaryWithContentsOfURL:
        [moduleURL URLByAppendingPathComponent:@"Info.plist"]];
    NSString *declaredExecutable = moduleInfo[@"CFBundleExecutable"];
    NSString *sourceIdentifier = moduleInfo[IOSSimWidgetSourceIdentifierKey];
    NSString *sourceRelativePath = moduleInfo[IOSSimWidgetSourceRelativePathKey];
    if (![declaredExecutable isEqualToString:executableURL.lastPathComponent]
        || ![sourceIdentifier isEqualToString:expectedExtensionIdentifier]
        || !sourceRelativePath.length) {
        if (errorMessage) *errorMessage =
            @"The widget environment metadata does not match the prepared executable.";
        return nil;
    }

    NSString *standardRelativePath = sourceRelativePath.stringByStandardizingPath;
    NSArray<NSString *> *relativeComponents = standardRelativePath.pathComponents;
    if (sourceRelativePath.isAbsolutePath
        || ![standardRelativePath isEqualToString:sourceRelativePath]
        || relativeComponents.count < 2
        || [relativeComponents containsObject:@".."]
        || [relativeComponents containsObject:@"/"]) {
        if (errorMessage) *errorMessage =
            @"The staged widget contains an unsafe source-relative path.";
        return nil;
    }

    NSURL *appURL = moduleURL.URLByDeletingLastPathComponent;
    for (NSUInteger index = 0; index < relativeComponents.count - 1; index++) {
        appURL = appURL.URLByDeletingLastPathComponent;
    }
    NSString *appRoot = IOSSimWidgetGuestCanonicalPath(appURL.path);
    if (![appRoot.pathExtension.lowercaseString isEqualToString:@"app"]
        || !IOSSimWidgetGuestPathIsInside(moduleURL.path, appRoot)) {
        if (errorMessage) *errorMessage =
            @"The staged widget is not nested under its declared source app.";
        return nil;
    }

    NSURL *sourceExtensionURL = [[NSURL fileURLWithPath:appRoot isDirectory:YES]
        URLByAppendingPathComponent:sourceRelativePath isDirectory:YES];
    NSDictionary *sourceInfo = [NSDictionary dictionaryWithContentsOfURL:
        [sourceExtensionURL URLByAppendingPathComponent:@"Info.plist"]];
    if (![sourceInfo[@"CFBundleIdentifier"] isEqualToString:sourceIdentifier]) {
        if (errorMessage) *errorMessage =
            @"The immutable source extension no longer matches the staged widget.";
        return nil;
    }

    NSURL *payloadURL = [NSURL fileURLWithPath:appRoot].URLByDeletingLastPathComponent;
    if (![payloadURL.lastPathComponent isEqualToString:@"Payload"]) {
        if (errorMessage) *errorMessage =
            @"The widget source app is outside a LiveContainer payload.";
        return nil;
    }
    NSURL *dataRootURL = payloadURL.URLByDeletingLastPathComponent;
    NSString *dataRoot = IOSSimWidgetGuestCanonicalPath(dataRootURL.path);
    NSString *documentsRoot = IOSSimWidgetGuestCanonicalPath(
        [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                             inDomains:NSUserDomainMask].firstObject.path);
    if (!IOSSimWidgetGuestPathIsInside(dataRoot, documentsRoot)
        || access(dataRoot.fileSystemRepresentation, R_OK | W_OK) != 0) {
        if (errorMessage) *errorMessage =
            @"The widget's LiveContainer data root is missing or not writable.";
        return nil;
    }

    NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfURL:
        [[NSURL fileURLWithPath:appRoot] URLByAppendingPathComponent:@"Info.plist"]];
    NSDictionary *containerInfo = [NSDictionary dictionaryWithContentsOfURL:
        [dataRootURL URLByAppendingPathComponent:@"LCAppInfo.plist"]];
    NSString *ownerIdentifier = appInfo[@"CFBundleIdentifier"];
    NSString *containerOwner = containerInfo[@"LCOrignalBundleIdentifier"];
    NSString *containerUUID = containerInfo[@"LCDataUUID"];
    if (!ownerIdentifier.length
        || ![containerOwner isEqualToString:ownerIdentifier]
        || ![containerUUID isEqualToString:dataRootURL.lastPathComponent]) {
        if (errorMessage) *errorMessage =
            @"The widget payload does not match its LiveContainer data metadata.";
        return nil;
    }

    NSError *directoryError = nil;
    NSURL *preferencesURL = [[dataRootURL URLByAppendingPathComponent:@"Library"
                                                          isDirectory:YES]
        URLByAppendingPathComponent:@"Preferences" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:preferencesURL
                                 withIntermediateDirectories:YES attributes:nil
                                                      error:&directoryError]) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:
            @"The widget defaults directory could not be prepared: %@",
            directoryError.localizedDescription];
        return nil;
    }

    NSDictionary *guestContainerInfo = [NSDictionary dictionaryWithContentsOfURL:
        [dataRootURL URLByAppendingPathComponent:@"LCContainerInfo.plist"]];
    BOOL isolateAppGroups = [guestContainerInfo[@"isolateAppGroup"] boolValue];
    NSURL *appGroupRootURL = isolateAppGroups
        ? [dataRootURL URLByAppendingPathComponent:@"LCAppGroup" isDirectory:YES]
        : [[[NSURL fileURLWithPath:documentsRoot isDirectory:YES]
            URLByAppendingPathComponent:@"Data" isDirectory:YES]
            URLByAppendingPathComponent:@"AppGroup" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:appGroupRootURL
                                 withIntermediateDirectories:YES attributes:nil
                                                      error:&directoryError]) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:
            @"The widget app-group root could not be prepared: %@",
            directoryError.localizedDescription];
        return nil;
    }

    NSBundle *extensionBundle = [NSBundle bundleWithURL:moduleURL];
    if (!extensionBundle
        || ![extensionBundle.bundleIdentifier isEqualToString:sourceIdentifier]) {
        if (errorMessage) *errorMessage =
            @"Foundation could not create a resource bundle for the staged widget.";
        return nil;
    }
    NSUserDefaults *standardDefaults = IOSSimWidgetGuestDefaults(
        sourceIdentifier, dataRootURL);
    if (!standardDefaults) {
        if (errorMessage) *errorMessage =
            @"Foundation's scoped defaults initializer is unavailable.";
        return nil;
    }

    IOSSimWidgetGuestEnvironmentContext *context =
        [IOSSimWidgetGuestEnvironmentContext new];
    context.executablePath = executablePath;
    context.moduleRoot = IOSSimWidgetGuestCanonicalPath(moduleURL.path);
    context.appRoot = appRoot;
    context.dataRoot = dataRoot;
    context.extensionIdentifier = sourceIdentifier;
    context.extensionBundle = extensionBundle;
    context.standardDefaults = standardDefaults;
    context.dataRootURL = dataRootURL;
    context.appGroupRootURL = appGroupRootURL;
    return context;
}

char *IOSSimPrepareWidgetGuestEnvironment(const char *preparedExecutablePath,
                                          const char *extensionBundleIdentifier) {
#if TARGET_OS_SIMULATOR
    return IOSSimWidgetGuestError(
        @"The scoped widget guest environment currently supports physical iOS only.");
#else
    if (!preparedExecutablePath || !extensionBundleIdentifier) {
        return IOSSimWidgetGuestError(
            @"The widget guest environment path or identifier is missing.");
    }
    NSString *path = [NSString stringWithUTF8String:preparedExecutablePath];
    NSString *identifier = [NSString stringWithUTF8String:extensionBundleIdentifier];
    if (!path.length || !identifier.length) {
        return IOSSimWidgetGuestError(
            @"The widget guest environment metadata is not valid UTF-8.");
    }
    NSString *canonicalPath = IOSSimWidgetGuestCanonicalPath(path);
    @synchronized (IOSSimWidgetGuestPreparationLock()) {
        IOSSimInitializeWidgetGuestHookBindings();
        if (IOSSimWidgetGuestHookSetupError) {
            return IOSSimWidgetGuestError(IOSSimWidgetGuestHookSetupError);
        }

        IOSSimWidgetGuestEnvironmentContext *context =
            IOSSimRegisteredWidgetGuestEnvironment(canonicalPath);
        BOOL newlyRegistered = NO;
        if (context
            && ![context.extensionIdentifier isEqualToString:identifier]) {
            return IOSSimWidgetGuestError([NSString stringWithFormat:
                @"The prepared widget image at %@ is already registered for '%@', not '%@'.",
                canonicalPath, context.extensionIdentifier, identifier]);
        }
        if (!context) {
            NSString *buildError = nil;
            context = IOSSimBuildWidgetGuestEnvironment(
                canonicalPath, identifier, &buildError);
            if (!context) return IOSSimWidgetGuestError(buildError);

            NSString *registrationError = nil;
            context = IOSSimRegisterWidgetGuestEnvironment(
                context, &registrationError);
            if (!context) return IOSSimWidgetGuestError(registrationError);
            newlyRegistered = YES;
        }

        // The global rebind covers images added after registration. A later
        // module has already completed dlopen before it reaches this function,
        // so explicitly scan and bind its currently loaded images as well.
        IOSSimInstallWidgetGuestGlobalHooks();
        IOSSimRebindLoadedImagesForWidgetGuestEnvironment(context);
        if (newlyRegistered) {
            NSLog(@"[WidgetGuestEnvironment] Registered %@ under %@ with data %@.",
                  context.extensionIdentifier, context.moduleRoot, context.dataRoot);
        }
        return NULL;
    }
#endif
}

bool IOSSimWidgetGuestEnvironmentOwnsImage(
    const struct mach_header_64 *imageHeader
) {
#if TARGET_OS_SIMULATOR
    return false;
#else
    NSString *path = IOSSimWidgetGuestImagePath(imageHeader);
    IOSSimWidgetGuestCallerResolution resolution;
    (void)IOSSimWidgetGuestEnvironmentForImagePath(path, &resolution);
    return resolution == IOSSimWidgetGuestCallerResolutionUnique;
#endif
}

static IOSSimWidgetGuestEnvironmentContext *
IOSSimWidgetGuestEnvironmentForExportedAPICaller(const void *callerAddress) {
    IOSSimWidgetGuestCallerResolution resolution;
    IOSSimWidgetGuestEnvironmentContext *context =
        IOSSimWidgetGuestEnvironmentForCaller(callerAddress, &resolution);
    if (context || resolution == IOSSimWidgetGuestCallerResolutionAmbiguous) {
        return context;
    }
    // These two C APIs are also called by the host renderer. Preserve that
    // single-widget convenience only while the registry is unambiguous.
    return resolution == IOSSimWidgetGuestCallerResolutionOutside
        ? IOSSimSoleWidgetGuestEnvironment() : nil;
}

void *IOSSimWidgetGuestExtensionBundle(void) {
    IOSSimWidgetGuestEnvironmentContext *context =
        IOSSimWidgetGuestEnvironmentForExportedAPICaller(
            __builtin_return_address(0));
    return (__bridge void *)context.extensionBundle;
}

char *IOSSimCopyWidgetGuestAppGroupPath(const char *groupIdentifier) {
    if (!groupIdentifier) return NULL;
    NSString *identifier = [NSString stringWithUTF8String:groupIdentifier];
    IOSSimWidgetGuestEnvironmentContext *context =
        IOSSimWidgetGuestEnvironmentForExportedAPICaller(
            __builtin_return_address(0));
    NSURL *url = IOSSimWidgetGuestAppGroupURL(context, identifier, YES);
    return url.path.length ? strdup(url.path.fileSystemRepresentation) : NULL;
}

id IOSSimWidgetGuestMainBundleMessage(id receiver, SEL selector,
                                      const void *callerAddress) {
    if (receiver != NSBundle.class) {
        return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
    }
    IOSSimWidgetGuestCallerResolution resolution;
    IOSSimWidgetGuestEnvironmentContext *context =
        IOSSimWidgetGuestEnvironmentForCaller(callerAddress, &resolution);
    if (context.extensionBundle) return context.extensionBundle;
    if (resolution != IOSSimWidgetGuestCallerResolutionOutside) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

id IOSSimWidgetGuestStandardDefaultsMessage(id receiver, SEL selector,
                                            const void *callerAddress) {
    if (receiver != NSUserDefaults.class) {
        return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
    }
    IOSSimWidgetGuestCallerResolution resolution;
    IOSSimWidgetGuestEnvironmentContext *context =
        IOSSimWidgetGuestEnvironmentForCaller(callerAddress, &resolution);
    if (context.standardDefaults) return context.standardDefaults;
    if (resolution != IOSSimWidgetGuestCallerResolutionOutside) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

id IOSSimWidgetGuestSuiteDefaultsMessage(id receiver, SEL selector,
                                         NSString *suiteName,
                                         const void *callerAddress)
    __attribute__((ns_returns_retained)) {
    if (!IOSSimWidgetGuestObjectIsKindOfClass(receiver, NSUserDefaults.class)) {
        return ((id (*)(id, SEL, id))objc_msgSend)(receiver, selector, suiteName);
    }
    IOSSimWidgetGuestCallerResolution resolution;
    IOSSimWidgetGuestEnvironmentContext *context =
        IOSSimWidgetGuestEnvironmentForCaller(callerAddress, &resolution);
    if (!context) {
        if (resolution != IOSSimWidgetGuestCallerResolutionOutside) return nil;
        return ((id (*)(id, SEL, id))objc_msgSend)(receiver, selector, suiteName);
    }
    if (![suiteName isKindOfClass:NSString.class] || suiteName.length == 0) {
        return ((id (*)(id, SEL, id))objc_msgSend)(receiver, selector, suiteName);
    }

    NSURL *container = context.dataRootURL;
    if ([suiteName hasPrefix:@"group."]
        || [suiteName hasPrefix:@"systemgroup."]) {
        container = IOSSimWidgetGuestAppGroupURL(context, suiteName, YES);
        if (!container) return nil;
    }
    return [receiver _initWithSuiteName:suiteName container:container];
}

id IOSSimWidgetGuestAppGroupMessage(id receiver, SEL selector,
                                    NSString *groupIdentifier,
                                    const void *callerAddress) {
    if (!IOSSimWidgetGuestObjectIsKindOfClass(receiver, NSFileManager.class)) {
        return ((id (*)(id, SEL, id))objc_msgSend)(receiver, selector,
                                                   groupIdentifier);
    }
    IOSSimWidgetGuestCallerResolution resolution;
    IOSSimWidgetGuestEnvironmentContext *context =
        IOSSimWidgetGuestEnvironmentForCaller(callerAddress, &resolution);
    if (!context) {
        if (resolution != IOSSimWidgetGuestCallerResolutionOutside) return nil;
        return ((id (*)(id, SEL, id))objc_msgSend)(receiver, selector,
                                                   groupIdentifier);
    }
    return IOSSimWidgetGuestAppGroupURL(context, groupIdentifier, YES);
}
