import SwiftUI

/// Hand-drawn artwork for the Settings rows.
///
/// These are shapes rather than SF Symbols so each entry gets a mark that is
/// actually its own — a symbol set would hand back the same rounded-rect
/// silhouette three times over.
enum SettingsMark {
    case about
    case controller
    case customization
    case jit
    case multitasking
    case tweaks
    case webServer
    case packages
}

struct SettingsMarkTile: View {
    let mark: SettingsMark
    var size: CGFloat = 29

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(colors: tint, startPoint: .top, endPoint: .bottom)
                )
            glyph
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Palette.ink.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var tint: [Color] {
        switch mark {
        case .about: [Color(hex: "9FB4C4"), Color(hex: "6B8398")]
        case .controller: [Color(hex: "7FA9D9"), Color(hex: "416B9B")]
        case .customization: [Color(hex: "BFA3C7"), Color(hex: "8E74A0")]
        case .jit: [Color(hex: "74C69D"), Color(hex: "2D6A4F")]
        case .multitasking: [Color(hex: "7C91E5"), Color(hex: "4656A8")]
        case .tweaks: [Color(hex: "C4705C"), Color(hex: "8E4535")]
        case .webServer: [Color(hex: "82AFA8"), Color(hex: "3F6B67")]
        case .packages: [Color(hex: "E0B478"), Color(hex: "C08A4C")]
        }
    }

    @ViewBuilder private var glyph: some View {
        switch mark {
        case .about: AboutGlyph(size: size)
        case .controller: ControllerGlyph(size: size)
        case .customization: SlidersGlyph(size: size)
        case .jit: JITGlyph(size: size)
        case .multitasking: WindowsGlyph(size: size)
        case .tweaks: DrillGlyph(size: size)
        case .webServer: ServerGlyph(size: size)
        case .packages: FolderGlyph(size: size)
        }
    }
}

/// Two overlapping app windows for the multitasking controls.
private struct WindowsGlyph: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                .stroke(Palette.paper.opacity(0.65), lineWidth: size * 0.06)
                .frame(width: size * 0.47, height: size * 0.42)
                .offset(x: -size * 0.10, y: -size * 0.09)
            RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                .fill(Palette.paper)
                .frame(width: size * 0.47, height: size * 0.42)
                .offset(x: size * 0.10, y: size * 0.09)
                .overlay {
                    Capsule()
                        .fill(Color(hex: "4656A8"))
                        .frame(width: size * 0.23, height: size * 0.045)
                        .offset(x: size * 0.10, y: -size * 0.035)
                }
        }
    }
}

/// A small gamepad face: d-pad on the left, buttons on the right.
private struct ControllerGlyph: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(Palette.paper)
                .frame(width: size * 0.68, height: size * 0.42)

            ZStack {
                Capsule().frame(width: size * 0.22, height: size * 0.065)
                Capsule().frame(width: size * 0.065, height: size * 0.22)
            }
            .foregroundStyle(Color(hex: "416B9B"))
            .offset(x: -size * 0.18)

            HStack(spacing: size * 0.055) {
                Circle()
                Circle()
            }
            .foregroundStyle(Color(hex: "416B9B"))
            .frame(width: size * 0.21, height: size * 0.075)
            .offset(x: size * 0.18)
        }
    }
}

/// A compact lightning bolt for executable-code/JIT status.
private struct JITGlyph: View {
    let size: CGFloat

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: size * 0.56, y: size * 0.15))
            path.addLine(to: CGPoint(x: size * 0.27, y: size * 0.54))
            path.addLine(to: CGPoint(x: size * 0.47, y: size * 0.54))
            path.addLine(to: CGPoint(x: size * 0.38, y: size * 0.85))
            path.addLine(to: CGPoint(x: size * 0.73, y: size * 0.42))
            path.addLine(to: CGPoint(x: size * 0.52, y: size * 0.42))
            path.closeSubpath()
        }
        .fill(Palette.paper)
        .frame(width: size, height: size)
    }
}

// MARK: - Marks

/// A serif-ish lowercase "i" set in a ring.
private struct AboutGlyph: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.paper.opacity(0.95), lineWidth: size * 0.055)
                .frame(width: size * 0.62, height: size * 0.62)

            VStack(spacing: size * 0.05) {
                Circle()
                    .fill(Palette.paper)
                    .frame(width: size * 0.075, height: size * 0.075)
                Capsule()
                    .fill(Palette.paper)
                    .frame(width: size * 0.075, height: size * 0.20)
            }
        }
    }
}

/// Three mixer sliders at different settings.
private struct SlidersGlyph: View {
    let size: CGFloat

    private let knobs: [CGFloat] = [0.68, 0.34, 0.55]

    var body: some View {
        VStack(spacing: size * 0.115) {
            ForEach(Array(knobs.enumerated()), id: \.offset) { _, position in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Palette.paper.opacity(0.55))
                        .frame(height: size * 0.055)

                    Circle()
                        .fill(Palette.paper)
                        .frame(width: size * 0.135, height: size * 0.135)
                        .offset(x: (size * 0.60 - size * 0.135) * position)
                }
                .frame(width: size * 0.60)
            }
        }
    }
}

/// A rack of two server units with their lights on, broadcasting.
///
/// The arcs are struck from a point *below* the rack so they read as one signal
/// spreading upward, which a pair of concentric circles centred on the box does
/// not — that just looks like a target.
private struct ServerGlyph: View {
    let size: CGFloat

    private var paper: Color { Palette.paper }
    private var shade: Color { Color(hex: "2F5551") }

    var body: some View {
        VStack(spacing: size * 0.055) {
            // Signal, rising out of the top unit.
            ZStack {
                ForEach(0..<2, id: \.self) { ring in
                    let span = size * (0.20 + CGFloat(ring) * 0.13)
                    Circle()
                        .trim(from: 0.60, to: 0.90)
                        .stroke(paper.opacity(ring == 0 ? 0.95 : 0.6),
                                style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                        .frame(width: span, height: span)
                }
            }
            .frame(height: size * 0.20)

            ForEach(0..<2, id: \.self) { unit in
                RoundedRectangle(cornerRadius: size * 0.035, style: .continuous)
                    .fill(paper)
                    .frame(width: size * 0.60, height: size * 0.17)
                    .overlay(alignment: .leading) {
                        HStack(spacing: size * 0.035) {
                            Circle()
                                .fill(unit == 0 ? Color(hex: "6FA88B") : shade)
                                .frame(width: size * 0.045, height: size * 0.045)
                            Circle()
                                .fill(shade.opacity(0.55))
                                .frame(width: size * 0.045, height: size * 0.045)
                        }
                        .padding(.leading, size * 0.055)
                    }
                    .overlay(alignment: .trailing) {
                        RoundedRectangle(cornerRadius: size * 0.008)
                            .fill(shade.opacity(0.5))
                            .frame(width: size * 0.14, height: size * 0.035)
                            .padding(.trailing, size * 0.055)
                    }
            }
        }
        .frame(width: size, height: size)
    }
}

/// A cordless drill, bit pointing left.
///
/// The parts are opaque and deliberately overlap so the body and grip read as
/// one silhouette without a seam. The grip is a single tapered shape: at the
/// 29pt a Settings row gives it, a separate battery pack and trigger were two
/// smudges under the handle rather than two details.
private struct DrillGlyph: View {
    let size: CGFloat

    private var paper: Color { Palette.paper }
    private var shade: Color { Color(hex: "8E4535") }

    var body: some View {
        ZStack {
            // Grip, raked back from the body and rounded off at the foot.
            RoundedRectangle(cornerRadius: size * 0.075, style: .continuous)
                .fill(paper)
                .frame(width: size * 0.155, height: size * 0.33)
                .offset(x: -size * 0.115, y: size * 0.14)
                .rotationEffect(.degrees(-9))

            // Motor housing, with a pair of cooling vents at the back.
            //
            // The overlay goes on before the offset, not after: `offset` moves
            // what is drawn without moving the layout frame, so an overlay
            // attached afterwards lines itself up against the part's *original*
            // position. That is what had the bit's flutes sitting on the motor.
            RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                .fill(paper)
                .frame(width: size * 0.46, height: size * 0.26)
                .overlay(alignment: .leading) {
                    VStack(spacing: size * 0.035) {
                        ForEach(0..<2, id: \.self) { _ in
                            Capsule()
                                .fill(shade.opacity(0.55))
                                .frame(width: size * 0.10, height: size * 0.022)
                        }
                    }
                    .padding(.leading, size * 0.035)
                }
                .offset(x: -size * 0.04, y: -size * 0.10)

            // Chuck, then a plain bit. Flutes on a bit this thin were three
            // ticks too small to read as anything but grit.
            RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                .fill(paper)
                .frame(width: size * 0.10, height: size * 0.17)
                .offset(x: size * 0.235, y: -size * 0.10)

            Capsule()
                .fill(paper)
                .frame(width: size * 0.20, height: size * 0.05)
                .offset(x: size * 0.35, y: -size * 0.10)
        }
        // Framed first, so every offset above is measured from the tile's centre
        // rather than from whatever box the stack happens to take from its
        // largest child — that is what makes the centring below exact.
        .frame(width: size, height: size)
        // The drill spans -0.27…0.45 across and -0.23…0.32 down, so this puts
        // its own centre on the tile's, then insets it like the other marks.
        .offset(x: -size * 0.09, y: -size * 0.0435)
        .scaleEffect(0.94)
        // Drawn pointing right, shown pointing left. Mirroring the finished
        // composition keeps every part in the right relationship: the vents stay
        // at the back of the motor, the flutes stay at the tip of the bit.
        .scaleEffect(x: -1)
    }
}

/// Classic folder with a tab, and a star on the flap.
private struct FolderGlyph: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            FolderShape()
                .fill(Palette.paper)
                .frame(width: size * 0.66, height: size * 0.54)

            Star(points: 5)
                .fill(Color(hex: "C08A4C"))
                .frame(width: size * 0.24, height: size * 0.24)
                .offset(y: size * 0.055)
        }
    }
}

private struct FolderShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let radius = w * 0.10
        let tabHeight = h * 0.20

        var path = Path()
        // Tab across the left third, then a step up to the body.
        path.move(to: CGPoint(x: 0, y: tabHeight + radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: tabHeight),
                          control: CGPoint(x: 0, y: tabHeight))
        path.addLine(to: CGPoint(x: w * 0.36, y: tabHeight))
        path.addLine(to: CGPoint(x: w * 0.44, y: 0))
        path.addLine(to: CGPoint(x: w - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: w, y: radius),
                          control: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h - radius))
        path.addQuadCurve(to: CGPoint(x: w - radius, y: h),
                          control: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: radius, y: h))
        path.addQuadCurve(to: CGPoint(x: 0, y: h - radius),
                          control: CGPoint(x: 0, y: h))
        path.closeSubpath()
        return path
    }
}

struct Star: Shape {
    var points: Int = 5

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.45
        let step = Double.pi / Double(points)

        var path = Path()
        for index in 0..<(points * 2) {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = Double(index) * step - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius,
                                y: center.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
