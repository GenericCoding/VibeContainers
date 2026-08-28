import UIKit
import SwiftUI
import Intents

@objc class AppDelegate: UIResponder, UIApplicationDelegate {
        
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? ) -> Bool {
        application.shortcutItems = nil
        UserDefaults.standard.removeObject(forKey: "LCNeedToAcquireJIT")
        
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // Fix launching app if user opens JIT waiting dialog and kills the app. Won't trigger normally.
            if DataManager.shared.model.isJITModalOpen && !UserDefaults.standard.bool(forKey: "LCKeepSelectedWhenQuit"){
                UserDefaults.standard.removeObject(forKey: "selected")
                UserDefaults.standard.removeObject(forKey: "selectedContainer")
            }
        }
        
        MultitaskGuestSceneRuntime.installHostSupport()

        // remove symbol caches if user upgraded iOS
        if let lastIOSBuildVersion = LCUtils.appGroupUserDefault.string(forKey: "LCLastIOSBuildVersion"),
           let currentVersion = UIDevice.current.buildVersion,
           lastIOSBuildVersion == currentVersion {
            
        } else {
            LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
            LCUtils.appGroupUserDefault.setValue(UIDevice.current.buildVersion, forKey: "LCLastIOSBuildVersion")
        }
        
        return true
    }
    
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
    
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        switch intent {
        case is VBCViewAppIntent: return VBCViewAppIntentHandler()
        default:
            return nil
        }
    }
}

class SceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject { // Make SceneDelegate conform ObservableObject
    /// SwiftUI creates and owns the scene's window. During `willConnectTo` that
    /// window is not guaranteed to be key (or even present in `windows`) yet,
    /// so the scene itself is the stable identity used by multitasking.
    private weak var managedWindow: UIWindow?
    private(set) weak var windowScene: UIWindowScene?

    var window: UIWindow? {
        get {
            managedWindow
                ?? windowScene?.windows.first(where: \.isKeyWindow)
                ?? windowScene?.windows.first(where: { !$0.isHidden })
                ?? windowScene?.windows.first
        }
        set {
            managedWindow = newValue
            if let scene = newValue?.windowScene {
                windowScene = scene
            }
        }
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        windowScene = scene as? UIWindowScene
        managedWindow = windowScene?.windows.first(where: \.isKeyWindow)
            ?? windowScene?.windows.first(where: { !$0.isHidden })
            ?? windowScene?.windows.first
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let scene = scene as? UIWindowScene else { return }
        windowScene = scene
        managedWindow = scene.windows.first(where: \.isKeyWindow)
            ?? scene.windows.first(where: { !$0.isHidden })
            ?? scene.windows.first
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if #available(iOS 16.1, *) {
            MultitaskWindowManager.unregister(session: scene.session)
        }
        if windowScene === scene {
            managedWindow = nil
            windowScene = nil
        }
    }
    
}

/// Installs the UIKit behavior required by native guest UIWindowScenes in any
/// app embedding LiveContainerSwiftUI. The lazy token makes this safe when both
/// LiveContainer's AppDelegate and an embedding host initialize the runtime.
public enum MultitaskGuestSceneRuntime {
    private static let sceneActivationHook: Void = {
        guard let original = class_getInstanceMethod(
            UIApplication.self,
            #selector(UIApplication.requestSceneSessionActivation(_:userActivity:options:errorHandler:))
        ), let replacement = class_getInstanceMethod(
            UIApplication.self,
            #selector(UIApplication.hook_requestSceneSessionActivation(_:userActivity:options:errorHandler:))
        ) else {
            return
        }
        method_exchangeImplementations(original, replacement)
    }()

    @MainActor
    public static func installHostSupport() {
        _ = sceneActivationHook
    }
}


@objc extension UIApplication {
    
    func hook_requestSceneSessionActivation(
        _ sceneSession: UISceneSession?,
        userActivity: NSUserActivity?,
        options: UIScene.ActivationRequestOptions?,
        errorHandler: ((any Error) -> Void)? = nil
    ) {
        var newOptions = options
        if newOptions == nil {
            newOptions = UIScene.ActivationRequestOptions()
        }
        let activeWindow = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                let lhsActive = lhs.activationState == .foregroundActive
                let rhsActive = rhs.activationState == .foregroundActive
                return lhsActive && !rhsActive
            }
            .lazy
            .compactMap { scene in
                scene.windows.first(where: \.isKeyWindow)
                    ?? scene.windows.first(where: { !$0.isHidden })
                    ?? scene.windows.first
            }
            .first
        let requestsFullscreen = UIDevice.current.userInterfaceIdiom == .phone
            || activeWindow.map { UIScreen.main.bounds == $0.bounds } == true
        newOptions?._setRequestFullscreen(requestsFullscreen)
        self.hook_requestSceneSessionActivation(
            sceneSession,
            userActivity: userActivity,
            options: newOptions,
            errorHandler: errorHandler
        )
    }
    
}

public class VBCViewAppIntentHandler: NSObject, VBCViewAppIntentHandling
{
    public func provideAppOptionsCollection(for intent: VBCViewAppIntent, with completion: @escaping (INObjectCollection<VBCApp>?, Error?) -> Void)
    {
        completion(INObjectCollection(items:[]), nil)
    }
}
