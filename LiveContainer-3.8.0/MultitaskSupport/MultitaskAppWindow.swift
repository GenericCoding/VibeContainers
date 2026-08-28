//
//  MultitaskAppWindow.swift
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
import SwiftUI

@available(iOS 16.1, *)
struct MultitaskAppInfo {
    var displayName: String
    var dataUUID: String
    var bundleId: String
    
    init(displayName: String, dataUUID: String, bundleId: String) {
        self.displayName = displayName
        self.dataUUID = dataUUID
        self.bundleId = bundleId
    }
}

@available(iOS 16.1, *)
@objc class MultitaskWindowManager: NSObject {
    private struct OpenWindowRequest {
        let id: String
        let dataUUID: String
        let targetHostSessionID: String?
    }

    static let openWindowRequestNotification = Notification.Name(
        "LCMultitaskOpenAppWindowRequest"
    )
    static var appDict: [String: MultitaskAppInfo] = [:]
    private static var sessions: [String: UISceneSession] = [:]
    private typealias PIDCallback = (NSNumber, Error?) -> Void
    private static var pidCallbacks: [String: [PIDCallback]] = [:]
    private static var runningPIDs: [String: Int32] = [:]
    private static var terminating: Set<String> = []
    private static var launchAttemptIDs: [String: UUID] = [:]
    private static var admissionOwnerIDs: [String: UUID] = [:]
    private static var openRequests: [String: OpenWindowRequest] = [:]
    private static var claimedOpenRequestIDs: Set<String> = []
    private static let launchTimeout: TimeInterval = 20
    /// The main VibeContainers scene is captured while it is frontmost, before
    /// SwiftUI asks UIKit to create a guest scene. `connectedScenes.first` is
    /// unordered once more than one container exists.
    private static weak var hostSession: UISceneSession?
    
    @objc class func openAppWindow(displayName: String, dataUUID: String, bundleId: String, pidCallback: ((NSNumber, Error?) -> Void)?) {
        rememberHostSession()
        // A second request may only coalesce with a launch that is genuinely
        // pending or a process that is known to be running. A dead scene must
        // never report a synthetic PID-0 success to the host.
        if terminating.contains(dataUUID) {
            pidCallback?(NSNumber(value: 0), lifecycleError(
                code: EBUSY,
                message: "The previous guest scene is still closing. Try again in a moment."
            ))
            return
        }
        if appDict[dataUUID] != nil {
            if var callbacks = pidCallbacks[dataUUID] {
                if let pidCallback { callbacks.append(pidCallback) }
                pidCallbacks[dataUUID] = callbacks
                return
            }
            if let pid = runningPIDs[dataUUID] {
                _ = openExistingAppWindow(dataUUID: dataUUID)
                pidCallback?(NSNumber(value: pid), nil)
                return
            }
            if sessions[dataUUID] != nil {
                beginSceneDestruction(dataUUID: dataUUID)
                pidCallback?(NSNumber(value: 0), lifecycleError(
                    code: EBUSY,
                    message: "The terminated guest scene is being replaced. Try again in a moment."
                ))
                return
            }
            // An openWindow request can be abandoned before it creates a
            // session. Remove that orphan before starting a real retry.
            appDict.removeValue(forKey: dataUUID)
            launchAttemptIDs.removeValue(forKey: dataUUID)
            clearOpenRequest(dataUUID: dataUUID)
            MultitaskDockManager.shared.removeRunningApp(dataUUID)
        } else if sessions[dataUUID] != nil {
            beginSceneDestruction(dataUUID: dataUUID)
            pidCallback?(NSNumber(value: 0), lifecycleError(
                code: EBUSY,
                message: "A stale guest scene is being removed. Try again in a moment."
            ))
            return
        }

        DataManager.shared.model.enableMultipleWindow = true
        let attemptID = UUID()
        launchAttemptIDs[dataUUID] = attemptID
        pidCallbacks[dataUUID] = pidCallback.map { [$0] } ?? []
        appDict[dataUUID] = MultitaskAppInfo(displayName: displayName, dataUUID: dataUUID, bundleId: bundleId)
        armLaunchTimeout(dataUUID: dataUUID, attemptID: attemptID)
        NotificationCenter.default.post(
            name: Notification.Name("IOSSimMultitaskGuestDidOpen"),
            object: nil,
            userInfo: [
                "displayName": displayName,
                "dataUUID": dataUUID,
                "bundleIdentifier": bundleId
            ]
        )
        // `openWindow` is an environment action: reading it from a static
        // manager is outside SwiftUI's installed view hierarchy and can turn
        // into a no-op. Route the request through the live Main scene instead.
        let requestID = UUID().uuidString
        let targetHostSessionID = hostSession?.persistentIdentifier
        openRequests[dataUUID] = OpenWindowRequest(
            id: requestID,
            dataUUID: dataUUID,
            targetHostSessionID: targetHostSessionID
        )
        var requestInfo: [String: Any] = [
            "dataUUID": dataUUID,
            "requestID": requestID
        ]
        if let hostSessionID = targetHostSessionID {
            requestInfo["hostSessionID"] = hostSessionID
        }
        NotificationCenter.default.post(
            name: openWindowRequestNotification,
            object: nil,
            userInfo: requestInfo
        )
    }

    /// Accepts a completion only from the scene and launch generation that
    /// currently own this UUID. A delayed callback from a disconnected scene
    /// must not consume a retry's callbacks or publish its stale PID.
    @discardableResult
    class func completeLaunch(
        dataUUID: String,
        attemptID: UUID,
        session: UISceneSession,
        pid: Int32,
        error: Error?
    ) -> Bool {
        guard launchAttemptIDs[dataUUID] == attemptID,
              sessions[dataUUID] === session,
              pidCallbacks[dataUUID] != nil else {
            NSLog(
                "VibeContainers: ignored stale or duplicate launch completion for %@ attempt %@ scene %@",
                dataUUID,
                attemptID.uuidString,
                session.persistentIdentifier
            )
            return false
        }
        finishLaunch(dataUUID: dataUUID, pid: pid, error: error)
        return true
    }

    private class func finishLaunch(dataUUID: String, pid: Int32, error: Error?) {
        clearOpenRequest(dataUUID: dataUUID)
        let callbacks = pidCallbacks.removeValue(forKey: dataUUID) ?? []
        let launchError: Error?
        if let error {
            launchError = error
        } else if pid <= 0 {
            launchError = lifecycleError(
                code: EIO,
                message: "The guest scene initialized without a live process."
            )
        } else {
            launchError = nil
        }

        if let launchError {
            launchAttemptIDs.removeValue(forKey: dataUUID)
            runningPIDs.removeValue(forKey: dataUUID)
            callbacks.forEach { $0(NSNumber(value: 0), launchError) }
            MultitaskDockManager.shared.removeRunningApp(dataUUID)
            if sessions[dataUUID] != nil {
                beginSceneDestruction(dataUUID: dataUUID)
            } else {
                appDict.removeValue(forKey: dataUUID)
                postClosed(dataUUID)
            }
        } else {
            // Keep the attempt token for the lifetime of the admitted scene so
            // a late exit from an older controller cannot dismantle a retry.
            runningPIDs[dataUUID] = pid
            callbacks.forEach { $0(NSNumber(value: pid), nil) }
        }
    }
    
    @objc class func openExistingAppWindow(dataUUID: String) -> Bool {
        guard appDict[dataUUID] != nil, !terminating.contains(dataUUID) else { return false }
        // `openWindow(id:value:)` creates a new scene request even when one is
        // already bootstrapping. Activate the registered scene directly; when
        // registration has not happened yet, returning true simply coalesces
        // the duplicate request into the pending launch.
        if let session = sessions[dataUUID] {
            UIApplication.shared.requestSceneSessionActivation(
                session,
                userActivity: nil,
                options: nil,
                errorHandler: { error in
                    NSLog("VibeContainers: failed to focus guest scene: %@", error.localizedDescription)
                }
            )
            return true
        }
        return pidCallbacks[dataUUID] != nil
    }

    /// Claims one notification for the host scene that initiated it. Every
    /// Main WindowGroup instance receives process-wide notifications, so both
    /// the target identifier and the one-shot claim are required to avoid
    /// opening duplicate value-based guest scenes.
    class func claimOpenRequest(
        requestID: String,
        dataUUID: String,
        from session: UISceneSession
    ) -> Bool {
        guard let request = openRequests[dataUUID],
              request.id == requestID,
              request.dataUUID == dataUUID,
              appDict[dataUUID] != nil,
              sessions[dataUUID] == nil,
              !terminating.contains(dataUUID) else { return false }
        if let targetHostSessionID = request.targetHostSessionID {
            guard session.persistentIdentifier == targetHostSessionID else {
                return false
            }
        } else if let hostSession {
            guard hostSession === session else { return false }
        }
        guard claimedOpenRequestIDs.insert(requestID).inserted else {
            return false
        }
        if hostSession == nil {
            hostSession = session
        }
        return true
    }

    /// Records the concrete Main WindowGroup scene and replays requests that
    /// were posted before its SwiftUI notification receiver or attachment
    /// reader became ready.
    class func registerHostSession(_ session: UISceneSession) -> [String] {
        guard !sessions.values.contains(where: { $0 === session }) else {
            return []
        }
        hostSession = session
        let pendingRequests = Array(openRequests.values)
        return pendingRequests.compactMap { request in
            claimOpenRequest(
                requestID: request.id,
                dataUUID: request.dataUUID,
                from: session
            ) ? request.dataUUID : nil
        }
    }

    class var hasConnectedHostScene: Bool {
        guard let hostSession else { return false }
        let guestSessions = Set(sessions.values.map { ObjectIdentifier($0) })
        guard !guestSessions.contains(ObjectIdentifier(hostSession)) else {
            return false
        }
        return UIApplication.shared.connectedScenes.contains { scene in
            scene.session === hostSession
        }
    }

    /// Admits one canonical guest session before its remote process starts.
    /// A duplicate request must never replace the registry entry for the live
    /// session, or later focus and teardown calls will target the wrong scene.
    @discardableResult
    class func register(
        session: UISceneSession,
        for dataUUID: String,
        admissionOwnerID: UUID
    ) -> UUID? {
        clearOpenRequest(dataUUID: dataUUID)
        let canonicalOwner = sessions.first(where: { $0.value === session })?.key
        if let canonicalOwner, canonicalOwner != dataUUID {
            NSLog(
                "VibeContainers: scene %@ is already registered for %@; rejected %@",
                session.persistentIdentifier,
                canonicalOwner,
                dataUUID
            )
            // This object is the canonical scene for `canonicalOwner`;
            // destroying it would kill the legitimate guest. Reject only the
            // aliased view, even when the alias request is otherwise stale.
            return nil
        }
        guard appDict[dataUUID] != nil,
              !terminating.contains(dataUUID),
              let attemptID = launchAttemptIDs[dataUUID] else {
            // Canonical scenes own their own teardown path. Only destroy a
            // newly-created session that never entered the registry.
            if canonicalOwner == nil {
                destroyRejectedSession(session, reason: "stale guest request")
            }
            return nil
        }
        if let existing = sessions[dataUUID] {
            if existing === session {
                guard admissionOwnerIDs[dataUUID] == admissionOwnerID else {
                    NSLog(
                        "VibeContainers: rejected a second controller for %@ scene %@",
                        dataUUID,
                        session.persistentIdentifier
                    )
                    return nil
                }
                return attemptID
            }
            destroyRejectedSession(session, reason: "duplicate guest request")
            return nil
        }
        sessions[dataUUID] = session
        admissionOwnerIDs[dataUUID] = admissionOwnerID
        return attemptID
    }

    class func shouldTerminateController(
        dataUUID: String,
        attemptID: UUID,
        session: UISceneSession
    ) -> Bool {
        if terminating.contains(dataUUID) { return true }
        guard launchAttemptIDs[dataUUID] == attemptID,
              sessions[dataUUID] === session else { return true }
        return !UIApplication.shared.connectedScenes.contains { scene in
            scene.session === session
        }
    }

    class func unregister(session: UISceneSession, for dataUUID: String) {
        guard sessions[dataUUID] === session else { return }
        let callbacks = pidCallbacks.removeValue(forKey: dataUUID) ?? []
        if !callbacks.isEmpty {
            let error = lifecycleError(
                code: EPIPE,
                message: "The guest window closed before its app scene became ready."
            )
            callbacks.forEach { $0(NSNumber(value: 0), error) }
        }
        sessions.removeValue(forKey: dataUUID)
        admissionOwnerIDs.removeValue(forKey: dataUUID)
        appDict.removeValue(forKey: dataUUID)
        launchAttemptIDs.removeValue(forKey: dataUUID)
        clearOpenRequest(dataUUID: dataUUID)
        runningPIDs.removeValue(forKey: dataUUID)
        terminating.remove(dataUUID)
        MultitaskDockManager.shared.removeRunningApp(dataUUID)
        postClosed(dataUUID)
    }

    class func unregister(session: UISceneSession) {
        guard let dataUUID = sessions.first(where: { $0.value === session })?.key else { return }
        unregister(session: session, for: dataUUID)
    }

    class func guestProcessDidExit(
        dataUUID: String,
        attemptID: UUID,
        session: UISceneSession
    ) {
        guard launchAttemptIDs[dataUUID] == attemptID,
              sessions[dataUUID] === session else {
            NSLog(
                "VibeContainers: ignored stale guest exit for %@ attempt %@ scene %@",
                dataUUID,
                attemptID.uuidString,
                session.persistentIdentifier
            )
            return
        }
        launchAttemptIDs.removeValue(forKey: dataUUID)
        clearOpenRequest(dataUUID: dataUUID)
        let callbacks = pidCallbacks.removeValue(forKey: dataUUID) ?? []
        let error = lifecycleError(
            code: EPIPE,
            message: "The guest process exited before its scene was ready."
        )
        callbacks.forEach { $0(NSNumber(value: 0), error) }
        runningPIDs.removeValue(forKey: dataUUID)
        MultitaskDockManager.shared.removeRunningApp(dataUUID)
        if sessions[dataUUID] != nil {
            beginSceneDestruction(dataUUID: dataUUID)
        } else {
            appDict.removeValue(forKey: dataUUID)
            postClosed(dataUUID)
        }
    }

    @objc class func terminateAppWindow(dataUUID: String) -> Bool {
        guard appDict[dataUUID] != nil || sessions[dataUUID] != nil else { return false }

        launchAttemptIDs.removeValue(forKey: dataUUID)
        clearOpenRequest(dataUUID: dataUUID)
        let callbacks = pidCallbacks.removeValue(forKey: dataUUID) ?? []
        if !callbacks.isEmpty {
            let error = NSError(domain: "LiveProcess", code: Int(ECANCELED), userInfo: [
                NSLocalizedDescriptionKey: "The guest window was closed before launch completed."
            ])
            callbacks.forEach { $0(NSNumber(value: 0), error) }
        }
        MultitaskDockManager.shared.removeRunningApp(dataUUID)

        if sessions[dataUUID] != nil {
            beginSceneDestruction(dataUUID: dataUUID)
        } else {
            appDict.removeValue(forKey: dataUUID)
            runningPIDs.removeValue(forKey: dataUUID)
            terminating.remove(dataUUID)
            postClosed(dataUUID)
        }
        return true
    }

    /// Closes native iOS multitasking scenes without touching the host's main
    /// scene. Live Activity Exit reaches this even when the dock is hidden.
    @objc class func terminateAllAppWindows() {
        let activeSessions = sessions
        let cancelledCallbacks = pidCallbacks
        pidCallbacks.removeAll()
        launchAttemptIDs.removeAll()
        admissionOwnerIDs.removeAll()
        openRequests.removeAll()
        claimedOpenRequestIDs.removeAll()
        let knownUUIDs = Set(appDict.keys).union(activeSessions.keys)
        let error = NSError(domain: "LiveProcess", code: Int(ECANCELED), userInfo: [
            NSLocalizedDescriptionKey: "The guest window was closed before launch completed."
        ])
        cancelledCallbacks.values.flatMap { $0 }.forEach { $0(NSNumber(value: 0), error) }
        activeSessions.keys.forEach { dataUUID in
            beginSceneDestruction(dataUUID: dataUUID)
        }
        knownUUIDs.forEach { MultitaskDockManager.shared.removeRunningApp($0) }
        knownUUIDs.subtracting(activeSessions.keys).forEach { dataUUID in
            appDict.removeValue(forKey: dataUUID)
            admissionOwnerIDs.removeValue(forKey: dataUUID)
            runningPIDs.removeValue(forKey: dataUUID)
            terminating.remove(dataUUID)
            postClosed(dataUUID)
        }
    }

    /// Brings the host scene forward before asking its Springboard to reveal
    /// the card switcher. This is used by the bottom-edge gesture in a native
    /// guest UIWindowScene on iPhone.
    class func presentHostSwitcher(from guestScene: UIWindowScene?) {
        let previews = MultitaskDockManager.shared.captureAppSwitcherPreviews()
        let previewViews = MultitaskDockManager.shared.captureAppSwitcherPreviewViews()
        NotificationCenter.default.post(
            name: Notification.Name("IOSSimShowContainerSwitcher"),
            object: nil,
            userInfo: [
                "previews": previews,
                "previewViews": previewViews,
            ]
        )

        let connectedScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let guestSessions = Set(sessions.values.map { ObjectIdentifier($0) })
        let recordedHost = hostSession.flatMap { session in
            connectedScenes.first { scene in
                scene.session === session
                    && scene !== guestScene
                    && !guestSessions.contains(ObjectIdentifier(scene.session))
            }
        }
        let hostScene = recordedHost ?? connectedScenes
            .sorted { lhs, rhs in
                let lhsActive = lhs.activationState == .foregroundActive
                let rhsActive = rhs.activationState == .foregroundActive
                return lhsActive && !rhsActive
            }
            .first { scene in
                scene !== guestScene && !guestSessions.contains(ObjectIdentifier(scene.session))
            }
        guard let hostScene else { return }
        hostSession = hostScene.session
        UIApplication.shared.requestSceneSessionActivation(
            hostScene.session,
            userActivity: nil,
            options: nil,
            errorHandler: { error in
                NSLog("VibeContainers: failed to activate host switcher scene: %@", error.localizedDescription)
            }
        )
    }

    /// Captures the one foreground native scene once. The result carries both
    /// the compact bitmap and UIKit snapshot view so switcher presentation does
    /// not issue duplicate synchronous FrontBoard transactions per card.
    class func capturePreview(dataUUID: String) -> LCSwitcherPreviewCapture? {
        guard let session = sessions[dataUUID],
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.session === session }),
              scene.activationState == .foregroundActive
                || scene.activationState == .foregroundInactive,
              let window = scene.windows.first(where: \.isKeyWindow)
                ?? scene.windows.first(where: { !$0.isHidden && $0.alpha > 0.01 })
                ?? scene.windows.first else { return nil }
        return findAppSceneController(in: window.rootViewController)?
            .captureSwitcherPreviewResult(withMaximumWidth: 430)
    }

    /// Compatibility accessors intentionally each perform a capture when used
    /// alone. The app-switcher hot path uses `capturePreview(dataUUID:)` once.
    class func capturePreviewImage(dataUUID: String) -> UIImage? {
        capturePreview(dataUUID: dataUUID)?.image
    }

    class func capturePreviewView(dataUUID: String) -> UIView? {
        capturePreview(dataUUID: dataUUID)?.previewView
    }

    private class func findAppSceneController(
        in rootViewController: UIViewController?
    ) -> AppSceneViewController? {
        guard let rootViewController else { return nil }
        if let appSceneVC = rootViewController as? AppSceneViewController {
            return appSceneVC
        }
        if let presented = findAppSceneController(
            in: rootViewController.presentedViewController
        ) {
            return presented
        }
        for child in rootViewController.children {
            if let appSceneVC = findAppSceneController(in: child) {
                return appSceneVC
            }
        }
        return nil
    }

    private class func postClosed(_ dataUUID: String) {
        NotificationCenter.default.post(
            name: Notification.Name("IOSSimMultitaskGuestDidClose"),
            object: nil,
            userInfo: ["dataUUID": dataUUID]
        )
    }

    /// SwiftUI's `openWindow` has no completion handler. If UIKit declines or
    /// abandons a scene request, neither the representable nor LiveProcess gets
    /// a chance to report an error. Bound that pending state so the host can
    /// recover and the user can retry instead of staring at a permanent loader.
    private class func armLaunchTimeout(dataUUID: String, attemptID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + launchTimeout) {
            guard launchAttemptIDs[dataUUID] == attemptID,
                  pidCallbacks[dataUUID] != nil else { return }
            finishLaunch(
                dataUUID: dataUUID,
                pid: 0,
                error: lifecycleError(
                    code: ETIMEDOUT,
                    message: "The guest window did not become ready in time. Its process was closed so you can retry."
                )
            )
        }
    }

    /// Called only from the host-side launch bridge. Remembering the scene here
    /// avoids guessing later, when the native guest is itself foreground/key.
    private class func rememberHostSession() {
        let guestSessions = Set(sessions.values.map { ObjectIdentifier($0) })
        let candidate = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { !guestSessions.contains(ObjectIdentifier($0.session)) }
            .sorted { lhs, rhs in
                let lhsActive = lhs.activationState == .foregroundActive
                let rhsActive = rhs.activationState == .foregroundActive
                if lhsActive != rhsActive { return lhsActive }
                let lhsKey = lhs.windows.contains(where: \.isKeyWindow)
                let rhsKey = rhs.windows.contains(where: \.isKeyWindow)
                return lhsKey && !rhsKey
            }
            .first
        if let candidate {
            hostSession = candidate.session
        }
    }

    private class func beginSceneDestruction(dataUUID: String) {
        guard let session = sessions[dataUUID] else { return }
        guard terminating.insert(dataUUID).inserted else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
            // UIKit invokes this handler only when destruction fails. Keep the
            // registry intact so a running process cannot be launched twice.
            terminating.remove(dataUUID)
            NSLog("VibeContainers: failed to close guest scene: %@", error.localizedDescription)
        }
    }

    private class func destroyRejectedSession(
        _ session: UISceneSession,
        reason: String
    ) {
        UIApplication.shared.requestSceneSessionDestruction(
            session,
            options: nil
        ) { error in
            NSLog(
                "VibeContainers: failed to destroy %@ scene %@: %@",
                reason,
                session.persistentIdentifier,
                error.localizedDescription
            )
        }
    }

    private class func clearOpenRequest(dataUUID: String) {
        guard let request = openRequests.removeValue(forKey: dataUUID) else {
            return
        }
        claimedOpenRequestIDs.remove(request.id)
    }

    private class func lifecycleError(code: Int32, message: String) -> NSError {
        NSError(domain: "LiveProcess", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}

/// Owns SwiftUI's scene-opening environment action in the Main window that
/// actually received it. Native guest requests arrive from the Objective-C
/// bridge, so the manager cannot safely retain or synthesize this action.
@available(iOS 16.1, *)
public struct MultitaskWindowRequestModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var attachedSession: UISceneSession?

    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(
                WindowSceneAttachmentReader { scene in
                    attachedSession = scene.session
                    let pendingUUIDs = MultitaskWindowManager.registerHostSession(
                        scene.session
                    )
                    pendingUUIDs.forEach { dataUUID in
                        openWindow(
                            id: MultitaskGuestScene.windowGroupID,
                            value: dataUUID
                        )
                    }
                }
                .allowsHitTesting(false)
            )
            .onReceive(
                NotificationCenter.default.publisher(
                    for: MultitaskWindowManager.openWindowRequestNotification
                )
            ) { notification in
                guard let dataUUID = notification.userInfo?["dataUUID"] as? String,
                      !dataUUID.isEmpty,
                      let requestID = notification.userInfo?["requestID"] as? String,
                      let attachedSession,
                      MultitaskWindowManager.claimOpenRequest(
                        requestID: requestID,
                        dataUUID: dataUUID,
                        from: attachedSession
                      ) else { return }
                openWindow(id: MultitaskGuestScene.windowGroupID, value: dataUUID)
            }
    }
}

/// Public framework boundary for a native guest window. Host apps provide the
/// matching value-based `WindowGroup` while LiveContainer retains ownership of
/// process bootstrap, remote-scene hosting, focus, and teardown.
@available(iOS 16.1, *)
public struct MultitaskGuestScene: View {
    public static let windowGroupID = "appView"

    private let id: String
    private let fallbackHostWindowGroupID: String?

    public init(id: String, fallbackHostWindowGroupID: String? = nil) {
        self.id = id
        self.fallbackHostWindowGroupID = fallbackHostWindowGroupID
    }

    public var body: some View {
        MultitaskAppWindow(
            id: id,
            fallbackHostWindowGroupID: fallbackHostWindowGroupID
        )
    }
}

@available(iOS 16.1, *)
private struct WindowSceneAttachmentReader: UIViewRepresentable {
    final class ObserverView: UIView {
        var onAttach: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let windowScene = window?.windowScene else { return }
            // UIViewRepresentable may attach this view while SwiftUI is still
            // reconciling its body. Defer the state-producing callback one
            // main-queue turn and discard it if the view moved again first.
            DispatchQueue.main.async { [weak self, weak windowScene] in
                guard let self, let windowScene,
                      self.window?.windowScene === windowScene else { return }
                self.onAttach?(windowScene)
            }
        }
    }

    let onAttach: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onAttach = onAttach
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.onAttach = onAttach
    }
}

@available(iOS 16.1, *)
struct AppSceneViewSwiftUI: UIViewControllerRepresentable {
    @Binding var show: Bool
    let bundleId: String
    let dataUUID: String
    let attemptID: UUID
    let session: UISceneSession
    let onAppInitialize: (Int32, Error?) -> Void
    
    class Coordinator: NSObject, AppSceneViewControllerDelegate, UIGestureRecognizerDelegate {
        let onExit: () -> Void
        let onAppInitialize: (Int32, Error?) -> Void
        let shouldTerminateController: () -> Bool
        private var appSwitcherGesture: UIPanGestureRecognizer?
        private var appSwitcherGestureTriggered = false

        init(
            onAppInitialize: @escaping (Int32, Error?) -> Void,
            onExit: @escaping () -> Void,
            shouldTerminateController: @escaping () -> Bool
        ) {
            self.onAppInitialize = onAppInitialize
            self.onExit = onExit
            self.shouldTerminateController = shouldTerminateController
        }

        func installAppSwitcherGesture(on view: UIView) {
            guard UIDevice.current.userInterfaceIdiom == .phone else { return }

            // Once the native scene is attached, observe its UIWindow so the
            // recognizer owns the physical bottom edge rather than only the
            // representable's current safe-area-sized frame.
            let gestureHost = view.window ?? view
            if let appSwitcherGesture {
                guard appSwitcherGesture.view !== gestureHost else { return }
                appSwitcherGesture.view?.removeGestureRecognizer(appSwitcherGesture)
                gestureHost.addGestureRecognizer(appSwitcherGesture)
                return
            }

            let gesture = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleAppSwitcherGesture(_:))
            )
            gesture.minimumNumberOfTouches = 1
            gesture.maximumNumberOfTouches = 1
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.delegate = self
            gestureHost.addGestureRecognizer(gesture)
            appSwitcherGesture = gesture
        }

        func uninstallAppSwitcherGesture() {
            guard let appSwitcherGesture else { return }
            appSwitcherGesture.view?.removeGestureRecognizer(appSwitcherGesture)
            self.appSwitcherGesture = nil
        }

        func reportControllerCreationFailure() {
            let error = NSError(
                domain: "LiveProcess",
                code: Int(EIO),
                userInfo: [
                    NSLocalizedDescriptionKey: "The native guest scene controller could not be created."
                ]
            )
            onAppInitialize(0, error)
        }

        private func canHandleAppSwitcherGesture(_ gesture: UIPanGestureRecognizer) -> Bool {
            guard let gestureView = gesture.view,
                  let window = gestureView as? UIWindow ?? gestureView.window,
                  !window.isHidden,
                  window.alpha > 0.01 else { return false }

            let location = gesture.location(in: window)
            let translation = gesture.translation(in: window)
            let startY = location.y - translation.y
            let bottomBand = max(64, window.safeAreaInsets.bottom + 28)
            return startY >= window.bounds.maxY - bottomBand
        }

        @objc private func handleAppSwitcherGesture(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                appSwitcherGestureTriggered = false
                return
            case .cancelled, .failed:
                appSwitcherGestureTriggered = false
                return
            case .changed, .ended:
                break
            default:
                return
            }

            if !appSwitcherGestureTriggered,
               canHandleAppSwitcherGesture(gesture),
               let gestureView = gesture.view,
               let window = gestureView as? UIWindow ?? gestureView.window {
                let translation = gesture.translation(in: window)
                let velocity = gesture.velocity(in: window)
                let projectedVertical = translation.y + min(velocity.y, 0) * 0.06
                let upwardTranslation = -translation.y
                let upwardTravel = max(upwardTranslation, -projectedVertical)
                if upwardTranslation > 6,
                   upwardTravel > 22,
                   upwardTranslation > abs(translation.x) * 0.60 {
                    appSwitcherGestureTriggered = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    NSLog("VibeContainers: native bottom swipe requested the app switcher")
                    MultitaskWindowManager.presentHostSwitcher(from: window.windowScene)
                }
            }

            if gesture.state == .ended {
                appSwitcherGestureTriggered = false
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === appSwitcherGesture,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            // Direction is intentionally evaluated from later translation
            // samples; initial home-edge velocity is often zero or diagonal.
            return canHandleAppSwitcherGesture(pan)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
        
        func appSceneVCAppDidExit(_: AppSceneViewController!) {
            uninstallAppSwitcherGesture()
            onExit()
        }
        
        func appSceneVC(_ vc: AppSceneViewController!, didInitializeWithError error: (any Error)!) {
            installAppSwitcherGesture(on: vc.view)
            DispatchQueue.main.async {
                (vc.view.window?.windowScene?.statusBarManager as? LCStatusBarManager)?.nativeWindowViewController = vc
            }
            onAppInitialize(vc.pid, error)
        }
        
        func appSceneVCWillActivateScene(_ vc: AppSceneViewController!) {
            installAppSwitcherGesture(on: vc.view)
            vc.updateSettings { settings in
                guard let settings else { return }
                let defaultInsets = vc.view.window?.safeAreaInsets ?? .zero
                settings.peripheryInsets = defaultInsets
                settings.safeAreaInsetsPortrait = defaultInsets
                settings.deviceOrientation = UIDevice.current.orientation
                settings.setInterfaceOrientation(UIApplication.shared.statusBarOrientation)
                if(settings.interfaceOrientation().isLandscape) {
                    settings.setFrame(CGRect(x: 0, y: 0, width: vc.view.frame.size.height, height: vc.view.frame.size.width))
                } else {
                    settings.setFrame(CGRect(x: 0, y: 0, width: vc.view.frame.size.width, height: vc.view.frame.size.height))
                }
            }
            // fix live resize
            vc.contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        
        func appSceneVC(_ vc: AppSceneViewController!, didUpdateFrom settings: UIMutableApplicationSceneSettings!, transitionContext context: Any!, lifecycleActionType actionType: UInt32) {
            settings.interruptionPolicy = 0
            //settings.peripheryInsets = vc.view.window?.safeAreaInsets ?? .zero
            vc.presenter.scene.updateSettings(settings, withTransitionContext: context, completion: nil)
            // Not sure what actionType 2 is, but it's only set when this scene enters foreground, so we can pass URL scheme here
            if actionType == 2, let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
                UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
                vc.openURLScheme(launchUrl)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onAppInitialize: onAppInitialize, onExit: {
            show = false
            MultitaskWindowManager.guestProcessDidExit(
                dataUUID: dataUUID,
                attemptID: attemptID,
                session: session
            )
        }, shouldTerminateController: {
            MultitaskWindowManager.shouldTerminateController(
                dataUUID: dataUUID,
                attemptID: attemptID,
                session: session
            )
        })
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        guard let viewController = AppSceneViewController(
            bundleId: bundleId,
            dataUUID: dataUUID,
            delegate: context.coordinator
        ) else {
            let fallback = UIViewController()
            fallback.view.backgroundColor = .black
            Task { @MainActor in
                context.coordinator.reportControllerCreationFailure()
            }
            return fallback
        }
        context.coordinator.installAppSwitcherGesture(on: viewController.view)
        return viewController
    }
    
    func updateUIViewController(_ vc: UIViewController, context _: Context) {
        if let vc = vc as? AppSceneViewController {
            if !show {
                vc.terminate()
            }
        }
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.uninstallAppSwitcherGesture()
        guard coordinator.shouldTerminateController() else {
            NSLog("VibeContainers: preserved live guest during SwiftUI view reconciliation")
            return
        }
        (uiViewController as? AppSceneViewController)?.terminate()
    }
}

@available(iOS 16.1, *)
struct MultitaskAppWindow: View {
    @State var show = true
    @State var pid = 0
    @State var appInfo: MultitaskAppInfo? = nil
    @State var errorMessage: String? = nil
    @State private var hasScheduledAutoClose = false
    @State private var didRequestManualClose = false
    @State private var attachedSession: UISceneSession?
    @State private var admittedAttemptID: UUID?
    @State private var admissionOwnerID = UUID()
    @Environment(\.openWindow) var openWindow
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCSkipTerminatedScreen", store: LCUtils.appGroupUserDefault) var skipTerminatedScreen = false
    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
    let fallbackHostWindowGroupID: String?

    init(id: String, fallbackHostWindowGroupID: String? = nil) {
        self.fallbackHostWindowGroupID = fallbackHostWindowGroupID
        guard let appInfo = MultitaskWindowManager.appDict[id] else {
            return
        }
        _appInfo = State(initialValue: appInfo)
    }
    
    var body: some View {
        let isVirtualWindowMode = multitaskMode == .virtualWindow
        Group {
            if show,
               let appInfo,
               let admittedAttemptID,
               let attachedSession {
                AppSceneViewSwiftUI(
                    show: $show,
                    bundleId: appInfo.bundleId,
                    dataUUID: appInfo.dataUUID,
                    attemptID: admittedAttemptID,
                    session: attachedSession,
                    onAppInitialize: { pid, error in
                        DispatchQueue.main.async {
                            guard MultitaskWindowManager.completeLaunch(
                                dataUUID: appInfo.dataUUID,
                                attemptID: admittedAttemptID,
                                session: attachedSession,
                                pid: pid,
                                error: error
                            ) else {
                                self.show = false
                                return
                            }
                            if error == nil {
                                self.pid = Int(pid)
                            } else {
                                self.errorMessage = error?.localizedDescription
                                self.show = false
                            }
                        }
                    }
                )
                .background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.all, edges: .all)
                .defersSystemGestures(
                    on: UIDevice.current.userInterfaceIdiom == .phone ? .bottom : []
                )
                .navigationTitle(Text("\(appInfo.displayName) - \(String(pid))"))

            } else if show, appInfo != nil {
                // Do not bootstrap a remote process until this UIWindowScene
                // wins canonical admission for the container UUID.
                Color.black
                    .ignoresSafeArea(.all, edges: .all)
            } else if skipTerminatedScreen && isVirtualWindowMode, appInfo != nil {
                Color.clear
                    .ignoresSafeArea(.all, edges: .all)
                    .onAppear {
                        guard !didRequestManualClose else { return }
                        if let appInfo {
                            MultitaskRelaunchManager.scheduleRelaunchIfNeeded(bundleId: appInfo.bundleId, dataUUID: appInfo.dataUUID, isManualTermination: false)
                        }
                        if !hasScheduledAutoClose {
                            hasScheduledAutoClose = true
                            DispatchQueue.main.async {
                                requestSceneDestruction(isManual: false)
                            }
                        }
                    }
            } else {
                VStack {
                    Text("lc.multitaskAppWindow.appTerminated".loc)
                        .font(.largeTitle)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(.body, design: .monospaced))
                        Button("lc.common.copy".loc) {
                            UIPasteboard.general.string = errorMessage
                            requestSceneDestruction(isManual: true)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("lc.common.close".loc) {
                        requestSceneDestruction(isManual: true)
                    }
                    .buttonStyle(.bordered)
                }
                .onAppear {
                    guard appInfo == nil, !hasScheduledAutoClose else { return }
                    hasScheduledAutoClose = true
                    let openDelay: TimeInterval
                    if let fallbackHostWindowGroupID,
                       !MultitaskWindowManager.hasConnectedHostScene {
                        openDelay = 0.3
                        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay) {
                            openWindow(id: fallbackHostWindowGroupID)
                        }
                    } else {
                        openDelay = 0
                    }
                    // Keep an orphan restoration scene alive long enough for
                    // SwiftUI to attach its real UISceneSession before closing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + openDelay + 0.3) {
                        requestSceneDestruction()
                    }
                }
            }
        }
        .background(
            WindowSceneAttachmentReader { scene in
                attach(to: scene)
            }
            .allowsHitTesting(false)
        )
        .onReceive(pub) { notification in
            guard let scene = notification.object as? UIWindowScene,
                  let attachedSession,
                  scene.session === attachedSession else { return }
            if let appInfo {
                MultitaskWindowManager.unregister(
                    session: attachedSession,
                    for: appInfo.dataUUID
                )
            }
            self.attachedSession = nil
            admittedAttemptID = nil
            show = false
        }
    }

    private func attach(to scene: UIWindowScene) {
        let session = scene.session
        guard attachedSession !== session else { return }
        if let attachedSession, admittedAttemptID != nil, let appInfo {
            MultitaskWindowManager.unregister(
                session: attachedSession,
                for: appInfo.dataUUID
            )
        }
        attachedSession = session
        if let appInfo {
            admittedAttemptID = MultitaskWindowManager.register(
                session: session,
                for: appInfo.dataUUID,
                admissionOwnerID: admissionOwnerID
            )
        } else {
            admittedAttemptID = nil
        }
    }
    
    private func requestSceneDestruction(isManual: Bool = false) {
        if isManual {
            didRequestManualClose = true
        }
        guard let session = attachedSession else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
            print(error)
        }
    }
}

@objcMembers
class MultitaskRelaunchManager: NSObject {
    private static var pendingKeys: Set<String> = []
    private static let pendingLock = NSLock()
    
    static func scheduleRelaunchIfNeeded(bundleId: String, dataUUID: String, isManualTermination: Bool) {
        let defaults = LCUtils.appGroupUserDefault
        let multitaskMode = MultitaskMode(rawValue: defaults.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        guard defaults.bool(forKey: "LCSkipTerminatedScreen"),
              defaults.bool(forKey: "LCRestartTerminatedApp"),
              multitaskMode == .virtualWindow,
              !isManualTermination else { return }
        
        let key = "\(bundleId)#\(dataUUID)"
        guard markPendingIfNeeded(key: key) else { return }
        
        Task {
            defer { clearPending(key: key) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await relaunchApp(bundleId: bundleId, dataUUID: dataUUID)
        }
    }
    
    private static func markPendingIfNeeded(key: String) -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        if pendingKeys.contains(key) {
            return false
        }
        pendingKeys.insert(key)
        return true
    }
    
    private static func clearPending(key: String) {
        pendingLock.lock()
        pendingKeys.remove(key)
        pendingLock.unlock()
    }
    
    private static func relaunchApp(bundleId: String, dataUUID: String) async {
        guard let appModel = await MainActor.run(body: { lookupAppModel(bundleId: bundleId) }),
              appModel.appInfo.lastLaunched.distance(to: .now) > 2
        else {
            return
        }
        
        do {
            try await appModel.runApp(multitask: true, containerFolderName: dataUUID)
        } catch {
            print("Failed to restart \(bundleId): \(error)")
        }
    }
    
    @MainActor private static func lookupAppModel(bundleId: String) -> LCAppModel? {
        let sharedModel = DataManager.shared.model
        if let app = sharedModel.apps.first(where: { $0.appInfo.relativeBundlePath == bundleId }) {
            return app
        }
        return sharedModel.hiddenApps.first(where: { $0.appInfo.relativeBundlePath == bundleId })
    }
}
