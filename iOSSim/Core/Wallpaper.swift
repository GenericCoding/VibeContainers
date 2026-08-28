import SwiftUI
import UIKit

/// A restrained, layered wallpaper for the touch home screen. Controller mode
/// keeps the animated XMB wave; SpringBoard gets the softer gradients and
/// depth cues of a modern iOS wallpaper.
struct Wallpaper: View {
    let size: CGSize

    private var appearance: Appearance { Appearance.shared }
    private var wallpapers: WallpaperStore { WallpaperStore.shared }

    @ViewBuilder
    var body: some View {
        if let selected = wallpapers.selected,
           let url = wallpapers.fileURL(for: selected) {
            ImportedWallpaperView(item: selected, url: url, animates: appearance.wallpaperAnimates)
                .frame(width: size.width, height: size.height)
                .clipped()
                .id(selected.id)
        } else if appearance.wallpaperStyle == .vibe,
                  let url = Bundle.main.url(
                    forResource: "wallpaper",
                    withExtension: "jpg"
                  ),
                  let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            BuiltInWallpaper(size: size)
        }
    }
}

private struct BuiltInWallpaper: View {
    let size: CGSize

    private var appearance: Appearance { Appearance.shared }

    var body: some View {
        ZStack {
            LinearGradient(colors: colors.base, startPoint: .topLeading, endPoint: .bottomTrailing)

            Circle()
                .fill(RadialGradient(colors: [colors.primary.opacity(0.9), .clear],
                                     center: .center, startRadius: 0, endRadius: size.width * 0.62))
                .frame(width: size.width * 1.28, height: size.width * 1.28)
                .offset(x: size.width * 0.30, y: -size.height * 0.30)
                .blur(radius: 18)

            Circle()
                .fill(RadialGradient(colors: [colors.secondary.opacity(0.72), .clear],
                                     center: .center, startRadius: 0, endRadius: size.width * 0.64))
                .frame(width: size.width * 1.35, height: size.width * 1.35)
                .offset(x: -size.width * 0.40, y: size.height * 0.25)
                .blur(radius: 30)

            WallpaperRibbon()
                .fill(LinearGradient(colors: [colors.highlight.opacity(0.66),
                                              colors.primary.opacity(0.12), .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .blur(radius: 8)

            LinearGradient(colors: [.black.opacity(0.06), .clear, .black.opacity(0.26)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var colors: WallpaperColors {
        switch appearance.wallpaperStyle {
        case .vibe:
            // The bundled Vibe photograph is rendered by `Wallpaper`; this
            // value only keeps the legacy gradient renderer exhaustive.
            WallpaperColors(base: [Color.black, Color.black],
                            primary: .clear, secondary: .clear,
                            highlight: .clear)
        case .aurora:
            WallpaperColors(base: [Color(hex: "10152B"), Color(hex: "172B4D"), Color(hex: "090C17")],
                            primary: Color(hex: "4F7DFF"), secondary: Color(hex: "8E5CFF"),
                            highlight: Color(hex: "65D8FF"))
        case .ocean:
            WallpaperColors(base: [Color(hex: "071E2E"), Color(hex: "0B4960"), Color(hex: "06121F")],
                            primary: Color(hex: "00A7C4"), secondary: Color(hex: "1D6FD6"),
                            highlight: Color(hex: "70E1E8"))
        case .graphite:
            WallpaperColors(base: [Color(hex: "16181D"), Color(hex: "30343C"), Color(hex: "090A0D")],
                            primary: Color(hex: "667080"), secondary: Color(hex: "3E4653"),
                            highlight: Color(hex: "C7CED9"))
        }
    }
}

private struct WallpaperColors {
    let base: [Color]
    let primary: Color
    let secondary: Color
    let highlight: Color
}

private struct WallpaperRibbon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - rect.width * 0.1, y: rect.height * 0.54))
        path.addCurve(to: CGPoint(x: rect.maxX * 1.1, y: rect.height * 0.35),
                      control1: CGPoint(x: rect.width * 0.30, y: rect.height * 0.34),
                      control2: CGPoint(x: rect.width * 0.68, y: rect.height * 0.62))
        path.addLine(to: CGPoint(x: rect.maxX * 1.1, y: rect.height * 0.49))
        path.addCurve(to: CGPoint(x: rect.minX - rect.width * 0.1, y: rect.height * 0.68),
                      control1: CGPoint(x: rect.width * 0.70, y: rect.height * 0.72),
                      control2: CGPoint(x: rect.width * 0.24, y: rect.height * 0.43))
        path.closeSubpath()
        return path
    }
}
