import SwiftUI

/// The glyph + background for every app icon, drawn with shapes and SF Symbols
/// so nothing depends on bundled image assets.
struct IconArtwork: View {
    let app: AppID
    var size: CGFloat = 60

    var body: some View {
        ZStack {
            background
            glyph
        }
        .frame(width: size, height: size)
        .clipShape(Squircle(cornerRadius: Metrics.iconCorner(for: size)))
        .overlay(
            Squircle(cornerRadius: Metrics.iconCorner(for: size))
                .strokeBorder(Palette.paper.opacity(0.14), lineWidth: 0.5)
        )
    }

    private var unit: CGFloat { size / 60 }

    // MARK: - Backgrounds

    /// Icon tiles, lit from above.
    ///
    /// Every one is a cold, saturated ramp rather than a flat fill — the look
    /// of the era this theme comes from, where an icon was a little pane of
    /// coloured glass. The warm ones (Notes, Music) are deliberate exceptions:
    /// a set that is entirely blue stops being readable at a glance.
    @ViewBuilder private var background: some View {
        switch app {
        case .photos, .camera:
            gradient("2E3F5C", "141D2E")
        case .calculator:
            gradient("1B2231", "0A0E17")
        case .clock:
            gradient("16203A", "070B16")
        case .reminders:
            gradient("232B44", "0D1220")
        case .mail:
            gradient("4C9BFF", "1B4C9E")
        case .notes:
            gradient("FFCF6B", "D08A22")
        case .settings:
            // Gunmetal, with a cold sheen off the top-left so the gear has
            // something to catch the light against.
            ZStack {
                gradient("6E7C93", "2C3648")
                RadialGradient(
                    colors: [Palette.specular.opacity(0.32), .clear],
                    center: UnitPoint(x: 0.28, y: 0.18),
                    startRadius: 0,
                    endRadius: 46 * unit
                )
            }
        case .weather:
            gradient("5AB4FF", "1D5FA8")
        case .calendar:
            gradient("EAF2FF", "AFC4E0")
        case .stocks:
            gradient("101827", "05070E")
        case .maps:
            gradient("3FBFA0", "13624F")
        case .phone:
            gradient("4ADE9B", "12704C")
        case .safari:
            gradient("8FD8FF", "2C6FA8")
        case .messages:
            gradient("58E08A", "12703F")
        case .music:
            gradient("FF7BC0", "9B2C6B")
        }
    }

    private func gradient(_ top: String, _ bottom: String) -> LinearGradient {
        LinearGradient(colors: [Color(hex: top), Color(hex: bottom)],
                       startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Glyphs

    @ViewBuilder private var glyph: some View {
        switch app {
        case .photos:
            PhotosPinwheel().frame(width: 40 * unit, height: 40 * unit)

        case .camera:
            CameraGlyph().frame(width: 40 * unit, height: 40 * unit)

        case .calculator:
            CalculatorGlyph().frame(width: 44 * unit, height: 48 * unit)

        case .clock:
            ClockFace(showsSecondHand: true).frame(width: 52 * unit, height: 52 * unit)

        case .reminders:
            RemindersGlyph().frame(width: 34 * unit, height: 34 * unit)

        case .mail:
            EnvelopeGlyph().frame(width: 38 * unit, height: 27 * unit)

        case .notes:
            NotesGlyph().frame(width: 60 * unit, height: 60 * unit)

        case .settings:
            GearGlyph().frame(width: 46 * unit, height: 46 * unit)

        case .weather:
            WeatherGlyph().frame(width: 44 * unit, height: 38 * unit)

        case .calendar:
            CalendarGlyph().frame(width: 60 * unit, height: 60 * unit)

        case .stocks:
            StocksGlyph().frame(width: 40 * unit, height: 30 * unit)

        case .maps:
            MapsGlyph().frame(width: 60 * unit, height: 60 * unit)

        case .phone:
            Image(systemName: "phone.fill")
                .font(.system(size: 32 * unit, weight: .medium))
                .foregroundStyle(SysColor.label)

        case .safari:
            SafariCompass().frame(width: 52 * unit, height: 52 * unit)

        case .messages:
            SpeechBubble()
                .fill(Palette.paper)
                .frame(width: 40 * unit, height: 38 * unit)

        case .music:
            Image(systemName: "music.note")
                .font(.system(size: 34 * unit, weight: .medium))
                .foregroundStyle(SysColor.label)
        }
    }
}

// MARK: - Individual glyph shapes

private struct PhotosPinwheel: View {
    private let colors = ["DFC17C", "D79A5F", "C4705C", "C88E93", "A78CB4", "8285AB", "7C9EB8", "93AE7D"]

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    Ellipse()
                        .fill(Color(hex: colors[index]).opacity(0.85))
                        .frame(width: s * 0.30, height: s * 0.62)
                        .offset(y: -s * 0.19)
                        .rotationEffect(.degrees(Double(index) * 45))
                }
            }
            .blendMode(.multiply)
            .frame(width: s, height: s)
        }
        .compositingGroup()
    }
}

private struct CameraGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.22, style: .continuous)
                    .fill(Color(hex: "4A3D36"))
                    .frame(width: s, height: s * 0.78)
                Circle()
                    .fill(
                        RadialGradient(colors: [Color(hex: "7A6E64"), Color(hex: "241C19")],
                                       center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: s * 0.3)
                    )
                    .frame(width: s * 0.44)
                    .overlay(Circle().strokeBorder(Color(hex: "9C8B7D"), lineWidth: s * 0.03))
                Circle()
                    .fill(Color(hex: "9FBACD").opacity(0.6))
                    .frame(width: s * 0.14)
                    .offset(x: -s * 0.06, y: -s * 0.06)
                    .blur(radius: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct CalculatorGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let gap = w * 0.06
            let cell = (w - gap * 3) / 4

            VStack(spacing: gap) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(hex: "4A3D36"))
                    .frame(height: h * 0.16)

                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<4, id: \.self) { column in
                            RoundedRectangle(cornerRadius: cell * 0.22, style: .continuous)
                                .fill(color(row: row, column: column))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
    }

    private func color(row: Int, column: Int) -> Color {
        if column == 3 { return Palette.amber }
        if row == 0 { return Color(hex: "A5A5A5") }
        return Color(hex: "636366")
    }
}

struct ClockFace: View {
    var showsSecondHand = false
    var tint: Color = Palette.paper
    var faceColor: Color = Palette.paper

    /// Fixed anchor. Passing `.now` here re-anchors the schedule on every body
    /// pass, which makes the timeline invalidate itself continuously and pegs
    /// the main thread.
    private static let anchor = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        TimelineView(.periodic(from: Self.anchor, by: showsSecondHand ? 1 : 30)) { context in
            let calendar = Calendar.current
            let comps = calendar.dateComponents([.hour, .minute, .second], from: context.date)
            let hour = Double(comps.hour ?? 10)
            let minute = Double(comps.minute ?? 9)
            let second = Double(comps.second ?? 30)

            GeometryReader { geo in
                let s = min(geo.size.width, geo.size.height)

                ZStack {
                    Circle().fill(faceColor)

                    ForEach(0..<12, id: \.self) { tick in
                        Capsule()
                            .fill(Palette.ink.opacity(tick.isMultiple(of: 3) ? 0.85 : 0.35))
                            .frame(width: s * 0.018, height: s * (tick.isMultiple(of: 3) ? 0.075 : 0.05))
                            .offset(y: -s * 0.42)
                            .rotationEffect(.degrees(Double(tick) * 30))
                    }

                    hand(length: s * 0.26, width: s * 0.045, color: Palette.ink,
                         angle: (hour.truncatingRemainder(dividingBy: 12) + minute / 60) * 30)
                    hand(length: s * 0.36, width: s * 0.035, color: Palette.ink,
                         angle: minute * 6)

                    if showsSecondHand {
                        hand(length: s * 0.38, width: s * 0.018, color: Palette.clay,
                             angle: second * 6)
                    }

                    Circle()
                        .fill(Palette.amber)
                        .frame(width: s * 0.06)
                }
            }
        }
    }

    private func hand(length: CGFloat, width: CGFloat, color: Color, angle: Double) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(angle))
    }
}

private struct RemindersGlyph: View {
    private let colors = ["C4705C", "D79A5F", "7C9EB8", "8C7F74"]

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            VStack(spacing: s * 0.12) {
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: s * 0.14) {
                        Circle()
                            .fill(Color(hex: colors[index]))
                            .frame(width: s * 0.17)
                        Capsule()
                            .fill(Palette.paper.opacity(0.55))
                            .frame(height: s * 0.075)
                    }
                }
            }
        }
    }
}

private struct EnvelopeGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.14, style: .continuous)
                    .fill(Palette.paper)
                Path { path in
                    path.move(to: CGPoint(x: w * 0.06, y: h * 0.16))
                    path.addLine(to: CGPoint(x: w / 2, y: h * 0.62))
                    path.addLine(to: CGPoint(x: w * 0.94, y: h * 0.16))
                }
                .stroke(Color(hex: "5F809C"), style: StrokeStyle(lineWidth: h * 0.11, lineJoin: .round))
            }
        }
    }
}

private struct NotesGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .top) {
                Color.clear
                Rectangle()
                    .fill(Palette.paper.opacity(0.92))
                    .frame(height: h * 0.26)
                VStack(spacing: h * 0.075) {
                    ForEach(0..<4, id: \.self) { _ in
                        Rectangle()
                            .fill(Palette.ink.opacity(0.16))
                            .frame(height: h * 0.022)
                    }
                }
                .padding(.horizontal, w * 0.17)
                .padding(.top, h * 0.40)
            }
        }
    }
}

/// A machined gear: tapered teeth on a solid ring, with the hub punched out so
/// the icon's own metal shows through it.
///
/// The teeth are one continuous outline rather than a fan of overlapping bars.
/// Stacked bars gave every tooth the same blunt width at the tip and the root,
/// and their translucent edges seamed where they crossed; a single path takes
/// the flanks in at an angle, which is what makes the shape read as a gear at
/// 60pt and still hold up at the 512pt the launch transition scales it to.
struct GearShape: Shape {
    var teeth = 9
    /// All radii are fractions of the shape's half-extent.
    var tipRadius: CGFloat = 0.47
    var rootRadius: CGFloat = 0.355
    var hubRadius: CGFloat = 0.155
    /// Share of one tooth's pitch taken by the flat tip, and by each flank.
    var tipShare: CGFloat = 0.40
    var flankShare: CGFloat = 0.14

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let extent = min(rect.width, rect.height)
        let tip = extent * tipRadius
        let root = extent * rootRadius
        let pitch = 2 * CGFloat.pi / CGFloat(teeth)
        let halfTip = pitch * tipShare / 2
        let flank = pitch * flankShare

        var path = Path()
        for index in 0..<teeth {
            // Start a tooth centred on straight up, so the gear is symmetric
            // about the vertical no matter how many teeth it has.
            let axis = -CGFloat.pi / 2 + CGFloat(index) * pitch
            path.addArc(center: center, radius: tip,
                        startAngle: .radians(axis - halfTip),
                        endAngle: .radians(axis + halfTip),
                        clockwise: false)
            path.addArc(center: center, radius: root,
                        startAngle: .radians(axis + halfTip + flank),
                        endAngle: .radians(axis + pitch - halfTip - flank),
                        clockwise: false)
        }
        path.closeSubpath()

        // A second subpath, filled even-odd, is the hub hole.
        let hub = extent * hubRadius
        path.addEllipse(in: CGRect(x: center.x - hub, y: center.y - hub,
                                   width: hub * 2, height: hub * 2))
        return path
    }
}

private struct GearGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let gear = GearShape()
            // Stroking the same outline with a round join is what rounds the
            // tooth corners; the fill radii above are set back by half of it.
            let rounding = StrokeStyle(lineWidth: s * 0.05, lineCap: .round, lineJoin: .round)

            ZStack {
                gear.fill(metal, style: FillStyle(eoFill: true))
                gear.stroke(metal, style: rounding)

                // The machined edge of the hub, and a hairline of shade under
                // the top teeth, give the disc some thickness.
                Circle()
                    .strokeBorder(Palette.ink.opacity(0.16), lineWidth: s * 0.022)
                    .frame(width: s * 0.34, height: s * 0.34)
            }
            .frame(width: s, height: s)
            .shadow(color: Palette.ink.opacity(0.30), radius: s * 0.035, y: s * 0.02)
        }
    }

    private var metal: LinearGradient {
        LinearGradient(
            colors: [Palette.paper, Color(hex: "DCCDBA")],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct WeatherGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Sun
                ZStack {
                    ForEach(0..<8, id: \.self) { index in
                        Capsule()
                            .fill(Palette.wheat)
                            .frame(width: w * 0.05, height: w * 0.40)
                            .rotationEffect(.degrees(Double(index) * 45))
                    }
                    Circle()
                        .fill(Palette.wheat)
                        .frame(width: w * 0.26)
                }
                .position(x: w * 0.32, y: h * 0.30)

                // Cloud
                ZStack {
                    Circle().frame(width: w * 0.38).offset(x: -w * 0.16)
                    Circle().frame(width: w * 0.50).offset(x: w * 0.04, y: -w * 0.05)
                    Circle().frame(width: w * 0.34).offset(x: w * 0.24, y: w * 0.01)
                    Capsule().frame(width: w * 0.66, height: w * 0.26).offset(x: w * 0.03, y: w * 0.08)
                }
                .foregroundStyle(SysColor.label)
                .position(x: w * 0.55, y: h * 0.66)
            }
        }
    }
}

private struct CalendarGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 0) {
                Text(Date().formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(.system(size: h * 0.11, weight: .semibold))
                    .foregroundStyle(Palette.clay)
                    .padding(.top, h * 0.11)
                Text(Date().formatted(.dateTime.day()))
                    .font(.system(size: h * 0.52, weight: .light))
                    .foregroundStyle(Palette.ink)
                    .padding(.top, -h * 0.04)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct StocksGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                path.move(to: CGPoint(x: 0, y: h * 0.82))
                path.addLine(to: CGPoint(x: w * 0.28, y: h * 0.50))
                path.addLine(to: CGPoint(x: w * 0.48, y: h * 0.66))
                path.addLine(to: CGPoint(x: w * 0.72, y: h * 0.20))
                path.addLine(to: CGPoint(x: w, y: h * 0.05))
            }
            .stroke(Palette.sage,
                    style: StrokeStyle(lineWidth: h * 0.12, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct MapsGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.72))
                    path.addQuadCurve(to: CGPoint(x: w, y: h * 0.52),
                                      control: CGPoint(x: w * 0.5, y: h * 0.94))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                }
                .fill(Color(hex: "7C9EB8"))

                Path { path in
                    path.move(to: CGPoint(x: w * 0.08, y: 0))
                    path.addQuadCurve(to: CGPoint(x: w * 0.72, y: h),
                                      control: CGPoint(x: w * 0.62, y: h * 0.45))
                }
                .stroke(Color(hex: "F0E6D8"), style: StrokeStyle(lineWidth: h * 0.075, lineCap: .round))

                Image(systemName: "location.fill")
                    .font(.system(size: h * 0.24))
                    .foregroundStyle(SysColor.label)
                    .padding(h * 0.09)
                    .background(Circle().fill(Palette.clay))
                    .position(x: w * 0.68, y: h * 0.34)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
        }
    }
}

private struct SafariCompass: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(colors: [Color(hex: "8FAFC6"), Color(hex: "5F809C"),
                                                 Color(hex: "8FAFC6")], center: .center)
                    )
                Circle().fill(Palette.paper).frame(width: s * 0.86)
                Circle()
                    .strokeBorder(Color(hex: "C6B7A5"), lineWidth: s * 0.02)
                    .frame(width: s * 0.80)

                ForEach(0..<32, id: \.self) { tick in
                    Capsule()
                        .fill(Color(hex: "9C8B7D").opacity(tick.isMultiple(of: 4) ? 0.9 : 0.4))
                        .frame(width: s * 0.012, height: s * (tick.isMultiple(of: 4) ? 0.07 : 0.045))
                        .offset(y: -s * 0.36)
                        .rotationEffect(.degrees(Double(tick) * 11.25))
                }

                // Needle
                ZStack {
                    Triangle().fill(Palette.clay)
                        .frame(width: s * 0.15, height: s * 0.33)
                        .offset(y: -s * 0.165)
                    Triangle().fill(Color(hex: "E6D9C8"))
                        .frame(width: s * 0.15, height: s * 0.33)
                        .rotationEffect(.degrees(180))
                        .offset(y: s * 0.165)
                }
                .rotationEffect(.degrees(45))
            }
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct SpeechBubble: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bodyRect = CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.86)
        path.addRoundedRect(in: bodyRect,
                            cornerSize: CGSize(width: rect.width * 0.32, height: rect.width * 0.32),
                            style: .continuous)
        path.move(to: CGPoint(x: rect.width * 0.20, y: rect.height * 0.72))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.06, y: rect.height),
                          control: CGPoint(x: rect.width * 0.16, y: rect.height * 0.95))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.80),
                          control: CGPoint(x: rect.width * 0.30, y: rect.height * 0.92))
        path.closeSubpath()
        return path
    }
}
