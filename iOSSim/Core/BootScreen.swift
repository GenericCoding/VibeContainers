import SwiftUI
import UIKit

/// A short synthwave cold boot built around the real VibeContainers artwork.
/// Everything is native SwiftUI, so it stays crisp on every device size and
/// does not add another large launch asset to the bundle.
struct BootScreen: View {
    var onFinished: () -> Void

    @State private var appeared = false
    @State private var energized = false
    @State private var leaving = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [.black, Color(red: 0.055, green: 0.005, blue: 0.105),
                             Color(red: 0.20, green: 0.01, blue: 0.20)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                starField(in: geometry.size)

                RadialGradient(
                    colors: [Color.pink.opacity(0.34), Color.purple.opacity(0.12), .clear],
                    center: UnitPoint(x: 0.5, y: 0.48),
                    startRadius: 12,
                    endRadius: min(geometry.size.width, geometry.size.height) * 0.46
                )
                .scaleEffect(energized ? 1.14 : 0.82)

                synthGrid(in: geometry.size)

                VStack(spacing: 18) {
                    logoMark

                    VStack(spacing: 6) {
                        Text("VIBECONTAINERS")
                            .font(.system(size: 21, weight: .black, design: .rounded))
                            .tracking(3.2)
                            .foregroundStyle(.white)
                            .shadow(color: .pink.opacity(0.9), radius: 12)

                        Text("CONTAINER RUNTIME")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(2.8)
                            .foregroundStyle(.white.opacity(0.48))
                    }

                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.10))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.cyan, .blue, .purple, .pink],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .scaleEffect(x: energized ? 1 : 0.02, anchor: .leading)
                            .shadow(color: .pink.opacity(0.8), radius: 7)
                    }
                    .frame(width: 154, height: 3)
                }
                .offset(y: -16)
                .scaleEffect(appeared ? 1 : 0.82)
                .opacity(leaving ? 0 : (appeared ? 1 : 0))

                Color.white
                    .opacity(leaving ? 0.16 : 0)
                    .blendMode(.screen)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .onAppear(perform: run)
    }

    private var logoMark: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.48))
                .frame(width: 148, height: 148)
                .shadow(color: .purple.opacity(0.65), radius: 32)

            Circle()
                .trim(from: 0.06, to: 0.94)
                .stroke(
                    AngularGradient(colors: [.cyan, .blue, .purple, .pink, .cyan], center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 154, height: 154)
                .rotationEffect(.degrees(energized ? 215 : -145))
                .shadow(color: .pink.opacity(0.8), radius: 9)

            Circle()
                .stroke(.white.opacity(0.14), lineWidth: 1)
                .frame(width: 138, height: 138)

            Group {
                if let logo = Self.logoImage {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "shippingbox.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(30)
                        .foregroundStyle(.white)
                        .background(Color.purple)
                }
            }
            .frame(width: 126, height: 126)
            .clipShape(Circle())
            .overlay { Circle().stroke(.white.opacity(0.24), lineWidth: 1) }
        }
    }

    private func starField(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<42, id: \.self) { index in
                let x = CGFloat((index * 83 + 19) % 997) / 997
                let y = CGFloat((index * 47 + 31) % 431) / 862
                let diameter = CGFloat(1 + (index % 3))
                Circle()
                    .fill(index.isMultiple(of: 7) ? Color.cyan : Color.white)
                    .frame(width: diameter, height: diameter)
                    .opacity(appeared ? Double(35 + (index * 17) % 60) / 100 : 0)
                    .position(x: x * size.width, y: y * size.height)
            }
        }
    }

    private func synthGrid(in size: CGSize) -> some View {
        Canvas { context, canvas in
            let horizon = canvas.height * 0.72
            let bottom = canvas.height + 4
            let center = canvas.width / 2
            let color = Color.pink.opacity(energized ? 0.42 : 0.18)

            for index in -8...8 {
                var path = Path()
                path.move(to: CGPoint(x: center + CGFloat(index) * 7, y: horizon))
                path.addLine(to: CGPoint(x: center + CGFloat(index) * canvas.width * 0.17, y: bottom))
                context.stroke(path, with: .color(color), lineWidth: 0.7)
            }

            for index in 0..<11 {
                let t = CGFloat(index) / 10
                let eased = t * t
                let y = horizon + eased * (bottom - horizon)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvas.width, y: y))
                context.stroke(path, with: .color(color), lineWidth: 0.7)
            }

            var horizonLine = Path()
            horizonLine.move(to: CGPoint(x: 0, y: horizon))
            horizonLine.addLine(to: CGPoint(x: canvas.width, y: horizon))
            context.stroke(horizonLine, with: .color(.pink.opacity(0.75)), lineWidth: 1.2)
        }
        .mask(
            LinearGradient(colors: [.clear, .white.opacity(0.8), .white],
                           startPoint: UnitPoint(x: 0.5, y: 0.68), endPoint: .bottom)
        )
        .opacity(appeared ? 1 : 0)
    }

    private func run() {
        withAnimation(.spring(response: 0.52, dampingFraction: 0.78)) {
            appeared = true
        }
        withAnimation(.easeInOut(duration: 1.18)) {
            energized = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.24) {
            withAnimation(.easeInOut(duration: 0.24)) { leaving = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.52) {
            onFinished()
        }
    }

    private static let logoImage = HostAppIcon.image
}
