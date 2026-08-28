import SwiftUI

/// The dashboard.
///
/// Geometry first, because that is what makes it read as an XMB rather than as
/// a list with a wave behind it: the categories sit on one horizontal line, the
/// selected category is pinned to a fixed x, and the column hanging off it is
/// positioned so that the *selected row* is always at a fixed y. Moving the
/// cursor moves the world, not the cursor — everything else slides past two
/// anchor points that never move.
///
/// Normal use is controller-only. Settings can also enable a test layer whose
/// touch controls emit the exact same `XMBInput` values, allowing the complete
/// dashboard to be exercised without pairing hardware.
struct XMBRootView: View {
    /// Called when the dashboard is done — the PS button at the root, a
    /// "Return to iOS" row, or the pad going away.
    var onExit: () -> Void

    @State private var nav = XMBNavigator()
    @State private var hub = ControllerHub.shared
    @State private var appeared = false

    private var appearance: Appearance { Appearance.shared }

    // The two anchors everything is measured from.
    private static let anchorXFraction: CGFloat = 0.27
    private static let categoryYFraction: CGFloat = 0.26
    private static let itemYFraction: CGFloat = 0.45
    /// Inside a pushed column there is no crossbar above it, so it starts higher.
    private static let pushedItemYFraction: CGFloat = 0.27
    private static let rowHeight: CGFloat = 60
    private static let categorySpacing: CGFloat = 78
    private static let iconInset: CGFloat = 34   // icon centre, from a row's leading edge
    /// Height reserved under the information panel for the legend strip.
    private static let hoverBottomInset: CGFloat = 92
    /// Where the column stops when the panel is up.
    private static let hoverCeilingFraction: CGFloat = 0.52

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                ZStack {
                    background(size)

                    Group {
                        if nav.column.isPage {
                            page(size)
                        } else {
                            crossbar(size)
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                    .blur(radius: appeared ? 0 : 8)

                    topBar(size)
                    hoverPanel(size)
                    footer(size)
                }
                .allowsHitTesting(false)

                if hub.controllerUITestMode {
                    XMBTestControls { input in
                        nav.handle(input)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .background(Palette.ink)
        .onAppear(perform: activate)
        .onDisappear(perform: deactivate)
        .onChange(of: nav.wantsExit) { _, wants in
            guard wants else { return }
            nav.clearExit()
            onExit()
        }
    }

    // MARK: - Activation

    private func activate() {
        XMBSound.shared.prepare()
        nav.begin()

        // The navigator is a class, so the closure holds the same object the
        // view is rendering — no snapshot to go stale.
        hub.sink = { input in nav.handle(input) }
        hub.onHome = { nav.handle(.home) }

        withAnimation(.easeOut(duration: 0.6)) { appeared = true }
        // The engine has to finish building its buffers before the swell can
        // play; `prepare` is asynchronous by design.
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            XMBSound.shared.play(.boot)
        }

        // The Game column is the reason most people are here, and it is empty
        // until the repositories have been read. Nothing else in the app has
        // necessarily done that yet — Packages only fetches when its own screen
        // opens — so the dashboard fetches for itself.
        let store = PackageStore.shared
        if store.catalogs.isEmpty && store.loading.isEmpty {
            Task { await store.refreshAll() }
        }
        Task { await FeedStore.shared.refreshIfStale() }
    }

    private func deactivate() {
        hub.sink = nil
        hub.onHome = nil
        XMBSound.shared.shutdown()
    }

    // MARK: - Background

    /// The wave, washed with whatever colour the selected column is lit in.
    private func background(_ size: CGSize) -> some View {
        ZStack {
            XMBBackground(
                size: size,
                intensity: 1.05,
                moteCount: appearance.moteCount,
                scanlines: appearance.scanlines,
                animated: appearance.wallpaperAnimates
            )

            RadialGradient(
                colors: [nav.category.tint.opacity(0.22), .clear],
                center: UnitPoint(x: Self.anchorXFraction, y: Self.categoryYFraction),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.75
            )
            .blendMode(.plusLighter)
            .animation(.easeOut(duration: 0.5), value: nav.categoryIndex)
        }
        .ignoresSafeArea()
    }

    // MARK: - Crossbar

    private func crossbar(_ size: CGSize) -> some View {
        // Descending into a sub-column takes the crossbar off the screen and
        // gives the column its height, which is what the PS3 does when it
        // slides the whole dashboard sideways. Keeping the categories drawn
        // would only stack labels on top of the rows they led to.
        let pushed = !nav.atRoot
        let anchorX = size.width * Self.anchorXFraction
        let categoryY = size.height * Self.categoryYFraction
        let itemY = size.height * (pushed ? Self.pushedItemYFraction : Self.itemYFraction)
        let ceiling = pushed ? size.height * 0.17 : categoryY + 52
        let rowLeading = anchorX - Self.iconInset
        let rowWidth = max(180, size.width - rowLeading - 18)

        return ZStack(alignment: .topLeading) {
            // The bar itself: a soft horizontal light through the category row.
            LinearGradient(
                colors: [.clear, Palette.paper.opacity(0.16), Palette.paper.opacity(0.05), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1)
            .offset(y: categoryY)
            .blendMode(.plusLighter)
            .opacity(pushed ? 0 : 1)

            categories(anchorX: anchorX, y: categoryY, width: size.width)
                .opacity(pushed ? 0 : 1)
                .offset(x: pushed ? -70 : 0)

            column(leading: rowLeading,
                   width: rowWidth,
                   itemY: itemY,
                   ceiling: ceiling,
                   height: size.height)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: pushed)
    }

    private func categories(anchorX: CGFloat, y: CGFloat, width: CGFloat) -> some View {
        ForEach(Array(XMBCategory.allCases.enumerated()), id: \.element.id) { index, category in
            let offset = CGFloat(index - nav.categoryIndex)
            let x = anchorX + offset * Self.categorySpacing
            let selected = index == nav.categoryIndex
            let visible = x > -60 && x < width + 60

            VStack(spacing: 6) {
                Image(systemName: category.symbol)
                    .font(.system(size: selected ? 27 : 20, weight: .light))
                    .foregroundStyle(selected ? Palette.paper : Palette.paper.opacity(0.5))
                    .frame(height: 34)
                    .shadow(color: category.tint.opacity(selected ? 0.9 : 0), radius: 12)

                Text(category.title)
                    .font(.system(size: selected ? 12 : 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.paper : Palette.paperDim)
                    .opacity(selected ? 1 : 0.55)
                    .fixedSize()
            }
            .frame(width: Self.categorySpacing)
            .opacity(visible ? 1 : 0)
            .position(x: x, y: y)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: nav.categoryIndex)
    }

    @ViewBuilder
    private func column(leading: CGFloat,
                        width: CGFloat,
                        itemY: CGFloat,
                        ceiling: CGFloat,
                        height: CGFloat) -> some View {
        let itemCount = nav.itemCount
        let selection = nav.selection

        if itemCount == 0 {
            // What the PS3 says when a column has nothing in it.
            Text("There are no titles.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.paperDim)
                .frame(width: width, alignment: .leading)
                .offset(x: leading + Self.iconInset, y: itemY - 10)
        } else {
            // A window around the cursor. Photo has forty-eight rows in it and
            // the ones a screen away are not worth laying out.
            let lower = max(0, selection - 4)
            let upper = min(itemCount - 1, selection + 9)

            ForEach(lower...upper, id: \.self) { index in
                if let item = nav.item(at: index) {
                    let y = itemY + CGFloat(index - selection) * Self.rowHeight
                    XMBRow(item: item, focused: index == selection)
                        .frame(width: width, height: Self.rowHeight, alignment: .leading)
                        .opacity(rowOpacity(y: y, ceiling: ceiling, height: height))
                        .offset(x: leading, y: y - Self.rowHeight / 2)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: selection)
            .animation(.easeOut(duration: 0.2), value: nav.categoryIndex)
            .animation(.easeOut(duration: 0.28), value: nav.hovering)
        }
    }

    /// Rows climbing towards the crossbar fade out into it rather than
    /// colliding with the category labels; the bottom of the screen does the
    /// same in reverse, and moves up out of the way when the information panel
    /// is showing.
    private func rowOpacity(y: CGFloat, ceiling: CGFloat, height: CGFloat) -> Double {
        // A short ramp on purpose: the row above the cursor has to be gone
        // by the time it reaches the category labels, not merely dimmer.
        if y < ceiling { return Double(max(0, 1 + (y - ceiling) / 26)) }
        let floorY = nav.hovering ? height * Self.hoverCeilingFraction : height - 118
        if y > floorY { return Double(max(0, 1 - (y - floorY) / 56)) }
        return 1
    }

    // MARK: - Pages

    /// Settings-style columns: the same rows, framed, with a header.
    private func page(_ size: CGSize) -> some View {
        let header = nav.header(of: nav.column)
        let itemCount = nav.itemCount
        let available = size.height * 0.52
        let visible = max(3, Int(available / 56))
        let start = min(max(0, nav.selection - visible / 2),
                        max(0, itemCount - visible))
        let shown = start..<min(itemCount, start + visible)

        return VStack(alignment: .leading, spacing: 14) {
            if let header {
                HStack(alignment: .top, spacing: 14) {
                    if let icon = header.icon {
                        XMBIconTile(icon: icon, size: 62)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(header.title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Palette.paper)
                            .lineLimit(2)
                        if let subtitle = header.subtitle {
                            Text(subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.paperDim)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let body = header.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.paper.opacity(0.75))
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(nav.title(of: nav.column))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Palette.paper)
            }

            VStack(spacing: 2) {
                ForEach(shown, id: \.self) { index in
                    if let item = nav.item(at: index) {
                        XMBRow(item: item,
                               focused: index == nav.selection,
                               iconSize: 34,
                               wide: true)
                    }
                }

                if itemCount > visible {
                    Text("\(nav.selection + 1) of \(itemCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.paperDim)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Palette.ink.opacity(0.35))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 0.75)
                    }
            }
            .animation(.easeOut(duration: 0.16), value: nav.selection)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.top, size.height * 0.16)
        .padding(.bottom, 110)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    // MARK: - Chrome

    private func topBar(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    ForEach(Array(nav.path.enumerated()), id: \.offset) { index, name in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Palette.paperDim.opacity(0.7))
                        }
                        Text(name)
                            .font(.system(size: 11,
                                          weight: index == nav.path.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == nav.path.count - 1
                                             ? Palette.paper : Palette.paperDim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                XMBClock()
            }
            .padding(.horizontal, 22)
            .padding(.top, 58)

            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The panel lands under the column rather than beside it.
    ///
    /// The PS3 has a widescreen to put it in and can float it to the right of
    /// the crossbar; a phone held upright does not, and a panel there covers
    /// both the categories and the column it is describing. Below the column,
    /// with the rows it would have covered faded out, is the same idea in the
    /// space that actually exists.
    @ViewBuilder
    private func hoverPanel(_ size: CGSize) -> some View {
        if nav.hovering {
            let focused = nav.focused
            if let focused, let info = focused.info {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    XMBInfoOverlay(info: info, pinned: nav.hoverPinned)
                        .padding(.horizontal, 20)
                        .padding(.bottom, Self.hoverBottomInset)
                }
                .frame(width: size.width, height: size.height)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(focused.id)
            }
        }
    }

    private func footer(_ size: CGSize) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            if let toast = nav.toast {
                XMBToast(message: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if let song = nav.nowPlaying {
                        XMBNowPlaying(song: song)
                    }
                    // A PS4/PS5 pad gets the mark it actually has on it; any
                    // other pad reaches the same place through its Home button,
                    // and saying "PS" on a controller without one would be a
                    // lie about how to leave.
                    HStack(spacing: 5) {
                        Image(systemName: hub.hasPlayStationPad ? "playstation.logo" : "house.fill")
                            .font(.system(size: 11))
                        Text(nav.atRoot ? "Return to iOS" : "Exit")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Palette.paperDim)
                }

                Spacer(minLength: 12)

                XMBLegend(entries: legend)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 42)
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: nav.toast)
    }

    /// What the buttons do on *this* row.
    private var legend: [(PSGlyph.Mark, String)] {
        let focused = nav.focused
        var entries: [(PSGlyph.Mark, String)] = []
        if focused?.activate != nil {
            entries.append((.cross, "Enter"))
        } else if focused?.adjust != nil {
            entries.append((.cross, "Apply"))
        }
        if let title = focused?.secondaryTitle, focused?.secondary != nil {
            entries.append((.square, title))
        }
        if focused?.info != nil {
            entries.append((.triangle, nav.hoverPinned ? "Hide" : "Info"))
        }
        if !nav.atRoot || nav.hoverPinned {
            entries.append((.circle, "Back"))
        }
        return entries
    }
}

/// A translucent virtual controller for Settings-driven landscape testing.
/// It deliberately speaks only in `XMBInput`, so this cannot develop a second
/// navigation path that behaves differently from real controller hardware.
private struct XMBTestControls: View {
    var send: (XMBInput) -> Void

    var body: some View {
        ZStack {
            VStack {
                HStack {
                    Label("Controller mode", systemImage: "gamecontroller.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.paperDim)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(.black.opacity(0.25), in: Capsule())

                    Spacer()

                    Button { send(.home) } label: {
                        Label("Exit Controller mode", systemImage: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.paper)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(.black.opacity(0.45), in: Capsule())
                            .overlay(Capsule().stroke(Palette.paper.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                Spacer()

                HStack(alignment: .bottom) {
                    dpad
                    Spacer()
                    faceButtons
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }

            VStack {
                Spacer()
                HStack(spacing: 8) {
                    capsuleButton("L1", input: .l1)
                    capsuleButton("OPTIONS", input: .options)
                    capsuleButton("R1", input: .r1)
                }
                .padding(.bottom, 24)
            }
        }
    }

    private var dpad: some View {
        VStack(spacing: 3) {
            controlButton("chevron.up", input: .up)
            HStack(spacing: 3) {
                controlButton("chevron.left", input: .left)
                controlButton("chevron.down", input: .down)
                controlButton("chevron.right", input: .right)
            }
        }
    }

    private var faceButtons: some View {
        VStack(spacing: 3) {
            faceButton("△", input: .triangle, tint: Color(hex: "76C9A7"))
            HStack(spacing: 3) {
                faceButton("□", input: .square, tint: Color(hex: "D88EBB"))
                faceButton("✕", input: .cross, tint: Color(hex: "83AEE8"))
                faceButton("○", input: .circle, tint: Color(hex: "E98787"))
            }
        }
    }

    private func controlButton(_ symbol: String, input: XMBInput) -> some View {
        Button { send(input) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.paper)
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.38), in: Circle())
                .overlay(Circle().stroke(Palette.paper.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func faceButton(_ title: String, input: XMBInput, tint: Color) -> some View {
        Button { send(input) } label: {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.38), in: Circle())
                .overlay(Circle().stroke(tint.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func capsuleButton(_ title: String, input: XMBInput) -> some View {
        Button { send(input) } label: {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.paperDim)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.black.opacity(0.32), in: Capsule())
                .overlay(Capsule().stroke(Palette.paper.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
