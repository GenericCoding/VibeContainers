@import Foundation;
@import UIKit;

/// The sample tweak: a dylib whose only job is to prove it was loaded.
///
/// dyld runs this constructor when it loads the image, which — because the
/// `LC_LOAD_DYLIB` command naming it sits in the guest's own executable —
/// happens before the guest's `main`. There is no UIKit scene at that point, so
/// the banner waits for the app to become active. Once UIKit is ready it uses
/// the guest's own visible window, preserving both native and virtual guest
/// content beneath a passive, auto-dismissing banner.
///
/// The same shape works for a real tweak: swizzle in the constructor, touch UI
/// only once the app is up.

static BOOL HelloDyldDidShowBanner = NO;
static BOOL HelloDyldRetryScheduled = NO;
static NSUInteger HelloDyldRetryCount = 0;
static id HelloDyldActivationObserver = nil;
static const NSUInteger HelloDyldMaximumRetryCount = 12;

static UIWindow *HelloDyldPreferredWindow(UIWindowScene *scene, UIWindow *excludedWindow) {
    UIWindow *normalWindow = nil;
    UIWindow *otherWindow = nil;

    for (UIWindow *window in scene.windows) {
        if (window == excludedWindow || window.hidden || window.alpha <= 0.01 ||
            window.rootViewController == nil || CGRectIsEmpty(window.bounds)) {
            continue;
        }

        if (window.isKeyWindow) {
            return window;
        }
        if (normalWindow == nil && window.windowLevel == UIWindowLevelNormal) {
            normalWindow = window;
        }
        if (otherWindow == nil) {
            otherWindow = window;
        }
    }

    return normalWindow ?: otherWindow;
}

static UIWindowScene *HelloDyldPreferredScene(UIWindow **preferredWindow) {
    UIWindowScene *bestScene = nil;
    UIWindow *bestWindow = nil;
    NSInteger bestScore = NSIntegerMin;

    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) {
            continue;
        }

        UIWindowScene *scene = (UIWindowScene *)candidate;
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }

        UIWindow *window = HelloDyldPreferredWindow(scene, nil);
        NSInteger score = scene.activationState == UISceneActivationStateForegroundActive ? 1000 : 500;
        if (window != nil) {
            score += 100;
            if (window.isKeyWindow) {
                score += 100;
            }
            if (window.windowLevel == UIWindowLevelNormal) {
                score += 10;
            }
        }

        if (score > bestScore) {
            bestScore = score;
            bestScene = scene;
            bestWindow = window;
        }
    }

    if (preferredWindow != NULL) {
        *preferredWindow = bestWindow;
    }
    return bestScene;
}

static void HelloDyldStopWaitingForActivation(void) {
    if (HelloDyldActivationObserver == nil) {
        return;
    }

    [NSNotificationCenter.defaultCenter removeObserver:HelloDyldActivationObserver];
    HelloDyldActivationObserver = nil;
}

static void HelloDyldPresentBanner(void);

static void HelloDyldScheduleRetry(void) {
    if (HelloDyldDidShowBanner || HelloDyldRetryScheduled ||
        HelloDyldRetryCount >= HelloDyldMaximumRetryCount) {
        return;
    }

    HelloDyldRetryScheduled = YES;
    HelloDyldRetryCount += 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        HelloDyldRetryScheduled = NO;
        HelloDyldPresentBanner();
    });
}

static UIView *HelloDyldBanner(void) {
    UIView *banner = [UIView new];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.userInteractionEnabled = NO;
    banner.accessibilityElementsHidden = YES;
    banner.backgroundColor = UIColor.clearColor;
    banner.layer.shadowColor = UIColor.blackColor.CGColor;
    banner.layer.shadowOpacity = 0.18;
    banner.layer.shadowRadius = 16;
    banner.layer.shadowOffset = CGSizeMake(0, 8);

    UIVisualEffectView *material = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    material.translatesAutoresizingMaskIntoConstraints = NO;
    material.userInteractionEnabled = NO;
    material.clipsToBounds = YES;
    material.layer.cornerRadius = 18;
    material.layer.cornerCurve = kCACornerCurveContinuous;
    [banner addSubview:material];

    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"checkmark.seal.fill"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = UIColor.systemGreenColor;

    UILabel *title = [UILabel new];
    title.text = @"Hello from dyld!";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.textColor = UIColor.labelColor;

    UILabel *detail = [UILabel new];
    detail.text = @"HelloDyld loaded before the app's own code ran.";
    detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    detail.textColor = UIColor.secondaryLabelColor;
    detail.numberOfLines = 0;

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[title, detail]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[icon, text]];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 11;
    [material.contentView addSubview:content];

    NSLayoutConstraint *preferredWidth = [banner.widthAnchor constraintEqualToConstant:360];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [material.topAnchor constraintEqualToAnchor:banner.topAnchor],
        [material.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor],
        [material.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor],
        [material.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor],
        [content.topAnchor constraintEqualToAnchor:material.contentView.topAnchor constant:12],
        [content.leadingAnchor constraintEqualToAnchor:material.contentView.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:material.contentView.trailingAnchor constant:-14],
        [content.bottomAnchor constraintEqualToAnchor:material.contentView.bottomAnchor constant:-12],
        [icon.widthAnchor constraintEqualToConstant:28],
        [icon.heightAnchor constraintEqualToAnchor:icon.widthAnchor],
        preferredWidth
    ]];

    return banner;
}

static void HelloDyldShowBanner(UIWindow *guestWindow) {
    UIView *banner = HelloDyldBanner();
    [guestWindow addSubview:banner];
    [NSLayoutConstraint activateConstraints:@[
        [banner.centerXAnchor constraintEqualToAnchor:guestWindow.centerXAnchor],
        [banner.topAnchor constraintEqualToAnchor:guestWindow.safeAreaLayoutGuide.topAnchor
                                         constant:10],
        [banner.leadingAnchor constraintGreaterThanOrEqualToAnchor:guestWindow.leadingAnchor
                                                               constant:16],
        [banner.trailingAnchor constraintLessThanOrEqualToAnchor:guestWindow.trailingAnchor
                                                               constant:-16]
    ]];
    [guestWindow layoutIfNeeded];

    banner.alpha = 0;
    banner.transform = CGAffineTransformMakeTranslation(0, -12);
    [UIView animateWithDuration:0.28
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        banner.alpha = 1;
        banner.transform = CGAffineTransformIdentity;
    } completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.24
                              delay:0
                            options:UIViewAnimationOptionCurveEaseIn |
                                    UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            banner.alpha = 0;
            banner.transform = CGAffineTransformMakeTranslation(0, -10);
        } completion:^(BOOL finished) {
            [banner removeFromSuperview];
        }];
    });
}

static void HelloDyldPresentBanner(void) {
    NSCAssert(NSThread.isMainThread, @"HelloDyld UI must be updated on the main thread");
    if (HelloDyldDidShowBanner) {
        return;
    }

    UIWindow *guestWindow = nil;
    UIWindowScene *scene = HelloDyldPreferredScene(&guestWindow);
    UIViewController *rootViewController = guestWindow.rootViewController;
    UIView *rootView = rootViewController.viewIfLoaded;
    if (scene == nil || guestWindow == nil || rootViewController == nil ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        scene.activationState != UISceneActivationStateForegroundActive ||
        rootView.window != guestWindow || rootView.hidden || CGRectIsEmpty(rootView.bounds)) {
        HelloDyldScheduleRetry();
        return;
    }

    HelloDyldDidShowBanner = YES;
    HelloDyldStopWaitingForActivation();
    HelloDyldShowBanner(guestWindow);
}

__attribute__((constructor))
static void HelloDyldInit(void) {
    NSLog(@"[HelloDyld] loaded into %@", NSBundle.mainBundle.bundleIdentifier);

    HelloDyldActivationObserver =
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
        HelloDyldPresentBanner();
    }];

    // If the app is already active — a tweak dlopen'd late, say — the
    // notification has been and gone, so show it directly. The claim guard
    // makes this safe if activation and this block arrive in the same run loop.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            HelloDyldPresentBanner();
        }
    });
}
