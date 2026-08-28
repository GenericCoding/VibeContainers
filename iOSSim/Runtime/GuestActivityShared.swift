import ActivityKit
import AppIntents
import CoreFoundation
import Foundation

/// The one Live Activity iOSSim runs, shared by everything that needs to stay
/// visible while the app is not on screen.
///
/// It started as the guest-exit control and now also carries the web server, so
/// the state is a *session*: either half can be present, and the activity ends
/// when both are gone.
struct GuestSessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The guest app currently running, if any.
        var bundleIdentifier: String?
        /// The web server, if it is up.
        var server: ServerState?
    }

    struct ServerState: Codable, Hashable {
        /// `http://192.168.1.13:8080`, ready to be read off a lock screen.
        var address: String
        /// The folder being served, by name.
        var folder: String
        var requests: Int
        /// iOS suspended the app and the listener went with it.
        var paused: Bool
    }

    var startedAt: Date
}

/// Darwin notification names the widget posts and the app listens for. A widget
/// runs in its own process, so this is how a button press reaches the app —
/// and if the app is suspended, the note is delivered when it resumes.
enum SessionNotification {
    static let exitGuest = "com.iossim.exit-guest"
    static let stopServer = "com.iossim.stop-server"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

struct ExitGuestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Exit Guest"
    static let description = IntentDescription("Return from the running guest to VibeContainers.")
    // For a legacy full-process guest this asks iOS to activate a fresh host
    // after the guest receives the Darwin teardown notification. In normal
    // multitasking mode VibeContainers is already alive, so this simply brings
    // its existing window forward after the guest scene closes.
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        SessionNotification.post(SessionNotification.exitGuest)

        // Give the direct-guest process a moment to remove its one-shot ticket
        // and terminate before AppIntents asks SpringBoard to activate us.
        try? await Task.sleep(for: .milliseconds(180))

        // The host also ends stale activities on its next clean launch. Ending
        // here makes the Island collapse immediately after the action succeeds.
        for activity in Activity<GuestSessionAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

struct StopServerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop HTTP Server"
    static let description = IntentDescription("Stop serving the www folder over the local network.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        SessionNotification.post(SessionNotification.stopServer)

        // Drop the server half straight away so the control matches what just
        // happened; a guest still running keeps the activity alive.
        for activity in Activity<GuestSessionAttributes>.activities {
            var state = activity.content.state
            state.server = nil
            if state.bundleIdentifier == nil {
                await activity.end(nil, dismissalPolicy: .immediate)
            } else {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
        return .result()
    }
}
