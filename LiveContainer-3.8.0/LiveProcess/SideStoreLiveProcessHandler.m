//
//  SideStoreLiveProcessHandler.m
//  LiveContainer
//
//  Created by s s on 2025/7/20.
//

#include "../SideStore/XPCServer.h"

static LiveProcessSideStoreHandler* sharedHandler = nil;

@implementation LiveProcessSideStoreHandler

+ (LiveProcessSideStoreHandler*)shared {
    if(!sharedHandler) {
        sharedHandler = [LiveProcessSideStoreHandler new];
    }
    return sharedHandler;
}


@end
