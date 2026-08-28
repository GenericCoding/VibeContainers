import SwiftUI
import LiveContainerSwiftUI

@_silgen_name("IOSSimInstallGuestExitControl")
private func IOSSimInstallGuestExitControl()

@_silgen_name("IOSSimInstallContainerURLBridge")
private func IOSSimInstallContainerURLBridge()

/// UIKit's process-wide bridge invokes this before SwiftUI selects a scene.
/// A nonzero route result consumes the URL even when its container is
/// unavailable, so a private VibeContainers route never leaks into the active
/// guest app.
@_cdecl("IOSSimRouteContainerURL")
@MainActor
func IOSSimRouteContainerURL(_ urlBytes: UnsafePointer<CChar>?) -> Int32 {
    guard let urlBytes,
          let url = URL(string: String(cString: urlBytes)),
          url.scheme?.lowercased() == "iossim",
          url.host?.lowercased() == "guest" else { return 0 }
    let encoded = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
    guard let bundleIdentifier = encoded.removingPercentEncoding,
          !bundleIdentifier.isEmpty,
          let container = GuestContainerStore.shared.container(for: bundleIdentifier),
          GuestContainerStore.shared.hasPayload(container) else {
        NSLog("VibeContainers: process URL bridge consumed unavailable route %@", url.absoluteString)
        return 1
    }

    // A repeat shortcut is delivered inside UIKit's scene-update transaction.
    // Focus an existing guest synchronously while that action is being handled;
    // deferring the whole operation to an unstructured task can leave the
    // currently active guest scene in front even though the URL was consumed.
    if let existing = RunningContainerStore.shared.entry(for: container.uuid.uuidString),
       existing.phase.isActive {
        let focusResult = RunningContainerStore.shared.focusResult(existing)
        NSLog(
            "VibeContainers: process URL bridge focus %@ result=%d",
            bundleIdentifier,
            focusResult
        )
        return focusResult == 0 ? 3 : 100 + focusResult
    }

    NSLog("VibeContainers: process URL bridge routing %@", bundleIdentifier)
    Task { @MainActor in
        let outcome = await GuestInstaller.shared.launch(container)
        if !outcome.ok {
            NSLog(
                "VibeContainers: guest deep link %@ failed: %@ — %@",
                bundleIdentifier,
                outcome.headline,
                outcome.detail
            )
        }
    }
    return 2
}

struct iOSSimApp: App {
    var body: some Scene {
        WindowGroup(id: "Main") {
            RootView()
                .preferredColorScheme(.dark)
                .modifier(MultitaskWindowRequestModifier())
        }

        if UIApplication.shared.supportsMultipleScenes, #available(iOS 16.1, *) {
            WindowGroup(id: MultitaskGuestScene.windowGroupID, for: String.self) { $id in
                if let id {
                    MultitaskGuestScene(
                        id: id,
                        fallbackHostWindowGroupID: "Main"
                    )
                        .preferredColorScheme(.dark)
                }
            }
        }
    }
}

/// The executable has a small Objective-C entry point which either starts a
/// selected LiveContainer guest or falls through to the normal SwiftUI host.
/// Exporting the host entry point keeps SwiftUI's generated startup available
/// without making it the process' unconditional `main`.
@_cdecl("IOSSimHostMain")
@MainActor
func IOSSimHostMain() -> Int32 {
    MultitaskPreferences.configureDefaults()
    MultitaskGuestSceneRuntime.installHostSupport()
    IOSSimInstallContainerURLBridge()
    IOSSimInstallGuestExitControl()
    Task { await GuestExitActivityManager.endAll() }
    iOSSimApp.main()
    return 0
}
