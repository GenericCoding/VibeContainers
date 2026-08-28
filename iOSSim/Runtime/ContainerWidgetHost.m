#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <sys/stat.h>

static NSString *const IOSSimWidgetStatusNotification = @"IOSSimContainerWidgetHostStatus";
static NSString *const IOSSimWidgetLaunchNotification = @"IOSSimContainerWidgetRequestedLaunch";
static NSString *const IOSSimWidgetRunnerBundleIdentifier = @"com.genericcoding.vibecontainers.WidgetRunner";
static NSString *const IOSSimWidgetRunnerBundleName = @"IOSSimWidgetRunner.appex";
static NSString *const IOSSimWidgetSourceIdentifierKey = @"IOSSimSourceWidgetBundleIdentifier";
static NSString *const IOSSimWidgetSourceRelativePathKey = @"IOSSimSourceWidgetRelativePath";
static NSString *IOSSimWidgetLastError;

static id SendId0(id receiver, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static id SendId1(id receiver, SEL selector, id value) {
    return ((id (*)(id, SEL, id))objc_msgSend)(receiver, selector, value);
}

static id SendId2(id receiver, SEL selector, id first, id second) {
    return ((id (*)(id, SEL, id, id))objc_msgSend)(receiver, selector, first, second);
}

static void SendVoid0(id receiver, SEL selector) {
    ((void (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static void SendVoid1(id receiver, SEL selector, id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(receiver, selector, value);
}

static void SendBool(id receiver, SEL selector, BOOL value) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(receiver, selector, value);
}

static BOOL SendGetBool(id receiver, SEL selector) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static BOOL IOSSimWidgetBinaryIsMachO(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *header = [handle readDataOfLength:sizeof(uint32_t)];
    [handle closeFile];
    if (header.length != sizeof(uint32_t)) return NO;
    uint32_t magic = 0;
    [header getBytes:&magic length:sizeof(magic)];
    return magic == MH_MAGIC_64 || magic == MH_CIGAM_64
        || magic == FAT_MAGIC || magic == FAT_CIGAM
        || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64;
}

static void SetLastError(NSString *error) {
    @synchronized ([UIApplication class]) {
        IOSSimWidgetLastError = [error copy];
    }
}

static BOOL LoadWidgetFrameworks(void) {
    static dispatch_once_t onceToken;
    static BOOL loaded;
    dispatch_once(&onceToken, ^{
        void *chronoServices = dlopen(
            "/System/Library/PrivateFrameworks/ChronoServices.framework/ChronoServices",
            RTLD_NOW | RTLD_LOCAL
        );
        void *chronoUI = dlopen(
            "/System/Library/PrivateFrameworks/ChronoUIServices.framework/ChronoUIServices",
            RTLD_NOW | RTLD_LOCAL
        );
        loaded = chronoServices != NULL && chronoUI != NULL;
        if (!loaded) {
            const char *reason = dlerror();
            SetLastError([NSString stringWithFormat:@"Chrono frameworks unavailable: %s",
                                                     reason ?: "unknown error"]);
        }
    });
    return loaded;
}

@class IOSSimContainerWidgetBridgeController;

static NSHashTable<IOSSimContainerWidgetBridgeController *> *IOSSimLiveWidgetHosts(void) {
    static NSHashTable<IOSSimContainerWidgetBridgeController *> *hosts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hosts = [NSHashTable weakObjectsHashTable];
    });
    return hosts;
}

static void IOSSimRegisterWidgetHost(IOSSimContainerWidgetBridgeController *controller) {
    NSHashTable<IOSSimContainerWidgetBridgeController *> *hosts = IOSSimLiveWidgetHosts();
    @synchronized (hosts) {
        [hosts addObject:controller];
    }
}

@interface IOSSimContainerWidgetLaunchDelegate : NSObject
@property(nonatomic, weak) IOSSimContainerWidgetBridgeController *owner;
@end

@interface IOSSimContainerWidgetBridgeController : UIViewController
@property(nonatomic, copy) NSString *extensionBundleIdentifier;
@property(nonatomic, copy) NSString *containerBundleIdentifier;
@property(nonatomic, copy) NSString *widgetKind;
@property(nonatomic, copy) NSURL *extensionURL;
@property(nonatomic) NSInteger family;
@property(nonatomic) CGSize widgetSize;
@property(nonatomic, strong) UIViewController *widgetHost;
@property(nonatomic, strong) id privateExtensionProvider;
@property(nonatomic, strong) IOSSimContainerWidgetLaunchDelegate *launchDelegate;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL invalidated;
@property(nonatomic) BOOL hostCreated;
- (void)invalidateHost;
- (void)forwardLaunchRequest:(id)request;
@end

@implementation IOSSimContainerWidgetLaunchDelegate

- (void)widgetHostViewController:(id)controller requestsLaunch:(id)request {
    [self.owner forwardLaunchRequest:request];
}

- (void)widgetHostViewController:(id)controller requestsLaunchWithAction:(id)action {
    id request = nil;
    SEL requestSelector = NSSelectorFromString(@"launchRequest");
    if ([action respondsToSelector:requestSelector]) {
        request = SendId0(action, requestSelector);
    }
    [self.owner forwardLaunchRequest:request ?: action];
}

@end


@implementation IOSSimContainerWidgetBridgeController

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.clipsToBounds = YES;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.started) {
        self.started = YES;
        NSString *validationError = [self resolveProvisionedRunner];
        if (!validationError) validationError = [self validateExtensionBundle];
        validationError ? [self fail:validationError] : [self createPrivateHost];
    }
}

- (NSString *)resolveProvisionedRunner {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    NSURL *sourceURL = self.extensionURL.URLByStandardizingPath;
    NSURL *appURL = sourceURL;
    while (appURL.path.length > 1
           && ![appURL.pathExtension.lowercaseString isEqualToString:@"app"]) {
        appURL = [appURL URLByDeletingLastPathComponent];
    }
    if (![appURL.pathExtension.lowercaseString isEqualToString:@"app"]) {
        return @"The source widget is not contained in an app bundle, so its provisioned runner cannot be resolved.";
    }
    NSString *prefix = [appURL.path.stringByStandardizingPath stringByAppendingString:@"/"];
    NSString *sourcePath = sourceURL.path.stringByStandardizingPath;
    if (![sourcePath hasPrefix:prefix]) {
        return @"The source widget path is outside its app bundle.";
    }
    NSString *relativeSourcePath = [sourcePath substringFromIndex:prefix.length];
    NSURL *runnerURL = [[appURL URLByAppendingPathComponent:@"PlugIns" isDirectory:YES]
        URLByAppendingPathComponent:IOSSimWidgetRunnerBundleName isDirectory:YES];
    BOOL directory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:runnerURL.path
                                             isDirectory:&directory] || !directory) {
        return @"The provisioned widget runner is missing. Use Sign & Retry to stage and register this widget.";
    }
    NSDictionary *runnerInfo = [NSDictionary dictionaryWithContentsOfURL:
        [runnerURL URLByAppendingPathComponent:@"Info.plist"]];
    if (![runnerInfo[@"CFBundleIdentifier"] isEqualToString:
            IOSSimWidgetRunnerBundleIdentifier]) {
        return @"The widget runner exists, but its provisioned bundle identifier is invalid.";
    }
    if (![runnerInfo[IOSSimWidgetSourceIdentifierKey]
            isEqualToString:self.extensionBundleIdentifier]
        || ![runnerInfo[IOSSimWidgetSourceRelativePathKey]
            isEqualToString:relativeSourcePath]) {
        return @"The active widget runner was prepared for a different source extension. Use Sign & Retry to switch it atomically.";
    }
    self.extensionBundleIdentifier = IOSSimWidgetRunnerBundleIdentifier;
    self.extensionURL = runnerURL;
    return nil;
#endif
}

- (NSString *)validateExtensionBundle {
    if (!self.extensionURL.isFileURL) return @"The widget extension path is not a file URL.";

    BOOL directory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.extensionURL.path
                                             isDirectory:&directory] || !directory) {
        return @"The widget extension bundle is missing from this container.";
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:
        [self.extensionURL URLByAppendingPathComponent:@"Info.plist"]];
    if (!info) return @"The widget extension has no readable Info.plist.";
    NSString *bundleIdentifier = info[@"CFBundleIdentifier"];
    NSString *extensionPoint = info[@"NSExtension"][@"NSExtensionPointIdentifier"];
    if (![bundleIdentifier isEqualToString:self.extensionBundleIdentifier]) {
        return @"The widget extension identifier no longer matches its installed bundle.";
    }
    if (![extensionPoint isEqualToString:@"com.apple.widgetkit-extension"]) {
        return @"This extension is not a WidgetKit extension.";
    }

    NSString *executable = info[@"CFBundleExecutable"];
    if (!executable.length) return @"The widget Info.plist is missing CFBundleExecutable.";
    NSString *executablePath = [self.extensionURL URLByAppendingPathComponent:executable].path;
    BOOL executableDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:executablePath
                                             isDirectory:&executableDirectory]
        || executableDirectory) {
        return [NSString stringWithFormat:
            @"The widget Info.plist names '%@', but that binary is missing from the .appex.",
            executable];
    }
    struct stat executableStatus = {0};
    if (stat(executablePath.fileSystemRepresentation, &executableStatus) != 0
        || !S_ISREG(executableStatus.st_mode)
        || (executableStatus.st_mode & 0111) == 0) {
        return [NSString stringWithFormat:
            @"The widget binary '%@' has invalid POSIX mode %04o in the provisioned runner.",
            executable, executableStatus.st_mode & 07777];
    }
    if (!IOSSimWidgetBinaryIsMachO(executablePath)) {
        return [NSString stringWithFormat:
            @"The widget binary '%@' is not a supported Mach-O executable.", executable];
    }
    return nil;
}

- (id)makeLocalExtensionProviderWithDescriptor:(id)descriptor identity:(id)identity {
    Class providerClass = NSClassFromString(@"CHSWidgetExtensionProvider");
    Class mutableExtensionClass = NSClassFromString(@"CHSMutableWidgetExtension");
    if (!providerClass || !mutableExtensionClass || !descriptor || !identity) return nil;

    id provider = SendId0([providerClass alloc], @selector(init));
    id widgetExtension = SendId0([mutableExtensionClass alloc], @selector(init));
    if (!provider || !widgetExtension) return nil;

    SendVoid1(widgetExtension, NSSelectorFromString(@"setIdentity:"), identity);
    SendVoid1(widgetExtension, NSSelectorFromString(@"setLocalizedDisplayName:"),
              self.widgetKind);
    SendVoid1(widgetExtension,
              NSSelectorFromString(@"setContainerBundleLocalizedDisplayName:"),
              self.containerBundleIdentifier);
    SendVoid1(widgetExtension, NSSelectorFromString(@"setOrderedWidgetDescriptors:"),
              @[descriptor]);
    SendVoid1(widgetExtension, NSSelectorFromString(@"setOrderedControlDescriptors:"), @[]);
    SendVoid1(widgetExtension, NSSelectorFromString(@"setLiveActivityDescriptors:"), [NSSet set]);

    NSMutableArray *extensions = [NSMutableArray array];
    SEL extensionsSelector = NSSelectorFromString(@"extensions");
    if ([provider respondsToSelector:extensionsSelector]) {
        NSSet *existing = SendId0(provider, extensionsSelector);
        if ([existing isKindOfClass:NSSet.class]) [extensions addObjectsFromArray:existing.allObjects];
    }
    NSIndexSet *duplicates = [extensions indexesOfObjectsPassingTest:^BOOL(
        id candidate, NSUInteger index, BOOL *stop
    ) {
        SEL identitySelector = NSSelectorFromString(@"identity");
        id candidateIdentity = [candidate respondsToSelector:identitySelector]
            ? SendId0(candidate, identitySelector) : nil;
        return [candidateIdentity isEqual:identity];
    }];
    [extensions removeObjectsAtIndexes:duplicates];
    [extensions addObject:widgetExtension];

    SEL makeSet = NSSelectorFromString(@"_makeWidgetExtensionSetWithExtensions:iconResolver:");
    if ([providerClass respondsToSelector:makeSet]) {
        id extensionSet = SendId2(providerClass, makeSet, extensions, nil);
        if (extensionSet) {
            @try {
                [provider setValue:extensionSet forKey:@"_lock_extensionSet"];
            } @catch (__unused NSException *exception) {
                return nil;
            }
        }
    }
    return provider;
}

- (void)createPrivateHost {
    if (self.hostCreated || self.invalidated) return;
    self.hostCreated = YES;

    @try {
        Class identityClass = NSClassFromString(@"CHSExtensionIdentity");
        Class descriptorClass = NSClassFromString(@"CHSWidgetDescriptor");
        Class widgetClass = NSClassFromString(@"CHSWidget");
        Class metricsClass = NSClassFromString(@"CHSWidgetMetrics");
        Class hostClass = NSClassFromString(@"CHUISWidgetHostViewController");
        if (!identityClass || !descriptorClass || !widgetClass || !metricsClass || !hostClass) {
            [self fail:@"This iOS version does not expose the Chrono widget host classes."];
            return;
        }

        id identity = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
            [identityClass alloc],
            NSSelectorFromString(@"initWithExtensionBundleIdentifier:containerBundleIdentifier:deviceIdentifier:"),
            self.extensionBundleIdentifier, self.containerBundleIdentifier, nil
        );
        NSUInteger supportedFamilies = ((NSUInteger)1 << MAX((NSInteger)0, self.family));
        id descriptor = ((id (*)(id, SEL, id, id, NSUInteger, id))objc_msgSend)(
            [descriptorClass alloc],
            NSSelectorFromString(@"initWithExtensionIdentity:kind:supportedFamilies:intentType:"),
            identity, self.widgetKind, supportedFamilies, nil
        );
        self.privateExtensionProvider = [self makeLocalExtensionProviderWithDescriptor:descriptor
                                                                              identity:identity];

        id widget = ((id (*)(id, SEL, id, id, id, NSInteger, id))objc_msgSend)(
            [widgetClass alloc],
            NSSelectorFromString(@"initWithExtensionBundleIdentifier:containerBundleIdentifier:kind:family:intent:"),
            self.extensionBundleIdentifier, self.containerBundleIdentifier,
            self.widgetKind, self.family, nil
        );
        id metrics = ((id (*)(id, SEL, CGSize, CGFloat))objc_msgSend)(
            [metricsClass alloc], NSSelectorFromString(@"initWithSize:cornerRadius:"),
            self.widgetSize, 22.0
        );
        UIViewController *host = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
            [hostClass alloc],
            NSSelectorFromString(@"initWithWidget:metrics:widgetConfigurationIdentifier:"),
            widget, metrics, nil
        );
        if (!host) {
            [self fail:@"Chrono refused to create a widget host controller."];
            return;
        }

        if (self.privateExtensionProvider) {
            @try {
                id oldProvider = [host valueForKey:@"_extensionProvider"];
                SEL unregisterSelector = NSSelectorFromString(@"unregisterObserver:");
                if ([oldProvider respondsToSelector:unregisterSelector]) {
                    SendVoid1(oldProvider, unregisterSelector, host);
                }
                [host setValue:self.privateExtensionProvider forKey:@"_extensionProvider"];
                SEL registerSelector = NSSelectorFromString(@"registerObserver:");
                if ([self.privateExtensionProvider respondsToSelector:registerSelector]) {
                    SendVoid1(self.privateExtensionProvider, registerSelector, host);
                }
                SEL updateDescriptor = NSSelectorFromString(@"_updateDescriptorIfNecessary");
                if ([host respondsToSelector:updateDescriptor]) SendVoid0(host, updateDescriptor);
            } @catch (__unused NSException *exception) {
                // The shared provider remains a valid fallback on older iOS.
            }
        }

        self.launchDelegate = [IOSSimContainerWidgetLaunchDelegate new];
        self.launchDelegate.owner = self;
        SendVoid1(host, NSSelectorFromString(@"setDelegate:"), self.launchDelegate);
        if ([host respondsToSelector:NSSelectorFromString(@"setInteractionDisabled:")]) {
            SendBool(host, NSSelectorFromString(@"setInteractionDisabled:"), NO);
        }
        if ([host respondsToSelector:NSSelectorFromString(@"setCanAppearInSecureEnvironment:")]) {
            SendBool(host, NSSelectorFromString(@"setCanAppearInSecureEnvironment:"), YES);
        }
        if ([host respondsToSelector:NSSelectorFromString(@"setMetricsDefineSize:")]) {
            SendBool(host, NSSelectorFromString(@"setMetricsDefineSize:"), YES);
        }
        if ([host respondsToSelector:NSSelectorFromString(@"setShowsWidgetLabel:")]) {
            SendBool(host, NSSelectorFromString(@"setShowsWidgetLabel:"), NO);
        }
        SEL visibleBounds = NSSelectorFromString(@"setVisibleBounds:");
        if ([host respondsToSelector:visibleBounds]) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(
                host, visibleBounds, (CGRect){CGPointZero, self.widgetSize}
            );
        }

        self.widgetHost = host;
        [self addChildViewController:host];
        host.view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:host.view];
        [NSLayoutConstraint activateConstraints:@[
            [host.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [host.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [host.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [host.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ]];
        [host didMoveToParentViewController:self];

        SEL prewarm = NSSelectorFromString(@"prewarmContent");
        if ([host respondsToSelector:prewarm]) SendVoid0(host, prewarm);
        [self verifyContentAttempt:0];
    } @catch (NSException *exception) {
        [self fail:[NSString stringWithFormat:@"Widget host exception: %@",
                                                   exception.reason ?: exception.name]];
    }
}

- (void)verifyContentAttempt:(NSInteger)attempt {
    if (self.invalidated || !self.widgetHost) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || self.invalidated || !self.widgetHost) return;

        SEL hasScene = NSSelectorFromString(@"_hasScene");
        if ([self.widgetHost respondsToSelector:hasScene]
            && !SendGetBool(self.widgetHost, hasScene)) {
            if (attempt < 7) {
                SEL prewarm = NSSelectorFromString(@"prewarmContent");
                if ([self.widgetHost respondsToSelector:prewarm]) SendVoid0(self.widgetHost, prewarm);
                [self verifyContentAttempt:attempt + 1];
            } else {
                [self fail:[NSString stringWithFormat:
                    @"PlugInKit resolved the provisioned runner %@, but WidgetRenderer could not start a scene for kind '%@'. Check the device console for the renderer's launch rejection.",
                    self.extensionBundleIdentifier, self.widgetKind]];
            }
            return;
        }

        SEL ensure = NSSelectorFromString(@"ensureContentWithTimeout:completion:");
        if (![self.widgetHost respondsToSelector:ensure]) {
            [self ready];
            return;
        }
        void (^completion)(NSError *) = ^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (!self || self.invalidated) return;
                error ? [self fail:[NSString stringWithFormat:
                                      @"WidgetRenderer %@ (%ld) for %@/%@: %@",
                                      error.domain, (long)error.code,
                                      self.extensionBundleIdentifier, self.widgetKind,
                                      error.localizedDescription]] : [self ready];
            });
        };
        ((void (*)(id, SEL, NSTimeInterval, id))objc_msgSend)(
            self.widgetHost, ensure, 5.0, completion
        );
    });
}

- (void)ready {
    [[NSNotificationCenter defaultCenter] postNotificationName:IOSSimWidgetStatusNotification
                                                        object:self
                                                      userInfo:@{ @"phase": @"ready" }];
}

- (void)fail:(NSString *)message {
    SetLastError(message);
    [[NSNotificationCenter defaultCenter] postNotificationName:IOSSimWidgetStatusNotification
                                                        object:self
                                                      userInfo:@{ @"phase": @"failed",
                                                                  @"message": message ?: @"Widget unavailable" }];
}

- (void)forwardLaunchRequest:(id)request {
    NSMutableDictionary *info = [@{ @"bundleIdentifier": self.containerBundleIdentifier }
                                 mutableCopy];
    SEL urlSelector = NSSelectorFromString(@"url");
    if ([request respondsToSelector:urlSelector]) {
        NSURL *url = SendId0(request, urlSelector);
        if ([url isKindOfClass:NSURL.class]) info[@"url"] = url.absoluteString;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:IOSSimWidgetLaunchNotification
                                                        object:self
                                                      userInfo:info];
}

- (void)invalidateHost {
    if (self.invalidated) return;
    self.invalidated = YES;
    if (self.widgetHost) {
        SEL invalidate = NSSelectorFromString(@"invalidate");
        if ([self.widgetHost respondsToSelector:invalidate]) SendVoid0(self.widgetHost, invalidate);
        [self.widgetHost willMoveToParentViewController:nil];
        [self.widgetHost.view removeFromSuperview];
        [self.widgetHost removeFromParentViewController];
    }
    SEL invalidateProvider = NSSelectorFromString(@"invalidate");
    if ([self.privateExtensionProvider respondsToSelector:invalidateProvider]) {
        SendVoid0(self.privateExtensionProvider, invalidateProvider);
    }
    self.widgetHost = nil;
    self.privateExtensionProvider = nil;
}

- (void)dealloc {
    [self invalidateHost];
}

@end


void *IOSSimCreateContainerWidgetHost(const char *extensionBundleIdentifier,
                                      const char *containerBundleIdentifier,
                                      const char *widgetKind,
                                      const char *extensionPath,
                                      int64_t family,
                                      double width,
                                      double height) {
    if (!extensionBundleIdentifier || !containerBundleIdentifier || !widgetKind
        || !extensionPath || width <= 0 || height <= 0) {
        SetLastError(@"Incomplete widget host metadata.");
        return NULL;
    }
    if (!LoadWidgetFrameworks()) return NULL;

    IOSSimContainerWidgetBridgeController *controller =
        [IOSSimContainerWidgetBridgeController new];
    controller.extensionBundleIdentifier = [NSString stringWithUTF8String:extensionBundleIdentifier];
    controller.containerBundleIdentifier = [NSString stringWithUTF8String:containerBundleIdentifier];
    controller.widgetKind = [NSString stringWithUTF8String:widgetKind];
    controller.extensionURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:extensionPath]
                                        isDirectory:YES];
    controller.family = (NSInteger)family;
    controller.widgetSize = CGSizeMake(width, height);
    IOSSimRegisterWidgetHost(controller);
    return (__bridge_retained void *)controller;
}

void IOSSimInvalidateContainerWidgetHost(void *pointer) {
    if (!pointer) return;
    IOSSimContainerWidgetBridgeController *controller = (__bridge id)pointer;
    if ([controller isKindOfClass:IOSSimContainerWidgetBridgeController.class]) {
        [controller invalidateHost];
    }
}

void IOSSimInvalidateContainerWidgetHostsForContainer(const char *containerBundleIdentifier) {
    if (!containerBundleIdentifier) return;
    NSString *bundleIdentifier = [NSString stringWithUTF8String:containerBundleIdentifier];
    if (!bundleIdentifier.length) return;

    void (^invalidate)(void) = ^{
        NSHashTable<IOSSimContainerWidgetBridgeController *> *hosts = IOSSimLiveWidgetHosts();
        NSArray<IOSSimContainerWidgetBridgeController *> *snapshot;
        @synchronized (hosts) {
            snapshot = hosts.allObjects;
        }
        for (IOSSimContainerWidgetBridgeController *controller in snapshot) {
            if ([controller.containerBundleIdentifier isEqualToString:bundleIdentifier]) {
                [controller invalidateHost];
            }
        }
    };

    if (NSThread.isMainThread) {
        invalidate();
    } else {
        dispatch_sync(dispatch_get_main_queue(), invalidate);
    }
}

char *IOSSimCopyContainerWidgetHostError(void) {
    NSString *error;
    @synchronized ([UIApplication class]) {
        error = IOSSimWidgetLastError ?: @"Widget host unavailable";
    }
    return strdup(error.UTF8String);
}
