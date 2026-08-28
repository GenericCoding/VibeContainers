//
//  main.m
//  LiveContainer
//
//  Created by s s on 2026/2/17.
//
#import "LCShareExtensionLauncher.h"
#import "../LiveContainer/utils.h"
#import "../LiveContainer/UIKitPrivate.h"


@implementation LCShareExtensionLauncher

+ (BOOL)openURLFromShareExtension:(NSURL *)url {
    // unfortunately SpringBoard blocks openURL for iOS 10+ new extension types, so we need to chain through this old extension type to open the URL
    return [[PrivClass(LSApplicationWorkspace) defaultWorkspace] openURL:url];
}

+ (BOOL)canOpenURLFromShareExtension:(NSURL *)url {
    id error = nil;
    return [[PrivClass(LSApplicationWorkspace) defaultWorkspace] isApplicationAvailableToOpenURL:url error:&error];
}

@end

NSBundle* lcMainBundle = nil;
__attribute__((constructor))
static void init(void) {
    lcMainBundle = [NSBundle bundleWithURL:NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent];
    NSLog(@"%@", lcMainBundle);
}

@interface NSUserDefaults(ShareExtension)
+ (NSBundle*)lcMainBundle;
@end

@implementation NSUserDefaults(ShareExtension)

+ (NSBundle*)lcMainBundle {
    return lcMainBundle;
}

@end
