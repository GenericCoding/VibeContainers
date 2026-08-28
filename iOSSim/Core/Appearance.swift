import SwiftUI
import UIKit

/// Live theme settings, driven by the Customization page.
///
/// A singleton rather than an `@EnvironmentObject` so that `SysColor` can read
/// the accent from anywhere. That still tracks correctly: `@Observable` records
/// a dependency at the point of *access*, so any view whose body reads
/// `SysColor.blue` — even indirectly through a static — is invalidated when the
/// accent changes.
@Observable
final class Appearance {
    static let shared = Appearance()

    var accentIndex = 0
    var wallpaperStyle: WallpaperStyle {
        didSet {
            UserDefaults.standard.set(wallpaperStyle.rawValue, forKey: Self.wallpaperStyleKey)
        }
    }
    var showMotes = true
    var moteDensity: Double = 0.5
    var scanlines = true
    var reduceMotion = false
    var columns = 4
    var showLabels = true
    var hideDockBackground = false
    var pageTransition: PageTransition = .slide

    private static let wallpaperStyleKey = "appearance.wallpaperStyle"

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.wallpaperStyleKey)
        wallpaperStyle = saved.flatMap(WallpaperStyle.init(rawValue:)) ?? .vibe
    }

    var accent: Color { AccentChoice.all[accentIndex].color }

    /// Dust scales from a few specks to a full beam.
    var moteCount: Int {
        showMotes ? Int((6 + moteDensity * 30).rounded()) : 0
    }

    /// Reduce Motion freezes the wallpaper and shortens the springboard's
    /// spring animations.
    var wallpaperAnimates: Bool { !reduceMotion }

    func animation(_ base: Animation) -> Animation {
        reduceMotion ? .easeOut(duration: 0.16) : base
    }
}

struct AccentChoice {
    let name: String
    let color: Color

    static let all: [AccentChoice] = [
        .init(name: "Blue", color: Color(uiColor: .systemBlue)),
        .init(name: "Indigo", color: Color(uiColor: .systemIndigo)),
        .init(name: "Green", color: Color(uiColor: .systemGreen)),
        .init(name: "Orange", color: Color(uiColor: .systemOrange)),
        .init(name: "Purple", color: Color(uiColor: .systemPurple)),
        .init(name: "Pink", color: Color(uiColor: .systemPink))
    ]
}

enum WallpaperStyle: String, CaseIterable, Identifiable {
    case vibe, aurora, ocean, graphite

    var id: String { rawValue }
    var title: String {
        switch self {
        case .vibe: "Vibe"
        case .aurora: "Aurora"
        case .ocean: "Ocean"
        case .graphite: "Graphite"
        }
    }
}
