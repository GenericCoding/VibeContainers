import SwiftUI

/// Home screen page transitions, in the spirit of the old WinterBoard tweaks.
enum PageTransition: String, CaseIterable, Identifiable {
    case slide, cube, barrelRoll, flip, carousel, fade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slide: "Slide"
        case .cube: "Cube"
        case .barrelRoll: "Barrel Roll"
        case .flip: "Flip"
        case .carousel: "Carousel"
        case .fade: "Fade"
        }
    }

    var detail: String {
        switch self {
        case .slide: "The stock horizontal push."
        case .cube: "Pages hinge on a rotating cube."
        case .barrelRoll: "A full spin as the page flies past."
        case .flip: "The page turns over in place."
        case .carousel: "Pages angle away into depth."
        case .fade: "A soft cross-dissolve."
        }
    }
}

/// Places a page according to how far it sits from the one on screen.
///
/// `offset` is the page's position relative to the visible one — 0 while it is
/// centred, ±1 when a full page away — so it tracks the drag continuously
/// rather than only animating at the end of a swipe.
struct PageTransitionModifier: ViewModifier {
    let style: PageTransition
    let offset: CGFloat
    let width: CGFloat
    let reducesMotion: Bool

    private var distance: CGFloat { min(abs(offset), 1) }
    private var effectOffset: CGFloat { reducesMotion ? 0 : offset }
    private var effectDistance: CGFloat { reducesMotion ? 0 : distance }
    private var flipOpacity: CGFloat {
        // Cross-fade through the edge-on portion of the flip. A hard cutoff at
        // exactly 90 degrees can leave both pages invisible for a frame.
        min(1, max(0, (0.58 - effectDistance) / 0.16))
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            switch style {
            case .slide:
                content
                    .offset(x: effectOffset * width)

            case .cube:
                // Each page hinges on the edge it shares with its neighbour.
                content
                    .rotation3DEffect(
                        .degrees(Double(-effectOffset) * 90),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: offset > 0 ? .leading : .trailing,
                        perspective: 0.55
                    )
                    .offset(x: effectOffset * width)

            case .barrelRoll:
                content
                    .scaleEffect(1 - effectDistance * 0.32)
                    .rotationEffect(.degrees(Double(effectOffset) * 360))
                    .offset(x: effectOffset * width)

            case .flip:
                // Fade across the edge-on interval so the outgoing and
                // incoming faces exchange cleanly without showing a mirror.
                content
                    .opacity(flipOpacity)
                    .rotation3DEffect(
                        .degrees(Double(effectOffset) * 180),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.5
                    )

            case .carousel:
                content
                    .scaleEffect(1 - effectDistance * 0.28)
                    .rotation3DEffect(
                        .degrees(Double(-effectOffset) * 42),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.6
                    )
                    .offset(x: effectOffset * width * 0.88)
                    .opacity(1 - effectDistance * 0.55)

            case .fade:
                content
                    .scaleEffect(1 - effectDistance * 0.12)
                    .opacity(1 - effectDistance)
            }
        }
        // Keep modifier topology stable if Reduce Motion changes while a page
        // is alive. Its reduced presentation is a cross-fade with just enough
        // translation to remain connected to the finger.
        .offset(x: reducesMotion ? offset * width * 0.06 : 0)
        .opacity(reducesMotion ? max(0, 1 - distance) : 1)
    }
}

/// A paging container that exposes its own progress, which `TabView`'s page
/// style does not — without that, a transition can only animate after the
/// swipe instead of tracking your finger.
struct PageSwitcher<Content: View>: View {
    let count: Int
    @Binding var index: Int
    let style: PageTransition
    let size: CGSize
    /// Springboard disables swipe paging while icons jiggle; edge-hover owns
    /// page changes during a rearrangement.
    let pagingEnabled: Bool
    /// The gesture that picked an icon up belongs to its source page. Keeping
    /// that page interactive while it slides away prevents SwiftUI from
    /// cancelling the drag halfway through a cross-page move.
    let keepsPagesInteractive: Bool
    /// Lets interactive page content suppress its tap actions as soon as this
    /// container commits to a horizontal swipe.
    var onHorizontalSwipeChanged: (Bool) -> Void = { _ in }
    @ViewBuilder var page: (Int) -> Content

    @State private var drag: CGFloat = 0
    @State private var dragAxis: Axis?
    @GestureState private var horizontalSwipeActive = false
    @State private var suppressionReleaseToken = UUID()
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var progress: CGFloat {
        CGFloat(index) - drag / max(size.width, 1)
    }

    private var reducesMotion: Bool {
        accessibilityReduceMotion || Appearance.shared.reduceMotion
    }

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { pageIndex in
                let offset = CGFloat(pageIndex) - progress

                page(pageIndex)
                    .frame(width: size.width, height: size.height)
                    .modifier(PageTransitionModifier(
                        style: style,
                        offset: offset,
                        width: size.width,
                        reducesMotion: reducesMotion
                    ))
                    // Neighbours only; anything further out is off screen.
                    .opacity(abs(offset) > 1.02 ? 0 : 1)
                    .zIndex(-Double(abs(offset)))
                    .allowsHitTesting(keepsPagesInteractive || abs(offset) < 0.02)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        // Run alongside a page's vertical ScrollView. Once the gesture has a
        // clear axis, only horizontal movement drives the pager; this makes the
        // left-hand News panel both easy to scroll and easy to swipe away.
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .updating($horizontalSwipeActive) { value, active, _ in
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    if active || (horizontal >= 8 && horizontal > vertical * 1.08) {
                        active = true
                    }
                }
                .onChanged { value in
                    if dragAxis == nil {
                        let horizontal = abs(value.translation.width)
                        let vertical = abs(value.translation.height)
                        guard max(horizontal, vertical) >= 8 else { return }
                        dragAxis = horizontal > vertical * 1.08 ? .horizontal : .vertical
                        if dragAxis == .horizontal {
                            // Report directly from the recognizer instead of
                            // waiting for a GestureState-driven view update.
                            // A quick flick can otherwise end before child
                            // buttons observe the suppressed state.
                            suppressionReleaseToken = UUID()
                            onHorizontalSwipeChanged(true)
                        }
                    }
                    guard dragAxis == .horizontal else { return }

                    // Resist dragging past the first and last page.
                    let raw = value.translation.width
                    let atStart = index == 0 && raw > 0
                    let atEnd = index == count - 1 && raw < 0
                    drag = (atStart || atEnd) ? rubberBanded(raw) : raw
                }
                .onEnded { value in
                    let wasHorizontal = dragAxis == .horizontal
                    dragAxis = nil
                    guard wasHorizontal else {
                        drag = 0
                        return
                    }

                    // A slightly shorter commit distance makes the side panel
                    // dismiss reliably without making a vertical feed scroll
                    // turn the page (the axis lock above still owns that).
                    let threshold = size.width * 0.16
                    let flick = value.predictedEndTranslation.width
                    var target = index

                    if value.translation.width < -threshold || flick < -size.width * 0.34 {
                        target = min(count - 1, index + 1)
                    } else if value.translation.width > threshold || flick > size.width * 0.34 {
                        target = max(0, index - 1)
                    }

                    if target != index { Haptics.selection() }

                    withAnimation(settleAnimation) {
                        index = target
                        drag = 0
                    }

                    scheduleSuppressionRelease()
                },
            including: pagingEnabled ? .all : .none
        )
        .onChange(of: horizontalSwipeActive) { _, active in
            // `onEnded` owns the normal release. This also covers a gesture
            // cancelled by SwiftUI after it had become horizontal.
            if !active { scheduleSuppressionRelease() }
        }
        .onChange(of: pagingEnabled) { _, enabled in
            guard !enabled else { return }
            dragAxis = nil
            drag = 0
            suppressionReleaseToken = UUID()
            onHorizontalSwipeChanged(false)
        }
    }

    private func scheduleSuppressionRelease() {
        let token = UUID()
        suppressionReleaseToken = token
        // Keep child controls disarmed until the page spring has settled. In a
        // vertical ScrollView, Button recognition may finish after touch-up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard suppressionReleaseToken == token else { return }
            onHorizontalSwipeChanged(false)
        }
    }

    /// The same diminishing resistance UIScrollView applies beyond an edge,
    /// instead of a linear multiplier that feels increasingly elastic.
    private func rubberBanded(_ translation: CGFloat) -> CGFloat {
        let dimension = max(size.width, 1)
        let magnitude = abs(translation)
        let resisted = (1 - 1 / (magnitude * 0.42 / dimension + 1)) * dimension
        return translation < 0 ? -resisted : resisted
    }

    private var settleAnimation: Animation {
        if accessibilityReduceMotion {
            .easeOut(duration: 0.16)
        } else {
            Appearance.shared.animation(.gestureSettle)
        }
    }
}
