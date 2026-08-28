//
//  AppSceneView.m
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "../LiveContainerSwiftUI/Utilities/LCUtils.h"
#import "PiPManager.h"
#import "Localization.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import "UIKitPrivate+MultitaskSupport.h"

static const NSTimeInterval LCMultitaskSceneReadinessTimeout = 15.0;
static const NSTimeInterval LCMultitaskSceneReadinessPollInterval = 0.10;
static const CGFloat LCSwitcherPreviewMaximumWidth = 430.0;
static const CGFloat LCSwitcherPreviewMaximumHeight = 932.0;
static const size_t LCSwitcherPreviewSampleDimension = 12;

/// Render-server snapshots can expose a correctly sized CGImage whose pixels
/// are nevertheless a uniform black/transparent placeholder. Sampling a tiny
/// bitmap keeps that placeholder from replacing the last useful app frame.
static BOOL LCSceneSnapshotHasVisiblePixels(CGImageRef imageRef) {
    if (!imageRef) return NO;

    const size_t dimension = LCSwitcherPreviewSampleDimension;
    const size_t bytesPerRow = dimension * 4;
    uint8_t pixels[LCSwitcherPreviewSampleDimension *
                   LCSwitcherPreviewSampleDimension * 4] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixels,
        dimension,
        dimension,
        8,
        bytesPerRow,
        colorSpace,
        kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast
    );
    CGColorSpaceRelease(colorSpace);
    if (!context) return NO;

    CGContextSetInterpolationQuality(context, kCGInterpolationLow);
    CGContextDrawImage(context, CGRectMake(0, 0, dimension, dimension), imageRef);
    CGContextRelease(context);

    uint8_t maximumColor = 0;
    uint8_t maximumAlpha = 0;
    for (size_t index = 0; index < dimension * dimension; index++) {
        const size_t offset = index * 4;
        maximumColor = MAX(maximumColor, pixels[offset]);
        maximumColor = MAX(maximumColor, pixels[offset + 1]);
        maximumColor = MAX(maximumColor, pixels[offset + 2]);
        maximumAlpha = MAX(maximumAlpha, pixels[offset + 3]);
    }
    return maximumAlpha > 8 && maximumColor > 8;
}

static UIImage *LCImageFromCapturedSceneSnapshot(FBSceneSnapshot *snapshot,
                                                 CGFloat requestedMaximumWidth) {
    if (!snapshot || ![snapshot respondsToSelector:@selector(CGImage)]) return nil;
    CGImageRef imageRef = snapshot.CGImage;
    size_t pixelWidth = imageRef ? CGImageGetWidth(imageRef) : 0;
    size_t pixelHeight = imageRef ? CGImageGetHeight(imageRef) : 0;
    if (!imageRef || pixelWidth < 1 || pixelHeight < 1) {
        NSLog(@"VibeContainers: render-server guest snapshot produced no image");
        return nil;
    }
    if (!LCSceneSnapshotHasVisiblePixels(imageRef)) {
        NSLog(@"VibeContainers: ignored uniform blank guest snapshot %zux%zu",
              pixelWidth, pixelHeight);
        return nil;
    }

    CGFloat maximumWidth = requestedMaximumWidth > 0
        ? MIN(requestedMaximumWidth, LCSwitcherPreviewMaximumWidth)
        : LCSwitcherPreviewMaximumWidth;
    CGFloat scale = MIN(1.0, MIN(maximumWidth / (CGFloat)pixelWidth,
                                LCSwitcherPreviewMaximumHeight / (CGFloat)pixelHeight));
    CGSize targetSize = CGSizeMake(MAX(1.0, floor((CGFloat)pixelWidth * scale)),
                                   MAX(1.0, floor((CGFloat)pixelHeight * scale)));

    // UIImage retains the snapshot's CGImage. Render immediately into a small
    // standalone bitmap so retaining switcher cards does not retain a full
    // display-sized IOSurface for every running guest.
    UIImage *sourceImage = [UIImage imageWithCGImage:imageRef
                                               scale:1.0
                                         orientation:UIImageOrientationUp];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:targetSize format:format];
    UIImage *result = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.blackColor setFill];
        CGContextFillRect(context.CGContext,
                          (CGRect){ .origin = CGPointZero, .size = targetSize });
        [sourceImage drawInRect:(CGRect){ .origin = CGPointZero, .size = targetSize }];
    }];
    NSLog(@"VibeContainers: captured render-server guest preview %zux%zu -> %.0fx%.0f",
          pixelWidth, pixelHeight, targetSize.width, targetSize.height);
    return result;
}

@interface LCSwitcherPreviewCapture ()
@property(nonatomic, strong, readwrite, nullable) UIImage *image;
@property(nonatomic, strong, readwrite, nullable) UIView *previewView;
@property(nonatomic, assign, readwrite, getter=isProtectedContent) BOOL protectedContent;
@end

@implementation LCSwitcherPreviewCapture
@end

@interface AppSceneViewController()
@property int resizeDebounceToken;
@property CFTimeInterval lastResizeRequestTime;
@property CGPoint normalizedOrigin;
@property bool isNativeWindow;
@property NSUUID* identifier;
@property CGSize lastRequestedLayoutSize;
@property UIInterfaceOrientation lastRequestedOrientation;
@property BOOL containerReserved;
@end

@interface AppSceneViewController()
@property(nonatomic) UIWindowScene *hostScene;
@property(nonatomic) NSString *sceneID;
@property(nonatomic) NSExtension* extension;
@property(nonatomic) bool isAppTerminationCleanUpCalled;
@property(nonatomic) bool initializationDelivered;
@property(nonatomic) bool initializationSucceeded;
@property(nonatomic) bool presenterPrepared;
@property(nonatomic) bool receivedSceneUpdate;
@property(nonatomic) bool readinessPollScheduled;
- (void)finishInitializationWithError:(NSError *)error;
- (void)armLaunchWatchdog;
- (void)scheduleSceneReadinessCheck;
- (void)evaluateSceneReadiness;
- (BOOL)hasUsableSceneSurface;
- (void)layoutLegacySceneSurface;
- (NSError *)launchErrorWithCode:(NSInteger)code description:(NSString *)description;
- (BOOL)addResourceAtURL:(NSURL *)url
                    role:(NSString *)role
                readOnly:(BOOL)readOnly
             toResources:(NSMutableArray<NSDictionary *> *)resources
                   error:(NSError **)error;
@end

@implementation AppSceneViewController


- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    self.delegate = delegate;
    self.dataUUID = dataUUID;
    self.bundleId = bundleId;
    self.scaleRatio = 1.0;
    self.isAppTerminationCleanUpCalled = false;
    self.initializationDelivered = false;
    self.initializationSucceeded = false;
    self.presenterPrepared = false;
    self.receivedSceneUpdate = false;
    self.readinessPollScheduled = false;
    self.isNativeWindow = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode" ] == 1;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIKitFixesInit();
    });
    [self armLaunchWatchdog];
    
    // init extension
    NSError* error = nil;
    _extension = [NSExtension extensionWithIdentifier:LCUtils.liveProcessBundleIdentifier error:&error];
    if(error || !_extension) {
        [self finishInitializationWithError:error ?: [self launchErrorWithCode:1
            description:@"The LiveProcess extension could not be opened."]];
        return self;
    }
    _extension.preferredLanguages = @[];

    BOOL isBuiltInSideStore = [_bundleId isEqualToString:@"builtinSideStore"];
    if (isBuiltInSideStore && !_dataUUID.length) {
        self.dataUUID = @"builtinSideStore";
    }
    if (!_bundleId.length || !_dataUUID.length) {
        [self finishInitializationWithError:[self launchErrorWithCode:EINVAL
            description:@"The guest bundle or data-container identifier is missing."]];
        return self;
    }

    // Reserving before PlugInKit starts the extension closes the race where
    // two window requests can open the same SQLite/Core Data container before
    // either request has returned a pid.
    if ([MultitaskManager isUsingContainer:_dataUUID]) {
        [self finishInitializationWithError:[self launchErrorWithCode:EBUSY
            description:@"This container is already open in another guest process."]];
        return self;
    }
    [MultitaskManager registerMultitaskContainerWithContainer:_dataUUID];
    self.containerReserved = YES;
    
    NSExtensionItem *item = [NSExtensionItem new];
    NSMutableArray<NSDictionary *> *resources = [NSMutableArray array];
    NSString *hostURLScheme = NSUserDefaults.lcAppUrlScheme;
    if (!hostURLScheme.length) {
        NSArray *urlTypes = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"];
        NSArray *schemes = [urlTypes.firstObject objectForKey:@"CFBundleURLSchemes"];
        hostURLScheme = schemes.firstObject ?: @"iossim";
    }
    NSMutableDictionary *userInfo = @{
        @"hostUrlScheme": hostURLScheme,
        @"selected": _bundleId,
        @"selectedContainer": _dataUUID,
        @"resources": resources,
        @"lcHomePath": NSHomeDirectory(),
    }.mutableCopy;

    // VibeContainers stores its imported identity in private host defaults
    // rather than an app group. The guest binary is already signed; pass the
    // password value as LiveContainer's JIT-less-mode marker so LiveProcess
    // takes the signed-library path instead of probing for inherited JIT.
    NSString *certificatePassword = [NSUserDefaults.standardUserDefaults
        objectForKey:@"LCCertificatePassword"];
    if(certificatePassword) {
        userInfo[@"certificatePassword"] = certificatePassword;
    }
    
    NSString* launchAppUrlScheme = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    [NSUserDefaults.lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
    if(launchAppUrlScheme) {
        [userInfo setValue:launchAppUrlScheme forKey:@"launchAppUrlScheme"];
    }
    
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *docURL = [fileManager URLsForDirectory:NSDocumentDirectory
                                         inDomains:NSUserDomainMask].lastObject;
    NSError *resourceError = nil;
    if (isBuiltInSideStore) {
        NSURL *sideStoreURL = [docURL URLByAppendingPathComponent:@"SideStore"
                                                     isDirectory:YES];
        NSError *directoryError = nil;
        if (![fileManager createDirectoryAtURL:sideStoreURL
                   withIntermediateDirectories:YES attributes:nil error:&directoryError] ||
            ![self addResourceAtURL:sideStoreURL role:@"sideStoreContainer" readOnly:NO
                        toResources:resources error:&resourceError]) {
            [self finishInitializationWithError:resourceError ?: [self launchErrorWithCode:EACCES
                description:directoryError.localizedDescription ?: @"SideStore data is unavailable."]];
            return self;
        }
    } else {
        bool isSharedApp = false;
        NSBundle *bundle = [LCSharedUtils findBundleWithBundleId:bundleId
                                                 isSharedAppOut:&isSharedApp];
        if (!bundle.bundleURL) {
            [self finishInitializationWithError:[self launchErrorWithCode:ENOENT
                description:@"The selected guest bundle no longer exists."]];
            return self;
        }

        NSURL *storageRoot = docURL;
        if (isSharedApp) {
            NSURL *appGroupPath = [LCSharedUtils appGroupPath];
            if (!appGroupPath) {
                [self finishInitializationWithError:[self launchErrorWithCode:EACCES
                    description:@"The shared guest storage is not available to this build."]];
                return self;
            }
            storageRoot = [appGroupPath URLByAppendingPathComponent:@"LiveContainer"
                                                        isDirectory:YES];
        }

        NSURL *dataURL = [[storageRoot URLByAppendingPathComponent:@"Data/Application"
                                                        isDirectory:YES]
            URLByAppendingPathComponent:dataUUID isDirectory:YES];
        NSURL *tweaksURL = [storageRoot URLByAppendingPathComponent:@"Tweaks"
                                                       isDirectory:YES];
        NSURL *appGroupsURL = [[storageRoot URLByAppendingPathComponent:@"Data"
                                                            isDirectory:YES]
            URLByAppendingPathComponent:@"AppGroup" isDirectory:YES];
        NSURL *containerLocksURL = isSharedApp ? nil
            : [docURL URLByAppendingPathComponent:@"LiveContainer" isDirectory:YES];
        NSError *directoryError = nil;
        if (![fileManager createDirectoryAtURL:tweaksURL withIntermediateDirectories:YES
                                    attributes:nil error:&directoryError] ||
            ![fileManager createDirectoryAtURL:appGroupsURL withIntermediateDirectories:YES
                                    attributes:nil error:&directoryError] ||
            (containerLocksURL &&
             ![fileManager createDirectoryAtURL:containerLocksURL
                    withIntermediateDirectories:YES attributes:nil error:&directoryError])) {
            [self finishInitializationWithError:[self launchErrorWithCode:directoryError.code ?: EACCES
                description:[NSString stringWithFormat:@"The guest support directories could not be prepared: %@",
                             directoryError.localizedDescription ?: @"unknown error"]]];
            return self;
        }

        if (![self addResourceAtURL:bundle.bundleURL role:@"bundle" readOnly:YES
                        toResources:resources error:&resourceError] ||
            ![self addResourceAtURL:dataURL role:@"container" readOnly:NO
                        toResources:resources error:&resourceError] ||
            ![self addResourceAtURL:tweaksURL role:@"tweaks" readOnly:NO
                        toResources:resources error:&resourceError] ||
            ![self addResourceAtURL:appGroupsURL role:@"appGroups" readOnly:NO
                        toResources:resources error:&resourceError]) {
            [self finishInitializationWithError:resourceError ?: [self launchErrorWithCode:EACCES
                description:@"The guest files could not be shared with LiveProcess."]];
            return self;
        }

        // The child records its audit token here so other launch paths can
        // reject a second process for the same data container. Private hosts
        // do not entitle LiveProcess to Documents, so grant only this small
        // coordination directory rather than the entire host container.
        if (containerLocksURL &&
            ![self addResourceAtURL:containerLocksURL role:@"containerLocks" readOnly:NO
                        toResources:resources error:&resourceError]) {
            [self finishInitializationWithError:resourceError];
            return self;
        }

        if ([NSUserDefaults.standardUserDefaults boolForKey:@"LCSharePrivateDataWithLiveProcess"] &&
            ![self addResourceAtURL:docURL role:@"hostDocuments" readOnly:NO
                        toResources:resources error:&resourceError]) {
            [self finishInitializationWithError:resourceError];
            return self;
        }
    }
    item.userInfo = userInfo;
    
    __weak typeof(self) weakSelf = self;
    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppSceneViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            NSError *launchError = error ?: [strongSelf launchErrorWithCode:3
                description:@"LiveProcess cancelled the guest request."];
            NSLog(@"LiveProcess request cancelled: %@", launchError);
            if (!strongSelf.initializationDelivered) {
                [strongSelf finishInitializationWithError:launchError];
            } else {
                [strongSelf appTerminationCleanUp];
            }
        });
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppSceneViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            NSLog(@"LiveProcess request interrupted for %@", strongSelf.bundleId);
            if (!strongSelf.initializationDelivered) {
                [strongSelf finishInitializationWithError:[strongSelf launchErrorWithCode:4
                    description:@"LiveProcess ended before its guest scene became ready."]];
            } else {
                [strongSelf appTerminationCleanUp];
            }
        });
    }];
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppSceneViewController *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.isAppTerminationCleanUpCalled) return;
            if(!identifier) {
                [strongSelf finishInitializationWithError:[strongSelf launchErrorWithCode:2
                    description:@"LiveProcess did not return a request identifier. The guest process may have exited during bootstrap."]];
                return;
            }

            strongSelf.identifier = identifier;
            strongSelf.pid = [strongSelf.extension pidForRequestIdentifier:identifier];
            if (strongSelf.pid <= 0) {
                [strongSelf finishInitializationWithError:[strongSelf launchErrorWithCode:ESRCH
                    description:@"LiveProcess returned no running guest process."]];
                return;
            }
            [strongSelf setUpAppPresenter];
        });
    }];
    
    return self;
}

- (BOOL)addResourceAtURL:(NSURL *)url
                    role:(NSString *)role
                readOnly:(BOOL)readOnly
             toResources:(NSMutableArray<NSDictionary *> *)resources
                   error:(NSError **)error {
    if (!url.isFileURL || !role.length) {
        if (error) {
            *error = [self launchErrorWithCode:EINVAL
                description:[NSString stringWithFormat:@"The %@ resource has an invalid path.",
                             role.length ? role : @"guest"]];
        }
        return NO;
    }

    // Documents/Applications and Documents/Data/Application are aliases in
    // VibeContainers. A transferable bookmark made from the alias asks
    // sandboxd to issue an extension for the symlink rather than its target;
    // on device that fails with ENOENT and leaves Core Data read-only. Always
    // hand LiveProcess the real vnode-backed path.
    NSURL *canonicalURL = url.URLByResolvingSymlinksInPath.standardizedURL;
    BOOL isDirectory = NO;
    if (!canonicalURL.path.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:canonicalURL.path
                                             isDirectory:&isDirectory] ||
        !isDirectory) {
        if (error) {
            *error = [self launchErrorWithCode:ENOENT
                description:[NSString stringWithFormat:@"The %@ resource is missing or is not a directory at %@.",
                             role, canonicalURL.path ?: url.path ?: @"(unknown path)"]];
        }
        return NO;
    }

    NSError *bookmarkError = nil;
    NSUInteger options = (1UL << 11);
    if (readOnly) options |= (1UL << 12);
    NSData *bookmark = [canonicalURL bookmarkDataWithOptions:options
                            includingResourceValuesForKeys:nil
                                             relativeToURL:nil
                                                     error:&bookmarkError];
    if (!bookmark) {
        if (error) {
            NSString *detail = bookmarkError.localizedDescription ?: @"sandbox extension creation failed";
            *error = [self launchErrorWithCode:bookmarkError.code ?: EACCES
                description:[NSString stringWithFormat:@"LiveProcess could not access the %@ resource: %@",
                             role, detail]];
        }
        return NO;
    }

    [resources addObject:@{
        @"role": role,
        @"bookmark": bookmark,
        @"readOnly": @(readOnly),
    }];
    return YES;
}

- (NSError *)launchErrorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:@"LiveProcess"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey:
        description.length ? description : @"The guest process could not be started."}];
}

- (void)armLaunchWatchdog {
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(LCMultitaskSceneReadinessTimeout * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            AppSceneViewController *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.initializationDelivered) return;

            NSString *description = strongSelf.presenterPrepared
                ? @"LiveProcess started, but its app scene did not become ready in time."
                : @"LiveProcess did not finish starting the guest in time.";
            [strongSelf finishInitializationWithError:
                [strongSelf launchErrorWithCode:ETIMEDOUT description:description]];
        });
}

- (void)scheduleSceneReadinessCheck {
    if (self.initializationDelivered || self.readinessPollScheduled || !self.presenterPrepared) {
        return;
    }

    self.readinessPollScheduled = true;
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(LCMultitaskSceneReadinessPollInterval * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            AppSceneViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.readinessPollScheduled = false;
            [strongSelf evaluateSceneReadiness];
            [strongSelf scheduleSceneReadinessCheck];
        });
}

- (void)evaluateSceneReadiness {
    if (self.initializationDelivered || !self.presenterPrepared) return;

    if (!self.isAppRunning) {
        [self finishInitializationWithError:[self launchErrorWithCode:EPIPE
            description:@"The guest process exited before its app scene became ready."]];
        return;
    }

    if ([self hasUsableSceneSurface]) {
        [self finishInitializationWithError:nil];
    }
}

- (BOOL)hasUsableSceneSurface {
    [self layoutLegacySceneSurface];
    if (!self.presenterPrepared || !self.presenter.scene || !self.contentView) return NO;
    if (!self.view.window || !self.contentView.window) return NO;
    if (CGRectIsEmpty(self.view.bounds) || CGRectIsEmpty(self.contentView.bounds)) return NO;

    // A presenter can be allocated before FrontBoard has connected the client.
    // Treat either a real client process or the first scene-settings callback as
    // proof that the remote scene completed its handoff to this host.
    BOOL clientAttached = self.presenter.scene.clientProcess != nil || self.receivedSceneUpdate;
    if (!clientAttached) return NO;

    if (!self.usesHostingControllerAPI) {
        UIView *presentationView = self.presenter.presentationView;
        if (!self.presenter.isActive || !presentationView.window || CGRectIsEmpty(presentationView.bounds)) {
            return NO;
        }
    }
    return YES;
}

/// The legacy FrontBoard presenter does not install constraints of its own.
/// Giving both host views an explicit, flexible frame prevents a zero-sized
/// presentation surface from remaining black forever on iOS 16 and 17.
- (void)layoutLegacySceneSurface {
    if (self.usesHostingControllerAPI || !self.contentView) return;

    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) return;

    self.contentView.frame = bounds;
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    UIView *presentationView = self.presenter.presentationView;
    presentationView.frame = self.contentView.bounds;
    presentationView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
}

- (void)finishInitializationWithError:(NSError *)error {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishInitializationWithError:error];
        });
        return;
    }
    if (self.initializationDelivered) return;

    self.initializationDelivered = true;
    self.initializationSucceeded = error == nil;
    self.readinessPollScheduled = false;
    id<AppSceneViewControllerDelegate> delegate = self.delegate;
    if (error) {
        // Presenter/bootstrap failures can happen after LiveProcess already
        // spawned. Do not leave a headless guest consuming a container slot.
        [self terminate];
        [self appTerminationCleanUp];
    }
    [delegate appSceneVC:self didInitializeWithError:error];
}

- (void)setUpAppPresenter {
    if (self.isAppTerminationCleanUpCalled || !self.isAppRunning) {
        [self finishInitializationWithError:[self launchErrorWithCode:ESRCH
            description:@"The guest process exited before its scene could be attached."]];
        return;
    }
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    FBProcessManager *manager = [PrivClass(FBProcessManager) sharedInstance];
    // At this point, the process is spawned and we're ready to create a scene to render in our app
    NSError *processError = nil;
    RBSProcessHandle* processHandle = [PrivClass(RBSProcessHandle) handleForPredicate:predicate error:&processError];
    if (!processHandle || !processHandle.identity) {
        [self finishInitializationWithError:processError ?: [self launchErrorWithCode:ESRCH
            description:@"The guest process disappeared before UIKit could host it."]];
        return;
    }
    [manager registerProcessForAuditToken:processHandle.auditToken];
    UIApplicationSceneSpecification *specification = [UIApplicationSceneSpecification specification];
    
    void (^updateSceneSettings)(id) = ^void(UIMutableApplicationSceneSettings *settings) {
        settings.canShowAlerts = YES;
        settings.cornerRadiusConfiguration = [[PrivClass(BSCornerRadiusConfiguration) alloc] initWithTopLeft:self.view.layer.cornerRadius bottomLeft:self.view.layer.cornerRadius bottomRight:self.view.layer.cornerRadius topRight:self.view.layer.cornerRadius];
        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
        settings.foreground = YES;
        //settings.interruptionPolicy = 2; // reconnect
        settings.level = 1;
        settings.persistenceIdentifier = self.dataUUID;
        settings.statusBarDisabled = !self.isNativeWindow;
        //settings.previewMaximumSize =
        //settings.deviceOrientationEventsEnabled = YES;
        if(!self.usesHostingControllerAPI) {
            settings.safeAreaInsetsPortrait = self.view.safeAreaInsets;
        }
    };
    void (^updateSceneClientSettings)(id) = ^void(UIMutableApplicationSceneClientSettings *clientSettings) {
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        clientSettings.statusBarStyle = 0;
    };

    if (@available(iOS 18.0, *)) {
        // The hosting classes exist on 17.4, but LiveContainer's 3.8 branch is
        // known to crash when this path is used on iOS 17. Use the proven
        // legacy FrontBoard presenter there and reserve the new host for 18+.
        _UISceneHostingControllerAdvancedConfiguration *config = [[_UISceneHostingControllerAdvancedConfiguration alloc] initWithProcessIdentity:processHandle.identity];
        config.sceneSpecification = specification;
        if (@available(iOS 27.0, *)) {} else {
            // on 27 manually adding this is not need, also setAdditionalExtensions: doesn't exist for some reason
            config.additionalExtensions = [NSOrderedSet orderedSetWithArray:@[
                PrivClass(_UISceneHostingEventDeferringExtension),
            ]];
        }
        self.hostingController = [[_UISceneHostingController alloc] initWithAdvancedConfiguration:config];
        if (!self.hostingController || !self.hostingController.sceneViewController) {
            [self finishInitializationWithError:[self launchErrorWithCode:5
                description:@"UIKit could not create a scene host for LiveProcess."]];
            return;
        }
        /// !! do NOT use self.hostingController.sceneView here as it breaks keyboard focus on iOS 26 below. I have no idea why this happens even though both return the same object. Maybe sceneView didn't initialize its ViewController properly?
        self.contentView = self.hostingController.sceneViewController.view;
        self.contentView.clipsToBounds = NO;
        // _scenePresenter was a property in 26, but made only ivar in 27
        self.presenter = [self.contentView valueForKey:@"_scenePresenter"];
        if (!self.presenter || !self.presenter.scene) {
            [self finishInitializationWithError:[self launchErrorWithCode:6
                description:@"UIKit did not provide a presenter for the guest scene."]];
            return;
        }
        self.sceneID = self.presenter.identifier;
        FBScene *scene = self.presenter.scene;
        [scene configureParameters:^(FBSMutableSceneParameters *parameters) {
            [parameters updateSettingsWithBlock:updateSceneSettings];
            [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        }];
        
        /// Fix keyboard focus by setting up event deferring extension. Previously we worked around it by changing identifier, but that broke other things
        _UISceneEventDeferringHostComponent *deferringComponent = self.hostingController._eventDeferringComponent;
        if (@available(iOS 27.0, *)) { // _UIKeyboardArbiterUsesDeferringGraph()
            /// UIKitCore`__85-[_UIRemoteViewControllerSceneHostingImpl _viewServiceHostSessionDidConnectToClient:]_block_invoke
            /// iOS 27 requires setting up _UISceneEventDeferringHostComponent for keyboard focus to work
            
            /// Replicate these methods since they are made private
            /// -[_UISceneEventDeferringHostComponent setFirstResponderTrackingSelectionPath:]:
            if (deferringComponent) {
                [deferringComponent setValue:self forKey:@"_firstResponderTrackingSelectionPath"];
            // if (!deferringComponent->_flags.clientIsInChain) return;
            /// -[_UISceneEventDeferringHostComponent becomeFirstResponderIfNecessary]:
            // if (deferringComponent->_flags.maintainHostFirstResponderWhenClientWantsKeyboard)
            
                deferringComponent.grantBehavior = 2;
                deferringComponent.selectionRequestBehavior = 2;
            }
        }
        /// UIKitCore`-[_UISceneHostingController createSceneWithConfiguration:]
        /// Lower iOS uses _UISceneHostingEventDeferringExtension, no further setup needed
        
        // Now it's time to get the initial settings from decorated VC
        [self.delegate appSceneVCWillActivateScene:self];
        [self addChildViewController:self.hostingController.sceneViewController];

        // The hosted scene now owns its lifecycle. If NSExtension also mirrors
        // the host app's resign/background notifications, a transient host
        // state change interrupts LiveProcess even though the guest scene is
        // still foreground.
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center removeObserver:self.extension name:UIApplicationDidBecomeActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillEnterForegroundNotification object:UIApp];
    } else {
        self.sceneID = [NSString stringWithFormat:@"sceneID:%@-%@", @"LiveProcess", self.dataUUID];
        FBSMutableSceneDefinition *definition = [PrivClass(FBSMutableSceneDefinition) definition];
        definition.identity = [PrivClass(FBSSceneIdentity) identityForIdentifier:self.sceneID];
        definition.clientIdentity = [PrivClass(FBSSceneClientIdentity) identityForProcessIdentity:processHandle.identity];
        definition.specification = specification;
        
        FBSMutableSceneParameters *parameters = [PrivClass(FBSMutableSceneParameters) parametersForSpecification:specification];
        [parameters updateSettingsWithBlock:updateSceneSettings];
        [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        FBScene *scene = [[PrivClass(FBSceneManager) sharedInstance] createSceneWithDefinition:definition initialParameters:parameters];
        if (!scene) {
            [self finishInitializationWithError:[self launchErrorWithCode:7
                description:@"UIKit could not create the legacy guest scene."]];
            return;
        }
        self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
        if (!self.presenter) {
            [self finishInitializationWithError:[self launchErrorWithCode:8
                description:@"UIKit could not create the legacy guest presenter."]];
            return;
        }
        [self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *context) {
            context.appearanceStyle = 2;
        }];
        [self.presenter activate];
        
        self.contentView = [[UIView alloc] initWithFrame:self.view.bounds];
        self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        UIView *presentationView = self.presenter.presentationView;
        presentationView.frame = self.contentView.bounds;
        presentationView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        [self.contentView addSubview:presentationView];
    }
    [self.view addSubview:_contentView];
    [self layoutLegacySceneSurface];
    if (@available(iOS 17.0, *)) {
        if (self.usesHostingControllerAPI) {
            [self.hostingController.sceneViewController didMoveToParentViewController:self];
        }
    }
    
    // If we have a staging URL scheme, pass it now
    NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    if(launchUrl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        [self openURLScheme:launchUrl];
    }
    
    self.contentView.layer.anchorPoint = CGPointMake(0, 0);
    self.contentView.layer.position = CGPointMake(0, 0);

    UIWindowScene *windowScene = self.view.window.windowScene;
    if (windowScene && self.sceneID.length) {
        self.hostScene = windowScene;
        [windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];
    }
    self.presenterPrepared = true;
    [self evaluateSceneReadiness];
    [self scheduleSceneReadinessCheck];
}

- (void)terminate {
    if(self.isAppRunning) {
        NSExtension *extensionToTerminate = self.extension;
        pid_t pidToTerminate = self.pid;
        [extensionToTerminate _kill:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // Do not let a delayed force-kill target a newer request after the
            // old extension pid has exited and the user has relaunched it.
            if (pidToTerminate > 0 && getpgid(pidToTerminate) > 0) {
                [extensionToTerminate _kill:SIGKILL];
            }
        });
    }
}

- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {
    if(!self.isAppRunning) {
        if (!self.initializationDelivered) {
            [self finishInitializationWithError:[self launchErrorWithCode:EPIPE
                description:@"The guest process exited while its app scene was connecting."]];
        } else {
            [self appTerminationCleanUp];
        }
        return;
    }
    if(!diff) return;

    self.receivedSceneUpdate = true;
    UIMutableApplicationSceneSettings *baseSettings = [diff settingsByApplyingToMutableCopyOfSettings:settings];
    UIApplicationSceneTransitionContext *newContext = [context copy];
    newContext.actions = nil;
    [self.delegate appSceneVC:self didUpdateFromSettings:baseSettings transitionContext:newContext lifecycleActionType:actionType];
    [self evaluateSceneReadiness];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self layoutLegacySceneSurface];
    /// For native window we let iPadOS handle it however it wants, which is usually live resize (autoresizingMask set in appSceneVCWillActivateScene)
    if(!self.usesHostingControllerAPI) {
        CGSize size = self.view.bounds.size;
        UIInterfaceOrientation orientation = self.view.window.windowScene.interfaceOrientation;
        if (!CGSizeEqualToSize(size, self.lastRequestedLayoutSize) ||
            orientation != self.lastRequestedOrientation) {
            self.lastRequestedLayoutSize = size;
            self.lastRequestedOrientation = orientation;
            [self updateFrameWithSettingsBlock:nil];
        }
    }
    [self evaluateSceneReadiness];
}
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {
    __block int currentDebounceToken = ++_resizeDebounceToken;
    dispatch_block_t queueBlock = ^{
        if(currentDebounceToken != self.resizeDebounceToken) {
            return;
        }
        [self updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.deviceOrientation = UIDevice.currentDevice.orientation;
            settings.interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
            CGRect frame = self.view.frame;
            if(!self.usesHostingControllerAPI) {
                frame.size.width /= self.scaleRatio;
                frame.size.height /= self.scaleRatio;
            }
            if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
                CGSize size = frame.size;
                frame.size.width = size.height;
                frame.size.height = size.width;
            }
            settings.frame = frame;
            if(block) {
                block(settings);
            }
        }];
    };
    if(_shouldSkipDebounceOnce) {
        _shouldSkipDebounceOnce = NO;
        queueBlock();
    } else {
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC));
        dispatch_after(delay, dispatch_get_main_queue(), queueBlock);
    }
}
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {
    if(_shouldIgnoreSceneUpdates || !updateSettingsBlock || !self.presenter.scene) {
        // Ignore all updates when in PiP mode
        return;
    }
    
    if(!_hostingController && self.contentView) {
        // Legacy path
        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];
        return;
    }
    
    /// iOS 18+ path, most are automatically handled by setting values to _UISceneHostingViewController
    /// This is also reachable on legacy path when contentView is nil during early setup
    UIMutableApplicationSceneSettings *tempSettings = [self.presenter.scene.settings mutableCopy];
    if(!tempSettings) {
        tempSettings = [UIMutableApplicationSceneSettings new];
    }
    updateSettingsBlock(tempSettings);
    CGRect frame = tempSettings.frame;
    if(UIInterfaceOrientationIsLandscape(tempSettings.interfaceOrientation)) {
        frame = CGRectMake(frame.origin.x, frame.origin.y, frame.size.height, frame.size.width);
    }
    
    if (self.contentView) {
        BOOL isiOS26 = NO;
        if(@available(iOS 19.0, *)) { if(@available(iOS 27.0, *)) {} else isiOS26 = YES; }
        // Discard position
        frame.origin = CGPointZero;
        if (!CGRectEqualToRect(self.contentView.frame, frame)) {
            self.contentView.frame = frame;
        }
    } else {
        // This method can be called while contentView is nil to set up initial frame
        if (!CGRectEqualToRect(self.view.frame, frame)) {
            self.view.frame = frame;
        }
    }
}

- (BOOL)isAppRunning {
    return _pid > 0 && getpgid(_pid) > 0;
}

- (void)appTerminationCleanUp {
    if(_isAppTerminationCleanUpCalled) {
        return;
    }
    _isAppTerminationCleanUpCalled = true;
    BOOL shouldNotifyExit = self.initializationSucceeded;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.sceneID.length) {
            [self.hostScene _unregisterSettingsDiffActionArrayForKey:self.sceneID];
        }
        if(self.usesHostingControllerAPI) {
            if(@available(iOS 17.0, *)) {
                // _UISceneHostingController owns the modern FBScene. Calling
                // FBSceneManager destroyScene as well races its invalidation
                // and can make PlugInKit terminate LiveProcess with SIGKILL.
                UIViewController *sceneViewController = self.hostingController.sceneViewController;
                [sceneViewController willMoveToParentViewController:nil];
                [self.hostingController invalidate];
                [sceneViewController.view removeFromSuperview];
                [sceneViewController removeFromParentViewController];
                self.hostingController = nil;
            }
        } else if(self.presenter){
            if(self.sceneID.length) {
                [[PrivClass(FBSceneManager) sharedInstance]
                    destroyScene:self.sceneID withTransitionContext:nil];
            }
            [self.presenter deactivate];
            [self.presenter invalidate];
        }
        self.presenter = nil;
        self.hostScene = nil;
        
        if (shouldNotifyExit) {
            [self.delegate appSceneVCAppDidExit:self];
        }
        if (self.containerReserved) {
            self.containerReserved = NO;
            [MultitaskManager unregisterMultitaskContainerWithContainer:self.dataUUID];
        }
    });
}

- (void)setBackgroundNotificationEnabled:(bool)enabled {
    if(self.usesHostingControllerAPI) {
        // FBSSceneObserver controls lifecycle for the modern host. Keep a guest
        // foreground when background mirroring is disabled instead of adding
        // NSExtension observers back and racing the scene observer.
        if (!enabled) {
            [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                settings.foreground = YES;
                settings.deactivationReasons = 0;
            }];
        }
        return;
    }
    if(enabled) {
        // Re-add UIApplicationDidEnterBackgroundNotification
        [NSNotificationCenter.defaultCenter addObserver:self.extension selector:@selector(_hostDidEnterBackgroundNote:) name:UIApplicationDidEnterBackgroundNotification object:UIApplication.sharedApplication];
        [NSNotificationCenter.defaultCenter addObserver:self.extension selector:@selector(_hostWillResignActiveNote:) name:UIApplicationWillResignActiveNotification object:UIApplication.sharedApplication];
    } else {
        // Remove UIApplicationDidEnterBackgroundNotification so apps like YouTube can continue playing video
        [NSNotificationCenter.defaultCenter removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApplication.sharedApplication];
        [NSNotificationCenter.defaultCenter removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApplication.sharedApplication];
    }
}

- (void)viewDidMoveToWindow:(UIWindow *)newWindow shouldAppearOrDisappear:(BOOL)appear {
    [super viewDidMoveToWindow:newWindow shouldAppearOrDisappear:appear];
    if (newWindow) {
        [self layoutLegacySceneSurface];
        UIWindowScene *newHostScene = newWindow.windowScene;
        if (self.hostScene != newHostScene && self.sceneID.length) {
            [self.hostScene _unregisterSettingsDiffActionArrayForKey:self.sceneID];
            self.hostScene = newHostScene;
            [newHostScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];
        }
        [self evaluateSceneReadiness];
        [self scheduleSceneReadinessCheck];
    } else {
        if(self.sceneID.length) {
            [self.hostScene _unregisterSettingsDiffActionArrayForKey:self.sceneID];
        }
        self.hostScene = nil;
    }
}

- (void)openURLScheme:(NSString *)urlString {
    if (!urlString.length || !self.presenter.scene) return;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        // pull from UserDefaults.standard.setValue(launchURLStr, forKey: "launchAppUrlScheme")
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        context.payload = @{UIApplicationLaunchOptionsURLKey: urlString};
        context.actions = [NSSet setWithObject:[[UIOpenURLAction alloc] initWithURL:url]];
        return context;
    }];
}

- (void)handleStatusBarTapAction:(UIAction *)action {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        context.actions = [NSSet setWithObject:action];
        return context;
    }];
}

- (BOOL)usesHostingControllerAPI {
    return _hostingController != nil;
}

- (LCSwitcherPreviewCapture *)captureSwitcherPreviewResultWithMaximumWidth:(CGFloat)maximumWidth {
    if (![NSThread isMainThread]) {
        __block LCSwitcherPreviewCapture *capture = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            capture = [self captureSwitcherPreviewResultWithMaximumWidth:maximumWidth];
        });
        return capture;
    }

    _UIScenePresenter *presenter = self.presenter;
    if (!self.initializationSucceeded ||
        ![self hasUsableSceneSurface] ||
        !presenter ||
        !presenter.scene) {
        NSLog(@"VibeContainers: skipped switcher snapshot before guest readiness");
        return nil;
    }

    FBSceneSnapshot *snapshot = nil;
    @try {
        // Create one detached FrontBoard snapshot and explicitly capture it
        // before reading CGImage. captureSnapshotPresentationView does not
        // guarantee that its sceneSnapshot has populated pixels on iOS 27,
        // and its remote UIView becomes blank after the guest is hidden.
        if ([presenter respondsToSelector:@selector(newSnapshot)]) {
            snapshot = [presenter newSnapshot];
        } else if ([presenter.scene respondsToSelector:@selector(createSnapshot)]) {
            snapshot = [presenter.scene createSnapshot];
        }
        if (snapshot && [snapshot respondsToSelector:@selector(capture)]) {
            [snapshot capture];
        }
    } @catch (NSException *exception) {
        NSLog(@"VibeContainers: render-server guest snapshot failed: %@",
              exception.reason ?: exception.name);
        snapshot = nil;
    }

    // Compatibility fallback for presenter variants that cannot create a
    // snapshot directly. Use the view only to obtain its FBSceneSnapshot,
    // capture that object explicitly, and discard the remote UIView.
    if (!snapshot &&
        [presenter respondsToSelector:@selector(captureSnapshotPresentationView)]) {
        @try {
            _UISceneSnapshotPresentationView *snapshotView =
                [presenter captureSnapshotPresentationView];
            if ([snapshotView respondsToSelector:@selector(sceneSnapshot)]) {
                snapshot = snapshotView.sceneSnapshot;
            }
            if (snapshot && [snapshot respondsToSelector:@selector(capture)]) {
                [snapshot capture];
            }
        } @catch (NSException *exception) {
            NSLog(@"VibeContainers: fallback guest snapshot failed: %@",
                  exception.reason ?: exception.name);
            snapshot = nil;
        }
    }

    if (!snapshot) return nil;

    LCSwitcherPreviewCapture *result = [LCSwitcherPreviewCapture new];
    if ([snapshot respondsToSelector:@selector(hasProtectedContent)] &&
        snapshot.hasProtectedContent) {
        NSLog(@"VibeContainers: refusing to cache protected guest snapshot content");
        result.protectedContent = YES;
        return result;
    }

    result.image = LCImageFromCapturedSceneSnapshot(snapshot, maximumWidth);
    return result.image ? result : nil;
}

- (UIImage *)captureSwitcherPreviewWithMaximumWidth:(CGFloat)maximumWidth {
    return [self captureSwitcherPreviewResultWithMaximumWidth:maximumWidth].image;
}

- (UIView *)captureSwitcherPreviewView {
    return [self captureSwitcherPreviewResultWithMaximumWidth:
            LCSwitcherPreviewMaximumWidth].previewView;
}

@end
 
