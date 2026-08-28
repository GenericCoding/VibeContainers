//
//  NSURLSessionConfiguration+GuestHooks.m
//  LiveContainer
//
//  Created by Duy Tran on 27/6/26.
//
#import "utils.h"
#import "LCSharedUtils.h"

@implementation NSURLSessionConfiguration(LiveContainerHook)
- (void)hook_encodeWithCoder:(NSCoder *)coder {
    // Fix background downloads in LiveProcess by using the host group only
    // when the running binary is actually entitled to one.
    NSString *groupID = LCSharedUtils.appGroupID;
    // VibeContainers intentionally uses private-container bookmarks and has
    // no application-group entitlement. Passing the sentinel "Unknown" asks
    // networkingd/containerd for a container this process can never open.
    self.sharedContainerIdentifier = (groupID.length && ![groupID isEqualToString:@"Unknown"])
        ? groupID
        : nil;
    [self hook_encodeWithCoder:coder];
}
@end

void NSURLSCGuestHooksInit(void) {
    swizzle(NSURLSessionConfiguration.class, @selector(encodeWithCoder:), @selector(hook_encodeWithCoder:));
}
