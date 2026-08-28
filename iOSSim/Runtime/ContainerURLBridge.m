#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>

extern int32_t IOSSimRouteContainerURL(const char *urlBytes);

static BOOL IOSSimIsContainerURL(NSURL *url) {
    if (!url) return NO;
    NSString *scheme = url.scheme;
    NSString *host = url.host;
    if (!scheme || !host) return NO;
    return [scheme caseInsensitiveCompare:@"iossim"] == NSOrderedSame &&
           [host caseInsensitiveCompare:@"guest"] == NSOrderedSame;
}

static NSURL *IOSSimURLFromValue(id value) {
    if ([value isKindOfClass:NSURL.class]) return value;
    if ([value isKindOfClass:NSString.class]) {
        return [NSURL URLWithString:value];
    }
    return nil;
}

static NSURL *IOSSimURLFromAction(id action) {
    Class actionClass = NSClassFromString(@"UIOpenURLAction");
    SEL urlSelector = NSSelectorFromString(@"url");
    if (!actionClass || ![action isKindOfClass:actionClass] ||
        ![action respondsToSelector:urlSelector]) {
        return nil;
    }
    return ((NSURL *(*)(id, SEL))objc_msgSend)(action, urlSelector);
}

/// Returns YES only when the URL belongs to VibeContainers and has been
/// claimed. UIKit normally invokes these hooks on its main thread; retain a
/// defensive hop for any future delivery path that does not.
static BOOL IOSSimRouteURL(NSURL *url, NSString *source) {
    if (!IOSSimIsContainerURL(url)) return NO;

    NSString *urlString = url.absoluteString;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            int32_t routeResult = IOSSimRouteContainerURL(urlString.UTF8String);
            NSLog(@"[iOSSim] URL bridge %@ deferred route result=%d (%@)",
                  source, routeResult, urlString);
        });
        return YES;
    }

    int32_t routeResult = IOSSimRouteContainerURL(urlString.UTF8String);
    NSLog(@"[iOSSim] URL bridge %@ route result=%d (%@)",
          source, routeResult, urlString);
    return routeResult != 0;
}

static NSSet *IOSSimRemovingRoutedActions(NSSet *actions,
                                          NSString *source,
                                          BOOL *didRoute) {
    if (![actions isKindOfClass:NSSet.class] || actions.count == 0) {
        return actions;
    }

    NSMutableSet *forwarded = [actions mutableCopy];
    for (id action in actions) {
        NSURL *url = IOSSimURLFromAction(action);
        if (url && IOSSimRouteURL(url, source)) {
            [forwarded removeObject:action];
            if (didRoute) *didRoute = YES;
        }
    }
    return forwarded;
}

#pragma mark - Concrete scene delegates

static char IOSSimSceneDelegateHookMarker;

static SEL IOSSimOriginalOpenURLContextsSelector(void) {
    return NSSelectorFromString(@"iossim_original_scene:openURLContexts:");
}

static void IOSSimSceneDelegateOpenURLContexts(id delegate,
                                               SEL selector,
                                               UIScene *scene,
                                               NSSet<UIOpenURLContext *> *contexts) {
    NSMutableSet *forwarded = [contexts mutableCopy];
    BOOL didRoute = NO;
    for (id context in contexts) {
        if (![context isKindOfClass:UIOpenURLContext.class]) continue;
        if (IOSSimRouteURL(((UIOpenURLContext *)context).URL,
                          @"scene-delegate")) {
            [forwarded removeObject:context];
            didRoute = YES;
        }
    }

    if (didRoute && forwarded.count == 0) return;
    SEL originalSelector = IOSSimOriginalOpenURLContextsSelector();
    if ([delegate respondsToSelector:originalSelector]) {
        ((void (*)(id, SEL, UIScene *, NSSet *))objc_msgSend)(
            delegate,
            originalSelector,
            scene,
            forwarded
        );
    }
}

static void IOSSimInstallSceneDelegateHook(UIScene *scene) {
    id delegate = scene.delegate;
    if (!delegate) return;
    Class delegateClass = object_getClass(delegate);
    if (objc_getAssociatedObject(delegateClass, &IOSSimSceneDelegateHookMarker)) {
        return;
    }

    SEL selector = @selector(scene:openURLContexts:);
    Method original = class_getInstanceMethod(delegateClass, selector);
    const char *types = original ? method_getTypeEncoding(original) : "v@:@@";
    if (original) {
        class_addMethod(
            delegateClass,
            IOSSimOriginalOpenURLContextsSelector(),
            method_getImplementation(original),
            types
        );
    }

    if (!class_addMethod(delegateClass,
                         selector,
                         (IMP)IOSSimSceneDelegateOpenURLContexts,
                         types)) {
        class_replaceMethod(delegateClass,
                            selector,
                            (IMP)IOSSimSceneDelegateOpenURLContexts,
                            types);
    }
    objc_setAssociatedObject(delegateClass,
                             &IOSSimSceneDelegateHookMarker,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[iOSSim] URL bridge hooked scene delegate %@ original=%@",
          NSStringFromClass(delegateClass), original ? @"yes" : @"no");
}

static void IOSSimInstallConnectedSceneDelegateHooks(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        IOSSimInstallSceneDelegateHook(scene);
    }
}

@interface UIScene (IOSSimContainerURLBridge)
- (void)iossim_scene:(id)scene
    didReceiveActions:(NSSet *)actions
 fromTransitionContext:(id)context;
@end

@implementation UIScene (IOSSimContainerURLBridge)

- (void)iossim_scene:(id)scene
    didReceiveActions:(NSSet *)actions
 fromTransitionContext:(id)context {
    if ([scene isKindOfClass:UIScene.class]) {
        IOSSimInstallSceneDelegateHook(scene);
    } else {
        IOSSimInstallSceneDelegateHook(self);
    }
    BOOL didRoute = NO;
    NSSet *forwarded = IOSSimRemovingRoutedActions(
        actions, @"scene-action", &didRoute);
    if (didRoute && forwarded.count == 0) return;
    [self iossim_scene:scene
        didReceiveActions:forwarded
     fromTransitionContext:context];
}

@end

@interface UIApplication (IOSSimContainerURLBridge)
- (void)iossim_connectUISceneFromFBSScene:(id)scene transitionContext:(id)context;
- (void)iossim_applicationOpenURLAction:(id)action
                                payload:(NSDictionary *)payload
                                 origin:(id)origin;
@end

@implementation UIApplication (IOSSimContainerURLBridge)

/// Cold URL launches arrive in the scene connection context rather than an
/// already-connected UIScene. Consume the iOSSim action before SwiftUI chooses
/// a WindowGroup, while preserving every unrelated lifecycle action.
- (void)iossim_connectUISceneFromFBSScene:(id)scene transitionContext:(id)context {
    @try {
        NSSet *actions = [context valueForKey:@"actions"];
        BOOL didRoute = NO;
        NSSet *forwarded = IOSSimRemovingRoutedActions(
            actions, @"scene-connect", &didRoute);
        if (didRoute) {
            [context setValue:forwarded forKey:@"actions"];
        }

        NSDictionary *payload = [context valueForKey:@"payload"];
        NSURL *payloadURL = IOSSimURLFromValue(payload[UIApplicationLaunchOptionsURLKey]);
        if (IOSSimIsContainerURL(payloadURL)) {
            if (!didRoute) {
                didRoute = IOSSimRouteURL(payloadURL, @"scene-connect-payload");
            }
            if (didRoute) {
                NSMutableDictionary *forwardedPayload = [payload mutableCopy];
                [forwardedPayload removeObjectForKey:UIApplicationLaunchOptionsURLKey];
                [context setValue:forwardedPayload forKey:@"payload"];
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[iOSSim] URL bridge could not inspect scene connection: %@",
              exception.reason);
    }

    [self iossim_connectUISceneFromFBSScene:scene transitionContext:context];
    IOSSimInstallConnectedSceneDelegateHooks();
}

/// Fallback for non-scene delivery and older UIKit routing. A claimed
/// container URL must not continue into a guest or a second SwiftUI handler.
- (void)iossim_applicationOpenURLAction:(id)action
                                payload:(NSDictionary *)payload
                                 origin:(id)origin {
    NSURL *url = IOSSimURLFromAction(action)
        ?: IOSSimURLFromValue(payload[UIApplicationLaunchOptionsURLKey]);
    if (IOSSimRouteURL(url, @"application-action")) return;
    [self iossim_applicationOpenURLAction:action payload:payload origin:origin];
}

@end

static BOOL IOSSimExchangeInstanceMethod(Class cls,
                                         SEL originalSelector,
                                         SEL replacementSelector) {
    Method original = class_getInstanceMethod(cls, originalSelector);
    Method replacement = class_getInstanceMethod(cls, replacementSelector);
    if (!original || !replacement) return NO;
    method_exchangeImplementations(original, replacement);
    return YES;
}

void IOSSimInstallContainerURLBridge(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BOOL sceneAction = IOSSimExchangeInstanceMethod(
            UIScene.class,
            NSSelectorFromString(@"scene:didReceiveActions:fromTransitionContext:"),
            @selector(iossim_scene:didReceiveActions:fromTransitionContext:));
        BOOL sceneConnect = IOSSimExchangeInstanceMethod(
            UIApplication.class,
            NSSelectorFromString(@"_connectUISceneFromFBSScene:transitionContext:"),
            @selector(iossim_connectUISceneFromFBSScene:transitionContext:));
        BOOL applicationAction = IOSSimExchangeInstanceMethod(
            UIApplication.class,
            NSSelectorFromString(@"_applicationOpenURLAction:payload:origin:"),
            @selector(iossim_applicationOpenURLAction:payload:origin:));
        NSLog(@"[iOSSim] URL bridge installed scene-action=%@ scene-connect=%@ application-action=%@",
              sceneAction ? @"yes" : @"no",
              sceneConnect ? @"yes" : @"no",
              applicationAction ? @"yes" : @"no");

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[
            UISceneWillConnectNotification,
            UISceneDidActivateNotification,
            UIApplicationDidBecomeActiveNotification
        ]) {
            [center addObserverForName:name
                                object:nil
                                 queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *notification) {
                if ([notification.object isKindOfClass:UIScene.class]) {
                    IOSSimInstallSceneDelegateHook(notification.object);
                } else {
                    IOSSimInstallConnectedSceneDelegateHooks();
                }
            }];
        }
        IOSSimInstallConnectedSceneDelegateHooks();
    });
}
