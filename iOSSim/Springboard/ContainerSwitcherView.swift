import SwiftUI

/// An adaptive view over LiveContainer's running remote scenes.
///
/// iPhone uses the familiar horizontally paged card switcher. A wide iPad
/// canvas becomes a Stage Manager-inspired rail and card grid, while retaining
/// the same focus and terminate actions underneath.
private struct LegacyContainerSwitcherView: View {
    let entries: [RunningContainerStore.Entry]
    let onFocus: (RunningContainerStore.Entry) -> Void
    let onTerminate: (RunningContainerStore.Entry) -> Bool
    let onRetry: (RunningContainerStore.Entry) -> Void
    let onHome: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.deviceSafeArea) private var safeArea

    private var displayedEntries: [RunningContainerStore.Entry] {
        entries.filter {
            if case .terminated = $0.phase { return false }
            return true
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.30),
                        Color(hex: "11152A").opacity(0.55),
                        Color.black.opacity(0.48)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // A landscape iPhone can be wider than a compact iPad window,
                // but it must remain the phone switcher. Stage Manager is an
                // iPad presentation, not a raw-width breakpoint.
                if UIDevice.current.userInterfaceIdiom == .pad,
                   geometry.size.width >= 700 {
                    stageManager(size: geometry.size)
                } else {
                    phoneSwitcher(size: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.04)))
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - iPhone

    private func phoneSwitcher(size: CGSize) -> some View {
        let cardWidth = min(370, size.width * 0.78)
        let usableHeight = max(1, size.height - safeArea.top - safeArea.bottom)
        let compactHeight = usableHeight < 520
        let cardHeight = compactHeight
            ? max(180, min(300, usableHeight - 160))
            : min(530, max(350, usableHeight * 0.60))
        let topInset = compactHeight
            ? max(8, safeArea.top + 8)
            : max(safeArea.top + 12, size.height * 0.055)
        let bottomInset = compactHeight
            ? max(8, safeArea.bottom + 4)
            : max(safeArea.bottom + 12, size.height * 0.045)

        return VStack(spacing: 0) {
            switcherHeader(title: "App Switcher", subtitle: statusSummary)
                .padding(.top, topInset)
                .padding(.horizontal, 22)

            Spacer(minLength: compactHeight ? 4 : 18)

            if displayedEntries.isEmpty {
                emptyState
                    .frame(maxHeight: cardHeight)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 18) {
                        ForEach(displayedEntries) { entry in
                            SwitcherCard(
                                entry: entry,
                                width: cardWidth,
                                height: cardHeight,
                                isFrontmost: entry.id == displayedEntries.first?.id,
                                closeButtonVisible: false,
                                onActivate: { activate(entry) },
                                onTerminate: { onTerminate(entry) }
                            )
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1 : 0.91)
                                    .opacity(phase.isIdentity ? 1 : 0.68)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, max(22, (size.width - cardWidth) / 2), for: .scrollContent)
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .frame(height: cardHeight + (compactHeight ? 8 : 20))
            }

            Spacer(minLength: compactHeight ? 4 : 12)

            VStack(spacing: compactHeight ? 6 : 12) {
                if !compactHeight, !displayedEntries.isEmpty {
                    Label("Swipe a card up to close", systemImage: "hand.draw")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                homeButton
            }
            .padding(.horizontal, 24)
            .padding(.bottom, bottomInset)
        }
    }

    // MARK: - iPad / wide canvas

    private func stageManager(size: CGSize) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                switcherHeader(title: "Stage Manager", subtitle: statusSummary)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(displayedEntries) { entry in
                            StageSidebarRow(
                                entry: entry,
                                isFrontmost: entry.id == displayedEntries.first?.id,
                                onActivate: { activate(entry) }
                            )
                        }
                    }
                }

                Spacer(minLength: 0)
                homeButton
            }
            .padding(.top, max(40, safeArea.top + 16))
            .padding(.bottom, max(30, safeArea.bottom + 16))
            .padding(.horizontal, 22)
            .frame(width: min(260, size.width * 0.28))
            .background(.black.opacity(0.20))

            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(width: 1)

            if displayedEntries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 270, maximum: 440), spacing: 24)],
                        spacing: 24
                    ) {
                        ForEach(displayedEntries) { entry in
                            SwitcherCard(
                                entry: entry,
                                width: 340,
                                height: 430,
                                isFrontmost: entry.id == displayedEntries.first?.id,
                                closeButtonVisible: true,
                                onActivate: { activate(entry) },
                                onTerminate: { onTerminate(entry) }
                            )
                            .frame(maxWidth: 440)
                        }
                    }
                    .padding(32)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func activate(_ entry: RunningContainerStore.Entry) {
        switch entry.phase {
        case .failed:
            onRetry(entry)
        case .terminated:
            break
        case .launching, .running:
            onFocus(entry)
        }
    }

    private func switcherHeader(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 21, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer(minLength: 0)
        }
    }

    private var statusSummary: String {
        let count = displayedEntries.filter(\.phase.isActive).count
        return count == 1 ? "1 container open" : "\(count) containers open"
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.72))
            Text("No Open Containers")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Launch an installed app and it will appear here.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var homeButton: some View {
        Button {
            Haptics.tap(.light)
            onHome()
        } label: {
            Label("VibeContainers Home", systemImage: "house.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(.white.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

private struct SwitcherCard: View {
    let entry: RunningContainerStore.Entry
    let width: CGFloat
    let height: CGFloat
    let isFrontmost: Bool
    let closeButtonVisible: Bool
    let onActivate: () -> Void
    let onTerminate: () -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var verticalOffset: CGFloat = 0
    @State private var isClosing = false
    /// Once a drag has a clear direction it keeps it. Without this lock a
    /// horizontal page swipe whose predicted endpoint happened to drift up
    /// could close a card, while a vertical close could be stolen by paging.
    @State private var dragAxis: Axis?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                ContainerSwitcherIcon(bundleIdentifier: entry.bundleIdentifier, size: 30)
                Text(entry.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                phasePill
                if closeButtonVisible {
                    Button {
                        Haptics.tap(.medium)
                        close()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(entry.displayName)")
                }
            }
            .padding(.horizontal, 4)

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.82),
                                Color(hex: "161A31"),
                                Color.black.opacity(0.92)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(accent.opacity(0.28))
                    .frame(width: width * 0.92)
                    .blur(radius: 46)
                    .offset(x: -width * 0.25, y: -height * 0.28)

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.72))
                    .padding(18)
                    .overlay {
                        VStack(spacing: 18) {
                            Spacer(minLength: 0)
                            ContainerSwitcherIcon(
                                bundleIdentifier: entry.bundleIdentifier,
                                size: min(104, width * 0.29)
                            )
                            VStack(spacing: 6) {
                                Text(entry.displayName)
                                    .font(.system(size: 23, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(detailText)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.67))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            Spacer(minLength: 0)
                            if case .launching = entry.phase {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: callToActionSymbol)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                        }
                        .padding(36)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(isFrontmost ? 0.28 : 0.12), lineWidth: isFrontmost ? 1.2 : 0.6)
            }
            .shadow(color: .black.opacity(0.42), radius: 22, y: 14)
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .onTapGesture { onActivate() }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .offset(y: verticalOffset)
        .opacity(isClosing ? 0 : 1)
        .scaleEffect(isClosing && !reduceMotion ? 0.88 : 1)
        .simultaneousGesture(closeGesture)
        .accessibilityElement(children: closeButtonVisible ? .contain : .combine)
        .accessibilityLabel("\(entry.displayName), \(phaseText)")
        .accessibilityHint("Double tap to switch. Swipe up to close.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onActivate() }
        .accessibilityAction(named: "Close") { close() }
    }

    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isClosing else { return }
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)

                if dragAxis == nil {
                    // Wait for an intentional direction instead of assigning
                    // diagonal movement to whichever component is one point
                    // larger on the first callback.
                    guard max(horizontal, vertical) >= 14 else { return }
                    if vertical > horizontal * 1.15 {
                        dragAxis = .vertical
                    } else if horizontal > vertical * 1.15 {
                        dragAxis = .horizontal
                    } else {
                        return
                    }
                }

                guard dragAxis == .vertical, value.translation.height < 0 else { return }
                verticalOffset = value.translation.height * 0.72
            }
            .onEnded { value in
                let wasVertical = dragAxis == .vertical
                dragAxis = nil
                guard wasVertical else {
                    restoreCard()
                    return
                }

                // A deliberate displacement or a shorter, fast upward flick
                // closes. Horizontal paging never reaches this branch.
                let projected = min(value.translation.height, value.predictedEndTranslation.height)
                if value.translation.height < -72 || projected < -125 {
                    Haptics.tap(.medium)
                    close()
                } else {
                    restoreCard()
                }
            }
    }

    private func close() {
        guard !isClosing else { return }
        guard onTerminate() else {
            restoreCard()
            return
        }
        let animation: Animation = reduceMotion
            ? .linear(duration: 0.01)
            : .easeIn(duration: 0.2)
        withAnimation(animation) {
            verticalOffset = -height * 0.72
            isClosing = true
        }
        // A successful scene destruction removes this card through the runtime
        // close notification. AppSceneViewController gives a cooperative guest
        // three seconds before its SIGKILL fallback, so this UI watchdog must
        // outlive that runtime deadline instead of visibly resurrecting the
        // card while termination is still progressing.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.5))
            guard isClosing else { return }
            restoreCard()
        }
    }

    private func restoreCard() {
        withAnimation(
            reduceMotion
                ? .linear(duration: 0.01)
                : .spring(response: 0.3, dampingFraction: 0.82)
        ) {
            verticalOffset = 0
            isClosing = false
        }
    }

    private var phasePill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(phaseColor(entry.phase))
                .frame(width: 7, height: 7)
            Text(phaseText)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.84))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.white.opacity(0.10), in: Capsule())
    }

    private var accent: Color {
        let palette: [Color] = [.indigo, .purple, .cyan, .blue, .pink, .mint]
        let value = entry.bundleIdentifier.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(value) % palette.count]
    }

    private var phaseText: String {
        phaseLabel(entry.phase)
    }

    private var detailText: String {
        switch entry.phase {
        case .launching:
            "Preparing its independent scene…"
        case .running(let pid):
            pid.map { "Running independently • PID \($0)" } ?? "Running independently"
        case .failed(let message):
            "Launch failed • \(message)"
        case .terminated:
            "Closed"
        }
    }

    private var callToActionSymbol: String {
        if case .failed = entry.phase { return "arrow.clockwise.circle.fill" }
        return "arrow.up.forward.app.fill"
    }
}

private struct StageSidebarRow: View {
    let entry: RunningContainerStore.Entry
    let isFrontmost: Bool
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 12) {
                ContainerSwitcherIcon(bundleIdentifier: entry.bundleIdentifier, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(phaseLabel(entry.phase))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(phaseColor(entry.phase))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(isFrontmost ? 0.14 : 0.065))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ContainerSwitcherIcon: View {
    let bundleIdentifier: String
    let size: CGFloat

    private var iconURL: String? {
        PackageStore.shared.installed[bundleIdentifier]?.iconURL
    }

    var body: some View {
        PackageIcon(url: iconURL, tint: nil, size: size)
    }
}

private func phaseLabel(_ phase: RunningContainerStore.Phase) -> String {
    switch phase {
    case .launching: "Opening"
    case .running: "Running"
    case .failed: "Try Again"
    case .terminated: "Closed"
    }
}

private func phaseColor(_ phase: RunningContainerStore.Phase) -> Color {
    switch phase {
    case .launching: .orange
    case .running: .green
    case .failed: .red
    case .terminated: .secondary
    }
}
