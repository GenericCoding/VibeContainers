#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static char IOSSimTendiesPackageKey;
static char IOSSimTendiesStateControllerKey;

static NSString *IOSSimLockedStateName(CALayer *layer) {
    NSArray *states = nil;
    @try {
        states = [layer valueForKey:@"states"];
    } @catch (__unused NSException *exception) {
        return @"Locked";
    }
    if (![states isKindOfClass:NSArray.class]) return @"Locked";

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id state in states) {
        NSString *name = nil;
        @try {
            name = [state valueForKey:@"name"];
        } @catch (__unused NSException *exception) {
            continue;
        }
        if ([name isKindOfClass:NSString.class]) [names addObject:name];
    }

    // PosterBoard uses both the short state (`Locked`) and contextual state
    // names (`Lock PortraitUp Dark`) depending on the package generation.
    NSArray<NSString *> *preferences = @[
        @"Locked", @"Lock PortraitUp Dark", @"Lock PortraitUp Light", @"Lock"
    ];
    for (NSString *preference in preferences) {
        for (NSString *name in names) {
            if ([name caseInsensitiveCompare:preference] == NSOrderedSame) return name;
        }
    }
    for (NSString *name in names) {
        if ([name rangeOfString:@"lock" options:NSCaseInsensitiveSearch].location == 0) return name;
    }
    return @"Locked";
}

/// Loads Apple's Core Animation package dynamically. Tendies packages contain
/// PosterBoard `.ca` bundles; using the system's CAPackage reader preserves
/// their authored layers, state transitions, and JavaScript-backed animation
/// without linking iOSSim against a private header.
void *IOSSimCreateTendiesLayer(const char *fileSystemPath) {
    if (fileSystemPath == NULL) return NULL;

    Class packageClass = NSClassFromString(@"CAPackage");
    SEL loadSelector = NSSelectorFromString(@"packageWithContentsOfURL:type:options:error:");
    if (packageClass == Nil || ![packageClass respondsToSelector:loadSelector]) return NULL;

    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:fileSystemPath]
                           isDirectory:YES];
    id packageType = @"CAMLBundle";
    void *typeSymbol = dlsym(RTLD_DEFAULT, "kCAPackageTypeCAMLBundle");
    if (typeSymbol != NULL) {
        __unsafe_unretained id *typePointer = (__unsafe_unretained id *)typeSymbol;
        if (*typePointer != nil) packageType = *typePointer;
    }

    NSError *error = nil;
    typedef id (*LoadPackage)(id, SEL, NSURL *, id, NSDictionary *, NSError **);
    id package = ((LoadPackage)objc_msgSend)(packageClass, loadSelector, url, packageType, nil, &error);
    if (package == nil) return NULL;

    SEL rootSelector = NSSelectorFromString(@"rootLayer");
    if (![package respondsToSelector:rootSelector]) return NULL;
    typedef id (*GetObject)(id, SEL);
    id rootObject = ((GetObject)objc_msgSend)(package, rootSelector);
    if (![rootObject isKindOfClass:CALayer.class]) return NULL;
    CALayer *rootLayer = rootObject;

    // CAPackage owns decoded resources that the root layer may still need.
    objc_setAssociatedObject(rootLayer, &IOSSimTendiesPackageKey,
                             package, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    Class controllerClass = NSClassFromString(@"CAStateController");
    SEL initSelector = NSSelectorFromString(@"initWithLayer:");
    if (controllerClass != Nil && [controllerClass instancesRespondToSelector:initSelector]) {
        typedef id (*InitController)(id, SEL, CALayer *);
        id controller = ((InitController)objc_msgSend)([controllerClass alloc], initSelector, rootLayer);
        if (controller != nil) {
            objc_setAssociatedObject(rootLayer, &IOSSimTendiesStateControllerKey,
                                     controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SEL initialSelector = NSSelectorFromString(@"setInitialStatesOfLayer:");
            if ([controller respondsToSelector:initialSelector]) {
                typedef void (*SetInitial)(id, SEL, CALayer *);
                ((SetInitial)objc_msgSend)(controller, initialSelector, rootLayer);
            }

            SEL stateSelector = NSSelectorFromString(@"setState:ofLayer:transitionSpeed:");
            if ([controller respondsToSelector:stateSelector]) {
                typedef void (*SetState)(id, SEL, NSString *, CALayer *, float);
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                ((SetState)objc_msgSend)(controller, stateSelector,
                                         IOSSimLockedStateName(rootLayer), rootLayer, 1.0f);
                [CATransaction commit];
            }
        }
    }

    return (__bridge_retained void *)rootLayer;
}

void IOSSimSetTendiesLayerState(void *layerPointer, const char *stateName, int animated) {
    if (layerPointer == NULL) return;
    CALayer *layer = (__bridge CALayer *)layerPointer;
    id controller = objc_getAssociatedObject(layer, &IOSSimTendiesStateControllerKey);
    SEL stateSelector = NSSelectorFromString(@"setState:ofLayer:transitionSpeed:");
    if (controller == nil || ![controller respondsToSelector:stateSelector]) return;
    if (stateName == NULL) return;

    NSString *state = [NSString stringWithUTF8String:stateName];
    if ([state caseInsensitiveCompare:@"Locked"] == NSOrderedSame) {
        state = IOSSimLockedStateName(layer);
    }

    typedef void (*SetState)(id, SEL, NSString *, CALayer *, float);
    [CATransaction begin];
    [CATransaction setDisableActions:!animated];
    [CATransaction setAnimationDuration:animated ? 1.25 : 0];
    [CATransaction setAnimationTimingFunction:
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    ((SetState)objc_msgSend)(controller, stateSelector, state, layer, 1.0f);
    [CATransaction commit];
}
