import SwiftUI

/// The categories along the crossbar, in the PS3's own order.
///
/// The set is trimmed to what this device actually has — there is no TV tuner
/// and no PSN to sign into — but the ordering, the icon vocabulary and the
/// per-column tint are the dashboard's.
enum XMBCategory: String, CaseIterable, Identifiable {
    case users, settings, photo, music, video, game, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .users: "Users"
        case .settings: "Settings"
        case .photo: "Photo"
        case .music: "Music"
        case .video: "Video"
        case .game: "Game"
        case .network: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .users: "person.fill"
        case .settings: "wrench.and.screwdriver.fill"
        case .photo: "camera.fill"
        case .music: "music.note"
        case .video: "film.fill"
        case .game: "gamecontroller.fill"
        case .network: "globe"
        }
    }

    /// Each column is lit its own colour, and the wave behind the whole
    /// dashboard picks the selected one up.
    var tint: Color {
        switch self {
        case .users: Palette.wheat
        case .settings: Palette.stone
        case .photo: Palette.mauve
        case .music: Palette.sage
        case .video: Palette.clay
        case .game: Palette.ice
        case .network: Palette.denim
        }
    }
}

/// How an item draws its 48-point tile.
enum XMBItemIcon {
    case symbol(String, Color)
    /// A package icon from a repo, or a sideloaded app's extracted artwork.
    case package(url: String?, tint: String?)
    /// A drawn gradient, for photos and anything else with no real artwork.
    case swatch([Color])
}

/// One row of a column.
///
/// `activate` and `secondary` are closures rather than an action enum because
/// items are rebuilt from the stores on every read — there is no stored item
/// graph to keep in step, so the row that is on screen is always holding the
/// action that matches the state it was drawn from.
struct XMBItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    var icon: XMBItemIcon = .symbol("circle", Palette.ice)
    /// Drawn on the right of the row: a version, a count, "INSTALLED".
    var badge: String?
    var badgeTint: Color = Palette.ice
    /// Shown in the hover panel once the cursor has rested here for a beat.
    var info: XMBInfo?
    /// ✕ / →
    var activate: (() -> Void)?
    /// □
    var secondary: (() -> Void)?
    var secondaryTitle: String?
    /// ← / → on a settings page, for rows that hold a value.
    var adjust: ((Int) -> Void)?
    /// A live 0…1 bar under the title — downloads, volume, mote density.
    var progress: Double?
    var dimmed = false
}

/// The contents of the hover panel.
struct XMBInfo {
    var title: String
    var subtitle: String?
    var icon: XMBItemIcon?
    var lines: [XMBInfoLine] = []
    var body: String?
    var footnote: String?
    var accent: Color = Palette.ice
}

struct XMBInfoLine: Identifiable {
    let label: String
    let value: String
    var id: String { label + value }
}

/// Which column is being shown. The root of the stack is always a category;
/// everything else was pushed onto it.
enum XMBColumnID: Hashable {
    case category(XMBCategory)
    /// Every app in every repo, which is what the Game column's first item
    /// opens.
    case allPackages
    case source(UUID)
    case installed
    case updates
    case sources
    case tweaks

    // Pages — same navigation, drawn as a settings panel rather than a column.
    case httpServer
    case jit
    case theme
    case sound
    case controllers
    case about
    case connection
    case package(String)
    case guest(String)
    case article(String)
}

extension XMBColumnID {
    /// A page fills the right-hand side and shows its rows in a framed panel;
    /// a list is a plain XMB column hanging off the crossbar.
    var isPage: Bool {
        switch self {
        case .httpServer, .jit, .theme, .sound, .controllers, .about,
             .connection, .package, .guest, .article:
            true
        default:
            false
        }
    }
}
