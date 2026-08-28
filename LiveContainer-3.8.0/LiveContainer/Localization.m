//
//  Localization.m
//  LiveContainer
//
//  Created by s s on 2024/9/21.
//
#import "Localization.h"

@implementation NSString (Localization)

// Class method for the English language bundle
+ (NSBundle *)enBundle {
    static NSBundle *enBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *mainBundle = [NSUserDefaults lcMainBundle] ?: NSBundle.mainBundle;
        NSString *path = [mainBundle pathForResource:@"en" ofType:@"lproj"];
        if (path.length) {
            enBundle = [NSBundle bundleWithPath:path];
        }
    });
    return enBundle;
}

// Instance method to return a localized string
- (NSString *)localized {
    // The framework can be embedded in a host which intentionally does not
    // ship LiveContainer's resource catalogue. `lcMainBundle` is also not set
    // until the guest bootstrap starts. Messaging either missing bundle used
    // to produce nil here, which is illegal for UIAlertAction titles on iPhone
    // and turned a recoverable LiveProcess error into a host-app crash.
    NSBundle *mainBundle = [NSUserDefaults lcMainBundle] ?: NSBundle.mainBundle;
    NSString *message = [mainBundle localizedStringForKey:self value:nil table:nil];
    if (message.length && ![message isEqualToString:self]) {
        return message;
    }

    NSString *forcedString = [[NSString enBundle] localizedStringForKey:self value:nil table:nil];
    if (forcedString.length && ![forcedString isEqualToString:self]) {
        return forcedString;
    }

    // Keep the controls useful when localization resources are absent. Every
    // other key still falls back to its nonnull key, matching Foundation.
    NSDictionary<NSString *, NSString *> *fallbacks = @{
        @"lc.common.cancel": @"Cancel",
        @"lc.common.close": @"Close",
        @"lc.common.copy": @"Copy",
        @"lc.common.error": @"Error",
        @"lc.common.ok": @"OK",
        @"lc.multitask.copyPid": @"Copy PID",
        @"lc.multitask.enablePip": @"Picture in Picture",
        @"lc.multitask.scale": @"Scale",
        @"lc.multitaskAppWindow.appTerminated": @"App Terminated",
    };
    return fallbacks[self] ?: self ?: @"";
}

// Instance method for localization with format
- (NSString *)localizeWithFormat:(NSString*)arg1, ... {
    va_list args;
    va_start(args, arg1);
    NSString *formattedString = [[NSString alloc] initWithFormat:self.localized
                                                          locale:NSLocale.currentLocale
                                                       arguments:args];
    va_end(args);
    return formattedString;
}

@end
