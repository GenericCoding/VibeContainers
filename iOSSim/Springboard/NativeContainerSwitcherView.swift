import SwiftUI
import UIKit

/// A host-owned recreation of the iPhone app switcher for independently
/// running LiveContainer scenes.
struct ContainerSwitcherView: View {
    let entries: [RunningContainerStore.Entry]
    let onFocus: (RunningContainerStore.Entry) -> Void
    let onTerminate: (RunningContainerStore.Entry) -> Bool
    let onRetry: (RunningContainerStore.Entry) -> Void
    let onHome: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.deviceSafeArea) private var safeArea
    @State private var runningContainers = RunningContainerStore.shared
    @State private var committedDismissOffset: CGFloat = 0
    @GestureState(
        reset: { value, transaction in
            transaction.animation = value.reducesMotion
                ? .reducedMotionFade
                : .gestureSettle
        }
    ) private var dismissDrag = DismissDragState()

    private enum DismissDragAxis {
        case undecided
        case vertical
        case rejected
    }

    private struct DismissDragState {
        var axis: DismissDragAxis = .undecided
        var offset: CGFloat = 0
        var reducesMotion = false
    }

    private var displayedEntries: [RunningContainerStore.Entry] {
        entries.filter {
            if case .terminated = $0.phase { return false }
            return true
        }
    }

    private var reducesMotion: Bool {
        accessibilityReduceMotion || Appearance.shared.reduceMotion
    }

    var body: some View {
        GeometryReader { geometry in
            let dismissOffset = max(
                dismissDrag.offset,
                committedDismissOffset
            )
            let dismissProgress = min(
                1,
                dismissOffset / max(1, geometry.size.height * 0.18)
            )

            ZStack {
                NativeSwitcherBackdrop(onDismiss: dismiss)

                if displayedEntries.isEmpty {
                    NativeSwitcherEmptyState(onDismiss: dismiss)
                } else {
                    switcherCards(in: geometry.size)
                }

                NativeSwitcherHomeIndicator(onDismiss: dismiss)
                    .padding(.bottom, max(4, safeArea.bottom - 5))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .offset(y: reducesMotion ? 0 : dismissOffset)
            .scaleEffect(
                reducesMotion ? 1 : 1 - dismissProgress * 0.018,
                anchor: .bottom
            )
            .opacity(
                1 - Double(dismissProgress) * (reducesMotion ? 0.34 : 0.10)
            )
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .simultaneousGesture(dismissGesture)
        .transition(presentationTransition)
        // SwiftUI can keep an outgoing transition mounted for a few frames.
        // Disarm it as soon as the store dismisses so the focused guest never
        // inherits an invisible full-screen touch interceptor.
        .allowsHitTesting(runningContainers.isSwitcherPresented)
        .accessibilityAddTraits(.isModal)
    }

    private func switcherCards(in size: CGSize) -> some View {
        let metrics = NativeSwitcherMetrics(
            containerSize: size,
            safeArea: safeArea,
            isPad: UIDevice.current.userInterfaceIdiom == .pad
        )
        let motionIsReduced = reducesMotion

        return ScrollView(.horizontal) {
            LazyHStack(alignment: .center, spacing: metrics.cardSpacing) {
                ForEach(displayedEntries) { entry in
                    NativeContainerSwitcherCard(
                        entry: entry,
                        previewView: runningContainers.previewView(for: entry.dataUUID),
                        preview: runningContainers.preview(for: entry.dataUUID),
                        width: metrics.cardWidth,
                        previewHeight: metrics.previewHeight,
                        onActivate: { activate(entry) },
                        onTerminate: { onTerminate(entry) }
                    )
                    .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                        let progress = CGFloat(min(1, abs(phase.value)))

                        return content
                            .scaleEffect(
                                motionIsReduced ? 1 : 1 - progress * 0.055
                            )
                            .offset(y: motionIsReduced ? 0 : progress * 9)
                            .opacity(
                                1 - Double(progress)
                                    * (motionIsReduced ? 0.07 : 0.11)
                            )
                    }
                    .transition(cardTransition)
                }
            }
            .scrollTargetLayout()
            .animation(
                motionIsReduced ? nil : .interfaceSpring,
                value: displayedEntries.map(\.id)
            )
        }
        .contentMargins(
            .horizontal,
            max(18, (size.width - metrics.cardWidth) / 2),
            for: .scrollContent
        )
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollBounceBehavior(.basedOnSize)
        .scrollClipDisabled()
        .frame(height: metrics.totalCardHeight)
    }

    private var presentationTransition: AnyTransition {
        if reducesMotion {
            .opacity.animation(.reducedMotionFade)
        } else {
            .asymmetric(
                insertion: .opacity
                    .combined(with: .scale(scale: 0.955, anchor: .bottom))
                    .animation(.interfaceSpring),
                removal: .opacity
                    .combined(with: .scale(scale: 0.985, anchor: .bottom))
                    .animation(.windowClose)
            )
        }
    }

    private var cardTransition: AnyTransition {
        if reducesMotion {
            .opacity
        } else {
            .opacity.combined(with: .scale(scale: 0.96))
        }
    }

    private func activate(_ entry: RunningContainerStore.Entry) {
        switch entry.phase {
        case .failed:
            onRetry(entry)
        case .launching, .running:
            onFocus(entry)
        case .terminated:
            break
        }
    }

    private func dismiss() {
        Haptics.tap(.light)
        onHome()
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .updating($dismissDrag) { value, state, _ in
                updateDismissDrag(value.translation, state: &state)
            }
            .onEnded { value in
                let translation = value.translation
                let projectedTranslation = value.predictedEndTranslation
                let isDownward = translation.height > 0
                    && translation.height > abs(translation.width) * 1.2
                let isProjectedDownward = projectedTranslation.height > 0
                    && projectedTranslation.height
                        > abs(projectedTranslation.width) * 1.2

                let shouldDismiss = dismissDrag.axis == .vertical
                    && isDownward
                    && isProjectedDownward
                    && (translation.height > 44
                        || projectedTranslation.height > 90)

                guard shouldDismiss else { return }

                committedDismissOffset = resistedDismissDistance(
                    for: translation.height
                )
                dismiss()
            }
    }

    private func updateDismissDrag(
        _ translation: CGSize,
        state: inout DismissDragState
    ) {
        state.reducesMotion = reducesMotion

        if state.axis == .undecided {
            let horizontalDistance = abs(translation.width)
            let verticalDistance = abs(translation.height)

            if translation.height > horizontalDistance * 1.2 {
                state.axis = .vertical
            } else if horizontalDistance > verticalDistance * 1.2 {
                state.axis = .rejected
            }
        }

        guard state.axis == .vertical else { return }
        state.offset = resistedDismissDistance(for: translation.height)
    }

    private func resistedDismissDistance(for rawDistance: CGFloat) -> CGFloat {
        let distance = max(0, rawDistance)
        let resistanceStart: CGFloat = 120
        guard distance > resistanceStart else { return distance }
        return resistanceStart + (distance - resistanceStart) * 0.38
    }
}

private struct NativeSwitcherMetrics {
    let cardWidth: CGFloat
    let previewHeight: CGFloat
    let cardSpacing: CGFloat
    let totalCardHeight: CGFloat

    init(containerSize: CGSize, safeArea: EdgeInsets, isPad: Bool) {
        let safeHeight = max(1, containerSize.height - safeArea.top - safeArea.bottom)
        let labelHeight: CGFloat = 34
        let labelSpacing: CGFloat = 10
        let verticalReserve: CGFloat = isPad ? 126 : 108
        let maximumPreviewHeight = max(190, safeHeight - verticalReserve)
        let maximumCardWidth = min(
            isPad ? 520 : 430,
            containerSize.width * (isPad ? 0.58 : 0.80)
        )
        let screenAspect = max(0.2, containerSize.width / max(1, containerSize.height))
        let aspectFittedHeight = maximumCardWidth / screenAspect

        previewHeight = min(maximumPreviewHeight, aspectFittedHeight)
        cardWidth = min(maximumCardWidth, previewHeight * screenAspect)
        cardSpacing = isPad ? 22 : 14
        totalCardHeight = labelHeight + labelSpacing + previewHeight
    }
}

private struct NativeSwitcherBackdrop: View {
    let onDismiss: () -> Void

    var body: some View {
        Button("Close App Switcher", action: onDismiss)
            .buttonStyle(NativeSwitcherBackdropButtonStyle())
            .accessibilityHint("Returns to the VibeContainers Home Screen")
    }
}

private struct NativeSwitcherBackdropButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay {
                Color.black.opacity(configuration.isPressed ? 0.28 : 0.20)
            }
            .contentShape(Rectangle())
    }
}

private struct NativeSwitcherHomeIndicator: View {
    let onDismiss: () -> Void

    var body: some View {
        Button("Return to Home", action: onDismiss)
            .buttonStyle(NativeSwitcherHomeIndicatorButtonStyle())
            .accessibilityHint("Closes the app switcher")
    }
}

private struct NativeSwitcherHomeIndicatorButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(.white.opacity(configuration.isPressed ? 0.62 : 0.88))
            .frame(width: 134, height: 5)
            .frame(width: 180, height: 44)
            .contentShape(Rectangle())
    }
}

private struct NativeSwitcherEmptyState: View {
    let onDismiss: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Open Apps", systemImage: "rectangle.stack.badge.minus")
        } description: {
            Text("Open a container to see it here.")
        } actions: {
            Button("Return to Home", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(28)
    }
}

private struct NativeContainerSwitcherCard: View {
    let entry: RunningContainerStore.Entry
    let previewView: UIView?
    let preview: UIImage?
    let width: CGFloat
    let previewHeight: CGFloat
    let onActivate: () -> Void
    let onTerminate: () -> Bool

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var verticalOffset: CGFloat = 0
    @State private var isClosing = false

    private var reducesMotion: Bool {
        accessibilityReduceMotion || Appearance.shared.reduceMotion
    }

    var body: some View {
        VStack(spacing: 10) {
            appLabel
            appPreview
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .overlay {
            NativeSwitcherCardInteractionView(
                isEnabled: !isClosing,
                onTap: activate,
                onSwipeChanged: updateCloseDrag,
                onSwipeEnded: finishCloseDrag
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
        }
        .offset(y: reducesMotion ? 0 : verticalOffset)
        .opacity(closeOpacity)
        .scaleEffect(closeScale, anchor: .top)
        .allowsHitTesting(!isClosing)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(entry.displayName), \(phaseLabel)")
        .accessibilityHint("Double tap to switch. Swipe up to close.")
        .accessibilityAction(.default) { activate() }
        .accessibilityAction(named: "Close") { close() }
    }

    private var appLabel: some View {
        HStack(spacing: 9) {
            NativeContainerSwitcherIcon(
                bundleIdentifier: entry.bundleIdentifier,
                size: 30
            )
            Text(entry.displayName)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 34)
        .padding(.horizontal, 3)
        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
    }

    private var appPreview: some View {
        ZStack {
            Color.black

            // Prefer the independently captured render-server bitmap. Its
            // pixel dimensions are validated before it reaches this view,
            // whereas UIKit may return a snapshot-presentation UIView whose
            // remote layer is not drawable after the source scene is hidden.
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .accessibilityHidden(true)
            } else if let previewView {
                NativeSceneSnapshotView(snapshotView: previewView)
                    .accessibilityHidden(true)
            } else {
                missingPreview
            }

            switch entry.phase {
            case .launching:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(18)
                    .background(.thinMaterial, in: Circle())
            case .failed(let message):
                failedOverlay(message: message)
            case .running, .terminated:
                EmptyView()
            }
        }
        .frame(width: width, height: previewHeight)
        .clipShape(.rect(cornerRadius: 32))
        .overlay {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.48), radius: 24, y: 16)
        .contentShape(.rect(cornerRadius: 32))
    }

    private var missingPreview: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.72), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            NativeContainerSwitcherIcon(
                bundleIdentifier: entry.bundleIdentifier,
                size: min(96, width * 0.30)
            )
            .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
        }
    }

    private func failedOverlay(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title)
            Text("Tap to Try Again")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(24)
    }

    private func updateCloseDrag(translationY: CGFloat) {
        guard !isClosing else { return }
        verticalOffset = -resistedCloseDistance(for: max(0, -translationY))
    }

    private func finishCloseDrag(
        translationY: CGFloat,
        projectedTranslationY: CGFloat,
        wasCancelled: Bool
    ) {
        guard !isClosing else { return }
        guard !wasCancelled else {
            restoreCard()
            return
        }

        let isReversing = projectedTranslationY > translationY + 44
        let crossedDistance = translationY < -72
        let hasClosingMomentum = projectedTranslationY < -125
        if !isReversing && (crossedDistance || hasClosingMomentum) {
            Haptics.tap(.medium)
            close()
        } else {
            restoreCard()
        }
    }

    private func activate() {
        guard !isClosing else { return }
        onActivate()
    }

    private func close() {
        guard !isClosing else { return }
        withAnimation(
            reducesMotion
                ? .reducedMotionFade
                : .windowClose,
            completionCriteria: .logicallyComplete
        ) {
            verticalOffset = -(previewHeight + 110)
            isClosing = true
        } completion: {
            guard isClosing else { return }
            guard onTerminate() else {
                restoreCard(animation: .interfaceSpring)
                return
            }

            // LiveContainer normally confirms the scene disconnection and
            // removes this view. If its kill fallback stalls, keep local state
            // recoverable so the store can reveal a usable card again.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4.5))
                guard isClosing else { return }
                restoreCard(animation: .interfaceSpring)
            }
        }
    }

    private func restoreCard(animation: Animation = .gestureSettle) {
        withAnimation(
            reducesMotion
                ? .reducedMotionFade
                : animation
        ) {
            verticalOffset = 0
            isClosing = false
        }
    }

    private func resistedCloseDistance(for distance: CGFloat) -> CGFloat {
        let resistanceStart = max(84, min(150, previewHeight * 0.22))
        guard distance > resistanceStart else { return distance }
        return resistanceStart + (distance - resistanceStart) * 0.58
    }

    private var closeProgress: CGFloat {
        let progressDistance = max(120, min(210, previewHeight * 0.30))
        return min(1, max(0, -verticalOffset / progressDistance))
    }

    private var closeOpacity: Double {
        guard !isClosing else { return 0 }
        let fadeAmount = reducesMotion ? 0.34 : 0.11
        return 1 - Double(closeProgress) * fadeAmount
    }

    private var closeScale: CGFloat {
        guard !reducesMotion else { return 1 }
        return 1 - closeProgress * 0.055 - (isClosing ? 0.035 : 0)
    }

    private var phaseLabel: String {
        switch entry.phase {
        case .launching: "Opening"
        case .running: "Running"
        case .failed: "Try Again"
        case .terminated: "Closed"
        }
    }

    private var accent: Color {
        let palette: [Color] = [.indigo, .purple, .cyan, .blue, .pink, .mint]
        let value = entry.bundleIdentifier.unicodeScalars.reduce(0) {
            ($0 &* 31) &+ Int($1.value)
        }
        return palette[abs(value) % palette.count]
    }
}

/// Owns only an upward, predominantly vertical pan. Failing horizontal pans
/// at recognition time lets the enclosing horizontal `ScrollView` page even
/// when a swipe begins over the preview instead of the label or card margins.
private struct NativeSwitcherCardInteractionView: UIViewRepresentable {
    let isEnabled: Bool
    let onTap: () -> Void
    let onSwipeChanged: (_ translationY: CGFloat) -> Void
    let onSwipeEnded: (
        _ translationY: CGFloat,
        _ projectedTranslationY: CGFloat,
        _ wasCancelled: Bool
    ) -> Void

    func makeUIView(context: Context) -> NativeSwitcherCardInteractionHostView {
        let hostView = NativeSwitcherCardInteractionHostView(frame: .zero)
        update(hostView)
        return hostView
    }

    func updateUIView(
        _ hostView: NativeSwitcherCardInteractionHostView,
        context: Context
    ) {
        update(hostView)
    }

    private func update(_ hostView: NativeSwitcherCardInteractionHostView) {
        hostView.isUserInteractionEnabled = isEnabled
        hostView.onTap = onTap
        hostView.onSwipeChanged = onSwipeChanged
        hostView.onSwipeEnded = onSwipeEnded
    }
}

private final class NativeSwitcherCardInteractionHostView: UIView,
    UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?
    var onSwipeChanged: ((CGFloat) -> Void)?
    var onSwipeEnded: ((CGFloat, CGFloat, Bool) -> Void)?

    private lazy var swipeRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleSwipe(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var tapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTap)
        )
        recognizer.require(toFail: swipeRecognizer)
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        addGestureRecognizer(swipeRecognizer)
        addGestureRecognizer(tapRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === swipeRecognizer else { return true }
        let velocity = swipeRecognizer.velocity(in: gestureCoordinateView)
        return velocity.y < 0 && abs(velocity.y) > abs(velocity.x) * 1.15
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === swipeRecognizer
            || otherGestureRecognizer === swipeRecognizer
    }

    @objc private func handleTap() {
        onTap?()
    }

    @objc private func handleSwipe(_ recognizer: UIPanGestureRecognizer) {
        let translationY = recognizer.translation(in: gestureCoordinateView).y

        switch recognizer.state {
        case .began, .changed:
            onSwipeChanged?(translationY)
        case .ended:
            let projectedTranslationY = translationY
                + recognizer.velocity(in: gestureCoordinateView).y * 0.2
            onSwipeEnded?(translationY, projectedTranslationY, false)
        case .cancelled, .failed:
            onSwipeEnded?(translationY, translationY, true)
        case .possible:
            break
        @unknown default:
            onSwipeEnded?(translationY, translationY, true)
        }
    }

    /// The card itself scales and translates during the drag. Reading the pan
    /// in its window keeps those visual transforms from feeding back into the
    /// recognizer's translation and velocity.
    private var gestureCoordinateView: UIView {
        window ?? self
    }
}

/// Rehosts UIKit's render-server snapshot without converting it to a UIImage.
/// Remote FBScene pixels live in a cross-process IOSurface, so keeping the
/// snapshot presentation view intact is what lets the card show real content.
private struct NativeSceneSnapshotView: UIViewRepresentable {
    let snapshotView: UIView

    func makeUIView(context: Context) -> NativeSceneSnapshotHostView {
        NativeSceneSnapshotHostView(snapshotView: snapshotView)
    }

    func updateUIView(_ hostView: NativeSceneSnapshotHostView, context: Context) {
        hostView.setSnapshotView(snapshotView)
    }

    static func dismantleUIView(
        _ hostView: NativeSceneSnapshotHostView,
        coordinator: Void
    ) {
        hostView.setSnapshotView(nil)
    }
}

private final class NativeSceneSnapshotHostView: UIView {
    private var snapshotView: UIView?
    private var sourceSize: CGSize = .zero

    init(snapshotView: UIView) {
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
        setSnapshotView(snapshotView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setSnapshotView(_ newSnapshotView: UIView?) {
        guard snapshotView !== newSnapshotView else { return }
        snapshotView?.removeFromSuperview()
        snapshotView = newSnapshotView
        sourceSize = newSnapshotView?.bounds.size ?? .zero
        guard let newSnapshotView else { return }
        newSnapshotView.removeFromSuperview()
        newSnapshotView.isUserInteractionEnabled = false
        newSnapshotView.accessibilityElementsHidden = true
        addSubview(newSnapshotView)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let snapshotView,
              sourceSize.width > 0,
              sourceSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else { return }

        let scale = max(
            bounds.width / sourceSize.width,
            bounds.height / sourceSize.height
        )
        snapshotView.transform = .identity
        snapshotView.bounds = CGRect(origin: .zero, size: sourceSize)
        snapshotView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        snapshotView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

private struct NativeContainerSwitcherIcon: View {
    let bundleIdentifier: String
    let size: CGFloat

    private var iconURL: String? {
        PackageStore.shared.installed[bundleIdentifier]?.iconURL
    }

    var body: some View {
        PackageIcon(url: iconURL, tint: nil, size: size)
    }
}
