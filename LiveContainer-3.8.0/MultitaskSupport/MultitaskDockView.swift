//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//

import Foundation
import SwiftUI
import UIKit
import Combine

// MARK: - App Info Provider
class AppInfoProvider {
    
    static let shared = AppInfoProvider()
    
    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    private let cacheQueue = DispatchQueue(label: "com.livecontainer.appinfoprovider.cachequeue", attributes: .concurrent)
    
    private init() {}
    
    public func findAppInfo(appName: String, dataUUID: String) -> LCAppInfo? {
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) {
            return appInfo
        }
        if let appInfo = findAppInfo(byUUID: dataUUID) {
            return appInfo
        }
        return findAppInfo(byName: appName)
    }
    
    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByUUID[dataUUID] }) {
            return cachedInfo
        }
        
        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }
        
        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]
        
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let appInfoDict = NSDictionary(contentsOfFile: path),
               let bundlePath = appInfoDict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {
                
                cacheQueue.async(flags: .barrier) { self.infoCacheByUUID[dataUUID] = appInfo }
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByName[appName] }) {
            return cachedInfo
        }

        var searchPaths: [String] = []
        if let appGroupPath = LCSharedUtils.appGroupPath()?.path {
            searchPaths.append("\(appGroupPath)/LiveContainer/Applications")
        }
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(docPath)/Applications")
        }

        for appsPath in searchPaths {
            guard let appDirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }
            
            for appDir in appDirs where appDir.hasSuffix(".app") {
                if let appInfo = LCAppInfo(bundlePath: "\(appsPath)/\(appDir)"), appInfo.displayName() == appName {
                    cacheQueue.async(flags: .barrier) { self.infoCacheByName[appName] = appInfo }
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        
        for appModel in allApps {
            if appModel.appInfo.containers.contains(where: { $0.folderName == dataUUID }) {
                return appModel.appInfo
            }
        }
        
        for appModel in allApps {
            if appModel.appInfo.displayName() == appName {
                return appModel.appInfo
            }
        }
        return nil
    }
    
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.infoCacheByUUID.removeAll()
            self.infoCacheByName.removeAll()
        }
    }
}

// MARK: - App Model for Dock
@objc class DockAppModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @objc let appName: String
    @objc let appUUID: String
    let appInfo: LCAppInfo?
    let view: UIView?
    
    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        super.init()
    }
}

// MARK: - MultitaskDockView Manager
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject {
    @objc public static let shared = MultitaskDockManager()
    
    @Published var apps: [DockAppModel] = []
    @Published var isVisible: Bool = false
    @Published @objc var isCollapsed: Bool = false
    @Published var isDockHidden: Bool = false
    @Published var settingsChanged: Bool = false

    @objc public var windowHostingView = VirtualWindowsHostView()
    internal var hostingController: UIHostingController<AnyView>?
    /// The window that was frontmost when the multitasking runtime was first
    /// asked to launch a guest. Retaining its identity matters once additional
    /// UIWindowScenes exist: `connectedScenes.first` is not ordered and may be
    /// a guest rather than VibeContainers' Springboard.
    private weak var hostWindow: UIWindow?
    /// Last real frame captured from each guest surface. Phone multitasking
    /// keeps background guests hidden, so the switcher must retain the frame
    /// from when each surface was most recently visible instead of replacing
    /// it with a synthetic app card.
    private var appSwitcherPreviewCache: [String: UIImage] = [:]
    /// UIKit's scene-snapshot presentation views are retained separately from
    /// raster previews. They preserve FrontBoard's cross-process render
    /// context, which ordinary UIView hierarchy snapshots cannot capture.
    private var appSwitcherPreviewViewCache: [String: UIView] = [:]
    /// Only these gestures belong to the floating dock. Removing arbitrary
    /// gestures from the host window breaks Springboard taps and guest home
    /// gestures, so every installation is tracked explicitly.
    private var dockEdgeGestures: [UIScreenEdgePanGestureRecognizer] = []

    public struct Constants {
        // MARK: - Layout & Sizing
        static let defaultDockWidth: CGFloat = 90.0
        static let minAdaptiveDockWidth: CGFloat = 50.0
        static let minAdaptiveIconSize: CGFloat = 10.0
        static let maxIconSize: CGFloat = 100.0
        static let minCollapsedHeight: CGFloat = 60.0
        static let minCollapsedButtonSize: CGFloat = 44.0
        static let maxCollapsedButtonSize: CGFloat = 80.0
        static let initialDockShowHeight: CGFloat = 120.0

        // MARK: - Margins & Padding
        static let adaptiveWidthVerticalMargin: CGFloat = 20.0
        static let dockVerticalMargin: CGFloat = 30.0
        static let dockContentSpacing: CGFloat = 8.0
        static let dockVerticalPadding: CGFloat = 30.0
        // Extra padding is derived from dockVerticalPadding to match the SwiftUI layout exactly
        
        // MARK: - Ratios & Factors
        static let iconToWidthRatio: CGFloat = 0.75
        static let collapsedButtonToWidthRatio: CGFloat = 0.7
        static let maxHeightRatioOfAvailableArea: CGFloat = 0.85
        
        // MARK: - Animation & Interaction
        static var dockHiddenOffset: CGFloat {
            get {
                let ans = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
                if ans != 0 {
                    return ans * 2 / 3
                } else {
                    return 50
                }
            }
        }
        static var hideGestureThreshold: CGFloat {
            get {
                let ans = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
                if ans != 0 {
                    return ans / 5
                } else {
                    return 16
                }
            }
        }
        static let edgeSwipeThreshold: CGFloat = 30.0
        
        static let standardAnimationDuration: TimeInterval = 0.3
        static let longAnimationDuration: TimeInterval = 0.4
        static let shortAnimationDuration1: TimeInterval = 0.15
        static let shortAnimationDuration2: TimeInterval = 0.1
        
        static let standardSpringDamping: CGFloat = 0.8
        static let showHideSpringDamping: CGFloat = 0.7
        static let standardSpringVelocity: CGFloat = 0.3
        static let showHideSpringVelocity: CGFloat = 0.5
        
        static let initialScale: CGFloat = 0.8
        static let bringToFrontScale: CGFloat = 1.02
    }
    
    // Original dock width from user settings (without auto-adjustment)
    private var originalDockWidth: CGFloat {
        let storedValue = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
        return storedValue > 0 ? CGFloat(storedValue) : Constants.defaultDockWidth
    }
    
    // Calculate adaptive dock width (auto-adjust when exceeding safe area)
    public var dockWidth: CGFloat {
        guard !apps.isEmpty else { return originalDockWidth }
        
        let totalVerticalMargin = Constants.adaptiveWidthVerticalMargin * 2
        let availableHeight = self.safeAreaHeight - totalVerticalMargin
        
        let maxSafeHeight = availableHeight * Constants.maxHeightRatioOfAvailableArea
        
        let userWidth = originalDockWidth
        let iconSize = calculateIconSize(for: userWidth)
        let requiredHeight = expandedDockHeight(for: userWidth, iconSize: iconSize)
        
        if requiredHeight > maxSafeHeight && !apps.isEmpty {
            let buttonSize = calculateButtonSize(for: userWidth)
            let baseHeight = expandedDockBaseHeight(for: userWidth, buttonSize: buttonSize)
            let availableForIcons = maxSafeHeight - baseHeight
            let maxAllowedIconSize = availableForIcons / CGFloat(apps.count)
            
            let targetIconSize = max(Constants.minAdaptiveIconSize, maxAllowedIconSize)
            
            let targetWidth = targetIconSize / Constants.iconToWidthRatio
            
            return max(Constants.minAdaptiveDockWidth, targetWidth)
        }
        
        return userWidth
    }
    
    // Calculate icon size based on dock width
    private func calculateIconSize(for width: CGFloat) -> CGFloat {
        let iconSize = width * Constants.iconToWidthRatio
        return max(Constants.minAdaptiveIconSize, min(Constants.maxIconSize, iconSize))
    }

    private func calculateButtonSize(for width: CGFloat) -> CGFloat {
        let targetSize = width * Constants.collapsedButtonToWidthRatio
        return max(Constants.minCollapsedButtonSize, min(Constants.maxCollapsedButtonSize, targetSize))
    }

    private func expandedDockBaseHeight(for width: CGFloat, buttonSize: CGFloat) -> CGFloat {
        let spacingCount = max(self.apps.count + 1, 0)
        let totalSpacingHeight = CGFloat(spacingCount) * Constants.dockContentSpacing
        return Constants.dockVerticalPadding + buttonSize * 2 + totalSpacingHeight
    }

    private func expandedDockHeight(for width: CGFloat, iconSize: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        let baseHeight = expandedDockBaseHeight(for: width, buttonSize: buttonSize)
        let iconHeight = CGFloat(self.apps.count) * iconSize
        return baseHeight + iconHeight
    }

    private func collapsedDockHeight(for width: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        return Constants.dockVerticalPadding + buttonSize
    }
    

    // Calculate adaptive icon size
    public var adaptiveIconSize: CGFloat {
        return calculateIconSize(for: dockWidth)
    }

    public var keyWindow: UIWindow? {
        // Once the virtual-host view is attached, its window is the only
        // authoritative host. A native guest scene can become key while the
        // switcher is visible; choosing that scene here detaches the virtual
        // surface and makes a subsequent card focus fail with EAGAIN.
        if let attachedWindow = windowHostingView.window,
           Self.isConnectedHostWindow(attachedWindow) {
            return attachedWindow
        }
        if let hostWindow, Self.isConnectedHostWindow(hostWindow) {
            return hostWindow
        }
        return Self.activeHostWindow()
    }

    public var safeAreaInsets: UIEdgeInsets {
        if #available(iOS 11.0, *) {
            return keyWindow?.safeAreaInsets ?? .zero
        }
        return .zero
    }

    private var safeAreaHeight: CGFloat {
        keyWindow!.bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
    }
    
    override init() {
        super.init()
        hostWindow = Self.activeHostWindow()
        raiseHostedSurfaces()
        setupDockView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: LCUtils.appGroupUserDefault
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    /// UIKit does not promise an ordering for `connectedScenes`; prefer the
    /// foreground key window and only then fall back to another visible host.
    private static func activeHostWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                let lhsActive = lhs.activationState == .foregroundActive
                let rhsActive = rhs.activationState == .foregroundActive
                if lhsActive != rhsActive { return lhsActive }

                let lhsKey = lhs.windows.contains(where: \.isKeyWindow)
                let rhsKey = rhs.windows.contains(where: \.isKeyWindow)
                if lhsKey != rhsKey { return lhsKey }

                return lhs.session.persistentIdentifier < rhs.session.persistentIdentifier
            }
        return scenes.lazy.compactMap { scene in
            scene.windows.first(where: \.isKeyWindow)
                ?? scene.windows.first(where: { !$0.isHidden && $0.rootViewController != nil })
                ?? scene.windows.first(where: { $0.rootViewController != nil })
        }.first
    }

    private static func isConnectedHostWindow(_ window: UIWindow) -> Bool {
        guard let scene = window.windowScene else { return false }
        return UIApplication.shared.connectedScenes.contains { $0 === scene }
    }

    /// Resolves and raises the window that owns VibeContainers' Springboard.
    ///
    /// Virtual guests are launched after an asynchronous preparation pass. By
    /// then another UIWindowScene can be connected or key, while a cold deep
    /// link can arrive before any arbitrary scene has a window. Keep using the
    /// recorded host whenever it is still connected, and return nil when no
    /// attached host exists so the launch bridge can fail instead of presenting
    /// a detached black view indefinitely.
    @objc(prepareHostWindowForGuestLaunch)
    public func prepareHostWindowForGuestLaunch() -> UIWindow? {
        dispatchPrecondition(condition: .onQueue(.main))

        if let attachedWindow = windowHostingView.window,
           Self.isConnectedHostWindow(attachedWindow) {
            hostWindow = attachedWindow
        } else if hostWindow.map(Self.isConnectedHostWindow) != true {
            hostWindow = Self.activeHostWindow()
        }

        guard let hostWindow, hostWindow.rootViewController != nil else {
            return nil
        }
        raiseHostedSurfaces()
        return hostWindow
    }

    /// Keep guest content above SwiftUI's private rendering subtree while also
    /// keeping every child controller's view inside its parent's hierarchy.
    /// The host view deliberately passes empty-space hits through, so raising
    /// it does not block Springboard after all guest cards are minimized.
    private func raiseHostedSurfaces() {
        guard let window = keyWindow,
              let rootView = window.rootViewController?.view else { return }
        hostWindow = window

        if windowHostingView.superview !== rootView {
            windowHostingView.removeFromSuperview()
            windowHostingView.frame = rootView.bounds
            windowHostingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            rootView.addSubview(windowHostingView)
        }
        rootView.bringSubviewToFront(windowHostingView)

        if let dockView = hostingController?.view,
           let dockSuperview = dockView.superview {
            dockSuperview.bringSubviewToFront(dockView)
        }
    }

    private func attachDockController(
        _ hostingController: UIHostingController<AnyView>,
        to rootViewController: UIViewController
    ) {
        if hostingController.parent !== rootViewController {
            if hostingController.parent != nil {
                hostingController.willMove(toParent: nil)
                hostingController.view.removeFromSuperview()
                hostingController.removeFromParent()
            }
            rootViewController.addChild(hostingController)
            rootViewController.view.addSubview(hostingController.view)
            hostingController.didMove(toParent: rootViewController)
        } else if hostingController.view.superview !== rootViewController.view {
            rootViewController.view.addSubview(hostingController.view)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.async {
            if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    @objc private func userDefaultsDidChange() {
        DispatchQueue.main.async {
            self.settingsChanged.toggle()
            if self.isVisible {
                // The size slider writes continuously. Tracking those writes
                // directly avoids stacking a new spring on every intermediate
                // value and briefly ballooning the dock past its target size.
                self.updateDockFrame(animated: false)
            }
        }
    }
    
    private func setupDockView() {
        DispatchQueue.main.async {
            let dockView = AnyView(MultitaskDockSwiftView()
                .environmentObject(self))
            
            self.hostingController = UIHostingController(rootView: dockView)
            self.hostingController?.view.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
            self.hostingController?.view.backgroundColor = .clear
        }
    }

    private func updateDockFrame(animated: Bool = true) {
        guard let hostingController = hostingController else { return }

        let screenBounds = keyWindow!.bounds
        let currentDockWidth = self.dockWidth
        
        let dockHeight = calculateTargetDockHeight(forWidth: currentDockWidth)

        let currentFrame = hostingController.view.frame
        let isOnRightSide = (currentFrame.midX > screenBounds.width / 2) || (currentFrame.isEmpty)
        let targetX = calculateTargetX(isDockHidden: self.isDockHidden, 
                                    isOnRightSide: isOnRightSide, 
                                    dockWidth: currentDockWidth, 
                                    screenWidth: screenBounds.width)

        let targetY = calculateTargetY(for: currentFrame, 
                                    dockHeight: dockHeight, 
                                    screenHeight: screenBounds.height)
        
        let newFrame = CGRect(x: targetX, y: targetY, width: currentDockWidth, height: dockHeight)
        
        applyNewFrame(newFrame, for: hostingController, animated: animated)
    }

    // MARK: - Frame Calculation Helpers

    private func calculateTargetDockHeight(forWidth width: CGFloat) -> CGFloat {
        if isCollapsed {
            let collapsedHeight = collapsedDockHeight(for: width)
            return max(Constants.minCollapsedHeight, collapsedHeight)
        } else {
            let currentIconSize = calculateIconSize(for: width)
            return expandedDockHeight(for: width, iconSize: currentIconSize)
        }
    }

    func calculateTargetX(isDockHidden: Bool, isOnRightSide: Bool, dockWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {

        let safeInsets = self.safeAreaInsets
        var ans : CGFloat
        if isOnRightSide {
            ans = screenWidth - dockWidth
            if self.hostingController?.view.window?.windowScene?.interfaceOrientation == UIInterfaceOrientation.landscapeLeft {
                ans -= safeInsets.right
            }
            
            if isDockHidden {
                ans += Constants.dockHiddenOffset
            }
        } else {
            ans = 0
            if self.hostingController?.view.window?.windowScene?.interfaceOrientation == UIInterfaceOrientation.landscapeRight {
                ans += safeInsets.left
            }
            if isDockHidden {
                ans -= Constants.dockHiddenOffset
            }
        }
        
        return ans;

    }

    private func calculateTargetY(for currentFrame: CGRect, dockHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let safeAreaMinY = self.safeAreaInsets.top + Constants.dockVerticalMargin
        let safeAreaMaxY = screenHeight - self.safeAreaInsets.bottom - dockHeight - Constants.dockVerticalMargin
        
        if currentFrame.height > 0 {
            let desiredY = currentFrame.midY - dockHeight / 2
            return max(safeAreaMinY, min(safeAreaMaxY, desiredY))
        } else {
            let safeAreaCenterY = safeAreaMinY + (safeAreaMaxY - safeAreaMinY) / 2
            return max(safeAreaMinY, min(safeAreaMaxY, safeAreaCenterY - dockHeight / 2))
        }
    }

    private func applyNewFrame(_ newFrame: CGRect, for hostingController: UIHostingController<AnyView>, animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                hostingController.view.frame = newFrame
            }
        } else {
            hostingController.view.frame = newFrame
        }
    }
    
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }
    
    @objc public func removeRunningApp(_ appUUID: String) {
        DispatchQueue.main.async {
            let didRemove = self.apps.contains { $0.appUUID == appUUID }
            self.apps.removeAll { $0.appUUID == appUUID }
            self.appSwitcherPreviewCache.removeValue(forKey: appUUID)
            self.appSwitcherPreviewViewCache.removeValue(forKey: appUUID)

            if didRemove {
                NotificationCenter.default.post(
                    name: Notification.Name("IOSSimMultitaskGuestDidClose"),
                    object: nil,
                    userInfo: ["dataUUID": appUUID]
                )
            }

            // Native-window mode still needs lifecycle bookkeeping for the
            // host switcher; only the floating dock UI is mode-specific.
            guard self.isDockEnabled() else { return }
            
            if self.apps.isEmpty {
                self.hideDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
        }
    }

    /// Closes every virtual or native guest window. Used by the Live Activity
    /// Exit action, which runs outside the host's SwiftUI hierarchy.
    @objc public func terminateAllApps() {
        let controllers = apps.compactMap {
            $0.view?._viewDelegate() as? DecoratedAppSceneViewController
        }
        controllers.forEach { $0.closeWindow() }
        if #available(iOS 16.1, *) {
            MultitaskWindowManager.terminateAllAppWindows()
        }
    }

    /// Focuses a virtual hosted view or reactivates a native UIWindowScene.
    /// The C bridge calls this small Objective-C-visible surface so the host
    /// switcher does not need to know which presentation mode owns the guest.
    @objc public func focusApp(_ appUUID: String) -> Bool {
        focusAppResult(appUUID) == 0
    }

    /// Preserves the distinction between an absent registry entry and a live
    /// guest whose host surface is temporarily detached. The parent bridge
    /// uses ENOENT to retire stale cards, while EAGAIN remains retryable.
    @objc public func focusAppResult(_ appUUID: String) -> Int32 {
        if let app = apps.first(where: { $0.appUUID == appUUID }), app.view != nil {
            guard bringMultitaskViewToFront(uuid: appUUID) else {
                NSLog("VibeContainers: virtual focus %@ is temporarily unavailable", appUUID)
                return Int32(EAGAIN)
            }
            NSLog("VibeContainers: focus bridge %@ resolved to virtual surface", appUUID)
            return 0
        }
        if #available(iOS 16.1, *) {
            let focused = MultitaskWindowManager.openExistingAppWindow(dataUUID: appUUID)
            NSLog(
                "VibeContainers: focus bridge %@ resolved to native scene: %@",
                appUUID,
                focused ? "yes" : "no"
            )
            if focused { return 0 }
            if apps.contains(where: { $0.appUUID == appUUID }) {
                return Int32(EAGAIN)
            }
        }
        NSLog("VibeContainers: focus bridge %@ found no guest surface", appUUID)
        return Int32(ENOENT)
    }

    /// Terminates exactly one guest in either presentation mode.
    @objc public func terminateApp(_ appUUID: String) -> Bool {
        if let app = apps.first(where: { $0.appUUID == appUUID }),
           let controller = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
            controller.closeWindow()
            return true
        }
        if #available(iOS 16.1, *) {
            return MultitaskWindowManager.terminateAppWindow(dataUUID: appUUID)
        }
        return false
    }

    /// Reveals VibeContainers' adaptive app switcher after clearing the guest
    /// windows from the host surface. The processes themselves keep running.
    @objc public func presentAppSwitcher() {
        presentAppSwitcher(animated: true)
    }

    /// The visible guest's close button must land directly in the switcher.
    /// Suppressing only that insertion avoids a frame of Home between the
    /// guest disappearing and the host overlay becoming visible.
    @objc public func presentAppSwitcherWithoutAnimation() {
        presentAppSwitcher(animated: false)
    }

    private func presentAppSwitcher(animated: Bool) {
        let present = {
            let startedAt = ProcessInfo.processInfo.systemUptime
            let previews = self.captureAppSwitcherPreviews()
            let previewViews = self.captureAppSwitcherPreviewViews()
            self.hideGuestSurfacesForAppSwitcher()
            NotificationCenter.default.post(
                name: Notification.Name("IOSSimShowContainerSwitcher"),
                object: nil,
                userInfo: [
                    "previews": previews,
                    "previewViews": previewViews,
                    "animated": animated,
                ]
            )
            NSLog(
                "VibeContainers: presented switcher with %ld cached preview(s) in %.1f ms",
                max(previews.count, previewViews.count),
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            )
        }

        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async(execute: present)
        }
    }

    /// A switcher presentation is a state transition, not a request to start
    /// several independent minimize animations. Hide every virtual surface in
    /// one main-thread transaction so a quick card tap cannot be undone by a
    /// late minimize completion. Hidden views remain attached and their guest
    /// processes continue running.
    private func hideGuestSurfacesForAppSwitcher() {
        dispatchPrecondition(condition: .onQueue(.main))
        apps.forEach { app in
            guard let view = app.view else { return }
            view.layer.removeAllAnimations()
            view.transform = .identity
            view.alpha = 0
            view.isHidden = true
            view.superview?.sendSubviewToBack(view)
        }
    }
    
    @objc public func showDock() {
        guard isDockEnabled() else { return }
        guard !isVisible, let hostingController = hostingController else { return }
        
        guard let keyWindow = self.keyWindow,
              let rootViewController = keyWindow.rootViewController else { return }
        
        DispatchQueue.main.async {
            self.raiseHostedSurfaces()
            self.isVisible = true
            
            let screenBounds = keyWindow.bounds
            let currentDockWidth = self.dockWidth
            let initialHeight = Constants.initialDockShowHeight
            
            // If not already in view hierarchy, add it
            if hostingController.view.superview == nil {
                hostingController.view.frame = CGRect(
                    x: screenBounds.width - currentDockWidth,
                    y: (screenBounds.height - initialHeight) / 2,
                    width: currentDockWidth,
                    height: initialHeight
                )
            }
            self.attachDockController(hostingController, to: rootViewController)
            hostingController.view.superview?.bringSubviewToFront(hostingController.view)
            
            self.updateDockFrame(animated: false) 
            
            self.setupEdgeGestureRecognizers()
            
            hostingController.view.alpha = 0
            let initialScale = Constants.initialScale
            hostingController.view.transform = CGAffineTransform(scaleX: initialScale, y: initialScale)
            
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 1
                hostingController.view.transform = .identity
            }
        }
    }
    
    @objc public func hideDock() {
        guard isVisible, let hostingController = hostingController else { return }
        
        DispatchQueue.main.async {
            self.removeDockEdgeGestures()
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 0
                let finalScale = Constants.initialScale
                hostingController.view.transform = CGAffineTransform(scaleX: finalScale, y: finalScale)
                // Move off-screen to hide, but keep in view hierarchy
                let screenBounds = self.keyWindow!.bounds
                let currentDockWidth = self.dockWidth
                let targetX = self.calculateTargetX(isDockHidden: true, isOnRightSide: hostingController.view.frame.midX > screenBounds.width / 2, dockWidth: currentDockWidth, screenWidth: screenBounds.width)
                let targetY = hostingController.view.frame.origin.y // Keep current Y
                hostingController.view.frame.origin = CGPoint(x: targetX, y: targetY)
            } completion: { _ in
                self.isVisible = false
                hostingController.view.transform = .identity
            }
        }
    }

    @objc public func animateFrame(to finalFrame: CGRect) {
        guard let hostingController = self.hostingController else { return }
        
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0,
            usingSpringWithDamping: Constants.standardSpringDamping,
            initialSpringVelocity: Constants.standardSpringVelocity,
            options: .curveEaseOut
        ) {
            hostingController.view.frame = finalFrame
        }
    }

    @objc public func updateFrameAfterAnimation(finalOffset: CGSize) {
        guard let hostingController = self.hostingController else { return }
        
        let newFrame = hostingController.view.frame.offsetBy(dx: finalOffset.width, dy: finalOffset.height)
        
        hostingController.view.frame = newFrame
    }

    func handleSwipeToHideOrShowGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let screenWidth = keyWindow!.bounds.width
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        let isSwipingAway = (isOnRightSide && translation.width > 0) || (!isOnRightSide && translation.width < 0)
        
        if isSwipingAway {
            guard !self.isDockHidden else { return false }
            self.hideDockToSide()
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            return true
        } else {
            guard self.isDockHidden else { return false }
            self.showDockFromHidden()
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
            return true
        }
    }
    
    // Check if gesture is for cross-screen movement (left to right or vice versa)
    func isPositionChangeGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let horizontalDistance = abs(translation.width)
        let verticalDistance = abs(translation.height)
        
        guard !self.isDockHidden, horizontalDistance > verticalDistance else {
            return false
        }
        
        let screenWidth = keyWindow!.bounds.width
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        
        guard !self.isDockHidden else { return false }
        
        let isMovingToOtherSide = (isOnRightSide && translation.width < 0) || (!isOnRightSide && translation.width > 0)
        guard isMovingToOtherSide else { return false }
        
        let draggedX = originalFrame.origin.x + translation.width
        let screenCenter = screenWidth / 2
        
        if isOnRightSide {
            return draggedX < screenCenter
        } else {
            return (draggedX + originalFrame.width) > screenCenter
        }
    }
    
    // Find and bring corresponding multitask view to front
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let targetView = apps.first(where: { $0.appUUID == uuid })?.view else {
            NSLog("VibeContainers: no virtual surface registered for %@", uuid)
            return false
        }
        raiseHostedSurfaces()
        guard targetView.superview === windowHostingView,
              let attachedHostWindow = windowHostingView.window,
              targetView.window === attachedHostWindow else {
            NSLog(
                "VibeContainers: virtual surface %@ is detached (surface=%@ host=%@ targetWindow=%@ recordedWindow=%@)",
                uuid,
                String(describing: ObjectIdentifier(targetView)),
                String(describing: ObjectIdentifier(windowHostingView)),
                String(describing: targetView.window),
                String(describing: keyWindow)
            )
            return false
        }
        hostWindow = attachedHostWindow
        let beforeSnapshot = phoneSurfaceSnapshot()
        passURLSchemeToView(targetView)
        if UIDevice.current.userInterfaceIdiom == .phone {
            focusPhoneFullscreenGuest(targetView, dataUUID: uuid)
        } else if let window = targetView.window ?? keyWindow {
            animateViewAppearance(targetView, from: center, in: window)
        }

        let focused = targetView.superview === windowHostingView
            && windowHostingView.subviews.last === targetView
            && !targetView.isHidden
            && targetView.alpha > 0.99
            && targetView.window != nil
        NSLog(
            "VibeContainers: virtual focus %@ %@ (surface=%@ top=%@ hostWindow=%@)",
            uuid,
            focused ? "succeeded" : "failed",
            String(describing: ObjectIdentifier(targetView)),
            String(describing: windowHostingView.subviews.last.map(ObjectIdentifier.init)),
            String(describing: windowHostingView.window)
        )
        if UIDevice.current.userInterfaceIdiom == .phone {
            NSLog(
                "VibeContainers: virtual focus %@ surfaces before=[%@] after=[%@]",
                uuid,
                beforeSnapshot,
                phoneSurfaceSnapshot()
            )
        }
        return focused
    }

    /// Captures only the ready foreground guest when the user explicitly opens
    /// the switcher, then returns the complete bitmap cache. Background cards
    /// retain the frame captured when they were previously foreground.
    @objc public func captureAppSwitcherPreviews() -> [String: UIImage] {
        dispatchPrecondition(condition: .onQueue(.main))
        // Bitmap previews are detached from FrontBoard. Never carry an older
        // IOSurface-backed UIView into a new switcher presentation.
        appSwitcherPreviewViewCache.removeAll(keepingCapacity: false)
        captureVisibleVirtualPreviews()
        if #available(iOS 16.1, *) {
            for app in apps where app.view == nil {
                let capture = MultitaskWindowManager.capturePreview(
                    dataUUID: app.appUUID
                )
                updatePreviewCaches(with: capture, dataUUID: app.appUUID)
            }
        }
        return appSwitcherPreviewCache
    }

    /// Returns the view cache populated by `captureAppSwitcherPreviews()`.
    /// Keeping this accessor capture-free is important: the switcher includes
    /// both dictionaries in one notification and must not hit FrontBoard twice.
    @objc public func captureAppSwitcherPreviewViews() -> [String: UIView] {
        dispatchPrecondition(condition: .onQueue(.main))
        return appSwitcherPreviewViewCache
    }

    @discardableResult
    private func captureVisibleVirtualPreviews() -> Int {
        var captureCount = 0
        for app in apps {
            guard let view = app.view,
                  view.window != nil,
                  !view.isHidden,
                  view.alpha > 0.01 else { continue }
            let capture = captureAppSwitcherPreview(of: view)
            updatePreviewCaches(with: capture, dataUUID: app.appUUID)
            if capture != nil { captureCount += 1 }
        }
        return captureCount
    }

    /// Applies only verified output. Transient capture failures and uniform
    /// black placeholders leave the last useful frame untouched. Protected
    /// content is different: remove any retained surface immediately.
    @discardableResult
    private func updatePreviewCaches(
        with capture: LCSwitcherPreviewCapture?,
        dataUUID: String
    ) -> Bool {
        guard let capture else { return false }
        if capture.isProtectedContent {
            appSwitcherPreviewCache.removeValue(forKey: dataUUID)
            appSwitcherPreviewViewCache.removeValue(forKey: dataUUID)
            return true
        }

        var didUpdate = false
        if let image = capture.image {
            appSwitcherPreviewCache[dataUUID] = image
            appSwitcherPreviewViewCache.removeValue(forKey: dataUUID)
            didUpdate = true
        } else if let previewView = capture.previewView {
            if appSwitcherPreviewCache[dataUUID] == nil {
                appSwitcherPreviewViewCache[dataUUID] = previewView
            }
            didUpdate = true
        }
        return didUpdate
    }

    private func appSceneController(for view: UIView) -> AppSceneViewController? {
        if let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
            return decoratedVC.appSceneVC
        }
        return view._viewDelegate() as? AppSceneViewController
    }

    private func captureAppSwitcherPreview(
        of view: UIView
    ) -> LCSwitcherPreviewCapture? {
        appSceneController(for: view)?
            .captureSwitcherPreviewResult(withMaximumWidth: 430)
    }

    /// Returns UIKit's captured scene presentation view for direct rehosting
    /// inside the SwiftUI app-switcher card. A generic UIView snapshot omits
    /// the guest's cross-process IOSurface, so there is deliberately no local
    /// hierarchy-snapshot fallback here.
    func makeAppSwitcherPreviewView(of view: UIView) -> UIView? {
        captureAppSwitcherPreview(of: view)?.previewView
    }

    func renderAppSwitcherPreview(of view: UIView) -> UIImage? {
        // Hosted guest pixels live in FrontBoard's cross-process render
        // context, outside this UIView's local layer tree. Ask the scene
        // presenter for a real render-server snapshot before falling back to
        // ordinary hierarchy drawing for host-owned windows.
        if let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
            // Never replace a failed remote-scene capture with a local
            // hierarchy image: that hierarchy cannot contain guest pixels.
            return decoratedVC.appSceneVC
                .captureSwitcherPreviewResult(withMaximumWidth: 430)?.image
        }
        if let appSceneVC = view._viewDelegate() as? AppSceneViewController {
            return appSceneVC
                .captureSwitcherPreviewResult(withMaximumWidth: 430)?.image
        }

        let sourceBounds = view.bounds.standardized
        guard sourceBounds.width >= 1, sourceBounds.height >= 1 else { return nil }

        view.layoutIfNeeded()
        let targetScale = min(1, 430 / sourceBounds.width)
        let targetSize = CGSize(
            width: max(1, sourceBounds.width * targetScale),
            height: max(1, sourceBounds.height * targetScale)
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            context.cgContext.saveGState()
            context.cgContext.scaleBy(x: targetScale, y: targetScale)
            context.cgContext.translateBy(x: -sourceBounds.minX, y: -sourceBounds.minY)
            if !view.drawHierarchy(in: sourceBounds, afterScreenUpdates: false) {
                view.layer.render(in: context.cgContext)
            }
            context.cgContext.restoreGState()
        }
    }

    private func phoneSurfaceSnapshot() -> String {
        apps.map { app in
            guard let view = app.view else { return "\(app.appUUID):native" }
            let index = view.superview?.subviews.firstIndex(where: { $0 === view }) ?? -1
            let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
            let appSceneVC = decoratedVC?.appSceneVC
            let sceneID = appSceneVC?.presenter?.identifier ?? "none"
            let presenterActive = appSceneVC?.presenter?.isActive() ?? false
            return "\(app.appUUID){pid=\(appSceneVC?.pid ?? 0),scene=\(sceneID),active=\(presenterActive),index=\(index),hidden=\(view.isHidden),alpha=\(view.alpha)}"
        }.joined(separator: ",")
    }

    /// iPhone virtual mode is a single full-screen stage. Keeping every guest
    /// view visible and merely reordering it allowed the bridge to report a
    /// successful focus while another remote surface remained effective. Hide
    /// non-target surfaces synchronously; their LiveProcess instances and
    /// hosted scenes continue running and can be restored without relaunch.
    private func focusPhoneFullscreenGuest(_ targetView: UIView, dataUUID: String) {
        apps.forEach { app in
            guard let view = app.view else { return }
            view.layer.removeAllAnimations()
            view.transform = .identity
            if view === targetView {
                view.isHidden = false
                view.alpha = 1
            } else {
                view.alpha = 0
                view.isHidden = true
                view.superview?.sendSubviewToBack(view)
            }
        }
        guard let window = targetView.window ?? keyWindow else { return }
        bringViewToFront(targetView, in: window)
        if targetView._viewDelegate() as? DecoratedAppSceneViewController == nil {
            NSLog("VibeContainers: focused surface %@ has no decorated controller", dataUUID)
        }
        // Do not ask UIKit for a render-server snapshot while a newly attached
        // guest is still completing its first safe-area/layout transaction.
        // On iOS 27, captureSnapshotPresentationView during that window can
        // abort Swift-based guests from UIKit's unowned safe-area callback.
        // The explicit app-switcher action captures the now-ready foreground
        // scene once, before it is hidden, so no eager retry is necessary.
    }

    private func passURLSchemeToView(_ view: UIView) {
        if let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            if let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
                decoratedVC.appSceneVC.openURLScheme(launchUrl)
            }
        }
    }

    private func animateViewAppearance(_ view: UIView, from center: CGPoint?, in window: UIWindow) {
        let isHidden = view.isHidden || view.alpha < 0.1
        let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
        let isMaximized = decoratedVC?.isMaximized ?? false
        
        // when a fullscreen multitask app is brought to front, optionally hide other windows
        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized {
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC)
        }
        
        if isHidden {
            view.layer.removeAllAnimations()
            view.isHidden = true
            view.transform = .identity
            let origFrame = view.frame
            let pipManager = PiPManager.shared!
            if let decoratedVC = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: decoratedVC) {
                pipManager.stopPiP()
            } else {
                view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                view.isHidden = false
                let smaller = min(view.frame.size.width, view.frame.size.height)
                view.frame.size = CGSize(width: smaller, height: smaller)
                if let center { view.center = center }
            }
            
            self.bringViewToFront(view, in: window)
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: .curveEaseInOut,
                animations: {
                    view.alpha = 1.0
                    view.transform = .identity
                    view.frame = origFrame
                }
            )
        } else {
            bringViewToFront(view, in: window)
            
            UIView.animate(withDuration: Constants.shortAnimationDuration1, animations: {
                let scale = Constants.bringToFrontScale
                view.transform = CGAffineTransform(scaleX: scale, y: scale)
            }) { _ in
                UIView.animate(withDuration: Constants.shortAnimationDuration2) {
                    view.transform = .identity
                }
            }
        }
    }

    private func bringViewToFront(_ view: UIView, in window: UIWindow) {
        raiseHostedSurfaces()
        if let superview = view.superview {
            superview.bringSubviewToFront(view)
        }
        if let dockView = hostingController?.view,
           let dockSuperview = dockView.superview {
            dockSuperview.bringSubviewToFront(dockView)
        }
    }
    
    // Recursively find multitask view
    private func findMultitaskView(in view: UIView, withUUID uuid: String) -> UIView? {
        apps.first { $0.appUUID == uuid }?.view
    }
    
    // Get view's dataUUID property through reflection
    private func getDataUUID(from view: UIView) -> String? {
        let mirror = Mirror(reflecting: view)
        
        if let child = (mirror.children.first { $0.label == "dataUUID" })?.value as? String {
            return child
        }
        
        if view.responds(to: NSSelectorFromString("dataUUID")) {
            return view.value(forKey: "dataUUID") as? String
        }
        
        return nil
    }
    
    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        let appName = appInfo?.displayName() ?? "Unknown App"
        let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)
        
        DispatchQueue.main.async {
            self.raiseHostedSurfaces()
            guard !self.apps.contains(where: { $0.appUUID == appUUID }) else { return }
            self.apps.append(appModel)
            if UIDevice.current.userInterfaceIdiom == .phone,
               let view,
               view.superview === self.windowHostingView,
               view.window != nil {
                self.focusPhoneFullscreenGuest(view, dataUUID: appUUID)
            }
            NotificationCenter.default.post(
                name: Notification.Name("IOSSimMultitaskGuestDidOpen"),
                object: nil,
                userInfo: [
                    "displayName": appName,
                    "dataUUID": appUUID
                ]
            )

            // Keep native scenes in the lifecycle registry without displaying
            // LiveContainer's floating virtual-window dock for them.
            guard self.isDockEnabled() else { return }
            
            if self.apps.count == 1 {
                self.showDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        DispatchQueue.main.async {
            self.apps.forEach { app in
                if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
                   vc != except {
                    app.view?.layer.removeAllAnimations()
                    vc.minimizeWindow()
                }
            }
        }
    }
    
    @objc public func toggleDockCollapse() {
        DispatchQueue.main.async {
            self.isCollapsed.toggle()
            self.notifyDockCollapseChanged()
        }
    }
    
    @objc public func notifyDockCollapseChanged() {
        self.updateDockFrame()
        // find fullscreen apps and hide its UINavigationBar
        self.apps.forEach { app in
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController, vc.isMaximized {
                vc.updateVerticalConstraints()
            }
        }
    }
    
    // Toggle dock hide/show state
    @objc public func toggleDockVisibility() {
        DispatchQueue.main.async {
            self.isDockHidden.toggle()
            self.updateDockFrame()
        }
    }
    
    @objc public func showDockFromHidden() {
        DispatchQueue.main.async {
            self.isDockHidden = false
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }
    
    @objc public func hideDockToSide() {
        DispatchQueue.main.async {
            self.isDockHidden = true
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }
    
    // Add edge gesture recognition areas when dock is hidden
    private func setupEdgeGestureRecognizers() {
        removeDockEdgeGestures()
        guard let gestureHost = keyWindow?.rootViewController?.view else { return }
        
        if isDockHidden {
            let leftEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            leftEdgeGesture.edges = .left
            leftEdgeGesture.cancelsTouchesInView = false
            gestureHost.addGestureRecognizer(leftEdgeGesture)
            
            let rightEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            rightEdgeGesture.edges = .right
            rightEdgeGesture.cancelsTouchesInView = false
            gestureHost.addGestureRecognizer(rightEdgeGesture)
            dockEdgeGestures = [leftEdgeGesture, rightEdgeGesture]
        }
    }

    private func removeDockEdgeGestures() {
        dockEdgeGestures.forEach { gesture in
            gesture.view?.removeGestureRecognizer(gesture)
        }
        dockEdgeGestures.removeAll()
    }
    
    @objc private func handleEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard isDockHidden, gesture.state == .began || gesture.state == .changed else {
            return
        }
        
        let translation = gesture.translation(in: gesture.view)
        let swipeDistance = abs(translation.x)
        
        if swipeDistance > Constants.edgeSwipeThreshold {
            showDockFromHidden()
        }
    }
    
    // MARK: - Multitask Mode Check
    private func isDockEnabled() -> Bool {
        // Phones present a single edge-to-edge guest and use the host's
        // full-screen card switcher. The floating dock/window rail is the iPad
        // Stage Manager affordance and should never cover a phone app scene.
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}

// MARK: - SwiftUI Dock View
@available(iOS 16.0, *)
public struct MultitaskDockSwiftView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @State private var dragOffset = CGSize.zero
    @State private var isMoving: Bool = false
    @AppStorage("LCHideCollapsedDock", store: LCUtils.appGroupUserDefault) var hideCollapsedDock: Bool = false
    
    // Calculate dynamic padding based on user settings
    private var dynamicPadding: CGFloat {
        let basePadding: CGFloat = 4
        let extraPadding = (dockManager.dockWidth - MultitaskDockManager.Constants.defaultDockWidth) * 0.2
        return max(basePadding, basePadding + extraPadding)
    }
    
    public var body: some View {
        GeometryReader { g in
            VStack(spacing: 8) {
                if dockManager.isCollapsed {
                    CollapsedDockView(isHidden: dockManager.isDockHidden)
                        .onTapGesture {
                            dockManager.toggleDockCollapse()
                        }
                } else {
                    VStack(spacing: 8) {
                        CollapseButtonView()
                            .onTapGesture {
                                dockManager.toggleDockCollapse()
                            }
                        
                        MinimizeAllButtonView()
                            .onTapGesture {
                                dockManager.minimizeAllWindows()
                            }
                        
                        ForEach(dockManager.apps) { app in
                            AppIconView(app: app)
                        }
                    }
                }
            }
            .padding(dynamicPadding)
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content.glassEffect(.regular, in: .rect(cornerRadius: 15))
                } else {
                    content.background(
                        RoundedRectangle(cornerRadius: 15)
                            .fill(Color.black.opacity(dockManager.isDockHidden ? 0.3 : 0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(Color.white.opacity(dockManager.isDockHidden ? 0.1 : 0.3), lineWidth: 1)
                            )
                    )
                }
            }
            .scaleEffect(dockManager.isVisible ? 1.0 : 0.8)
            .opacity(dockManager.isDockHidden ? (hideCollapsedDock && dockManager.isCollapsed ? 0.01 : 0.4) : 1.0)
            .offset(dragOffset)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }



        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 5)
            .onChanged { value in
                self.isMoving = true
                self.dragOffset = value.translation
            }
            .onEnded { value in
                self.isMoving = true

                let hcFrame = dockManager.hostingController?.view.frame ?? .zero
                
                let currentPhysicalFrame = hcFrame.offsetBy(dx: self.dragOffset.width, dy: self.dragOffset.height)
                
                if dockManager.isPositionChangeGesture(for: hcFrame, translation: value.translation) {
                    let screenBounds = dockManager.keyWindow!.bounds
                    let targetX = dockManager.calculateTargetX(isDockHidden: false, isOnRightSide: currentPhysicalFrame.midX > screenBounds.width / 2, dockWidth: dockManager.dockWidth, screenWidth: screenBounds.width)
                    
                    let safeAreaInsets = dockManager.safeAreaInsets
                    let dockVerticalMargin = MultitaskDockManager.Constants.dockVerticalMargin
                    let minY = safeAreaInsets.top + dockVerticalMargin
                    let maxY = screenBounds.height - safeAreaInsets.bottom - currentPhysicalFrame.height - dockVerticalMargin
                    let targetY = max(minY, min(maxY, currentPhysicalFrame.origin.y))
                    
                    let finalPhysicalPosition = CGPoint(x: targetX, y: targetY)
                    
                    let newOffset = CGSize(
                        width: finalPhysicalPosition.x - hcFrame.origin.x,
                        height: finalPhysicalPosition.y - hcFrame.origin.y
                    )
                    
                    let animationDuration = MultitaskDockManager.Constants.longAnimationDuration
                    
                    withAnimation(.spring(response: animationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                        self.dragOffset = newOffset
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                        dockManager.updateFrameAfterAnimation(finalOffset: newOffset)
                        
                        self.dragOffset = .zero
                        
                        self.isMoving = false
                    }
                    return
                }
                
                if dockManager.handleSwipeToHideOrShowGesture(for: hcFrame, translation: value.translation) {
                    withAnimation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                        self.dragOffset = .zero
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + MultitaskDockManager.Constants.longAnimationDuration) {
                        self.isMoving = false
                    }
                    return
                }
                
                let screenBounds = dockManager.keyWindow!.bounds
                let safeAreaInsets = dockManager.safeAreaInsets
                let dockVerticalMargin = MultitaskDockManager.Constants.dockVerticalMargin
                let minY = safeAreaInsets.top + dockVerticalMargin
                let maxY = screenBounds.height - safeAreaInsets.bottom - currentPhysicalFrame.height - dockVerticalMargin
                let targetY = max(minY, min(maxY, currentPhysicalFrame.origin.y))
                
                let targetX: CGFloat

                let isOnRightSide = hcFrame.origin.x > screenBounds.width / 2
                targetX = dockManager.calculateTargetX(isDockHidden: dockManager.isDockHidden, isOnRightSide: isOnRightSide, dockWidth: currentPhysicalFrame.width, screenWidth: screenBounds.width)
                
                let finalPhysicalPosition = CGPoint(x: targetX, y: targetY)
                
                let newOffset = CGSize(
                    width: finalPhysicalPosition.x - hcFrame.origin.x,
                    height: finalPhysicalPosition.y - hcFrame.origin.y
                )
                
                let animationDuration = MultitaskDockManager.Constants.longAnimationDuration
                
                withAnimation(.spring(response: animationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                    self.dragOffset = newOffset
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                    dockManager.updateFrameAfterAnimation(finalOffset: newOffset)
                    
                    self.dragOffset = .zero
                    
                    self.isMoving = false
                }
            }
        )
        .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.isCollapsed)
        .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.isDockHidden)
    }
    
    public init() {}
}

// MARK: - Collapsed Dock View
@available(iOS 16.0, *)
struct CollapsedDockView: View {
    let isHidden: Bool
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.blue.opacity(isHidden ? 0.4 : 0.8),
                            Color.blue.opacity(isHidden ? 0.3 : 0.6)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            
            Group {
                if isHidden {
                    Image(systemName: "eye.slash")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.system(size: dockManager.adaptiveIconSize * 0.35, weight: .bold))
                } else {
                    Image(systemName: "chevron.up")
                        .foregroundColor(.white)
                        .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .bold))
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(isHidden ? 0.2 : 0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
        .scaleEffect(isHidden ? 0.9 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHidden)
    }
}

// MARK: - Collapse Button View
@available(iOS 16.0, *)
struct CollapseButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)  
                .fill(Color.gray.opacity(0.8))
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            
            Image(systemName: "chevron.down")
                .foregroundColor(.white)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)  
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Minimize All Button View
@available(iOS 16.0, *)
struct MinimizeAllButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.8))
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            
            Image(systemName: "rectangle.stack.badge.minus")
                .foregroundColor(.white)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Icon Cache Manager
class IconCacheManager {
    static let shared = IconCacheManager()
    private var cache: [String: UIImage] = [:]
    private let cacheQueue = DispatchQueue(label: "icon.cache.queue", attributes: .concurrent)
    
    private init() {}
    
    func getIcon(for key: String) -> UIImage? {
        return cacheQueue.sync {
            return cache[key]
        }
    }
    
    func setIcon(_ icon: UIImage, for key: String) {
        cacheQueue.async(flags: .barrier) {
            self.cache[key] = icon
        }
    }
    
    func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }
}
// MARK: - App Icon View
@available(iOS 16.0, *)
struct AppIconView: View {
    let app: DockAppModel
    @State private var isPressed = false
    @State private var appIcon: UIImage?
    @State private var isLoading = true
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    private var iconSize: CGFloat {
        return dockManager.adaptiveIconSize
    }
    
    var body: some View {
        Group {
            if isLoading && appIcon == nil {
                LoadingIconView()
            } else if let icon = appIcon {
                IconImageView(icon: icon)
            } else {
                RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.3))
            }
        }
        .frame(width: iconSize, height: iconSize)
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
        .scaleEffect(isPressed ? 1.15 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .onAppear {
            loadAppIcon()
        }
        .onPressGesture(
            onPress: { 
                isPressed = true
            },
            onRelease: { location in 
                isPressed = false
                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                impactFeedback.impactOccurred()
                let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID, from: location)
            }
        )
        .contentShape(Rectangle())
    }
    
    private func loadAppIcon() {
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        
        if let cachedIcon = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cachedIcon
            self.isLoading = false
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var finalIcon: UIImage?
            
            if let appInfo = self.app.appInfo {
                finalIcon = appInfo.iconIsDarkIcon(darkModeIcon)
            } else {
                if let foundAppInfo = AppInfoProvider.shared.findAppInfo(appName: self.app.appName, dataUUID: self.app.appUUID) {
                    finalIcon = foundAppInfo.iconIsDarkIcon(darkModeIcon)
                }
            }
            
            DispatchQueue.main.async {
                self.isLoading = false
                if let icon = finalIcon {
                    self.appIcon = icon
                    IconCacheManager.shared.setIcon(icon, for: cacheKey)
                }
            }
        }
    }
}

// MARK: - Press Gesture Helper
extension View {
    func onPressGesture(onPress: @escaping () -> Void, onRelease: @escaping (_ location: CGPoint) -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if value.translation == CGSize.zero {
                        onPress()
                    }
                }
                .onEnded { value in
                    onRelease(value.startLocation)
                }
        )
    }
}

// MARK: - Loading Icon View
struct LoadingIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
        }
    }
}
