import SwiftUI

enum AppID: String, CaseIterable, Identifiable, Hashable {
    case photos, calculator, clock, reminders, mail, notes, camera, settings
    case weather, calendar, stocks, maps
    case phone, safari, messages, music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: "Photos"
        case .calculator: "Calculator"
        case .clock: "Clock"
        case .reminders: "Reminders"
        case .mail: "Mail"
        case .notes: "Notes"
        case .camera: "Camera"
        case .settings: "Settings"
        case .weather: "Weather"
        case .calendar: "Calendar"
        case .stocks: "Stocks"
        case .maps: "Maps"
        case .phone: "Phone"
        case .safari: "Safari"
        case .messages: "Messages"
        case .music: "Music"
        }
    }

    /// Unread/notification badge shown on the springboard.
    var badge: Int? {
        switch self {
        case .messages: 3
        case .mail: 12
        case .phone: 1
        default: nil
        }
    }

    /// The app-specific shortcuts at the top of the long-press menu, the way
    /// real apps contribute Home Screen quick actions.
    var quickActions: [QuickAction] {
        switch self {
        case .photos: [.init("Recents", "photo.on.rectangle", .photosRecents),
                       .init("Favorites", "heart", .photosFavorites)]
        case .calculator: [.init("Copy Last Result", "doc.on.doc", .calculatorCopyResult)]
        case .clock: [.init("Create Alarm", "alarm", .clockCreateAlarm),
                      .init("Start Stopwatch", "stopwatch", .clockStartStopwatch)]
        case .reminders: [.init("New Reminder", "plus.circle", .remindersNew)]
        case .mail: [.init("New Message", "square.and.pencil", .mailCompose),
                     .init("Search", "magnifyingglass", .mailSearch)]
        case .notes: [.init("New Note", "square.and.pencil", .notesNew),
                      .init("New Checklist", "checklist", .notesChecklist)]
        case .camera: [.init("Take Selfie", "person.crop.square", .cameraSelfie),
                       .init("Record Video", "video", .cameraVideo)]
        case .settings: [.init("Customization", "slider.horizontal.3", .settingsCustomization),
                         .init("★ Applications", "folder", .settingsPackages)]
        case .weather: [.init("My Location", "location", .weatherMyLocation)]
        case .calendar: [.init("New Event", "plus.circle", .calendarNewEvent)]
        case .stocks: [.init("Watchlist", "list.bullet", .stocksWatchlist)]
        case .maps: [.init("Directions Home", "house", .mapsDirectionsHome),
                     .init("Search Nearby", "magnifyingglass", .mapsSearchNearby)]
        case .phone: [.init("New Contact", "person.badge.plus", .phoneNewContact)]
        case .safari: [.init("New Tab", "plus.square.on.square", .safariNewTab),
                       .init("Reading List", "eyeglasses", .safariReadingList)]
        case .messages: [.init("New Message", "square.and.pencil", .messagesCompose)]
        case .music: [.init("Play Recents", "play.fill", .musicPlayRecents),
                      .init("Search", "magnifyingglass", .musicSearch)]
        }
    }

    /// Type-erased on purpose. A 16-branch `@ViewBuilder` switch produces one
    /// enormous nested `_ConditionalContent` type; hosting it — even in a
    /// branch that is not currently taken — is enough to stall SwiftUI's
    /// update loop. `AnyView` collapses it to a single dynamic type.
    var screen: AnyView {
        switch self {
        case .photos: AnyView(PhotosApp())
        case .calculator: AnyView(CalculatorApp())
        case .clock: AnyView(ClockApp())
        case .reminders: AnyView(RemindersApp())
        case .mail: AnyView(MailApp())
        case .notes: AnyView(NotesApp())
        case .camera: AnyView(CameraApp())
        case .settings: AnyView(SettingsApp())
        case .weather: AnyView(WeatherApp())
        case .calendar: AnyView(CalendarApp())
        case .stocks: AnyView(StocksApp())
        case .maps: AnyView(MapsApp())
        case .phone: AnyView(PhoneApp())
        case .safari: AnyView(SafariApp())
        case .messages: AnyView(MessagesApp())
        case .music: AnyView(MusicApp())
        }
    }
}

enum HomeLayout {
    /// The simulator starts as an empty device. The other built-in app
    /// implementations stay available to the project, but are not installed
    /// into a new home-screen layout.
    static let pages: [[AppID]] = [[.settings]]

    static let dock: [AppID] = []

    /// The built-ins that are installed in this product configuration.
    static let builtins: [AppID] = pages.flatMap { $0 } + dock
}

/// Holds an icon's on-screen frame in global coordinates so the open
/// animation knows where to grow from.
///
/// This is deliberately a plain reference type rather than SwiftUI state:
/// writing a frame here must not invalidate any view. Publishing icon frames
/// upward (via a preference or observable state) re-enters layout inside the
/// paged `TabView` that hosts them, which feeds back into the same
/// measurement and wedges the view graph.
final class IconFrameBox {
    var rect: CGRect = .zero
}

/// Every icon's frame, shared upward for the same reason and under the same
/// rules as `IconFrameBox`: rearranging needs to know what sits where, and
/// publishing that through observable state would re-enter layout.
///
/// Read it from a gesture, never from a `body`.
final class IconFrameRegistry {
    private(set) var rects: [String: CGRect] = [:]
    /// page → slot index → frame, so an *empty* slot can be a drop target too.
    private var slots: [Int: [Int: CGRect]] = [:]

    func record(_ rect: CGRect, for id: String) { rects[id] = rect }
    func rect(for item: HomeItem) -> CGRect? { rects[item.id] }

    func recordSlot(_ rect: CGRect, page: Int, index: Int) {
        slots[page, default: [:]][index] = rect
    }

    func slotRects(page: Int) -> [(index: Int, rect: CGRect)] {
        (slots[page] ?? [:]).map { ($0.key, $0.value) }
    }
}

/// Something that can sit on the home screen: a built-in app, an app installed
/// from a package source, a folder holding either, or a placed container widget.
enum HomeItem: Hashable, Identifiable {
    case builtin(AppID)
    case guest(String)          // bundle identifier
    case folder(UUID)
    case widget(UUID)           // HomeLayoutStore.WidgetPlacement id

    var id: String {
        switch self {
        case .builtin(let app): "builtin.\(app.rawValue)"
        case .guest(let bundle): "guest.\(bundle)"
        case .folder(let uuid): "folder.\(uuid.uuidString)"
        case .widget(let uuid): "widget.\(uuid.uuidString)"
        }
    }

    var builtinApp: AppID? {
        if case .builtin(let app) = self { return app }
        return nil
    }

    var guestBundle: String? {
        if case .guest(let bundle) = self { return bundle }
        return nil
    }

    var folderID: UUID? {
        if case .folder(let uuid) = self { return uuid }
        return nil
    }

    var widgetID: UUID? {
        if case .widget(let uuid) = self { return uuid }
        return nil
    }

    var isWidget: Bool { widgetID != nil }

    /// Folders open; everything else launches.
    var isFolder: Bool { folderID != nil }
}

struct QuickAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    /// What the app should do once the action has opened it.
    let intent: AppIntent

    init(_ title: String, _ symbol: String, _ intent: AppIntent) {
        self.title = title
        self.symbol = symbol
        self.intent = intent
    }
}
