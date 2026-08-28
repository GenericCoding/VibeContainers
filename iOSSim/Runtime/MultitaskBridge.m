#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>

static Class IOSSimLoadMultitaskClass(NSString *name) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *framework = [NSBundle.mainBundle.privateFrameworksPath
            stringByAppendingPathComponent:@"LiveContainerSwiftUI.framework/LiveContainerSwiftUI"];
        void *handle = dlopen(framework.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        if (!handle) {
            NSLog(@"[iOSSim] Could not load multitasking framework: %s", dlerror());
        }
    });
    Class runtimeClass = NSClassFromString(name);
    if (runtimeClass) return runtimeClass;

    // Swift classes keep their module in the Objective-C runtime name unless
    // they declare an explicit @objc name. LCUtils is implemented in
    // Objective-C, while MultitaskDockManager is Swift, so looking up only the
    // bare class name made every switcher-card tap report a missing manager.
    return NSClassFromString(
        [@"LiveContainerSwiftUI." stringByAppendingString:name]
    );
}

bool IOSSimMultitaskRuntimeAvailable(void) {
    NSString *extension = [NSBundle.mainBundle.builtInPlugInsPath
        stringByAppendingPathComponent:@"LiveProcess.appex"];
    return [NSFileManager.defaultManager fileExistsAtPath:extension] &&
           IOSSimLoadMultitaskClass(@"LCUtils") != Nil;
}

int32_t IOSSimLaunchMultitaskGuest(const char *displayNameBytes,
                                   const char *relativeBundleNameBytes,
                                   const char *dataUUIDBytes) {
    if (!displayNameBytes || !relativeBundleNameBytes || !dataUUIDBytes) return EINVAL;
    if (![NSThread isMainThread]) return EDEADLK;

    Class utils = IOSSimLoadMultitaskClass(@"LCUtils");
    SEL launch = NSSelectorFromString(@"launchMultitaskGuestApp:completionHandler:");
    if (!utils || ![utils respondsToSelector:launch]) return ENOSYS;

    NSString *displayName = [NSString stringWithUTF8String:displayNameBytes];
    NSString *relativeBundleName = [NSString stringWithUTF8String:relativeBundleNameBytes];
    NSString *dataUUID = [NSString stringWithUTF8String:dataUUIDBytes];
    if (!displayName.length || !relativeBundleName.length || !dataUUID.length) return EINVAL;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:relativeBundleName forKey:@"selected"];
    [defaults setObject:dataUUID forKey:@"selectedContainer"];

    void (^completion)(NSNumber *, NSError *) = ^(NSNumber *pid, NSError *error) {
        if (error) {
            NSLog(@"[iOSSim] Multitask guest %@ failed: %@", displayName, error);
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"IOSSimMultitaskGuestDidFail"
                              object:nil
                            userInfo:@{
                                @"dataUUID": dataUUID,
                                @"message": error.localizedDescription.length
                                    ? error.localizedDescription
                                    : @"The guest process ended before its scene became ready."
                            }];
        } else {
            NSLog(@"[iOSSim] Multitask guest %@ is running as pid %@", displayName, pid);
            NSMutableDictionary *info = [@{@"dataUUID": dataUUID} mutableCopy];
            if (pid) info[@"pid"] = pid;
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"IOSSimMultitaskGuestDidBecomeReady"
                              object:nil
                            userInfo:info];
        }
    };
    ((void (*)(id, SEL, NSString *, id))objc_msgSend)(utils, launch, displayName, completion);
    return 0;
}

static id IOSSimMultitaskManager(void) {
    Class managerClass = IOSSimLoadMultitaskClass(@"MultitaskDockManager");
    SEL sharedSelector = NSSelectorFromString(@"shared");
    if (!managerClass || ![managerClass respondsToSelector:sharedSelector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(managerClass, sharedSelector);
}

int32_t IOSSimFocusMultitaskGuest(const char *dataUUIDBytes) {
    if (!dataUUIDBytes) return EINVAL;
    if (![NSThread isMainThread]) return EDEADLK;

    NSString *dataUUID = [NSString stringWithUTF8String:dataUUIDBytes];
    if (!dataUUID.length) return EINVAL;
    id manager = IOSSimMultitaskManager();
    SEL resultSelector = NSSelectorFromString(@"focusAppResult:");
    if (manager && [manager respondsToSelector:resultSelector]) {
        int32_t result = ((int32_t (*)(id, SEL, NSString *))objc_msgSend)(
            manager,
            resultSelector,
            dataUUID
        );
        NSLog(@"[iOSSim] Focus bridge manager=%@ UUID=%@ result=%d",
              NSStringFromClass([manager class]), dataUUID, result);
        return result;
    }
    SEL selector = NSSelectorFromString(@"focusApp:");
    if (!manager || ![manager respondsToSelector:selector]) {
        NSLog(@"[iOSSim] Focus bridge unavailable manager=%@ resultSelector=%@ legacySelector=%@",
              manager,
              manager && [manager respondsToSelector:resultSelector] ? @"yes" : @"no",
              manager && [manager respondsToSelector:selector] ? @"yes" : @"no");
        return ENOSYS;
    }
    BOOL focused = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(manager, selector, dataUUID);
    int32_t result = focused ? 0 : ENOENT;
    NSLog(@"[iOSSim] Legacy focus bridge UUID=%@ result=%d", dataUUID, result);
    return result;
}

int32_t IOSSimTerminateMultitaskGuest(const char *dataUUIDBytes) {
    if (!dataUUIDBytes) return EINVAL;
    if (![NSThread isMainThread]) return EDEADLK;

    NSString *dataUUID = [NSString stringWithUTF8String:dataUUIDBytes];
    if (!dataUUID.length) return EINVAL;
    id manager = IOSSimMultitaskManager();
    SEL selector = NSSelectorFromString(@"terminateApp:");
    if (!manager || ![manager respondsToSelector:selector]) return ENOSYS;
    BOOL terminated = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(manager, selector, dataUUID);
    return terminated ? 0 : ENOENT;
}

int32_t IOSSimPresentMultitaskSwitcher(void) {
    if (![NSThread isMainThread]) return EDEADLK;

    id manager = IOSSimMultitaskManager();
    SEL selector = NSSelectorFromString(@"presentAppSwitcher");
    if (!manager || ![manager respondsToSelector:selector]) return ENOSYS;
    ((void (*)(id, SEL))objc_msgSend)(manager, selector);
    return 0;
}

int32_t IOSSimTerminateMultitaskGuests(void) {
    if (![NSThread isMainThread]) return EDEADLK;
    SEL terminateSelector = NSSelectorFromString(@"terminateAllApps");
    id manager = IOSSimMultitaskManager();
    if (![manager respondsToSelector:terminateSelector]) return ENOSYS;
    ((void (*)(id, SEL))objc_msgSend)(manager, terminateSelector);
    return 0;
}
