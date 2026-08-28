#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/// LiveContainer already contains the IconServices-backed renderer that turns
/// an arbitrary installed .app's compiled Assets.car app-icon rendition into
/// a UIImage. Swift cannot import that private Objective-C category from the
/// embedded framework, so expose one retained, exception-safe C boundary.
void *IOSSimCopyContainerApplicationIcon(const char *bundlePath) {
    if (!bundlePath) return NULL;

    @autoreleasepool {
        @try {
            SEL selector = NSSelectorFromString(
                @"generateIconForBundleURL:style:hasBorder:");

            // The framework is normally linked at launch. Explicit loading is
            // a harmless fallback for build configurations that dead-strip all
            // direct references to its Objective-C category.
            if (![UIImage respondsToSelector:selector]) {
                NSURL *frameworkURL = [NSBundle.mainBundle.privateFrameworksURL
                    URLByAppendingPathComponent:@"LiveContainerSwiftUI.framework"];
                NSBundle *framework = [NSBundle bundleWithURL:frameworkURL];
                NSError *loadError = nil;
                if (![framework loadAndReturnError:&loadError]) {
                    NSLog(@"[ShortcutIcon] Could not load icon renderer: %@",
                          loadError.localizedDescription);
                    return NULL;
                }
            }

            Method method = class_getClassMethod(UIImage.class, selector);
            if (!method) return NULL;
            typedef UIImage *(*IconRenderer)(id, SEL, NSURL *, NSInteger, BOOL);
            IconRenderer render = (IconRenderer)method_getImplementation(method);
            NSString *path = [NSString stringWithUTF8String:bundlePath];
            if (!path.length) return NULL;
            UIImage *image = render(UIImage.class, selector,
                                    [NSURL fileURLWithPath:path isDirectory:YES],
                                    0, NO);
            if (!image.CGImage) return NULL;
            return (__bridge_retained void *)image;
        } @catch (NSException *exception) {
            NSLog(@"[ShortcutIcon] Guest app-icon rendering raised %@: %@",
                  exception.name, exception.reason ?: @"no reason");
            return NULL;
        }
    }
}
