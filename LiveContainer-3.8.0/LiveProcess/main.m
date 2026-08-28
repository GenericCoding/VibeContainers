//
//  main.m
//  LiveProcess
//
//  Created by Duy Tran on 3/5/25.
//

#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import "../LiveContainer/utils.h"
#import "../LiveContainer/Tweaks/Tweaks.h"
#import "../SideStore/XPCServer.h"

@interface LiveProcessHandler : NSObject<NSExtensionRequestHandling>
@end
@implementation LiveProcessHandler
static NSExtensionContext *extensionContext;
static NSDictionary *retrievedAppInfo;
static NSMutableArray<NSURL *> *activeResourceURLs;
+ (NSExtensionContext *)extensionContext {
    return extensionContext;
}

+ (NSDictionary *)retrievedAppInfo {
    return retrievedAppInfo;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    extensionContext = context;
    retrievedAppInfo = [context.inputItems.firstObject userInfo];
    // Return control to LiveContainerMain
    CFRunLoopStop(CFRunLoopGetMain());
}
@end

extern int LiveContainerMain(int argc, char *argv[]);
static char **_envp, **_apple = NULL;

static NSError *LiveProcessLaunchError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"LiveProcess"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey:
        description.length ? description : @"LiveProcess could not access the guest files."}];
}

static BOOL ConfigureGuestResources(NSDictionary *appInfo, NSError **outError) {
    NSArray *resources = appInfo[@"resources"];
    if (![resources isKindOfClass:NSArray.class] || resources.count == 0) {
        return NO;
    }

    activeResourceURLs = [NSMutableArray arrayWithCapacity:resources.count];
    NSMutableSet<NSString *> *configuredRoles = [NSMutableSet set];
    NSDictionary<NSString *, NSString *> *environmentKeys = @{
        @"bundle": @"LC_LIVEPROCESS_BUNDLE_PATH",
        @"container": @"LC_LIVEPROCESS_DATA_PATH",
        @"tweaks": @"LC_LIVEPROCESS_TWEAKS_PATH",
        @"appGroups": @"LC_LIVEPROCESS_APP_GROUPS_PATH",
        @"containerLocks": @"LC_LIVEPROCESS_LOCKS_PATH",
        @"sideStoreContainer": @"LC_LIVEPROCESS_SIDESTORE_PATH",
    };

    for (id candidate in resources) {
        if (![candidate isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *resource = candidate;
        NSString *role = resource[@"role"];
        NSData *bookmark = resource[@"bookmark"];
        if (![role isKindOfClass:NSString.class] ||
            ![bookmark isKindOfClass:NSData.class] || !bookmark.length) {
            if (outError) {
                *outError = LiveProcessLaunchError(EINVAL,
                    @"The host supplied an invalid guest resource bookmark.");
            }
            return NO;
        }

        BOOL isStale = NO;
        NSError *resolutionError = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                               options:0
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&isStale
                                                 error:&resolutionError];
        if (!url.isFileURL || !url.path.length) {
            if (outError) {
                NSString *detail = resolutionError.localizedDescription ?: @"the bookmark did not resolve";
                *outError = LiveProcessLaunchError(resolutionError.code ?: EACCES,
                    [NSString stringWithFormat:@"The %@ resource is unavailable: %@", role, detail]);
            }
            return NO;
        }

        // Resolution installs an ephemeral extension on iOS. Explicitly hold
        // its security scope too, and retain every URL for the full guest
        // lifetime so Foundation cannot release the access grant early.
        BOOL scoped = [url startAccessingSecurityScopedResource];
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:url.path];
        BOOL readOnly = [resource[@"readOnly"] boolValue];
        BOOL accessible = exists && access(url.fileSystemRepresentation, R_OK) == 0;
        if (!readOnly) accessible = accessible && access(url.fileSystemRepresentation, W_OK) == 0;
        if (!accessible) {
            if (scoped) [url stopAccessingSecurityScopedResource];
            if (outError) {
                *outError = LiveProcessLaunchError(EACCES,
                    [NSString stringWithFormat:@"LiveProcess cannot %@ the %@ resource at %@.",
                     readOnly ? @"read" : @"read or write", role, url.path]);
            }
            return NO;
        }
        if (isStale) {
            NSLog(@"LiveProcess: %@ resource bookmark is stale but remains accessible", role);
        }
        [activeResourceURLs addObject:url];
        [configuredRoles addObject:role];

        NSString *environmentKey = environmentKeys[role];
        if (environmentKey.length) {
            setenv(environmentKey.UTF8String, url.fileSystemRepresentation, 1);
        }
    }

    BOOL isSideStore = [appInfo[@"selected"] isEqualToString:@"builtinSideStore"];
    BOOL missingRequiredRole = isSideStore
        ? ![configuredRoles containsObject:@"sideStoreContainer"]
        : (![configuredRoles containsObject:@"bundle"] ||
           ![configuredRoles containsObject:@"container"] ||
           ![configuredRoles containsObject:@"tweaks"] ||
           ![configuredRoles containsObject:@"appGroups"]);
    if (missingRequiredRole) {
        if (outError) {
            *outError = LiveProcessLaunchError(EINVAL,
                @"The host did not provide all required guest resources.");
        }
        return NO;
    }
    return YES;
}

int LiveProcessMain(int argc, char *argv[]) {
    // Let NSExtensionContext initialize, once it's done it will call CFRunLoopStop
    CFRunLoopRun();
    // Ensure app info is delivered
    NSDictionary *appInfo = LiveProcessHandler.retrievedAppInfo;
    NSCAssert(appInfo, @"Failed to retrieve app info");
    
    // Check if we received a request to execute a custom payload
    NSString *customPayloadDylib = appInfo[@"customPayloadDylib"];
    if(customPayloadDylib) {
        void *handle = dlopen(customPayloadDylib.fileSystemRepresentation, RTLD_LAZY);
        NSCAssert(appInfo, @"Failed to load custom payload dylib at path: %@", customPayloadDylib);
        
        NSString *customPayloadEntry = appInfo[@"customPayloadEntry"];
        NSCAssert(customPayloadEntry, @"Missing customPayloadEntry");
        int (*payloadEntry)(int, char **, char **, char **) = dlsym(handle, customPayloadEntry.UTF8String);
        return payloadEntry(argc, argv, _envp, _apple);
    }
    
    NSLog(@"LiveProcess: received launch for %@ (%@)",
          appInfo[@"selected"], appInfo[@"selectedContainer"]);
    // Set LiveContainer's home path
    setenv("LP_HOME_PATH", getenv("HOME"), 1);
    const char *overrideHomePath = [appInfo[@"lcHomePath"] fileSystemRepresentation];
    if(overrideHomePath) setenv("LC_HOME_PATH", overrideHomePath, 1);
    // Pass selected app info to user defaults
    NSUserDefaults *lcUserDefaults = NSUserDefaults.standardUserDefaults;
    NSDictionary<NSString *, NSString *> *launchValues = @{
        @"hostUrlScheme": appInfo[@"hostUrlScheme"] ?: @"iossim",
        @"selected": appInfo[@"selected"] ?: @"",
        @"selectedContainer": appInfo[@"selectedContainer"] ?: @""
    };
    [launchValues enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        if (value.length) [lcUserDefaults setObject:value forKey:key];
        else [lcUserDefaults removeObjectForKey:key];
    }];
    NSString *launchURLScheme = appInfo[@"launchAppUrlScheme"];
    if (launchURLScheme.length) [lcUserDefaults setObject:launchURLScheme forKey:@"launchAppUrlScheme"];
    else [lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
    if(appInfo[@"certificatePassword"]) {
        [lcUserDefaults setObject:appInfo[@"certificatePassword"] forKey:@"LCCertificatePassword"];
    } else {
        [lcUserDefaults removeObjectForKey:@"LCCertificatePassword"];
    }
    
    NSError *resourceError = nil;
    BOOL hasStructuredResources = ConfigureGuestResources(appInfo, &resourceError);
    if (resourceError) {
        [LiveProcessHandler.extensionContext cancelRequestWithError:resourceError];
        return EACCES;
    }

    // Compatibility for SideStore/older hosts which still send an unlabelled
    // bookmark array. New VibeContainers launches always use role-labelled
    // resources so bootstrap receives the bookmark-resolved canonical paths.
    BOOL legacyAccess = NO;
    NSMutableArray<NSURL *> *legacyURLs = [NSMutableArray array];
    if (!hasStructuredResources) {
        NSArray *bookmarks = appInfo[@"bookmarks"];
        for (NSData *bookmark in bookmarks) {
            if (![bookmark isKindOfClass:NSData.class]) continue;
            BOOL isStale = NO;
            NSError *error = nil;
            NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:0
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&isStale error:&error];
            if (!url) {
                NSLog(@"LiveProcess: failed to resolve legacy bookmark: %@", error.localizedDescription);
                continue;
            }
            [legacyURLs addObject:url];
            legacyAccess |= [url startAccessingSecurityScopedResource];
        }
        activeResourceURLs = legacyURLs;
    }
    
    if ([appInfo[@"selected"] isEqualToString:@"builtinSideStore"]) {
        const char *resolvedSideStorePath = getenv("LC_LIVEPROCESS_SIDESTORE_PATH");
        if (resolvedSideStorePath && resolvedSideStorePath[0]) {
            [lcUserDefaults setObject:[NSString stringWithUTF8String:resolvedSideStorePath]
                               forKey:@"specifiedSideStoreContainerPath"];
        } else if(legacyAccess && legacyURLs.count > 0) {
            [lcUserDefaults setObject:legacyURLs.firstObject.path forKey:@"specifiedSideStoreContainerPath"];
        }
        NSXPCListenerEndpoint* endpoint = appInfo[@"endpoint"];
        if (endpoint) {
            NSXPCConnection* connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
            connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RefreshServer)];
            connection.interruptionHandler = ^{
                NSLog(@"LiveProcess: SideStore refresh connection interrupted");
            };

            [connection activate];

            NSObject<RefreshServer>* proxy = [connection remoteObjectProxy];
            LiveProcessSideStoreHandler.shared.server = proxy;
            LiveProcessSideStoreHandler.shared.connection = connection;
        }
        
    }

    
    return LiveContainerMain(argc, argv);
}

// this is our fake UIApplicationMain called from _xpc_objc_uimain (xpc_main)
__attribute__((visibility("default")))
int UIApplicationMain(int argc, char * argv[], NSString * principalClassName, NSString * delegateClassName) {
    return LiveProcessMain(argc, argv);
}

// NSExtensionMain will load UIKit and call UIApplicationMain, so we need to redirect it to our fake one
static void* (*orig_dlopen)(void* dyldApiInstancePtr, const char* path, int mode);
static void* hook_dlopen(void* dyldApiInstancePtr, const char* path, int mode) {
    const char *UIKitFrameworkPath = "/System/Library/Frameworks/UIKit.framework/UIKit";
    if(path && !strncmp(path, UIKitFrameworkPath, strlen(UIKitFrameworkPath))) {
        // switch back to original dlopen
        performHookDyldApi("dlopen", 2, (void**)&orig_dlopen, orig_dlopen);
        // FIXME: may be incompatible with jailbreak tweaks?
        return RTLD_MAIN_ONLY;
    } else {
        __attribute__((musttail)) return orig_dlopen(dyldApiInstancePtr, path, mode);
    }
}

// Extension entry point
int NSExtensionMain(int argc, char *argv[], char *envp[], char *apple[]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    method_setImplementation(class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"), @selector(_validateAllowedClass:forKey:allowingInvocations:)), (IMP)hook_do_nothing);
#pragma clang diagnostic pop
    // hook dlopen UIKit
    performHookDyldApi("dlopen", 2, (void**)&orig_dlopen, hook_dlopen);
    // call the real one
    _envp = envp;
    _apple = apple;
    int (*orig_NSExtensionMain)(int argc, char * argv[]) = dlsym(RTLD_NEXT, "NSExtensionMain");
    return orig_NSExtensionMain(argc, argv);
}
