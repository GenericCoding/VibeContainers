import SwiftUI

// MARK: - Icons

/// An item's tile. Category icons and rows share it, at different sizes.
struct XMBIconTile: View {
    let icon: XMBItemIcon
    var size: CGFloat = 46
    /// Lit rows glow; the rest sit back.
    var focused: Bool = true

    var body: some View {
        Group {
            switch icon {
            case .symbol(let name, let tint):
                Image(systemName: name)
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .shadow(color: tint.opacity(focused ? 0.75 : 0), radius: size * 0.32)

            case .package(let url, let tint):
                PackageIcon(url: url, tint: tint, size: size)

            case .swatch(let colors):
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .fill(LinearGradient(colors: colors.isEmpty ? [Palette.stone] : colors,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size, height: size)
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                            .strokeBorder(Palette.paper.opacity(0.18), lineWidth: 0.5)
                    )
            }
        }
        .opacity(focused ? 1 : 0.55)
        .saturation(focused ? 1 : 0.6)
    }
}

// MARK: - Button glyphs

/// The four PlayStation face-button marks, drawn rather than typeset — the
/// glyphs are not in any system font, and the legend has to read correctly on
/// a device that has never seen a PlayStation.
struct PSGlyph: View {
    enum Mark { case cross, circle, triangle, square }

    let mark: Mark
    var size: CGFloat = 17

    private var tint: Color {
        switch mark {
        case .cross: Palette.ice
        case .circle: Palette.clay
        case .triangle: Palette.sage
        case .square: Palette.rose
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint.opacity(0.55), lineWidth: 1)
                .background(Circle().fill(Palette.ink.opacity(0.55)))
            shape
                .stroke(tint, style: StrokeStyle(lineWidth: size * 0.10,
                                                 lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
        .frame(width: size, height: size)
    }

    private var shape: some Shape {
        switch mark {
        case .cross: AnyShape(CrossMark())
        case .circle: AnyShape(Circle())
        case .triangle: AnyShape(TriangleMark())
        case .square: AnyShape(Rectangle())
        }
    }

    private struct CrossMark: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            return path
        }
    }

    private struct TriangleMark: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

/// The strip along the bottom of the dashboard that says what the buttons do
/// *here* — the legend changes with the row, the way the PS3's does.
struct XMBLegend: View {
    let entries: [(PSGlyph.Mark, String)]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 6) {
                    PSGlyph(mark: entry.0, size: 16)
                    Text(entry.1)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.paper.opacity(0.85))
                }
            }
        }
    }
}

// MARK: - Clock

/// Date and time, top right, where the PS3 puts them.
struct XMBClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let date = context.date
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(date, format: .dateTime.day().month(.abbreviated))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.paperDim)
                Text(date, format: .dateTime.hour().minute())
                    .font(.system(size: 19, weight: .light, design: .rounded))
                    .foregroundStyle(Palette.paper)
            }
            .shadow(color: Palette.ink.opacity(0.8), radius: 6)
        }
    }
}

// MARK: - Information panel

/// The information panel opened explicitly with △.
struct XMBInfoOverlay: View {
    let info: XMBInfo
    /// Set when the panel was opened with △ rather than by waiting, which is
    /// worth saying so the ○ that closes it is not a surprise.
    let pinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                if let icon = info.icon {
                    XMBIconTile(icon: icon, size: 56)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.paper)
                        .lineLimit(2)
                    if let subtitle = info.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.paperDim)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, info.lines.isEmpty && info.body == nil ? 0 : 14)

            if !info.lines.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(info.lines.enumerated()), id: \.element.id) { index, line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.paperDim)
                            Spacer(minLength: 12)
                            Text(line.value)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.paper)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 5)

                        if index != info.lines.count - 1 {
                            Rectangle()
                                .fill(Palette.hairline)
                                .frame(height: 0.5)
                        }
                    }
                }
            }

            if let body = info.body, !body.isEmpty {
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.paper.opacity(0.75))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            if let footnote = info.footnote {
                Text(footnote)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.paperDim.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 10)
            }

            if pinned {
                HStack(spacing: 6) {
                    PSGlyph(mark: .circle, size: 13)
                    Text("Close")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.paperDim)
                }
                .padding(.top, 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(
                            colors: [info.accent.opacity(0.16), Palette.ink.opacity(0.55)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(info.accent.opacity(0.45), lineWidth: 0.75)
                }
        }
        // The lit edge the PS3 draws down the side of an information panel.
        .overlay(alignment: .leading) {
            Capsule()
                .fill(info.accent)
                .frame(width: 2)
                .padding(.vertical, 14)
                .blur(radius: 0.5)
                .shadow(color: info.accent.opacity(0.9), radius: 6)
        }
        .shadow(color: Palette.ink.opacity(0.7), radius: 22, y: 10)
    }
}

// MARK: - Rows

/// One row of a column or a page.
struct XMBRow: View {
    let item: XMBItem
    let focused: Bool
    var iconSize: CGFloat = 44
    /// Pages give the title more room; columns keep the icon large and the
    /// text tight against it.
    var wide = false

    var body: some View {
        HStack(spacing: 12) {
            XMBIconTile(icon: item.icon, size: iconSize, focused: focused)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: focused ? 16 : 14,
                                  weight: focused ? .semibold : .regular))
                    .foregroundStyle(item.dimmed && !focused
                                     ? Palette.paperDim
                                     : Palette.paper.opacity(focused ? 1 : 0.72))
                    .lineLimit(1)

                if let subtitle = item.subtitle, focused || wide {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.paperDim)
                        .lineLimit(1)
                }

                if let progress = item.progress, focused {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Palette.ice)
                        .frame(width: 150)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            if let badge = item.badge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.badgeTint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(item.badgeTint.opacity(focused ? 0.18 : 0.10))
                    )
                    .opacity(focused ? 1 : 0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if focused {
                // The lit bar under the selection: brightest at the icon and
                // running out to nothing on the right, which is how the XMB
                // marks the cursor.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Palette.paper.opacity(0.20), Palette.paper.opacity(0.02)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Palette.ice)
                            .frame(width: 2)
                            .shadow(color: Palette.ice, radius: 5)
                    }
            }
        }
    }
}

// MARK: - Toast

struct XMBToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.paper)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().strokeBorder(Palette.ice.opacity(0.4), lineWidth: 0.75))
            }
            .shadow(color: Palette.ink.opacity(0.6), radius: 14, y: 6)
    }
}

/// The strip the Music column leaves behind when something is playing.
struct XMBNowPlaying: View {
    let song: Song

    var body: some View {
        HStack(spacing: 9) {
            XMBIconTile(icon: .swatch(song.colors), size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.paper)
                Text(song.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.paperDim)
            }
            Image(systemName: "waveform")
                .font(.system(size: 12))
                .foregroundStyle(Palette.sage)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(Palette.sage.opacity(0.3), lineWidth: 0.75))
        }
    }
}
