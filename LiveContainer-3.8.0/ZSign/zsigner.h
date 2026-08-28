//
//  zsigner.h
//  LiveContainer
//
//  Created by s s on 2024/11/10.
//
#import <Foundation/Foundation.h>


@interface ZSigner : NSObject
+ (NSProgress*)signWithAppPath:(NSString *)appPath bundleId:(NSString *)bundleId cert:(NSData *)key pass:(NSString *)pass completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (BOOL)adhocSignMachOAtPath:(NSString *)path bundleId:(NSString*)bundleId entitlementData:(NSData *)entitlementData;
+ (NSProgress*)signMachOPathArr:(NSArray<NSString*>*)machoPathArr bundleId:(NSString *)bundleId cert:(NSData *)key
                           pass:(NSString *)pass completionHandler:(void(^)(BOOL success, NSError *error))completionHandler;
+ (NSProgress*)signMachOPathArr:(NSArray<NSString*>*)machoPathArr bundleId:(NSString *)bundleId cert:(NSData *)key
                           pass:(NSString *)pass provision:(NSData *)provision
              completionHandler:(void(^)(BOOL success, NSError *error))completionHandler;
+ (NSProgress*)signMachOPathArr:(NSArray<NSString*>*)machoPathArr bundleId:(NSString *)bundleId cert:(NSData *)key
                           pass:(NSString *)pass provision:(NSData *)provision
                      infoPlist:(NSData *)infoPlist codeResources:(NSData *)codeResources
              completionHandler:(void(^)(BOOL success, NSError *error))completionHandler;
// this method is used to get teamId for ADP/Enterprise certs ,don't use it in normal jitless
+ (NSString*)getTeamIdWithCert:(NSData *)cert pass:(NSString *)pass;
+ (int)checkCert:(NSData *)cert pass:(NSString *)pass completionHandler:(void(^)(int status, NSDate* expirationDate, NSString* organizationalUnitName, NSString *error))completionHandler;
@end
