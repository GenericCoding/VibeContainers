//
//  IDFV.m
//  LiveContainer
//
//  Created by s s on 2026/4/25.
//
@import Foundation;
@import ObjectiveC;

NSUUID* idForVendorUUID = nil;

NSUUID* getIDFV_hook(NSObject* cur) {
    return idForVendorUUID;
}

void IDFVHookInit(NSUUID* uuid) {
    idForVendorUUID = uuid;
    Method getIDFVOrig = class_getInstanceMethod(objc_getClass("LSApplicationWorkspace"), @selector(deviceIdentifierForVendor));
    method_setImplementation(getIDFVOrig, (IMP)getIDFV_hook);
}
