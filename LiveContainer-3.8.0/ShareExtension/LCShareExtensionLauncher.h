#import <Foundation/Foundation.h>

@interface LCShareExtensionLauncher : NSObject
+ (BOOL)openURLFromShareExtension:(NSURL *)url;
+ (BOOL)canOpenURLFromShareExtension:(NSURL *)url;
@end
