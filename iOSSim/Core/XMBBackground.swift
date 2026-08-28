import SwiftUI

/// The live background: a cold gradient with a light ribbon moving through it,
/// dust in the beam, and a vignette closing the corners.
///
/// This is the PS3 dashboard's wave, rebuilt from sines rather than shipped as
/// a video. Three ribbons run at different frequencies and speeds so the crests
/// drift in and out of phase and the pattern never visibly loops; each one is a
/// filled falloff with a bright crest struck over it in `plusLighter`, which is
/// what makes the light look additive instead of painted.
///
/// It is one `Canvas` inside one `TimelineView`: the whole scene is a single
/// draw per frame with no view-tree churn, which is the only way something this
/// busy can sit under a home screen without costing scroll performance.
struct XMBBackground: View {
    let size: CGSize
    /// Scales every light source at once — the boot screen runs dimmer.
    var intensity: CGFloat = 1
    var moteCount: Int = 22
    var scanlines: Bool = true
    var animated: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: animated ? 1.0 / 30.0 : .infinity,
                                paused: !animated)) { timeline in
            let time = animated
                ? timeline.date.timeIntervalSinceReferenceDate
                : 0

            Canvas(rendersAsynchronously: true) { context, canvas in
                drawSky(&context, canvas)
                drawGlow(&context, canvas)
                drawWave(&context, canvas, time: time)
                drawMotes(&context, canvas, time: time)
                if scanlines { drawScanlines(&context, canvas) }
                drawVignette(&context, canvas)
            }
        }
        .frame(width: size.width, height: size.height)
        .drawingGroup()
        .clipped()
    }

    // MARK: - Sky

    private func drawSky(_ ctx: inout GraphicsContext, _ canvas: CGSize) {
        let gradient = Gradient(stops: [
            .init(color: Palette.skyTop, location: 0),
            .init(color: Palette.skyUpper, location: 0.28),
            .init(color: Palette.skyMid, location: 0.56),
            .init(color: Palette.skyGlow.opacity(0.85), location: 0.74),
            .init(color: Palette.skyLow, location: 0.88),
            .init(color: Palette.ground, location: 1)
        ])
        ctx.fill(
            Path(CGRect(origin: .zero, size: canvas)),
            with: .linearGradient(gradient,
                                  startPoint: .zero,
                                  endPoint: CGPoint(x: 0, y: canvas.height))
        )
    }

    /// The cold bloom the wave appears to be lit by.
    private func drawGlow(_ ctx: inout GraphicsContext, _ canvas: CGSize) {
        let centre = CGPoint(x: canvas.width * 0.5, y: canvas.height * 0.66)
        let radius = max(canvas.width, canvas.height) * 0.62
        ctx.fill(
            Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                   width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [
                    Palette.waveMid.opacity(0.30 * intensity),
                    Palette.waveDeep.opacity(0.16 * intensity),
                    .clear
                ]),
                center: centre, startRadius: 0, endRadius: radius
            )
        )
    }

    // MARK: - Wave

    private struct Ribbon {
        let base: CGFloat        // vertical position, 0…1 of the canvas
        let amplitude: CGFloat   // in points, before the canvas scale
        let frequency: CGFloat   // cycles across the width
        let speed: Double
        let thickness: CGFloat
        let alpha: CGFloat
    }

    private static let ribbons: [Ribbon] = [
        Ribbon(base: 0.62, amplitude: 26, frequency: 1.15, speed: 0.28, thickness: 0.42, alpha: 0.30),
        Ribbon(base: 0.68, amplitude: 34, frequency: 0.80, speed: -0.19, thickness: 0.34, alpha: 0.24),
        Ribbon(base: 0.74, amplitude: 20, frequency: 1.70, speed: 0.42, thickness: 0.26, alpha: 0.18)
    ]

    private func drawWave(_ ctx: inout GraphicsContext, _ canvas: CGSize, time: TimeInterval) {
        for (index, ribbon) in Self.ribbons.enumerated() {
            let phase = time * ribbon.speed + Double(index) * 1.7
            let crest = crestPath(ribbon, canvas: canvas, phase: phase)

            // The body: the crest line closed down to the bottom of the screen.
            var body = crest
            body.addLine(to: CGPoint(x: canvas.width, y: canvas.height))
            body.addLine(to: CGPoint(x: 0, y: canvas.height))
            body.closeSubpath()

            let top = canvas.height * ribbon.base - ribbon.amplitude
            ctx.fill(
                body,
                with: .linearGradient(
                    Gradient(colors: [
                        Palette.waveMid.opacity(ribbon.alpha * intensity),
                        Palette.waveDeep.opacity(ribbon.alpha * 0.55 * intensity),
                        .clear
                    ]),
                    startPoint: CGPoint(x: 0, y: top),
                    endPoint: CGPoint(x: 0, y: top + canvas.height * ribbon.thickness)
                )
            )

            // The crest itself, struck three times at widening radii: a cheap
            // bloom that costs nothing next to a real blur filter.
            var glow = ctx
            glow.blendMode = .plusLighter
            for (width, alpha) in [(5.0, 0.07), (2.4, 0.16), (1.1, 0.55)] {
                glow.stroke(
                    crest,
                    with: .linearGradient(
                        Gradient(colors: [
                            Palette.wavePeak.opacity(0),
                            Palette.wavePeak.opacity(alpha * intensity),
                            Palette.ice.opacity(alpha * 0.9 * intensity),
                            Palette.wavePeak.opacity(0)
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: canvas.width, y: 0)
                    ),
                    lineWidth: width
                )
            }
        }
    }

    private func crestPath(_ ribbon: Ribbon, canvas: CGSize, phase: Double) -> Path {
        var path = Path()
        let base = canvas.height * ribbon.base
        let step: CGFloat = 6

        var x: CGFloat = 0
        while x <= canvas.width {
            let t = x / max(canvas.width, 1)
            // Two sines per ribbon: the second, slower one keeps the crest from
            // reading as a single repeating hump.
            let primary = sin(t * .pi * 2 * ribbon.frequency + phase)
            let secondary = sin(t * .pi * 2 * (ribbon.frequency * 0.43) - phase * 1.3)
            let y = base + (primary * 0.7 + secondary * 0.5) * ribbon.amplitude

            if x == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
            x += step
        }
        return path
    }

    // MARK: - Motes

    private func drawMotes(_ ctx: inout GraphicsContext, _ canvas: CGSize, time: TimeInterval) {
        guard moteCount > 0 else { return }
        var lit = ctx
        lit.blendMode = .plusLighter

        for index in 0..<moteCount {
            let seed = Double(index) * 12.9898
            let column = CGFloat((sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1).magnitude)
            let size = 1.2 + CGFloat((cos(seed) * 0.5 + 0.5)) * 2.4
            let speed = 12 + (cos(seed * 1.7) * 0.5 + 0.5) * 26

            // Rising, with a slow sway — dust in a projector beam.
            let travel = (time * speed + Double(index) * 97).truncatingRemainder(dividingBy: Double(canvas.height + 80))
            let y = canvas.height + 40 - CGFloat(travel)
            let sway = sin(time * 0.6 + seed) * 14
            let x = column * canvas.width + CGFloat(sway)

            let fade = 1 - abs((y / canvas.height) - 0.5) * 1.2
            guard fade > 0 else { continue }

            let tint = Palette.moteTints[index % Palette.moteTints.count]
            lit.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: size, height: size)),
                with: .color(tint.opacity(0.30 * fade * intensity))
            )
        }
    }

    // MARK: - Overlays

    /// A CRT's line structure, kept faint enough to read as texture rather than
    /// as stripes over the type.
    private func drawScanlines(_ ctx: inout GraphicsContext, _ canvas: CGSize) {
        var lines = Path()
        var y: CGFloat = 0
        while y < canvas.height {
            lines.addRect(CGRect(x: 0, y: y, width: canvas.width, height: 1))
            y += 3
        }
        ctx.fill(lines, with: .color(Palette.vignette.opacity(0.16)))
    }

    private func drawVignette(_ ctx: inout GraphicsContext, _ canvas: CGSize) {
        let radius = max(canvas.width, canvas.height) * 0.78
        let centre = CGPoint(x: canvas.width / 2, y: canvas.height * 0.46)
        ctx.fill(
            Path(CGRect(origin: .zero, size: canvas)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: Palette.vignette.opacity(0.55), location: 1)
                ]),
                center: centre, startRadius: 0, endRadius: radius
            )
        )
    }
}
