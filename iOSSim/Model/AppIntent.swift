import SwiftUI

/// What a home-screen quick action asks an app to do once it opens.
///
/// The menu rows used to dismiss and stop there. They open the app now, the way
/// a real quick action does, and hand it one of these on the way in — the app
/// picks it up in `onAppear` and lands on the right screen.
enum AppIntent: String, Hashable {
    case photosRecents, photosFavorites
    case calculatorCopyResult
    case clockCreateAlarm, clockStartStopwatch
    case remindersNew
    case mailCompose, mailSearch
    case notesNew, notesChecklist
    case cameraSelfie, cameraVideo
    case settingsCustomization, settingsPackages
    case weatherMyLocation
    case calendarNewEvent
    case stocksWatchlist
    case mapsDirectionsHome, mapsSearchNearby
    case phoneNewContact
    case safariNewTab, safariReadingList
    case messagesCompose
    case musicPlayRecents, musicSearch

    /// The app that answers it.
    var app: AppID {
        switch self {
        case .photosRecents, .photosFavorites: .photos
        case .calculatorCopyResult: .calculator
        case .clockCreateAlarm, .clockStartStopwatch: .clock
        case .remindersNew: .reminders
        case .mailCompose, .mailSearch: .mail
        case .notesNew, .notesChecklist: .notes
        case .cameraSelfie, .cameraVideo: .camera
        case .settingsCustomization, .settingsPackages: .settings
        case .weatherMyLocation: .weather
        case .calendarNewEvent: .calendar
        case .stocksWatchlist: .stocks
        case .mapsDirectionsHome, .mapsSearchNearby: .maps
        case .phoneNewContact: .phone
        case .safariNewTab, .safariReadingList: .safari
        case .messagesCompose: .messages
        case .musicPlayRecents, .musicSearch: .music
        }
    }
}

/// Carries a quick action from the springboard into the app that is opening.
///
/// A plain hand-off rather than an observable dependency: the app reads it once
/// as it appears and takes it off the queue, so a second launch of the same app
/// starts clean.
@MainActor
final class IntentRouter {
    static let shared = IntentRouter()
    private init() {}

    private var pending: AppIntent?

    func send(_ intent: AppIntent) { pending = intent }

    /// Hands over the pending intent if it belongs to this app, and clears it.
    func take(_ app: AppID) -> AppIntent? {
        guard let pending, pending.app == app else { return nil }
        self.pending = nil
        return pending
    }

    func clear() { pending = nil }
}

extension View {
    /// Runs `handler` with the quick action this app was opened by, if any.
    func onAppIntent(_ app: AppID, perform handler: @escaping (AppIntent) -> Void) -> some View {
        onAppear {
            guard let intent = IntentRouter.shared.take(app) else { return }
            handler(intent)
        }
    }
}
