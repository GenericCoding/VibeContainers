import SwiftUI

struct MapsApp: View {
    @Environment(\.deviceSafeArea) private var safeArea
    @State private var search = ""
    @State private var pulse = false
    @State private var sheetExpanded = false
    @State private var focusSearch = false

    var body: some View {
        ZStack(alignment: .top) {
            MapCanvas(pulse: pulse)
                .ignoresSafeArea()
                .onAppear {
                    withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                        pulse = true
                    }
                }

            mapControls
        }
        .overlay(alignment: .bottom) { sheet }
        .onAppIntent(.maps) { intent in
            withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
                sheetExpanded = true
            }
            switch intent {
            case .mapsDirectionsHome:
                // The route the Home shortcut always asks for.
                search = "Home"
            case .mapsSearchNearby:
                search = ""
                focusSearch = true
            default: break
            }
        }
    }

    private var mapControls: some View {
        HStack {
            Spacer()
            VStack(spacing: 10) {
                controlChip(symbol: "map")
                controlChip(symbol: "location")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, safeArea.top + 8)
    }

    private func controlChip(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(SysColor.blue)
            .frame(width: 42, height: 42)
            .background(Circle().fill(.ultraThinMaterial))
            .overlay(Circle().strokeBorder(Palette.paper.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: - Bottom sheet

    private var sheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(SysColor.secondaryLabel.opacity(0.6))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 12)

            SearchField(text: $search, placeholder: "Search Maps", requestFocus: $focusSearch)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            if sheetExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Favorites")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(SysColor.label)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)

                        HStack(spacing: 12) {
                            favorite("house.fill", "Home", SysColor.blue)
                            favorite("briefcase.fill", "Work", SysColor.gray)
                            favorite("car.fill", "Parked", SysColor.teal)
                            favorite("plus", "Add", SysColor.gray)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)

                        Text("Recents")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(SysColor.label)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)

                        ForEach(["Caffè Macs", "Studio B", "Ferry Building", "Big Sur"], id: \.self) { place in
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 15))
                                    .foregroundStyle(SysColor.secondaryLabel)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(SysColor.tertiary))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(place)
                                        .font(.system(size: 16))
                                        .foregroundStyle(SysColor.label)
                                    Text("Cupertino, CA")
                                        .font(.system(size: 13))
                                        .foregroundStyle(SysColor.secondaryLabel)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(SysColor.separator).frame(height: 0.5).padding(.leading, 58)
                            }
                        }
                    }
                    .padding(.bottom, 30)
                }
                .frame(maxHeight: 300)
                .transition(.opacity)
            }
        }
        .padding(.bottom, max(safeArea.bottom, 12))
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                sheetExpanded.toggle()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        sheetExpanded = value.translation.height < 0
                    }
                }
        )
    }

    private func favorite(_ symbol: String, _ title: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(SysColor.label)
                .frame(width: 48, height: 48)
                .background(Circle().fill(color))
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(SysColor.label)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Hand-drawn vector city: water, parks, blocks, roads and a location puck.
private struct MapCanvas: View {
    let pulse: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                Color(hex: "231C19")

                // Water
                Path { path in
                    path.move(to: CGPoint(x: w * 0.62, y: 0))
                    path.addQuadCurve(to: CGPoint(x: w * 0.88, y: h),
                                      control: CGPoint(x: w * 1.02, y: h * 0.5))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: w, y: 0))
                }
                .fill(Color(hex: "3B4E5E"))

                // Parks
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: "35402E"))
                    .frame(width: w * 0.34, height: h * 0.16)
                    .position(x: w * 0.24, y: h * 0.30)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hex: "35402E"))
                    .frame(width: w * 0.20, height: h * 0.09)
                    .position(x: w * 0.16, y: h * 0.72)

                // City blocks
                ForEach(0..<26, id: \.self) { index in
                    let column = index % 5
                    let row = index / 5
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: "33291F"))
                        .frame(width: w * 0.10, height: h * 0.045)
                        .position(x: w * (0.10 + Double(column) * 0.13),
                                  y: h * (0.44 + Double(row) * 0.085))
                }

                // Road grid
                Path { path in
                    for index in 0..<6 {
                        let x = w * (0.06 + Double(index) * 0.13)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: h))
                    }
                    for index in 0..<9 {
                        let y = h * (0.10 + Double(index) * 0.095)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: w * 0.78, y: y))
                    }
                }
                .stroke(Color(hex: "4A3D33"), lineWidth: 3)

                // Highway
                Path { path in
                    path.move(to: CGPoint(x: w * 0.02, y: h * 0.88))
                    path.addQuadCurve(to: CGPoint(x: w * 0.74, y: h * 0.12),
                                      control: CGPoint(x: w * 0.62, y: h * 0.62))
                }
                .stroke(Palette.amber.opacity(0.8),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))

                // Labels
                Text("MISSION PARK")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(hex: "7E9070"))
                    .position(x: w * 0.24, y: h * 0.30)

                Text("BAY")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: "7C9EB8"))
                    .position(x: w * 0.86, y: h * 0.24)

                // Destination pin
                VStack(spacing: 0) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SysColor.label)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Palette.amber))
                    Triangle()
                        .fill(Palette.amber)
                        .frame(width: 9, height: 7)
                        .rotationEffect(.degrees(180))
                        .offset(y: -1)
                }
                .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                .position(x: w * 0.46, y: h * 0.36)

                // Current location puck
                ZStack {
                    Circle()
                        .fill(SysColor.blue.opacity(pulse ? 0 : 0.35))
                        .frame(width: pulse ? 90 : 20)
                    Circle()
                        .fill(SysColor.blue)
                        .frame(width: 16)
                        .overlay(Circle().strokeBorder(Palette.paper, lineWidth: 3))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                }
                .position(x: w * 0.36, y: h * 0.58)
            }
        }
    }
}
