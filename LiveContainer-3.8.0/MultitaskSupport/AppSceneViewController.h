//
//  AppSceneView.h
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "UIKitPrivate+MultitaskSupport.h"
#import "../LiveContainer/FoundationPrivate.h"
@import UIKit;
@import Foundation;


@class AppSceneViewController;

/// One render-server transaction can provide both a compact bitmap and a
/// UIKit snapshot presentation view. Keeping them together prevents callers
/// from synchronously capturing the same cross-process scene twice.
API_AVAILABLE(ios(16.0))
@interface LCSwitcherPreviewCapture : NSObject
@property(nonatomic, strong, readonly, nullable) UIImage *image;
@property(nonatomic, strong, readonly, nullable) UIView *previewView;
@property(nonatomic, assign, readonly, getter=isProtectedContent) BOOL protectedContent;
@end

API_AVAILABLE(ios(16.0))
@protocol AppSceneViewControllerDelegate <NSObject>
- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc;
- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError*)error;
@optional
- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType;
- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc;
@end

API_AVAILABLE(ios(16.0))
@interface AppSceneViewController : UIViewController<_UISceneSettingsDiffAction>
@property(nonatomic) NSString* bundleId;
@property(nonatomic) NSString* dataUUID;
@property(nonatomic) int pid;
@property(nonatomic, weak) id<AppSceneViewControllerDelegate> delegate;
@property(nonatomic) BOOL isAppRunning;
@property(nonatomic) BOOL shouldIgnoreSceneUpdates, shouldSkipDebounceOnce;
@property(nonatomic) CGFloat scaleRatio;
@property(nonatomic) UIView* contentView;
@property(nonatomic) _UIScenePresenter *presenter;
@property(nonatomic) _UISceneHostingController *hostingController API_AVAILABLE(ios(17.0));
- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate;
- (void)setBackgroundNotificationEnabled:(bool)enabled;
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block;
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))block;
- (void)appTerminationCleanUp;
- (void)terminate;
- (void)openURLScheme:(NSString *)urlString;
- (void)handleStatusBarTapAction:(UIAction *)action;
- (BOOL)usesHostingControllerAPI;
- (nullable LCSwitcherPreviewCapture *)captureSwitcherPreviewResultWithMaximumWidth:(CGFloat)maximumWidth;
- (nullable UIImage *)captureSwitcherPreviewWithMaximumWidth:(CGFloat)maximumWidth;
- (nullable UIView *)captureSwitcherPreviewView;
@end
