import SwiftUI

/// The folder's own icon: a frosted tile with the first nine apps inside it,
/// drawn at a ninth of the size — the same trick iOS uses.
struct FolderIcon: View {
    let folder: HomeLayoutStore.Folder
    var size: CGFloat = 60

    private var slots: [HomeItem?] {
        var contents = folder.items.prefix(9).map { Optional($0) }
        contents.append(contentsOf: Array(repeating: nil, count: 9 - contents.count))
        return contents
    }

    var body: some View {
        let inset = size * 0.09
        let cell = (size - inset * 2 - size * 0.06 * 2) / 3

        ZStack {
            RoundedRectangle(cornerRadius: Metrics.iconCorner(for: size), style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.iconCorner(for: size), style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(cell), spacing: size * 0.06), count: 3),
                spacing: size * 0.06
            ) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, item in
                    Group {
                        if let item {
                            MiniIcon(item: item, size: cell)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: cell, height: cell)
                }
            }
            .padding(inset)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.iconCorner(for: size), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.iconCorner(for: size), style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
    }
}

/// One app inside a folder icon.
private struct MiniIcon: View {
    let item: HomeItem
    let size: CGFloat

    var body: some View {
        if let app = item.builtinApp {
            IconArtwork(app: app, size: size)
        } else if let bundle = item.guestBundle {
            PackageIcon(url: PackageStore.shared.installed[bundle]?.iconURL, tint: nil, size: size)
        }
    }
}

/// The opened folder: the page dims and blurs behind a titled grid.
struct FolderView: View {
    let folder: HomeLayoutStore.Folder
    let columns: Int
    var jiggling: Bool
    var carriedItem: HomeItem?
    var dropHighlighted: Bool
    var draggingOutside: Bool
    var registry: IconFrameRegistry?
    var frameBox: IconFrameBox
    /// Launch an app from inside the folder.
    var onOpen: (HomeItem, CGRect) -> Void
    /// Jiggle mode's way back out — the app returns to the folder's page.
    var onEject: (HomeItem) -> Void
    var onPickUp: (HomeItem, CGPoint) -> Void
    var onDragChange: (CGPoint) -> Void
    var onDrop: () -> Void
    var onRename: (String) -> Void
    var onDismiss: () -> Void

    @State private var presented = false
    @State private var backdropVisible = false
    @State private var name: String = ""
    @FocusState private var editingName: Bool
    @Environment(\.deviceSafeArea) private var safeArea
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var reducesMotion: Bool {
        accessibilityReduceMotion || Appearance.shared.reduceMotion
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .opacity(backdropVisible ? (draggingOutside ? 0.2 : 1) : 0)
                .animation(motionAnimation(.easeOut(duration: 0.16)), value: draggingOutside)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack(spacing: 18) {
                TextField("Folder", text: $name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SysColor.label)
                    .multilineTextAlignment(.center)
                    .focused($editingName)
                    .disabled(!jiggling)
                    .submitLabel(.done)
                    .onSubmit { onRename(name) }
                    .padding(.horizontal, 40)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: columns),
                    spacing: 22
                ) {
                    ForEach(folder.items) { item in
                        FolderAppTile(item: item, jiggling: jiggling,
                                      carried: carriedItem == item,
                                      registry: registry,
                                      onOpen: { rect in onOpen(item, rect) },
                                      onEject: { onEject(item) },
                                      onPickUp: { point in onPickUp(item, point) },
                                      onDragChange: onDragChange,
                                      onDrop: onDrop)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(.regularMaterial)
                    Color.clear
                        .recordGlobalFrame { frameBox.rect = $0 }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(dropHighlighted ? 0.78 : 0.10),
                        lineWidth: dropHighlighted ? 2 : 0.5
                    )
            }
            .padding(.horizontal, 16)
            .scaleEffect(reducesMotion ? 1 : (presented ? 1 : 0.94))
            .offset(y: reducesMotion ? 0 : (presented ? 0 : 10))
            .opacity(backdropVisible ? (draggingOutside ? 0.34 : 1) : 0)
            .animation(motionAnimation(.easeOut(duration: 0.16)), value: draggingOutside)
            .animation(motionAnimation(.easeOut(duration: 0.14)), value: dropHighlighted)
        }
        .onAppear {
            name = folder.name
            withAnimation(motionAnimation(.easeOut(duration: 0.18))) {
                backdropVisible = true
            }
            withAnimation(motionAnimation(.interfaceSpring)) {
                presented = true
            }
        }
        .onChange(of: jiggling) { _, active in
            if !active, name != folder.name { onRename(name) }
        }
    }

    private func dismiss() {
        guard presented || backdropVisible else { return }
        if name != folder.name { onRename(name) }
        editingName = false
        withAnimation(
            motionAnimation(.easeOut(duration: 0.18)),
            completionCriteria: .logicallyComplete
        ) {
            presented = false
            backdropVisible = false
        } completion: {
            onDismiss()
        }
    }

    private func motionAnimation(_ animation: Animation) -> Animation {
        if accessibilityReduceMotion {
            .easeOut(duration: 0.16)
        } else {
            Appearance.shared.animation(animation)
        }
    }
}

/// An app inside an open folder. In jiggle mode its badge moves the app out
/// rather than deleting it — the folder is a container, not an install.
private struct FolderAppTile: View {
    let item: HomeItem
    let jiggling: Bool
    let carried: Bool
    var registry: IconFrameRegistry?
    var onOpen: (CGRect) -> Void
    var onEject: () -> Void
    var onPickUp: (CGPoint) -> Void
    var onDragChange: (CGPoint) -> Void
    var onDrop: () -> Void

    @State private var frame = IconFrameBox()
    @State private var lifted = false

    private var title: String {
        item.builtinApp?.title
            ?? PackageStore.shared.installed[item.guestBundle ?? ""]?.name
            ?? "App"
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !jiggling)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let wave = time * 12.5 + jiggleSeed
            content(angle: jiggling ? sin(wave) * 1.25 : 0,
                    verticalOffset: CGFloat(jiggling ? cos(wave * 1.07) * 0.65 : 0))
        }
    }

    private func content(angle: Double, verticalOffset: CGFloat) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let app = item.builtinApp {
                        IconArtwork(app: app, size: 60)
                    } else if let bundle = item.guestBundle {
                        PackageIcon(url: PackageStore.shared.installed[bundle]?.iconURL,
                                    tint: nil, size: 60)
                    }
                }
                .shadow(color: Palette.ink.opacity(0.45), radius: 6, y: 3)
                .opacity(carried ? 0 : 1)

                if jiggling {
                    Button(action: onEject) {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color(hex: "CFC2B2")))
                            .overlay(Circle().strokeBorder(Palette.ink.opacity(0.2), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: -8, y: -8)
                    .opacity(carried ? 0 : 1)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 60, height: 60)

            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(SysColor.label)
                .lineLimit(1)
                .opacity(carried ? 0 : 1)
        }
        .rotationEffect(.degrees(angle))
        .offset(y: verticalOffset)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !jiggling else { return }
            Haptics.tap(.light)
            onOpen(frame.rect)
        }
        .gesture(rearrangeGesture, including: jiggling ? .all : .subviews)
        .onChange(of: jiggling) { _, active in
            if !active { lifted = false }
        }
        .recordGlobalFrame(record)
    }

    private var jiggleSeed: Double {
        let scalarSum = item.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double(scalarSum % 360) * .pi / 180
    }

    private func record(_ rect: CGRect) {
        frame.rect = rect
        registry?.record(rect, for: item.id)
    }

    private var rearrangeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if !lifted {
                    lifted = true
                    Haptics.tap(.light)
                    onPickUp(value.location)
                }
                onDragChange(value.location)
            }
            .onEnded { _ in
                lifted = false
                onDrop()
            }
    }
}
