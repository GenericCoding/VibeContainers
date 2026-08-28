import SwiftUI

struct AppIconView: View {
    let item: HomeItem
    var size: CGFloat = 60
    var showsLabel = true
    var jiggling = false
    var hidden = false          // hidden while its window is open
    /// True while this icon is the one being carried around the screen.
    var carried = false
    /// Shared frame table, so the springboard can work out what a drag is over.
    var registry: IconFrameRegistry?
    /// Receives the icon's global frame so the app can zoom out of it.
    var onTap: (CGRect) -> Void
    /// Also receives the frame — the context menu springs out from it.
    var onLongPress: (CGRect) -> Void = { _ in }
    var onDelete: () -> Void = {}
    /// Rearrangement, in global coordinates. Only ever called while jiggling.
    var onPickUp: (CGPoint) -> Void = { _ in }
    var onDragChange: (CGPoint) -> Void = { _ in }
    var onDrop: () -> Void = {}

    @State private var pressed = false
    @State private var frame = IconFrameBox()
    @State private var lifted = false

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var motionDisabled: Bool {
        accessibilityReduceMotion || Appearance.shared.reduceMotion
    }

    private var app: AppID? { item.builtinApp }
    private var guest: PackageStore.InstalledApp? {
        guard let bundle = item.guestBundle else { return nil }
        return PackageStore.shared.installed[bundle]
    }
    private var folder: HomeLayoutStore.Folder? {
        guard let id = item.folderID else { return nil }
        return HomeLayoutStore.shared.folder(id)
    }
    private var title: String { app?.title ?? guest?.name ?? folder?.name ?? "App" }

    var body: some View {
        // A paused timeline has an important advantage over a repeat-forever
        // state animation: the instant editing ends this renders a single zero
        // transform. Re-entering edit mode cannot stack another endless
        // animation on an icon and leave it twitching after Done is pressed.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !jiggling)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let wave = time * 12.5 + jiggleSeed

            interactiveContent(
                angle: jiggling ? sin(wave) * 1.25 : 0,
                verticalOffset: CGFloat(jiggling ? cos(wave * 1.07) * 0.65 : 0)
            )
        }
    }

    private func interactiveContent(angle: Double, verticalOffset: CGFloat) -> some View {
        content
            .contentShape(Rectangle())
            .scaleEffect(pressed && !motionDisabled ? 0.92 : 1)
            .brightness(pressed ? -0.05 : 0)
            .rotationEffect(.degrees(angle))
            .offset(y: verticalOffset)
            // Deliberately not a `Button`. A Button installs its own gesture
            // recogniser that claims the press, so a long press attached
            // alongside it never completes. Driving both from plain gestures
            // lets a held press open the menu while a quick tap still launches:
            // the tap only fires when the long press has failed.
            .onTapGesture {
                // Folder navigation remains available while editing; ordinary
                // app icons still do not launch until Done is pressed.
                guard !jiggling || item.isFolder else { return }
                Haptics.tap(.light)
                onTap(frame.rect)
            }
            .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 14) {
                guard !jiggling else { return }
                onLongPress(frame.rect)
            } onPressingChanged: { isPressing in
                guard !jiggling else { return }
                let animation: Animation = motionDisabled
                    ? .reducedMotionFade
                    : (isPressing ? .iconPress : .iconRelease)
                withAnimation(animation) { pressed = isPressing }
            }
            // Plain `.gesture`, not `.highPriorityGesture`: the delete button is
            // a child and has to keep winning its own taps. Being a child of the
            // page switcher is enough to outrank its swipe.
            .gesture(rearrangeGesture, including: jiggling ? .all : .subviews)
            .onChange(of: jiggling) { _, active in
                guard active else {
                    pressed = false
                    lifted = false
                    return
                }
            }
            // Recorded into a plain box, never into state — see IconFrameBox.
            .recordGlobalFrame(record)
    }

    /// Stable per-icon phase so neighbouring icons do not move in lock-step.
    private var jiggleSeed: Double {
        let scalarSum = item.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double(scalarSum % 360) * .pi / 180
    }

    private func record(_ rect: CGRect) {
        frame.rect = rect
        registry?.record(rect, for: item.id)
    }

    /// Pick up, carry, drop. The icon itself does not move: the springboard
    /// draws the one under your finger and reshuffles the rest as the drop
    /// target changes, which is what lets an icon land anywhere — another slot,
    /// the dock, or a page it was dragged to.
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

    private var content: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let app {
                        IconArtwork(app: app, size: size)
                    } else if let folder {
                        FolderIcon(folder: folder, size: size)
                    } else {
                            PackageIcon(url: guest?.iconURL, tint: nil, size: size)
                    }
                }
                // Modern iOS icons are matte. A small neutral shadow separates
                // the tile from bright wallpaper without adding a coloured
                // glow or a skeuomorphic gloss layer.
                .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                .opacity(hidden || carried ? 0 : 1)
                .overlay(alignment: .topTrailing) {
                    if let badge = app?.badge, !jiggling, !hidden {
                        BadgeView(count: badge).offset(x: 7, y: -6)
                    }
                }

                if jiggling {
                    // A real Button so it wins the press against the parent's
                    // tap gesture.
                    Button(action: onDelete) {
                        Image(systemName: "minus")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color(hex: "CFC2B2")))
                            .overlay(Circle().strokeBorder(Palette.ink.opacity(0.2), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: -8, y: -8)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)

            if showsLabel {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.72), radius: 2, y: 1)
                    .lineLimit(1)
                    .opacity(hidden || carried ? 0 : 1)
            }
        }
    }
}

struct BadgeView: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, count > 9 ? 6 : 0)
            .frame(minWidth: 21, minHeight: 21)
            .background(Capsule().fill(Color(uiColor: .systemRed)))
            .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
    }
}
