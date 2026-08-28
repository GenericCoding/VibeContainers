import SwiftUI

/// A deterministic procedural "photograph".
struct MockPhoto: View {
    let index: Int

    var body: some View {
        let colors = PhotosData.palette(index)
        ZStack {
            LinearGradient(colors: colors,
                           startPoint: index.isMultiple(of: 2) ? .topLeading : .top,
                           endPoint: index.isMultiple(of: 2) ? .bottomTrailing : .bottom)

            // Suggestion of a horizon / subject so the tiles read as pictures.
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.72))
                    path.addQuadCurve(to: CGPoint(x: w, y: h * 0.66),
                                      control: CGPoint(x: w * 0.5, y: h * (index.isMultiple(of: 3) ? 0.55 : 0.82)))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                }
                .fill(Palette.ink.opacity(0.22))

                Circle()
                    .fill(Palette.paper.opacity(0.5))
                    .frame(width: w * 0.16)
                    .position(x: w * (index.isMultiple(of: 2) ? 0.72 : 0.28), y: h * 0.28)
                    .blur(radius: 3)
            }
        }
    }
}

struct PhotosApp: View {
    @State private var tab = 0
    @State private var viewing: Int?
    @State private var scope = 2
    @Environment(\.deviceSafeArea) private var safeArea

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack {
            SysColor.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                content
                AppTabBar(items: [
                    TabItem(title: "Library", symbol: "photo.on.rectangle"),
                    TabItem(title: "For You", symbol: "heart.text.square"),
                    TabItem(title: "Albums", symbol: "square.stack"),
                    TabItem(title: "Search", symbol: "magnifyingglass")
                ], selection: $tab)
            }
            .ignoresSafeArea(edges: .bottom)

            if let index = viewing {
                PhotoViewer(index: index) {
                    withAnimation(.appClose) { viewing = nil }
                }
                .transition(.opacity.combined(with: .scale(scale: 1.05)))
                .zIndex(2)
            }
        }
        .onAppIntent(.photos) { intent in
            viewing = nil
            tab = intent == .photosFavorites ? 2 : 0
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case 2: albums
        case 1, 3: placeholder
        default: library
        }
    }

    private var library: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 10) {
                    Text("Recents")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(SysColor.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)

                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(0..<PhotosData.count, id: \.self) { index in
                            Button {
                                Haptics.tap(.light)
                                withAnimation(.appLaunch) { viewing = index }
                            } label: {
                                MockPhoto(index: index)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .padding(.top, safeArea.top + 46)
                .padding(.bottom, 90)
            }

            scopeBar
        }
    }

    private var scopeBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(["Years", "Months", "All"].enumerated()), id: \.offset) { index, title in
                Button {
                    Haptics.selection()
                    withAnimation(.snappy) { scope = index }
                } label: {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(scope == index ? Palette.ink : Palette.paper)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background {
                            if scope == index {
                                Capsule().fill(Palette.paper)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.ultraThinMaterial))
        .padding(.top, safeArea.top + 2)
    }

    private var albums: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Albums")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(SysColor.label)
                        .padding(.horizontal, 16)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                              spacing: 20) {
                        ForEach(Array(["Recents", "Favorites", "Trips", "Screenshots",
                                       "Selfies", "Live Photos"].enumerated()), id: \.offset) { index, name in
                            VStack(alignment: .leading, spacing: 6) {
                                MockPhoto(index: index * 5 + 1)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                Text(name)
                                    .font(.system(size: 15))
                                    .foregroundStyle(SysColor.label)
                                Text("\(24 + index * 13)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(SysColor.secondaryLabel)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, safeArea.top + 46)
                .padding(.bottom, 90)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: tab == 1 ? "heart.text.square" : "magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(SysColor.secondaryLabel)
            Text(tab == 1 ? "Memories appear here" : "Search your library")
                .font(.system(size: 17))
                .foregroundStyle(SysColor.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PhotoViewer: View {
    let index: Int
    var onClose: () -> Void

    @Environment(\.deviceSafeArea) private var safeArea
    @State private var chromeHidden = false
    @State private var liked = false

    var body: some View {
        ZStack {
            SysColor.groupedBackground.ignoresSafeArea()

            MockPhoto(index: index)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) { chromeHidden.toggle() }
                }

            if !chromeHidden {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    Text("Library").font(.system(size: 17))
                }
                .foregroundStyle(SysColor.blue)
            }
            Spacer()
            VStack(spacing: 1) {
                Text(PhotosData.caption(index))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                Text("Today · 11:04 AM")
                    .font(.system(size: 12))
                    .foregroundStyle(SysColor.secondaryLabel)
            }
            Spacer()
            Text("Edit")
                .font(.system(size: 17))
                .foregroundStyle(SysColor.blue)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .padding(.top, safeArea.top)
        .background { Rectangle().fill(.ultraThinMaterial).ignoresSafeArea() }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Image(systemName: "square.and.arrow.up").frame(maxWidth: .infinity)
            Button {
                Haptics.tap(.light)
                withAnimation(.snappy) { liked.toggle() }
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .foregroundStyle(liked ? SysColor.red : SysColor.blue)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(liked ? 1.15 : 1)
            }
            Image(systemName: "info.circle").frame(maxWidth: .infinity)
            Image(systemName: "trash").frame(maxWidth: .infinity)
        }
        .font(.system(size: 21))
        .foregroundStyle(SysColor.blue)
        .padding(.top, 12)
        .padding(.bottom, max(safeArea.bottom, 10) + 6)
        .background { Rectangle().fill(.ultraThinMaterial).ignoresSafeArea() }
    }
}
