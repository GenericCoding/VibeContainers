import SwiftUI

struct MusicApp: View {
    @Environment(\.deviceSafeArea) private var safeArea

    @State private var tab = 3
    @State private var index = 0
    @State private var playing = true
    @State private var elapsed: Double = 42
    @State private var showNowPlaying = false
    @State private var volume: Double = 0.65

    @State private var focusSearch = false
    @State private var searchText = ""

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var song: Song { MusicData.queue[index] }

    var body: some View {
        ZStack {
            SysColor.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                library
                miniPlayer
                AppTabBar(items: [
                    TabItem(title: "Home", symbol: "house.fill"),
                    TabItem(title: "New", symbol: "square.grid.2x2.fill"),
                    TabItem(title: "Radio", symbol: "dot.radiowaves.left.and.right"),
                    TabItem(title: "Library", symbol: "music.note.list"),
                    TabItem(title: "Search", symbol: "magnifyingglass")
                ], selection: $tab, tint: SysColor.pink)
            }
            .ignoresSafeArea(edges: .bottom)

            if showNowPlaying {
                NowPlayingView(
                    song: song,
                    playing: $playing,
                    elapsed: $elapsed,
                    volume: $volume,
                    onNext: next,
                    onPrevious: previous,
                    onClose: { withAnimation(.appLaunch) { showNowPlaying = false } }
                )
                .transition(.move(edge: .bottom))
                .zIndex(3)
            }
        }
        .onAppIntent(.music) { intent in
            switch intent {
            case .musicSearch:
                tab = 4
                focusSearch = true
            case .musicPlayRecents:
                index = 0
                elapsed = 0
                playing = true
                withAnimation(.appLaunch) { showNowPlaying = true }
            default: break
            }
        }
        .onReceive(ticker) { _ in
            guard playing, !showNowPlaying || true else { return }
            if elapsed < Double(song.duration) {
                elapsed += 1
            } else {
                next()
            }
        }
    }

    // MARK: - Library

    /// The grid is the whole catalogue until the Search tab narrows it.
    private var matchingSongs: [(offset: Int, element: Song)] {
        let all = Array(MusicData.queue.enumerated())
        guard tab == 4, !searchText.isEmpty else { return all }
        return all.filter {
            [$0.element.title, $0.element.artist, $0.element.album]
                .contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(tab == 4 ? "Search" : "Library")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(SysColor.label)
                    .padding(.horizontal, 20)

                if tab == 4 {
                    SearchField(text: $searchText,
                                placeholder: "Artists, Songs, Albums",
                                requestFocus: $focusSearch)
                        .padding(.horizontal, 16)
                }

                VStack(spacing: 0) {
                    ForEach(Array(["Playlists", "Artists", "Albums", "Songs", "Downloaded"].enumerated()), id: \.offset) { rowIndex, item in
                        HStack(spacing: 12) {
                            Image(systemName: ["music.note.list", "music.mic", "square.stack",
                                               "music.note", "arrow.down.circle"][rowIndex])
                                .font(.system(size: 17))
                                .foregroundStyle(SysColor.pink)
                                .frame(width: 26)
                            Text(item)
                                .font(.system(size: 19))
                                .foregroundStyle(SysColor.label)
                            Spacer()
                            Chevron()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(SysColor.separator).frame(height: 0.5).padding(.leading, 58)
                        }
                    }
                }

                Text(tab == 4 && !searchText.isEmpty ? "Results" : "Recently Added")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(SysColor.label)
                    .padding(.horizontal, 20)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                          spacing: 20) {
                    ForEach(matchingSongs, id: \.element.id) { songIndex, item in
                        Button {
                            Haptics.tap(.light)
                            index = songIndex
                            elapsed = 0
                            playing = true
                            withAnimation(.appLaunch) { showNowPlaying = true }
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Artwork(colors: item.colors)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                Text(item.album)
                                    .font(.system(size: 15))
                                    .foregroundStyle(SysColor.label)
                                    .lineLimit(1)
                                Text(item.artist)
                                    .font(.system(size: 14))
                                    .foregroundStyle(SysColor.secondaryLabel)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, safeArea.top + 46)
            .padding(.bottom, 30)
        }
    }

    // MARK: - Mini player

    private var miniPlayer: some View {
        HStack(spacing: 12) {
            Artwork(colors: song.colors)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(song.title)
                .font(.system(size: 15))
                .foregroundStyle(SysColor.label)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                Haptics.tap(.light)
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(SysColor.label)
            }

            Button(action: next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(SysColor.label)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle().fill(SysColor.separator).frame(height: 0.5)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.appLaunch) { showNowPlaying = true }
        }
    }

    private func next() {
        withAnimation(.snappy) {
            index = (index + 1) % MusicData.queue.count
            elapsed = 0
        }
    }

    private func previous() {
        withAnimation(.snappy) {
            if elapsed > 3 { elapsed = 0 }
            else { index = (index - 1 + MusicData.queue.count) % MusicData.queue.count }
        }
    }
}

// MARK: - Artwork

struct Artwork: View {
    let colors: [Color]

    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                let s = min(geo.size.width, geo.size.height)
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .strokeBorder(Palette.paper.opacity(0.18), lineWidth: s * 0.03)
                        .frame(width: s * (0.35 + CGFloat(ring) * 0.24))
                        .position(x: geo.size.width * 0.62, y: geo.size.height * 0.42)
                }
            }
        }
    }
}

// MARK: - Now Playing

private struct NowPlayingView: View {
    let song: Song
    @Binding var playing: Bool
    @Binding var elapsed: Double
    @Binding var volume: Double
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onClose: () -> Void

    @Environment(\.deviceSafeArea) private var safeArea

    var body: some View {
        ZStack {
            LinearGradient(colors: song.colors.map { $0.opacity(0.85) } + [.black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Palette.paper.opacity(0.4))
                    .frame(width: 38, height: 5)
                    .padding(.top, safeArea.top + 6)

                Spacer(minLength: 0)

                Artwork(colors: song.colors)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                    .scaleEffect(playing ? 1 : 0.86)
                    .animation(.spring(response: 0.5, dampingFraction: 0.75), value: playing)
                    .padding(.horizontal, 34)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(SysColor.label)
                            Text(song.artist)
                                .font(.system(size: 22))
                                .foregroundStyle(SysColor.label.opacity(0.65))
                        }
                        Spacer()
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(SysColor.label.opacity(0.55))
                    }
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 18)

                scrubber
                    .padding(.horizontal, 34)

                transport
                    .padding(.top, 22)

                volumeSlider
                    .padding(.horizontal, 34)
                    .padding(.top, 26)

                HStack(spacing: 60) {
                    Image(systemName: "quote.bubble")
                    Image(systemName: "airplayaudio")
                    Image(systemName: "list.bullet")
                }
                .font(.system(size: 20))
                .foregroundStyle(SysColor.label.opacity(0.7))
                .padding(.top, 28)
                .padding(.bottom, max(safeArea.bottom, 16) + 6)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height > 80 { onClose() }
                }
        )
    }

    private var progress: Double {
        min(1, elapsed / Double(song.duration))
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.paper.opacity(0.25))
                    Capsule().fill(Palette.paper.opacity(0.85))
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 6)

            HStack {
                Text(time(elapsed))
                Spacer()
                Text("-" + time(Double(song.duration) - elapsed))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SysColor.label.opacity(0.6))
        }
    }

    private var transport: some View {
        HStack(spacing: 46) {
            Button(action: onPrevious) {
                Image(systemName: "backward.fill").font(.system(size: 30))
            }
            Button {
                Haptics.tap(.medium)
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
                    .frame(width: 50)
            }
            Button(action: onNext) {
                Image(systemName: "forward.fill").font(.system(size: 30))
            }
        }
        .foregroundStyle(SysColor.label)
    }

    private var volumeSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            Slider(value: $volume).tint(Palette.paper.opacity(0.85))
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(SysColor.label.opacity(0.55))
    }

    private func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
