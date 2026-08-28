//
//  EXExtensionContextImplementationHook.m
//  LiveContainer
//
//  Created by s s on 2026/7/5.
//

#import "LCShareExtensionLauncher.h"
@import ObjectiveC;

static void (*orig__willPerformHostCallback)(id self, SEL _cmd, id callback);

static void hook__willPerformHostCallback(NSExtensionContext* self, SEL _cmd, id callback) {
    NSExtensionItem *item = self.inputItems.firstObject;
    NSURL* url = item.userInfo[@"url"];
    if (url) {
        [LCShareExtensionLauncher openURLFromShareExtension:url];
    }

    orig__willPerformHostCallback(self, _cmd, callback);
}

__attribute__((constructor))
static void ExtensionHookInit(void) {
    Class class = objc_lookUpClass("EXExtensionContextImplementation");
    Method method = class_getInstanceMethod(class, NSSelectorFromString(@"_willPerformHostCallback:"));
    orig__willPerformHostCallback = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)hook__willPerformHostCallback);
}
