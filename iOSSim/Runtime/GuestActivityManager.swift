import ActivityKit
import Foundation

enum GuestExitActivityError: LocalizedError {
    case disabled

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Live Activities are disabled for VibeContainers. Enable them in Settings before launching a guest."
        }
    }
}

/// Owns the single Live Activity and merges what goes into it.
///
/// Two features share one activity, so neither may clobber the other: starting
/// the server must not drop a running guest's Exit button, and exiting a guest
/// must not take a running server's address off the lock screen. Every change
/// goes through `apply(_:)`, which edits one half of the state and ends the
/// activity only once both halves are gone.
enum SessionActivity {
    static var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private static var current: Activity<GuestSessionAttributes>? { Activity<GuestSessionAttributes>.activities.first }

    static var state: GuestSessionAttributes.ContentState? { current?.content.state }

    /// Applies an edit to the session, starting or ending the activity as the
    /// result requires. Throws only when the activity has to be created and
    /// the user has Live Activities switched off.
    static func apply(_ edit: (inout GuestSessionAttributes.ContentState) -> Void) throws {
        var state = current?.content.state ?? GuestSessionAttributes.ContentState()
        edit(&state)

        let isEmpty = state.bundleIdentifier == nil && state.server == nil

        if let activity = current {
            let content = ActivityContent(state: state, staleDate: nil)
            Task {
                if isEmpty {
                    await activity.end(nil, dismissalPolicy: .immediate)
                } else {
                    await activity.update(content)
                }
            }
            return
        }

        guard !isEmpty else { return }
        guard isAvailable else { throw GuestExitActivityError.disabled }

        _ = try Activity<GuestSessionAttributes>.request(
            attributes: GuestSessionAttributes(startedAt: Date()),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
    }

    static func endAll() async {
        for activity in Activity<GuestSessionAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

enum GuestExitActivityManager {
    static func start(bundleIdentifier: String) throws {
        try SessionActivity.apply { $0.bundleIdentifier = bundleIdentifier }
    }

    /// Ends the guest half. A running server keeps the activity up.
    static func endGuest() {
        try? SessionActivity.apply { $0.bundleIdentifier = nil }
    }

    static func endAll() async {
        await SessionActivity.endAll()
    }
}

/// Diagnostic entry point used by the Simulator verification harness.
@_cdecl("IOSSimStartGuestExitActivity")
func IOSSimStartGuestExitActivity(_ bundleIdentifier: UnsafePointer<CChar>) -> Int32 {
    do {
        try GuestExitActivityManager.start(bundleIdentifier: String(cString: bundleIdentifier))
        return 0
    } catch {
        NSLog("[iOSSim] Live Activity request failed: %@", error.localizedDescription)
        return 1
    }
}
