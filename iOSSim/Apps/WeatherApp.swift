import SwiftUI

struct WeatherApp: View {
    @Environment(\.deviceSafeArea) private var safeArea
    @State private var collapsed = false
    /// Shown briefly by the "My Location" quick action.
    @State private var showingLocationBadge = false

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(hex: "8CA9BE"), Color(hex: "5A7691"), Color(hex: "2E3D4C")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            SunHaze()

            TrackingScrollView(showsIndicators: false, onOffset: { value in
                let shouldCollapse = value > 90
                guard shouldCollapse != collapsed else { return }
                withAnimation(.easeOut(duration: 0.2)) { collapsed = shouldCollapse }
            }) {
                VStack(spacing: 14) {
                    VStack(spacing: 6) {
                        if showingLocationBadge {
                            Label("My Location", systemImage: "location.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SysColor.label)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(.ultraThinMaterial))
                                .transition(.scale.combined(with: .opacity))
                        }
                        hero
                    }
                    .opacity(collapsed ? 0 : 1)
                    .padding(.top, safeArea.top + 8)

                    hourlyCard
                    dailyCard

                    HStack(spacing: 12) {
                        detailTile(title: "UV INDEX", symbol: "sun.max.fill",
                                   value: "4", caption: "Moderate")
                        detailTile(title: "WIND", symbol: "wind",
                                   value: "8", caption: "mph  NW")
                    }
                    HStack(spacing: 12) {
                        detailTile(title: "FEELS LIKE", symbol: "thermometer.medium",
                                   value: "74°", caption: "Humidity is making it warmer")
                        detailTile(title: "VISIBILITY", symbol: "eye.fill",
                                   value: "10", caption: "mi — perfectly clear")
                    }
                    .padding(.bottom, safeArea.bottom + 40)
                }
                .padding(.horizontal, 18)
            }

            collapsedBar
        }
        .onAppIntent(.weather) { _ in
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                showingLocationBadge = true
            }
            Task {
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.easeOut(duration: 0.3)) { showingLocationBadge = false }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 0) {
            Text("Cupertino")
                .font(.system(size: 34, weight: .regular))
            Text("72°")
                .font(.system(size: 96, weight: .thin))
                .padding(.top, -8)
            Text("Sunny")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(SysColor.label.opacity(0.85))
            Text("H:78°  L:61°")
                .font(.system(size: 20))
                .padding(.top, 2)
        }
        .foregroundStyle(SysColor.label)
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    private var collapsedBar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("Cupertino")
                    .font(.system(size: 17, weight: .semibold))
                HStack(spacing: 6) {
                    Text("72°")
                    Text("Sunny")
                    Text("H:78° L:61°")
                }
                .font(.system(size: 13))
                .foregroundStyle(SysColor.label.opacity(0.9))
            }
            .foregroundStyle(SysColor.label)
            .padding(.top, safeArea.top + 2)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            }
            Spacer(minLength: 0)
        }
        .opacity(collapsed ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: collapsed)
    }

    // MARK: - Cards

    private var hourlyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Sunny conditions will continue all day. Wind gusts up to 12 mph.",
                      systemImage: "clock")
                    .font(.system(size: 13))
                    .foregroundStyle(SysColor.label.opacity(0.8))
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                Rectangle().fill(Palette.paper.opacity(0.2)).frame(height: 0.5)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(WeatherData.hourly, id: \.hour) { slot in
                            VStack(spacing: 10) {
                                Text(slot.hour)
                                    .font(.system(size: 15, weight: .semibold))
                                Image(systemName: slot.symbol)
                                    .font(.system(size: 22))
                                    .foregroundStyle(Palette.wheat)
                                Text("\(slot.temp)°")
                                    .font(.system(size: 20, weight: .medium))
                            }
                            .foregroundStyle(SysColor.label)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private var dailyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                Label("10-DAY FORECAST", systemImage: "calendar")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SysColor.label.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                ForEach(Array(WeatherData.daily.enumerated()), id: \.element.id) { index, day in
                    HStack(spacing: 12) {
                        Text(day.day)
                            .font(.system(size: 18, weight: day.day == "Today" ? .semibold : .regular))
                            .frame(width: 56, alignment: .leading)

                        Image(systemName: day.symbol)
                            .font(.system(size: 20))
                            .foregroundStyle(Palette.wheat)
                            .frame(width: 32)

                        Text("\(day.low)°")
                            .font(.system(size: 18))
                            .foregroundStyle(SysColor.label.opacity(0.6))
                            .frame(width: 34, alignment: .trailing)

                        TempBar(low: day.low, high: day.high, isToday: day.day == "Today")

                        Text("\(day.high)°")
                            .font(.system(size: 18))
                            .frame(width: 34, alignment: .leading)
                    }
                    .foregroundStyle(SysColor.label)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) {
                        if index != WeatherData.daily.count - 1 {
                            Rectangle()
                                .fill(Palette.paper.opacity(0.18))
                                .frame(height: 0.5)
                                .padding(.leading, 16)
                        }
                    }
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func detailTile(title: String, symbol: String, value: String, caption: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SysColor.label.opacity(0.7))
                Text(value)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(SysColor.label)
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(SysColor.label.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        }
    }
}

private struct TempBar: View {
    let low: Int
    let high: Int
    let isToday: Bool

    var body: some View {
        GeometryReader { geo in
            let span = CGFloat(WeatherData.range.max - WeatherData.range.min)
            let start = CGFloat(low - WeatherData.range.min) / span
            let end = CGFloat(high - WeatherData.range.min) / span

            ZStack(alignment: .leading) {
                Capsule().fill(Palette.paper.opacity(0.22))
                Capsule()
                    .fill(LinearGradient(colors: [Palette.seafoam, Palette.wheat, Palette.amber],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, (end - start) * geo.size.width))
                    .offset(x: start * geo.size.width)
                if isToday {
                    Circle()
                        .fill(Palette.paper)
                        .frame(width: 7, height: 7)
                        .offset(x: (start + (end - start) * 0.62) * geo.size.width)
                        .shadow(color: .black.opacity(0.3), radius: 1)
                }
            }
        }
        .frame(height: 5)
    }
}

/// Soft sun glow drifting behind the content.
private struct SunHaze: View {
    var body: some View {
        GeometryReader { geo in
            Circle()
                .fill(
                    RadialGradient(colors: [Palette.wheat.opacity(0.5), .clear],
                                   center: .center, startRadius: 0, endRadius: geo.size.width * 0.5)
                )
                .frame(width: geo.size.width * 1.1)
                .position(x: geo.size.width * 0.82, y: geo.size.height * 0.14)
                .blur(radius: 30)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
