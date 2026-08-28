#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <unistd.h>

extern int32_t IOSSimRelaunchForHost(void);
extern int32_t IOSSimTerminateMultitaskGuests(void);
int32_t IOSSimExitGuest(void);

static CFStringRef const IOSSimExitGuestNotification = CFSTR("com.iossim.exit-guest");
static atomic_bool IOSSimGuestIsExiting = false;
/// Core Foundation requires a non-null identity for Darwin observers. The
/// address is stable for the lifetime of the guest process and the callback
/// does not otherwise need an Objective-C owner.
static char IOSSimExitObserverToken;

static void IOSSimExitNotificationCallback(CFNotificationCenterRef center,
                                            void *observer,
                                            CFNotificationName name,
                                            const void *object,
                                            CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // A legacy direct guest owns the app process. Remove its launch ticket
        // and get out of AppIntents' way; openAppWhenRun will then activate a
        // clean VibeContainers host. In multitasking mode the host is already
        // alive, so close its independently running LiveProcess scenes.
        const char *hostHome = getenv("LC_HOME_PATH");
        if (hostHome) {
            NSString *ticket = [[NSString stringWithUTF8String:hostHome]
                stringByAppendingPathComponent:@"Documents/.iossim-livecontainer-launch.plist"];
            unlink(ticket.fileSystemRepresentation);
            _exit(EXIT_SUCCESS);
        }

        int32_t result = IOSSimTerminateMultitaskGuests();
        if (result != 0 && result != EALREADY) {
            NSLog(@"[iOSSim] Live Activity guest termination failed: %d", result);
        }
    });
}

/// Removes any pending guest ticket and applies the same fresh-process handoff
/// used for guest launch. With no ticket, GuestRuntime starts IOSSimHostMain.
int32_t IOSSimExitGuest(void) {
    if (atomic_exchange(&IOSSimGuestIsExiting, true)) return EALREADY;

    const char *hostHome = getenv("LC_HOME_PATH");
    if (hostHome) {
        NSString *ticket = [[NSString stringWithUTF8String:hostHome]
            stringByAppendingPathComponent:@"Documents/.iossim-livecontainer-launch.plist"];
        unlink(ticket.fileSystemRepresentation);
    }

    int32_t result = IOSSimRelaunchForHost();
    if (result != 0) atomic_store(&IOSSimGuestIsExiting, false);
    return result;
}

#pragma mark - PS button

/// Arms the PS button on one pad.
///
/// The guest owns this process and is free to install its own GameController
/// handlers — a game almost certainly will — so this is not a one-shot bind.
/// The re-arm timer below reinstalls the handler on a slow tick, which means a
/// guest that takes the pad over can delay the exit button by a second but can
/// never take it away. That trade is deliberate: without a way out, a guest
/// that ignores the Live Activity control strands the user in it.
static void IOSSimArmExitButton(GCController *controller) {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return;

    controller.handlerQueue = dispatch_get_main_queue();

    if (pad.buttonHome) {
        pad.buttonHome.pressedChangedHandler =
            ^(GCControllerButtonInput *button, float value, BOOL pressed) {
                if (pressed) IOSSimExitGuest();
            };
    }

    // Not every host forwards the PS button — iOS keeps it for the system
    // overlay unless the app has opted out — so both sticks pressed together
    // is a second way out that no platform reserves.
    if (pad.leftThumbstickButton && pad.rightThumbstickButton) {
        GCControllerButtonInput *left = pad.leftThumbstickButton;
        GCControllerButtonInput *right = pad.rightThumbstickButton;
        GCControllerButtonValueChangedHandler both =
            ^(GCControllerButtonInput *button, float value, BOOL pressed) {
                if (pressed && left.isPressed && right.isPressed) IOSSimExitGuest();
            };
        left.pressedChangedHandler = both;
        right.pressedChangedHandler = both;
    }
}

static void IOSSimArmAllExitButtons(void) {
    for (GCController *controller in GCController.controllers) {
        IOSSimArmExitButton(controller);
    }
}

/// The LiveActivityIntent runs outside the guest's UIKit hierarchy. A Darwin
/// notification crosses that process boundary without asking the guest to
/// handle iOSSim's URL scheme or injecting a view into the guest application.
///
/// The controller path is the other half of the same job: the guest has the
/// screen, so the way back has to be a button the guest is not using.
void IOSSimInstallGuestExitControl(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            &IOSSimExitObserverToken,
            IOSSimExitNotificationCallback,
            IOSSimExitGuestNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:GCControllerDidConnectNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            IOSSimArmExitButton(note.object);
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            IOSSimArmAllExitButtons();
        }];

        IOSSimArmAllExitButtons();

        dispatch_source_t rearm = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(rearm,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                                  (uint64_t)(1.5 * NSEC_PER_SEC),
                                  (uint64_t)(0.5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(rearm, ^{ IOSSimArmAllExitButtons(); });
        dispatch_resume(rearm);
        // Intentionally never cancelled: the source lives as long as the guest.
        CFRetain((__bridge CFTypeRef)rearm);
    });
}
