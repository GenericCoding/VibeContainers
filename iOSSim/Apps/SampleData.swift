import SwiftUI

// MARK: - Weather

struct HourSlot {
    let hour: String
    let symbol: String
    let temp: Int
}

struct DayForecast: Identifiable {
    let id = UUID()
    let day: String
    let symbol: String
    let low: Int
    let high: Int
}

enum WeatherData {
    static let hourly: [HourSlot] = [
        .init(hour: "Now", symbol: "sun.max.fill", temp: 72),
        .init(hour: "1PM", symbol: "sun.max.fill", temp: 74),
        .init(hour: "2PM", symbol: "cloud.sun.fill", temp: 76),
        .init(hour: "3PM", symbol: "cloud.sun.fill", temp: 77),
        .init(hour: "4PM", symbol: "sun.max.fill", temp: 76),
        .init(hour: "5PM", symbol: "sun.max.fill", temp: 73),
        .init(hour: "6PM", symbol: "cloud.fill", temp: 69),
        .init(hour: "7PM", symbol: "cloud.fill", temp: 66),
        .init(hour: "8PM", symbol: "moon.stars.fill", temp: 64)
    ]

    static let daily: [DayForecast] = [
        .init(day: "Today", symbol: "sun.max.fill", low: 61, high: 78),
        .init(day: "Wed", symbol: "cloud.sun.fill", low: 60, high: 76),
        .init(day: "Thu", symbol: "cloud.fill", low: 58, high: 71),
        .init(day: "Fri", symbol: "cloud.rain.fill", low: 55, high: 66),
        .init(day: "Sat", symbol: "cloud.drizzle.fill", low: 54, high: 64),
        .init(day: "Sun", symbol: "sun.max.fill", low: 57, high: 72),
        .init(day: "Mon", symbol: "sun.max.fill", low: 59, high: 75),
        .init(day: "Tue", symbol: "cloud.sun.fill", low: 60, high: 74),
        .init(day: "Wed", symbol: "cloud.fill", low: 58, high: 70),
        .init(day: "Thu", symbol: "sun.max.fill", low: 61, high: 77)
    ]

    static let range = (min: 54, max: 78)
}

// MARK: - Calendar

struct CalendarEvent: Identifiable {
    let id = UUID()
    let title: String
    let time: String
    let location: String
    let color: Color
}

enum CalendarData {
    static let today: [CalendarEvent] = [
        .init(title: "Design review", time: "9:30 – 10:30 AM", location: "Studio B", color: Palette.denim),
        .init(title: "Lunch with Sam", time: "12:00 – 1:00 PM", location: "Caffè Macs", color: Palette.amber),
        .init(title: "Ship build 41", time: "3:00 – 3:30 PM", location: "Remote", color: Palette.sage),
        .init(title: "Gym", time: "6:00 – 7:00 PM", location: "Downtown", color: Palette.mauve)
    ]
}

// MARK: - Messages

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isMine: Bool
}

struct Conversation: Identifiable {
    let id = UUID()
    let name: String
    let time: String
    var unread: Bool
    var messages: [ChatMessage]

    var preview: String { messages.last?.text ?? "" }

    var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }

    var tint: Color {
        let palette: [Color] = [Palette.denim, Palette.mauve, Palette.rose,
                                Palette.seafoam, Palette.amber, Palette.dusk]
        return palette[abs(name.hashValue) % palette.count]
    }
}

enum MessagesData {
    static let conversations: [Conversation] = [
        .init(name: "Sam Rivera", time: "11:42 AM", unread: true, messages: [
            .init(text: "Did you see the new springboard build?", isMine: false),
            .init(text: "Just pulled it — the launch animation is unreal", isMine: true),
            .init(text: "Right? The icon morph lands perfectly now", isMine: false),
            .init(text: "Ship it 🚀", isMine: true),
            .init(text: "Demo at 3? I'll bring the good coffee", isMine: false)
        ]),
        .init(name: "Mom", time: "10:15 AM", unread: true, messages: [
            .init(text: "Are you coming for dinner Sunday?", isMine: false),
            .init(text: "Wouldn't miss it", isMine: true),
            .init(text: "Bring the sourdough starter 🥖", isMine: false)
        ]),
        .init(name: "Jordan Lee", time: "Yesterday", unread: true, messages: [
            .init(text: "Pushed the fix for the scroll jitter", isMine: false),
            .init(text: "Legend. Reviewing now.", isMine: true)
        ]),
        .init(name: "Design Team", time: "Yesterday", unread: false, messages: [
            .init(text: "New icon grid specs are in Figma", isMine: false),
            .init(text: "22pt spacing looks much better", isMine: true)
        ]),
        .init(name: "Priya Nair", time: "Monday", unread: false, messages: [
            .init(text: "Coffee tomorrow?", isMine: false),
            .init(text: "Always ☕️", isMine: true)
        ]),
        .init(name: "Alex Chen", time: "Monday", unread: false, messages: [
            .init(text: "Sent the deck over", isMine: false),
            .init(text: "Got it, thanks!", isMine: true)
        ]),
        .init(name: "Delivery", time: "Sunday", unread: false, messages: [
            .init(text: "Your package was left at the front door.", isMine: false)
        ])
    ]

    static let replies = [
        "Sounds good 👍",
        "On it!",
        "Ha, fair enough",
        "Let me check and get back to you",
        "Perfect timing",
        "Can you send that over?"
    ]
}

// MARK: - Mail

struct MailItem: Identifiable {
    let id = UUID()
    let sender: String
    let subject: String
    let preview: String
    let date: String
    var unread: Bool
    var flagged: Bool = false
    let body: String
}

enum MailData {
    static let inbox: [MailItem] = [
        .init(sender: "App Store Connect", subject: "Your app is ready for review",
              preview: "Version 1.0 of iOS Sim has completed processing and is…",
              date: "11:24 AM", unread: true,
              body: "Version 1.0 of iOS Sim has completed processing and is ready for you to submit for review.\n\nYou can submit it from App Store Connect at any time.\n\nThe App Store Team"),
        .init(sender: "Jordan Lee", subject: "Re: Springboard transitions",
              preview: "The corner-radius interpolation is what sells it. Nice…",
              date: "10:02 AM", unread: true, flagged: true,
              body: "The corner-radius interpolation is what sells it. Nice catch on matching the icon curve to the screen curve — that's the detail everyone misses.\n\nOne ask: can we get the interactive swipe-to-close in before Friday?\n\n— J"),
        .init(sender: "TestFlight", subject: "Build 41 is available to test",
              preview: "iOS Sim — Build 41 is now available for testing.",
              date: "9:15 AM", unread: true,
              body: "iOS Sim — Build 41 is now available for testing.\n\nWhat to test: launch animation timing, app open/close gestures, and the new widget row on page one."),
        .init(sender: "Priya Nair", subject: "Design review notes",
              preview: "Attaching the annotated screenshots from this morning.",
              date: "Yesterday", unread: false,
              body: "Attaching the annotated screenshots from this morning.\n\nBiggest wins: the dock material and the icon shadows. Biggest gap: page two feels empty — maybe a search field?\n\nP"),
        .init(sender: "GitHub", subject: "[iossim] 3 new pull requests",
              preview: "Weekly digest for the repositories you watch.",
              date: "Yesterday", unread: false,
              body: "Weekly digest for the repositories you watch.\n\n#128 Add interactive close gesture\n#129 Fix status bar tint in Photos\n#130 Calculator: chained operations"),
        .init(sender: "Sam Rivera", subject: "Coffee + demo at 3?",
              preview: "Booked Studio B. Bringing the good beans.",
              date: "Monday", unread: false,
              body: "Booked Studio B. Bringing the good beans.\n\nWant to run through the whole flow start to finish — cold boot, springboard, then a couple of apps."),
        .init(sender: "Calendar", subject: "Invitation: Ship build 41",
              preview: "You have been invited to an event on Friday at 3:00 PM.",
              date: "Monday", unread: false,
              body: "You have been invited to an event.\n\nShip build 41\nFriday, 3:00 – 3:30 PM\nRemote")
    ]
}

// MARK: - Notes

struct Note: Identifiable {
    let id = UUID()
    var title: String
    var body: String
    var date: String

    var preview: String {
        body.split(separator: "\n").dropFirst().first.map(String.init) ?? "No additional text"
    }
}

enum NotesData {
    static let notes: [Note] = [
        .init(title: "Springboard punch list",
              body: "Springboard punch list\nIcon corner radius = 0.2237 × size\nDock uses ultraThinMaterial\nPage dots sit 14pt above the dock\nJiggle mode: 1.7° rotation, 0.26s loop",
              date: "11:20 AM"),
        .init(title: "Groceries",
              body: "Groceries\nSourdough starter\nOat milk\nEspresso beans\nLemons\nOlive oil",
              date: "9:04 AM"),
        .init(title: "Launch animation timing",
              body: "Launch animation timing\nRings draw over 1.05s\nWordmark resolves at 0.95s\nProgress bar fills 1.05 → 2.2s\nBloom + flash hand-off at 2.25s",
              date: "Yesterday"),
        .init(title: "Books to read",
              body: "Books to read\nThe Design of Everyday Things\nRefactoring UI\nThinking in Systems",
              date: "Tuesday"),
        .init(title: "Trip ideas",
              body: "Trip ideas\nBig Sur — 2 nights\nPoint Reyes\nMendocino in the fall",
              date: "Aug 2")
    ]
}

// MARK: - Reminders

struct ReminderItem: Identifiable {
    let id = UUID()
    var title: String
    var done: Bool
    var note: String?
}

struct ReminderList: Identifiable {
    let id = UUID()
    let name: String
    let symbol: String
    let color: Color
    var items: [ReminderItem]
}

enum RemindersData {
    static let lists: [ReminderList] = [
        .init(name: "Today", symbol: "sun.max.fill", color: Palette.amber, items: [
            .init(title: "Review build 41", done: false, note: "Before the 3pm demo"),
            .init(title: "Reply to Priya", done: false, note: nil),
            .init(title: "Water the plants", done: true, note: nil)
        ]),
        .init(name: "Work", symbol: "briefcase.fill", color: Palette.denim, items: [
            .init(title: "Polish app open transition", done: false, note: nil),
            .init(title: "Write release notes", done: false, note: "Mention the widgets"),
            .init(title: "File radar for scroll jitter", done: true, note: nil)
        ]),
        .init(name: "Home", symbol: "house.fill", color: Palette.sage, items: [
            .init(title: "Pick up sourdough starter", done: false, note: nil),
            .init(title: "Fix the porch light", done: false, note: nil)
        ]),
        .init(name: "Reading", symbol: "book.fill", color: Palette.mauve, items: [
            .init(title: "Finish chapter 4", done: false, note: nil)
        ])
    ]
}

// MARK: - Stocks

struct Ticker: Identifiable {
    let id = UUID()
    let symbol: String
    let name: String
    let price: Double
    let change: Double
    let points: [CGFloat]

    var isUp: Bool { change >= 0 }
    var changeText: String { String(format: "%+.2f%%", change) }
    var priceText: String { String(format: "%.2f", price) }
}

enum StocksData {
    static let tickers: [Ticker] = [
        .init(symbol: "AAPL", name: "Apple Inc.", price: 228.41, change: 1.24,
              points: [0.4, 0.42, 0.38, 0.5, 0.55, 0.52, 0.62, 0.6, 0.72, 0.78, 0.74, 0.85]),
        .init(symbol: "NDAQ", name: "Nasdaq, Inc.", price: 74.88, change: 0.42,
              points: [0.5, 0.48, 0.53, 0.51, 0.58, 0.55, 0.6, 0.63, 0.61, 0.66, 0.7, 0.68]),
        .init(symbol: "TSLA", name: "Tesla, Inc.", price: 241.05, change: -2.16,
              points: [0.8, 0.76, 0.78, 0.7, 0.66, 0.68, 0.6, 0.55, 0.58, 0.48, 0.44, 0.4]),
        .init(symbol: "MSFT", name: "Microsoft Corp.", price: 415.60, change: 0.88,
              points: [0.45, 0.5, 0.47, 0.55, 0.6, 0.58, 0.64, 0.68, 0.66, 0.72, 0.75, 0.79]),
        .init(symbol: "AMZN", name: "Amazon.com, Inc.", price: 182.30, change: -0.54,
              points: [0.62, 0.6, 0.64, 0.58, 0.56, 0.6, 0.54, 0.52, 0.55, 0.5, 0.52, 0.48]),
        .init(symbol: "NVDA", name: "NVIDIA Corp.", price: 126.09, change: 3.41,
              points: [0.3, 0.34, 0.32, 0.42, 0.48, 0.46, 0.58, 0.64, 0.7, 0.76, 0.84, 0.92]),
        .init(symbol: "GOOG", name: "Alphabet Inc.", price: 168.77, change: 0.19,
              points: [0.55, 0.54, 0.56, 0.55, 0.57, 0.56, 0.58, 0.57, 0.59, 0.58, 0.6, 0.61])
    ]
}

// MARK: - Music

struct Song: Identifiable {
    let id = UUID()
    let title: String
    let artist: String
    let album: String
    let duration: Int          // seconds
    let colors: [Color]
}

enum MusicData {
    static let queue: [Song] = [
        .init(title: "Rainy Window", artist: "Sable Hours", album: "Tape Loops",
              duration: 214, colors: [Color(hex: "C4705C"), Color(hex: "D79A5F")]),
        .init(title: "Slow Transit", artist: "Kite Machine", album: "Northbound",
              duration: 187, colors: [Color(hex: "7C9EB8"), Color(hex: "A78CB4")]),
        .init(title: "Paper Lanterns", artist: "Odessa Bloom", album: "Late Bloom",
              duration: 245, colors: [Color(hex: "82AFA8"), Color(hex: "93AE7D")]),
        .init(title: "Dust & Vinyl", artist: "Sable Hours", album: "Tape Loops",
              duration: 198, colors: [Color(hex: "6B5B6E"), Color(hex: "8285AB")]),
        .init(title: "Second Cup", artist: "The Quiet Hours", album: "Interiors",
              duration: 226, colors: [Color(hex: "D79A5F"), Color(hex: "DFC17C")])
    ]
}

// MARK: - Phone

struct RecentCall: Identifiable {
    let id = UUID()
    let name: String
    let kind: String       // "mobile", "FaceTime Audio", …
    let time: String
    let missed: Bool
}

/// A contact the user added in the Phone app. The seeded contacts list is
/// empty on purpose — everything here arrives through New Contact.
struct PhoneContact: Identifiable {
    let id = UUID()
    let name: String
    let number: String

    var initials: String {
        let parts = name.split(separator: " ")
        return parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

enum PhoneData {
    static let recents: [RecentCall] = [
        .init(name: "Sam Rivera", kind: "mobile", time: "11:47 AM", missed: true),
        .init(name: "Mom", kind: "mobile", time: "9:30 AM", missed: false),
        .init(name: "Jordan Lee", kind: "FaceTime Audio", time: "Yesterday", missed: false),
        .init(name: "Unknown", kind: "San Jose, CA", time: "Yesterday", missed: true),
        .init(name: "Priya Nair", kind: "mobile", time: "Monday", missed: false),
        .init(name: "Dentist", kind: "office", time: "Monday", missed: false)
    ]
}

// MARK: - Photos

enum PhotosData {
    /// Deterministic gradient "photographs".
    static let palettes: [[Color]] = [
        [Color(hex: "C99B7B"), Color(hex: "A6725E"), Color(hex: "8C5A4C")],
        [Color(hex: "A78CB4"), Color(hex: "C88E93")],
        [Color(hex: "E0C9AE"), Color(hex: "C4A188")],
        [Color(hex: "93AE7D"), Color(hex: "82AFA8")],
        [Color(hex: "3B4E5E"), Color(hex: "7C9EB8"), Color(hex: "B7C7D3")],
        [Color(hex: "DFC17C"), Color(hex: "C4705C")],
        [Color(hex: "82AFA8"), Color(hex: "A78CB4")],
        [Color(hex: "4A413A"), Color(hex: "8C7F74")],
        [Color(hex: "C4A188"), Color(hex: "B08968")],
        [Color(hex: "3E3A42"), Color(hex: "6E8B93")],
        [Color(hex: "E8D3B0"), Color(hex: "D79A5F"), Color(hex: "C4705C")],
        [Color(hex: "93AE7D"), Color(hex: "6E8B93")]
    ]

    static let captions = [
        "Golden hour", "Rain on the window", "Second cup", "Back porch", "Fog rolling in",
        "Espresso", "Trailhead", "Blue hour", "Long drive home", "Paper lanterns",
        "Sunset ridge", "City rain"
    ]

    static func palette(_ index: Int) -> [Color] { palettes[index % palettes.count] }
    static func caption(_ index: Int) -> String { captions[index % captions.count] }

    static let count = 48
}

// MARK: - Safari

struct Favorite: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let color: Color
}

enum SafariData {
    static let favorites: [Favorite] = [
        .init(title: "Apple", symbol: "apple.logo", color: Palette.surfaceRaised),
        .init(title: "News", symbol: "newspaper.fill", color: Palette.clay),
        .init(title: "Maps", symbol: "map.fill", color: Palette.sage),
        .init(title: "Docs", symbol: "doc.text.fill", color: Palette.denim),
        .init(title: "Music", symbol: "music.note", color: Palette.rose),
        .init(title: "Photos", symbol: "photo.fill", color: Palette.amber),
        .init(title: "Mail", symbol: "envelope.fill", color: Palette.dusk),
        .init(title: "Search", symbol: "magnifyingglass", color: Palette.stone)
    ]

    static let readingList = [
        ("Designing the perfect launch animation", "uxdaily.com"),
        ("SwiftUI transitions, demystified", "swiftbyexample.dev"),
        ("A field guide to iOS spacing", "hig.notes")
    ]
}
